/// Multi-Process Load Balancer (nginx-style architecture)
///
/// Each worker is a separate process with its own:
/// - Event loop (std.Io) - single-threaded, no locks!
/// - Connection pool - no atomics needed
/// - Health state - independent circuit breaker per worker
///
/// Benefits:
/// - Zero lock contention (nothing shared between workers)
/// - Crash isolation (one worker dies, master restarts it)
/// - SO_REUSEPORT for kernel-level load balancing
const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.lb_mp);

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;
const Server = http.Server;
const Router = http.Router;
const Route = http.Route;

const types = @import("src/core/types.zig");
const config_mod = @import("src/core/config.zig");
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

const LoadBalancerConfig = config_mod.LoadBalancerConfig;
const BackendDef = config_mod.BackendDef;

// ============================================================================
// CLI Parsing
// ============================================================================

fn parseArgs(allocator: std.mem.Allocator) !LoadBalancerConfig {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var worker_count: usize = 0; // 0 = auto-detect
    var port: u16 = 8080;
    var host: []const u8 = "0.0.0.0";
    var strategy: types.LoadBalancerStrategy = .round_robin;

    var backend_list: std.ArrayListUnmanaged(BackendDef) = .empty;
    errdefer backend_list.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--workers") or
            std.mem.eql(u8, arg, "-w")) {
            if (i + 1 < args.len) {
                worker_count = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--port") or
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
        .worker_count = worker_count,
        .port = port,
        .host = host,
        .backends = try backend_list.toOwnedSlice(allocator),
        .strategy = strategy,
    };
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var config = try parseArgs(allocator);
    defer allocator.free(config.backends);

    // Auto-detect worker count if not specified
    if (config.worker_count == 0) {
        config.worker_count = try std.Thread.getCpuCount();
    }

    // Validate configuration
    try config.validate();

    log.info("=== Multi-Process Load Balancer ===", .{});
    log.info("Workers: {d}, Listen: {s}:{d}, Backends: {d}", .{
        config.worker_count,
        config.host,
        config.port,
        config.backends.len,
    });
    for (config.backends, 0..) |b, idx| {
        log.info("  Backend {d}: {s}:{d}", .{ idx + 1, b.host, b.port });
    }

    try spawnWorkers(allocator, config);
}

// Spawn worker processes and monitor for crashes
fn spawnWorkers(allocator: std.mem.Allocator, config: LoadBalancerConfig) !void {
    var worker_pids = try allocator.alloc(posix.pid_t, config.worker_count);
    defer allocator.free(worker_pids);

    for (0..config.worker_count) |worker_id| {
        worker_pids[worker_id] = try forkWorker(&config, worker_id);
        log.info("Spawned worker {d} (PID: {d})", .{
            worker_id,
            worker_pids[worker_id],
        });
    }

    log.info("All workers started. Press Ctrl+C to stop.", .{});

    // Monitor and restart crashed workers
    while (true) {
        const result = posix.waitpid(-1, 0);
        if (result.pid > 0) {
            try restartWorker(&config, worker_pids, result.pid);
        }
    }
}

// Fork a single worker process
fn forkWorker(config: *const LoadBalancerConfig, worker_id: usize) !posix.pid_t {
    const pid = try posix.fork();
    if (pid == 0) {
        // CPU affinity is set INSIDE workerMain, AFTER Io.Threaded.init
        workerMain(config, worker_id) catch |err| {
            log.err("Worker {d} fatal: {s}", .{
                worker_id,
                @errorName(err),
            });
            posix.exit(1);
        };
        posix.exit(0);
    }
    return pid;
}

// Restart a crashed worker by finding it in the PID list
fn restartWorker(
    config: *const LoadBalancerConfig,
    worker_pids: []posix.pid_t,
    crashed_pid: posix.pid_t,
) !void {
    for (worker_pids, 0..) |pid, worker_id| {
        if (pid == crashed_pid) {
            log.warn("Worker {d} died, restarting...", .{worker_id});
            worker_pids[worker_id] = try forkWorker(config, worker_id);
            break;
        }
    }
}

// ============================================================================
// Worker Process
// ============================================================================

var server: Server = undefined;

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

fn workerMain(config: *const LoadBalancerConfig, worker_id: usize) !void {
    // Thread-safe allocator since health probes run in separate thread
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Connection pool
    var connection_pool = simple_pool.SimpleConnectionPool{};
    defer connection_pool.deinit();

    // Backends
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    for (config.backends) |b| {
        try backends.append(allocator, types.BackendServer.init(b.host, b.port, b.weight));
    }
    connection_pool.addBackends(backends.items.len);

    // Worker state (health state, circuit breaker, backend selector)
    // Pass health check configuration from unified config
    var worker_state = mp.WorkerState.init(&backends, &connection_pool, .{
        .unhealthy_threshold = config.unhealthy_threshold,
        .healthy_threshold = config.healthy_threshold,
        .probe_interval_ms = config.probe_interval_ms,
        .probe_timeout_ms = config.probe_timeout_ms,
        .health_path = config.health_path,
    });
    worker_state.setWorkerId(worker_id);

    log.info("Worker {d}: Starting with {d} backends", .{
        worker_id,
        backends.items.len,
    });
    log.debug("Worker {d}: Healthy count = {d}", .{
        worker_id,
        worker_state.circuit_breaker.countHealthy(),
    });

    // Start health probe thread (runs blocking I/O in separate thread)
    const health_thread = health.startHealthProbes(
        &worker_state,
        worker_id,
    ) catch |err| {
        log.err("Worker {d}: Failed to start health probes: {s}", .{
            worker_id,
            @errorName(err),
        });
        return err;
    };
    defer health_thread.detach();

    // Signal handling
    posix.sigaction(posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    // std.Io runtime
    // IMPORTANT: Io.Threaded.init must happen BEFORE setCpuAffinity
    // because getCpuCount() is used to set async_limit, and if affinity
    // is already set to 1 CPU, async_limit becomes 0 (all ops run sync)
    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Now safe to set CPU affinity (after Io.Threaded has captured cpu count)
    setCpuAffinity(worker_id) catch {};

    // Router
    var router = switch (config.strategy) {
        inline else => |s| try createRouter(allocator, &worker_state, s),
    };
    defer router.deinit(allocator);

    // SO_REUSEPORT enables kernel-level multi-process load balancing
    const addr = try Io.net.IpAddress.parse(config.host, config.port);
    var socket = try addr.listen(io, .{
        .kernel_backlog = 4096,
        .reuse_address = true,
    });
    defer socket.deinit(io);

    log.info("Worker {d}: Listening on {s}:{d}", .{
        worker_id,
        config.host,
        config.port,
    });

    // Server
    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 32,
        .keepalive_count_max = null, // unlimited
        .connection_count_max = 10000,
    });
    defer server.deinit();

    try server.serve(io, &router, &socket);
}

fn createRouter(
    allocator: std.mem.Allocator,
    state: *mp.WorkerState,
    comptime strategy: types.LoadBalancerStrategy,
) !Router {
    return try Router.init(allocator, &.{
        Route.init("/metrics").get({}, metrics.metricsHandler).layer(),
        Route.init("/").all(state, mp.generateHandler(strategy)).layer(),
        // Catch-all for proxy
        Route.init("/%r").all(state, mp.generateHandler(strategy)).layer(),
    }, .{});
}

// ============================================================================
// Utilities
// ============================================================================

fn setCpuAffinity(worker_id: usize) !void {
    if (comptime @import("builtin").os.tag == .linux) {
        const cpu_count = try std.Thread.getCpuCount();
        const target_cpu = worker_id % cpu_count;

        var cpu_set: std.os.linux.cpu_set_t =
            std.mem.zeroes(std.os.linux.cpu_set_t);
        const word_idx = target_cpu / @bitSizeOf(usize);
        const bit_idx: std.math.Log2Int(usize) =
            @intCast(target_cpu % @bitSizeOf(usize));
        cpu_set[word_idx] |= @as(usize, 1) << bit_idx;

        const result = std.os.linux.sched_setaffinity(0, &cpu_set);
        result catch return error.SetAffinityFailed;
    }
}
