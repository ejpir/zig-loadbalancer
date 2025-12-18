/// Single-Process Load Balancer
///
/// Uses std.Io.Threaded's internal thread pool for concurrency.
/// No fork(), no SO_REUSEPORT - just one process, one event loop.
///
/// Benefits:
/// - Works correctly on macOS (no SO_REUSEPORT kernel load balancing needed)
/// - Simpler architecture
/// - Shared connection pool across all requests
/// - Lower memory footprint (no process duplication)
const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.lb_sp);

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;
const Server = http.Server;
const Router = http.Router;
const Route = http.Route;

const types = @import("src/core/types.zig");
const simple_pool = @import("src/memory/simple_connection_pool.zig");
const metrics = @import("src/utils/metrics.zig");
const mp = @import("src/multiprocess/mod.zig");
const health = @import("src/multiprocess/health.zig");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

// ============================================================================
// Configuration
// ============================================================================

const BackendDef = struct {
    host: []const u8,
    port: u16,
    weight: u16 = 1,
};

const CliConfig = struct {
    port: u16,
    host: []const u8,
    strategy: types.LoadBalancerStrategy,
    backends: []BackendDef,
};

// ============================================================================
// CLI Parsing
// ============================================================================

fn parseArgs(allocator: std.mem.Allocator) !CliConfig {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var port: u16 = 8080;
    var host: []const u8 = "0.0.0.0";
    var strategy: types.LoadBalancerStrategy = .round_robin;

    var backend_list: std.ArrayListUnmanaged(BackendDef) = .empty;
    errdefer backend_list.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") or
            std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                port = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--host") or
                   std.mem.eql(u8, arg, "-h")) {
            if (i + 1 < args.len) {
                // Dupe host string - args freed after parseArgs returns.
                host = try allocator.dupe(u8, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--backend") or
                   std.mem.eql(u8, arg, "-b")) {
            if (i + 1 < args.len) {
                const backend_str = args[i + 1];
                if (std.mem.lastIndexOf(u8, backend_str, ":")) |colon| {
                    // Dupe host string - args freed after parseArgs returns.
                    const backend_host = try allocator.dupe(
                        u8,
                        backend_str[0..colon],
                    );
                    const port_str = backend_str[colon + 1 ..];
                    const backend_port = try std.fmt.parseInt(u16, port_str, 10);
                    try backend_list.append(
                        allocator,
                        .{ .host = backend_host, .port = backend_port },
                    );
                }
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--strategy") or
                   std.mem.eql(u8, arg, "-s")) {
            if (i + 1 < args.len) {
                if (std.mem.eql(u8, args[i + 1], "random")) {
                    strategy = .random;
                } else if (std.mem.eql(u8, args[i + 1], "weighted")) {
                    strategy = .weighted_round_robin;
                }
                i += 1;
            }
        }
    }

    // Provide defaults when user doesn't specify backends
    if (backend_list.items.len == 0) {
        try backend_list.append(
            allocator,
            .{ .host = "127.0.0.1", .port = 9001 },
        );
        try backend_list.append(
            allocator,
            .{ .host = "127.0.0.1", .port = 9002 },
        );
    }

    return .{
        .port = port,
        .host = host,
        .strategy = strategy,
        .backends = try backend_list.toOwnedSlice(allocator),
    };
}

// ============================================================================
// Main
// ============================================================================

var server: Server = undefined;

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const cli = try parseArgs(allocator);
    defer allocator.free(cli.backends);

    const backend_defs = cli.backends;

    // Connection pool (shared across all requests)
    var connection_pool = simple_pool.SimpleConnectionPool{};
    connection_pool.init();
    defer connection_pool.deinit();

    // Backends
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    for (backend_defs) |b| {
        try backends.append(allocator, types.BackendServer.init(b.host, b.port, b.weight));
    }
    connection_pool.addBackends(backends.items.len);

    // Worker state (health state, circuit breaker, backend selector)
    var worker_state = mp.WorkerState.init(&backends, &connection_pool, .{});
    worker_state.setWorkerId(0);

    log.warn("=== Single-Process Load Balancer ===", .{});
    log.warn("Listen: {s}:{d}, Backends: {d}", .{
        cli.host,
        cli.port,
        backends.items.len,
    });
    for (backends.items, 0..) |b, idx| {
        log.warn("  Backend {d}: {s}:{d}", .{ idx + 1, b.getHost(), b.port });
    }

    // Start health probe thread
    const health_thread = health.startHealthProbes(&worker_state, 0) catch |err| {
        log.err("Failed to start health probes: {s}", .{@errorName(err)});
        return err;
    };
    defer health_thread.detach();

    setupSignalHandlers();

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var router = switch (cli.strategy) {
        inline else => |s| try createRouter(allocator, &worker_state, s),
    };
    defer router.deinit(allocator);

    // No SO_REUSEPORT needed for single process
    const addr = try Io.net.IpAddress.parse(cli.host, cli.port);
    var socket = try addr.listen(io, .{
        .kernel_backlog = 4096,
        .reuse_address = true,
    });
    defer socket.deinit(io);

    log.warn("Listening on {s}:{d}", .{ cli.host, cli.port });

    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 32,
        .keepalive_count_max = null, // unlimited
        .connection_count_max = 10000,
    });
    defer server.deinit();

    try server.serve(io, &router, &socket);
}

fn setupSignalHandlers() void {
    posix.sigaction(posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
    posix.sigaction(posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
}

fn createRouter(
    allocator: std.mem.Allocator,
    state: *mp.WorkerState,
    comptime strategy: types.LoadBalancerStrategy,
) !Router {
    return try Router.init(allocator, &.{
        Route.init("/metrics").get({}, metrics.metricsHandler).layer(),
        Route.init("/").all(state, mp.generateHandler(strategy)).layer(),
    }, .{});
}
