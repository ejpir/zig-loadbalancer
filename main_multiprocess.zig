/// Multi-Process Load Balancer (nginx-style architecture)
///
/// Each worker is a separate process with its own:
/// - Event loop (Tardy runtime) - single-threaded, no locks!
/// - Connection pool - no sharing, no atomics!
/// - Memory allocator - isolated
///
/// Benefits over multi-threaded:
/// - Zero lock contention (nothing shared between workers)
/// - Perfect CPU cache utilization (no false sharing)
/// - Crash isolation (one worker dies, master restarts it)
/// - Simpler code within each worker (no thread safety needed)
///
/// SO_REUSEPORT (already enabled in zzz) lets kernel distribute
/// connections across workers.
const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.@"lb_multiprocess");

const zzz = @import("zzz");
const tardy = zzz.tardy;
const http = zzz.HTTP;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;
const Router = http.Router;
const Server = http.Server;
const Route = http.Route;

// Local imports
const types = @import("src/core/types.zig");
const proxy = @import("src/core/proxy.zig");
const connection_pool_mod = @import("src/memory/connection_pool.zig");
const metrics = @import("src/utils/metrics.zig");
const cli = @import("src/utils/cli.zig");

pub const std_options: std.Options = .{
    .log_level = .err, // Use .info for debugging, .err for benchmarks
};

/// Configuration shared with workers (copied on fork)
const WorkerConfig = struct {
    host: []const u8,
    port: u16,
    backends: []const BackendDef,
    strategy: types.LoadBalancerStrategy,
    worker_id: usize,
    worker_count: usize,
};

const BackendDef = struct {
    host: []const u8,
    port: u16,
    weight: u16,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){}; // No thread safety needed in master!
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var worker_count: usize = try std.Thread.getCpuCount();
    var port: u16 = 8080;
    var host: []const u8 = "0.0.0.0";

    // Simple arg parsing
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

    // Default backend configuration (matches config/backends.yaml)
    const backends = [_]BackendDef{
        .{ .host = "127.0.0.1", .port = 9001, .weight = 1 },
        .{ .host = "127.0.0.1", .port = 9002, .weight = 1 },
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
    log.info("  Workers: {d} (one per CPU core)", .{worker_count});
    log.info("  Listen: {s}:{d}", .{host, port});
    log.info("  Backends: {d}", .{backends.len});
    log.info("  Strategy: {s}", .{@tagName(config.strategy)});
    log.info("", .{});

    // Store worker PIDs for monitoring
    var worker_pids = try allocator.alloc(posix.pid_t, worker_count);
    defer allocator.free(worker_pids);
    @memset(worker_pids, 0);

    // Fork worker processes
    for (0..worker_count) |worker_id| {
        const pid = try posix.fork();

        if (pid == 0) {
            // === CHILD PROCESS (Worker) ===
            var worker_config = config;
            worker_config.worker_id = worker_id;

            // Set CPU affinity to pin worker to specific core
            setCpuAffinity(worker_id) catch |err| {
                log.warn("Worker {d}: Failed to set CPU affinity: {s}", .{worker_id, @errorName(err)});
            };

            // Run worker (never returns)
            workerMain(worker_config) catch |err| {
                log.err("Worker {d}: Fatal error: {s}", .{worker_id, @errorName(err)});
                posix.exit(1);
            };
            posix.exit(0);
        } else {
            // === PARENT PROCESS (Master) ===
            worker_pids[worker_id] = pid;
            log.info("Spawned worker {d} (PID: {d})", .{worker_id, pid});
        }
    }

    log.info("", .{});
    log.info("All {d} workers started. Master monitoring...", .{worker_count});
    log.info("Press Ctrl+C to stop.", .{});

    // Master loop: monitor workers and restart on crash
    while (true) {
        const result = posix.waitpid(-1, 0);

        if (result.pid > 0) {
            // Find which worker died
            for (worker_pids, 0..) |pid, worker_id| {
                if (pid == result.pid) {
                    const status = result.status;

                    if (posix.W.IFEXITED(status)) {
                        const exit_code = posix.W.EXITSTATUS(status);
                        if (exit_code != 0) {
                            log.warn("Worker {d} exited with code {d}", .{worker_id, exit_code});
                        }
                    } else if (posix.W.IFSIGNALED(status)) {
                        log.err("Worker {d} killed by signal {d}", .{worker_id, posix.W.TERMSIG(status)});
                    }

                    // Restart the worker
                    log.info("Restarting worker {d}...", .{worker_id});

                    const new_pid = posix.fork() catch |err| {
                        log.err("Failed to restart worker {d}: {s}", .{worker_id, @errorName(err)});
                        continue;
                    };

                    if (new_pid == 0) {
                        var worker_config = config;
                        worker_config.worker_id = worker_id;
                        setCpuAffinity(worker_id) catch {};
                        workerMain(worker_config) catch |err| {
                            log.err("Worker {d}: Fatal error: {s}", .{worker_id, @errorName(err)});
                            posix.exit(1);
                        };
                        posix.exit(0);
                    } else {
                        worker_pids[worker_id] = new_pid;
                        log.info("Worker {d} restarted (new PID: {d})", .{worker_id, new_pid});
                    }
                    break;
                }
            }
        }
    }
}

/// Worker process main function
/// Each worker is completely independent - no shared state!
fn workerMain(config: WorkerConfig) !void {
    // Each worker gets its own allocator (no thread safety needed!)
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    log.info("Worker {d}: Starting", .{config.worker_id});

    // === Each worker creates its own connection pool (no sharing = no locks!) ===
    var connection_pool = connection_pool_mod.LockFreeConnectionPool{
        .pools = undefined,
        .allocator = undefined,
        .initialized = false,
    };
    try connection_pool.init(allocator);
    defer connection_pool.deinit();

    // Initialize backends for this worker
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    for (config.backends) |backend_def| {
        try backends.append(allocator, types.BackendServer.init(
            backend_def.host,
            backend_def.port,
            backend_def.weight,
        ));
    }

    try connection_pool.addBackends(backends.items.len);

    // Create proxy config for this worker
    var proxy_config = types.ProxyConfig{
        .backends = &backends,
        .connection_pool = &connection_pool,
        .strategy = config.strategy,
        .streaming = true,
    };

    // Initialize healthy bitmap
    for (backends.items, 0..) |_, idx| {
        proxy_config.markHealthy(idx);
    }

    // === Each worker creates its own Tardy runtime (SINGLE THREADED!) ===
    var t = try Tardy.init(allocator, .{
        .threading = .single, // KEY: Single-threaded per worker!
        .pooling = .grow,
        .size_tasks_initial = 1024,
        .size_aio_reap_max = 1024,
    });
    defer t.deinit();

    // Create router for this worker (use inline switch for comptime strategy)
    var router = switch (config.strategy) {
        inline else => |s| try createWorkerRouter(allocator, &proxy_config, s),
    };
    defer router.deinit(allocator);

    // === Each worker creates its own socket (SO_REUSEPORT distributes connections) ===
    var socket = try Socket.init(.{ .tcp = .{ .host = config.host, .port = config.port } });
    defer socket.close_blocking();

    try socket.bind();
    try socket.listen(4096);

    log.info("Worker {d}: Listening on {s}:{d}", .{config.worker_id, config.host, config.port});

    // Start serving (blocks forever)
    try t.entry(
        WorkerContext{
            .router = &router,
            .socket = socket,
            .worker_id = config.worker_id,
        },
        workerEntry,
    );
}

const WorkerContext = struct {
    router: *const Router,
    socket: Socket,
    worker_id: usize,
};

fn workerEntry(rt: *Runtime, ctx: WorkerContext) !void {
    log.info("Worker {d}: HTTP server starting", .{ctx.worker_id});

    var server = Server.init(.{
        .stack_size = 1024 * 1024 * 8,
        .socket_buffer_bytes = 1024 * 16,
        .keepalive_count_max = 100,
        .connection_count_max = 10000,
    });

    server.serve(rt, ctx.router, .{ .normal = ctx.socket }) catch |err| {
        log.err("Worker {d}: Server error: {s}", .{ctx.worker_id, @errorName(err)});
    };
}

/// Create router with comptime-specialized handler
fn createWorkerRouter(allocator: std.mem.Allocator, proxy_config: *types.ProxyConfig, comptime strategy: types.LoadBalancerStrategy) !Router {
    const handler = proxy.generateSpecializedHandler(strategy);

    return try Router.init(allocator, &.{
        Route.init("/metrics").get({}, metrics.metricsHandler).layer(),
        Route.init("/").all(proxy_config, handler).layer(),
    }, .{});
}

/// Set CPU affinity to pin worker to specific core
fn setCpuAffinity(worker_id: usize) !void {
    // Only works on Linux
    if (comptime @import("builtin").os.tag == .linux) {
        const cpu_count = try std.Thread.getCpuCount();
        const target_cpu = worker_id % cpu_count;

        var cpu_set: std.os.linux.cpu_set_t = .{ .bits = [_]usize{0} ** 16 };
        cpu_set.bits[target_cpu / 64] |= @as(usize, 1) << @intCast(target_cpu % 64);

        const rc = std.os.linux.sched_setaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &cpu_set);
        if (rc != 0) {
            return error.SetAffinityFailed;
        }
    }
    // On macOS, CPU affinity is advisory only (no direct equivalent)
}
