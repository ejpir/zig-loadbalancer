/// Multi-Process Load Balancer (nginx-style architecture)
///
/// Each worker is a separate process with its own:
/// - Event loop (Tardy runtime) - single-threaded, no locks!
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
const tardy = zzz.tardy;
const http = zzz.HTTP;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const types = @import("src/core/types.zig");
const simple_pool = @import("src/memory/simple_connection_pool.zig");
const metrics = @import("src/utils/metrics.zig");
const mp = @import("src/mp.zig");

pub const std_options: std.Options = .{
    .log_level = .warn, // .debug for verbose, .warn for health changes, .err for benchmarks
};

// ============================================================================
// Configuration
// ============================================================================

const BackendDef = struct {
    host: []const u8,
    port: u16,
    weight: u16 = 1,
};

const WorkerConfig = struct {
    host: []const u8,
    port: u16,
    backends: []const BackendDef,
    strategy: types.LoadBalancerStrategy,
    worker_id: usize,
    worker_count: usize,
};

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var worker_count: usize = try std.Thread.getCpuCount();
    var port: u16 = 8080;
    var host: []const u8 = "0.0.0.0";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--workers") or std.mem.eql(u8, args[i], "-w")) {
            if (i + 1 < args.len) {
                worker_count = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--port") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 < args.len) {
                port = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--host") or std.mem.eql(u8, args[i], "-h")) {
            if (i + 1 < args.len) {
                host = args[i + 1];
                i += 1;
            }
        }
    }

    // Backend configuration
    const backends = [_]BackendDef{
        .{ .host = "127.0.0.1", .port = 9001 },
        .{ .host = "127.0.0.1", .port = 9002 },
    };

    const config = WorkerConfig{
        .host = host,
        .port = port,
        .backends = &backends,
        .strategy = .round_robin,
        .worker_id = 0,
        .worker_count = worker_count,
    };

    log.info("=== Multi-Process Load Balancer ===", .{});
    log.info("Workers: {d}, Listen: {s}:{d}, Backends: {d}", .{worker_count, host, port, backends.len});

    // Fork workers
    var worker_pids = try allocator.alloc(posix.pid_t, worker_count);
    defer allocator.free(worker_pids);

    for (0..worker_count) |worker_id| {
        const pid = try posix.fork();

        if (pid == 0) {
            // Child: run worker
            var worker_config = config;
            worker_config.worker_id = worker_id;
            setCpuAffinity(worker_id) catch {};
            workerMain(worker_config) catch |err| {
                log.err("Worker {d} fatal: {s}", .{worker_id, @errorName(err)});
                posix.exit(1);
            };
            posix.exit(0);
        } else {
            worker_pids[worker_id] = pid;
            log.info("Spawned worker {d} (PID: {d})", .{worker_id, pid});
        }
    }

    log.info("All workers started. Press Ctrl+C to stop.", .{});

    // Master: monitor and restart crashed workers
    while (true) {
        const result = posix.waitpid(-1, 0);
        if (result.pid > 0) {
            for (worker_pids, 0..) |pid, worker_id| {
                if (pid == result.pid) {
                    log.warn("Worker {d} died, restarting...", .{worker_id});

                    const new_pid = posix.fork() catch continue;
                    if (new_pid == 0) {
                        var worker_config = config;
                        worker_config.worker_id = worker_id;
                        setCpuAffinity(worker_id) catch {};
                        workerMain(worker_config) catch |err| {
                            log.err("Worker {d} fatal: {s}", .{worker_id, @errorName(err)});
                            posix.exit(1);
                        };
                        posix.exit(0);
                    } else {
                        worker_pids[worker_id] = new_pid;
                    }
                    break;
                }
            }
        }
    }
}

// ============================================================================
// Worker Process
// ============================================================================

fn workerMain(config: WorkerConfig) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Connection pool
    var connection_pool = simple_pool.SimpleConnectionPool{};
    connection_pool.init();
    defer connection_pool.deinit();

    // Backends
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    for (config.backends) |b| {
        try backends.append(allocator, types.BackendServer.init(b.host, b.port, b.weight));
    }
    connection_pool.addBackends(backends.items.len);

    // Multi-process config (health state, circuit breaker)
    var mp_config = mp.Config{
        .backends = &backends,
        .connection_pool = &connection_pool,
        .strategy = config.strategy,
    };

    log.info("Worker {d}: Starting with {d} backends", .{config.worker_id, backends.items.len});

    // Tardy runtime (single-threaded!)
    var t = try Tardy.init(allocator, .{
        .threading = .single,
        .pooling = .grow,
        .size_tasks_initial = 4096,
        .size_aio_reap_max = 4096,
    });
    defer t.deinit();

    // Router
    var router = switch (config.strategy) {
        inline else => |s| try createRouter(allocator, &mp_config, s),
    };
    defer router.deinit(allocator);

    // Socket (SO_REUSEPORT)
    var socket = try Socket.init(.{ .tcp = .{ .host = config.host, .port = config.port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    log.info("Worker {d}: Listening on {s}:{d}", .{config.worker_id, config.host, config.port});

    // Start
    try t.entry(
        WorkerContext{ .router = &router, .socket = socket, .worker_id = config.worker_id, .mp_config = &mp_config, .allocator = allocator },
        workerEntry,
    );
}

const WorkerContext = struct {
    router: *const http.Router,
    socket: Socket,
    worker_id: usize,
    mp_config: *mp.Config,
    allocator: std.mem.Allocator,
};

fn workerEntry(rt: *Runtime, ctx: WorkerContext) !void {
    // Spawn health probe task
    rt.spawn(.{mp.HealthProbeContext{
        .config = ctx.mp_config,
        .allocator = ctx.allocator,
        .worker_id = ctx.worker_id,
        .runtime = rt,
    }}, mp.healthProbeTask, 1024 * 64) catch |err| {
        log.warn("Worker {d}: Failed to spawn health probe: {s}", .{ctx.worker_id, @errorName(err)});
    };

    // HTTP server
    var server = http.Server.init(.{
        .stack_size = 1024 * 1024 * 4,
        .socket_buffer_bytes = 1024 * 32,
        .keepalive_count_max = 1000,
        .connection_count_max = 10000,
    });

    server.serve(rt, ctx.router, .{ .normal = ctx.socket }) catch |err| {
        log.err("Worker {d}: Server error: {s}", .{ctx.worker_id, @errorName(err)});
    };
}

fn createRouter(allocator: std.mem.Allocator, config: *mp.Config, comptime strategy: types.LoadBalancerStrategy) !http.Router {
    return try http.Router.init(allocator, &.{
        http.Route.init("/metrics").get({}, metrics.metricsHandler).layer(),
        http.Route.init("/").all(config, mp.generateHandler(strategy)).layer(),
    }, .{});
}

// ============================================================================
// Utilities
// ============================================================================

fn setCpuAffinity(worker_id: usize) !void {
    if (comptime @import("builtin").os.tag == .linux) {
        const cpu_count = try std.Thread.getCpuCount();
        const target_cpu = worker_id % cpu_count;

        var cpu_set: std.os.linux.cpu_set_t = .{ .bits = [_]usize{0} ** 16 };
        cpu_set.bits[target_cpu / 64] |= @as(usize, 1) << @intCast(target_cpu % 64);

        const rc = std.os.linux.sched_setaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &cpu_set);
        if (rc != 0) return error.SetAffinityFailed;
    }
}
