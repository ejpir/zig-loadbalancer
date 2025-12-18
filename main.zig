/// Unified Load Balancer - Single Entry Point
///
/// Supports two execution modes:
/// - multiprocess (mp): nginx-style architecture with forked workers and SO_REUSEPORT
/// - singleprocess (sp): single process with std.Io.Threaded internal thread pool
///
/// Usage:
///   ./load_balancer --mode mp --port 8080 --backend 127.0.0.1:9001
///   ./load_balancer -m sp -p 8080 -b 127.0.0.1:9001
///
const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const log = std.log.scoped(.lb);

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

/// Run mode for the load balancer
pub const RunMode = enum {
    multiprocess,
    singleprocess,

    pub fn fromString(s: []const u8) ?RunMode {
        if (std.mem.eql(u8, s, "mp") or std.mem.eql(u8, s, "multiprocess")) {
            return .multiprocess;
        } else if (std.mem.eql(u8, s, "sp") or std.mem.eql(u8, s, "singleprocess")) {
            return .singleprocess;
        }
        return null;
    }

    pub fn toString(self: RunMode) []const u8 {
        return switch (self) {
            .multiprocess => "multiprocess",
            .singleprocess => "singleprocess",
        };
    }

    /// Get default mode based on platform
    pub fn default() RunMode {
        return switch (builtin.os.tag) {
            .linux => .multiprocess, // SO_REUSEPORT works best on Linux
            else => .singleprocess, // macOS/BSD have fork() issues
        };
    }
};

/// Configuration including run mode
const Config = struct {
    mode: RunMode,
    lbConfig: LoadBalancerConfig,
};

// ============================================================================
// CLI Parsing
// ============================================================================

fn printUsage() void {
    std.debug.print(
        \\Load Balancer - High-performance HTTP load balancer
        \\
        \\USAGE:
        \\    load_balancer [OPTIONS]
        \\
        \\OPTIONS:
        \\    -m, --mode <MODE>       Run mode: mp (multiprocess) or sp (singleprocess)
        \\                            Default: mp on Linux, sp on macOS
        \\    -p, --port <PORT>       Listen port (default: 8080)
        \\    -h, --host <HOST>       Listen host (default: 0.0.0.0)
        \\    -w, --workers <N>       Worker count, mp mode only (default: CPU count)
        \\    -b, --backend <H:P>     Backend server (can specify multiple)
        \\    -s, --strategy <S>      Load balancing strategy: round_robin, weighted, random
        \\    --help                  Show this help
        \\
        \\EXAMPLES:
        \\    load_balancer --mode mp --port 8080 --backend 127.0.0.1:9001
        \\    load_balancer -m sp -p 8080 -b 127.0.0.1:9001 -b 127.0.0.1:9002
        \\
    , .{});
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mode: ?RunMode = null;
    var worker_count: usize = 0; // 0 = auto-detect
    var port: u16 = 8080;
    var host: ?[]const u8 = null;
    var strategy: types.LoadBalancerStrategy = .round_robin;

    var backend_list: std.ArrayListUnmanaged(BackendDef) = .empty;
    errdefer backend_list.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--mode") or
                   std.mem.eql(u8, arg, "-m")) {
            if (i + 1 < args.len) {
                mode = RunMode.fromString(args[i + 1]);
                if (mode == null) {
                    std.debug.print("Invalid mode: {s}. Use 'mp' or 'sp'.\n", .{args[i + 1]});
                    return error.InvalidMode;
                }
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--workers") or
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
                host = try allocator.dupe(u8, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--backend") or
                   std.mem.eql(u8, arg, "-b")) {
            if (i + 1 < args.len) {
                const backend_str = args[i + 1];
                if (std.mem.lastIndexOf(u8, backend_str, ":")) |colon| {
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

    // Use default mode if not specified
    const final_mode = mode orelse RunMode.default();

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
        .mode = final_mode,
        .lbConfig = .{
            .worker_count = worker_count,
            .port = port,
            .host = host orelse "0.0.0.0",
            .backends = try backend_list.toOwnedSlice(allocator),
            .strategy = strategy,
        },
    };
}

fn freeConfig(allocator: std.mem.Allocator, config: Config) void {
    allocator.free(config.lbConfig.backends);
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const config = try parseArgs(allocator);
    defer freeConfig(allocator, config);

    // Validate configuration
    try config.lbConfig.validate();

    log.info("=== Load Balancer ({s} mode) ===", .{config.mode.toString()});
    log.info("Listen: {s}:{d}, Backends: {d}, Strategy: {s}", .{
        config.lbConfig.host,
        config.lbConfig.port,
        config.lbConfig.backends.len,
        @tagName(config.lbConfig.strategy),
    });

    // Dispatch to appropriate mode
    switch (config.mode) {
        .multiprocess => try runMultiProcess(allocator, config.lbConfig),
        .singleprocess => try runSingleProcess(allocator, config.lbConfig),
    }
}

// ============================================================================
// Multi-Process Mode
// ============================================================================

fn runMultiProcess(allocator: std.mem.Allocator, config: LoadBalancerConfig) !void {
    var mutable_config = config;

    // Auto-detect worker count if not specified
    if (mutable_config.worker_count == 0) {
        mutable_config.worker_count = try std.Thread.getCpuCount();
    }

    log.info("Workers: {d}", .{mutable_config.worker_count});
    for (mutable_config.backends, 0..) |b, idx| {
        log.info("  Backend {d}: {s}:{d}", .{ idx + 1, b.host, b.port });
    }

    try spawnWorkers(allocator, mutable_config);
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
// Worker Process (Multi-Process Mode)
// ============================================================================

var mp_server: Server = undefined;

fn mpShutdown(_: std.c.SIG) callconv(.c) void {
    mp_server.stop();
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

    // Worker state
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

    // Start health probe thread
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
        .handler = .{ .handler = mpShutdown },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    // std.Io runtime
    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Set CPU affinity after Io.Threaded.init
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
    mp_server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 32,
        .keepalive_count_max = null, // unlimited
        .connection_count_max = 10000,
    });
    defer mp_server.deinit();

    try mp_server.serve(io, &router, &socket);
}

// ============================================================================
// Single-Process Mode
// ============================================================================

var sp_server: Server = undefined;

fn spShutdown(_: std.c.SIG) callconv(.c) void {
    sp_server.stop();
}

fn runSingleProcess(_: std.mem.Allocator, config: LoadBalancerConfig) !void {
    // Thread-safe allocator since health probes run in separate thread
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    for (config.backends, 0..) |b, idx| {
        log.info("  Backend {d}: {s}:{d}", .{ idx + 1, b.host, b.port });
    }

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

    // Worker state
    var worker_state = mp.WorkerState.init(&backends, &connection_pool, .{
        .unhealthy_threshold = config.unhealthy_threshold,
        .healthy_threshold = config.healthy_threshold,
        .probe_interval_ms = config.probe_interval_ms,
        .probe_timeout_ms = config.probe_timeout_ms,
        .health_path = config.health_path,
    });
    worker_state.setWorkerId(0);

    // Start health probe thread
    const health_thread = health.startHealthProbes(&worker_state, 0) catch |err| {
        log.err("Failed to start health probes: {s}", .{@errorName(err)});
        return err;
    };
    defer health_thread.detach();

    // Signal handling
    setupSignalHandlers();

    // std.Io runtime
    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Router
    var router = switch (config.strategy) {
        inline else => |s| try createRouter(allocator, &worker_state, s),
    };
    defer router.deinit(allocator);

    // No SO_REUSEPORT needed for single process
    const addr = try Io.net.IpAddress.parse(config.host, config.port);
    var socket = try addr.listen(io, .{
        .kernel_backlog = 4096,
        .reuse_address = true,
    });
    defer socket.deinit(io);

    log.info("Listening on {s}:{d}", .{ config.host, config.port });

    // Server
    sp_server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 32,
        .keepalive_count_max = null, // unlimited
        .connection_count_max = 10000,
    });
    defer sp_server.deinit();

    try sp_server.serve(io, &router, &socket);
}

fn setupSignalHandlers() void {
    posix.sigaction(posix.SIG.TERM, &.{
        .handler = .{ .handler = spShutdown },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
    posix.sigaction(posix.SIG.INT, &.{
        .handler = .{ .handler = spShutdown },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
}

// ============================================================================
// Shared Utilities
// ============================================================================

fn createRouter(
    allocator: std.mem.Allocator,
    state: *mp.WorkerState,
    comptime strategy: types.LoadBalancerStrategy,
) !Router {
    return try Router.init(allocator, &.{
        Route.init("/metrics").get({}, metrics.metricsHandler).layer(),
        Route.init("/").all(state, mp.generateHandler(strategy)).layer(),
        Route.init("/%r").all(state, mp.generateHandler(strategy)).layer(),
    }, .{});
}

fn setCpuAffinity(worker_id: usize) !void {
    if (comptime builtin.os.tag == .linux) {
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
