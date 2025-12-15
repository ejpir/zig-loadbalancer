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
const simple_pool = @import("src/memory/simple_connection_pool.zig");
const metrics = @import("src/utils/metrics.zig");
const cli = @import("src/utils/cli.zig");
const UltraSock = @import("src/http/ultra_sock.zig").UltraSock;
const http_utils = @import("src/http/http_utils.zig");
const simd_parse = @import("src/internal/simd_parse.zig");

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
    // Using SimpleConnectionPool - no atomics needed in single-threaded workers!
    var connection_pool = simple_pool.SimpleConnectionPool{};
    connection_pool.init();
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

    connection_pool.addBackends(backends.items.len);

    // Create multiprocess proxy config (uses SimpleConnectionPool - no atomics!)
    var mp_config = MultiProcessProxyConfig{
        .backends = &backends,
        .connection_pool = &connection_pool,
        .strategy = config.strategy,
    };

    // Initialize healthy bitmap
    for (backends.items, 0..) |_, idx| {
        mp_config.markHealthy(idx);
    }

    // === Each worker creates its own Tardy runtime (SINGLE THREADED!) ===
    var t = try Tardy.init(allocator, .{
        .threading = .single, // KEY: Single-threaded per worker!
        .pooling = .grow,
        .size_tasks_initial = 4096, // More task slots for high concurrency
        .size_aio_reap_max = 4096, // Process more I/O events per cycle
    });
    defer t.deinit();

    // Create router using multiprocess-optimized handler
    var router = switch (config.strategy) {
        inline else => |s| try createWorkerRouter(allocator, &mp_config, s),
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
        .stack_size = 1024 * 1024 * 4, // 4MB stack (sufficient for most requests)
        .socket_buffer_bytes = 1024 * 32, // 32KB buffer (matches SIMD recv buffer)
        .keepalive_count_max = 1000, // More keepalive reuse
        .connection_count_max = 10000,
    });

    server.serve(rt, ctx.router, .{ .normal = ctx.socket }) catch |err| {
        log.err("Worker {d}: Server error: {s}", .{ctx.worker_id, @errorName(err)});
    };
}

/// Multiprocess-specific proxy config (no atomics)
const MultiProcessProxyConfig = struct {
    backends: *const types.BackendsList,
    connection_pool: *simple_pool.SimpleConnectionPool,
    strategy: types.LoadBalancerStrategy = .round_robin,
    healthy_bitmap: u64 = 0,
    rr_counter: usize = 0,

    pub fn markHealthy(self: *MultiProcessProxyConfig, idx: usize) void {
        if (idx >= 64) return;
        self.healthy_bitmap |= @as(u64, 1) << @intCast(idx);
    }
};

/// Create router with multiprocess-optimized handler
fn createWorkerRouter(allocator: std.mem.Allocator, mp_config: *MultiProcessProxyConfig, comptime strategy: types.LoadBalancerStrategy) !Router {
    const handler = generateMultiProcessHandler(strategy);

    return try Router.init(allocator, &.{
        Route.init("/metrics").get({}, metrics.metricsHandler).layer(),
        Route.init("/").all(mp_config, handler).layer(),
    }, .{});
}

/// Generate multiprocess-optimized handler (no atomics)
fn generateMultiProcessHandler(comptime strategy: types.LoadBalancerStrategy) fn (*const http.Context, *MultiProcessProxyConfig) anyerror!http.Respond {
    return struct {
        pub fn handle(ctx: *const http.Context, config: *MultiProcessProxyConfig) !http.Respond {
            const backends = config.backends;
            if (backends.items.len == 0) {
                return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "No backends" });
            }

            // Round-robin selection (no atomics!)
            const backend_idx = switch (strategy) {
                .round_robin, .weighted_round_robin => blk: {
                    const idx = config.rr_counter % backends.items.len;
                    config.rr_counter +%= 1;
                    break :blk idx;
                },
                .random => @as(usize, @intCast(std.time.milliTimestamp())) % backends.items.len,
                .sticky => 0,
            };

            return multiprocessStreamingProxy(ctx, &backends.items[backend_idx], backend_idx, config);
        }
    }.handle;
}

/// Streaming proxy optimized for multiprocess (no atomics, arena allocator)
fn multiprocessStreamingProxy(ctx: *const http.Context, backend: *const types.BackendServer, backend_idx: usize, config: *MultiProcessProxyConfig) !http.Respond {
    const start_time = std.time.milliTimestamp();
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var return_to_pool = true;

    // Get or create connection (no atomics!)
    var sock = config.connection_pool.getConnection(backend_idx) orelse blk: {
        var ultra_sock = UltraSock.fromBackendServer(alloc, backend) catch {
            return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.TEXT, .body = "Connection failed" });
        };
        ultra_sock.connect(ctx.runtime) catch {
            ultra_sock.close_blocking();
            return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.TEXT, .body = "Backend unavailable" });
        };
        break :blk ultra_sock;
    };

    if (sock.socket == null or !sock.connected) {
        return_to_pool = false;
        sock = UltraSock.fromBackendServer(alloc, backend) catch {
            return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.TEXT, .body = "Connection failed" });
        };
        sock.connect(ctx.runtime) catch {
            sock.close_blocking();
            return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.TEXT, .body = "Backend unavailable" });
        };
        return_to_pool = true;
    }

    defer {
        if (return_to_pool) config.connection_pool.returnConnection(backend_idx, sock) else sock.close_blocking();
    }

    // Build and send request
    const request_data = try std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: keep-alive\r\n\r\n{s}", .{
        @tagName(ctx.request.method orelse .GET), ctx.request.uri orelse "/",
        backend.getFullHost(), backend.port, ctx.request.body orelse "",
    });

    _ = sock.send_all(ctx.runtime, request_data) catch {
        return_to_pool = false;
        return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.TEXT, .body = "Send failed" });
    };

    // Read headers
    var header_buffer = try std.ArrayList(u8).initCapacity(alloc, 4096);
    var recv_buffer: [32768]u8 = undefined;
    const start_recv = std.time.milliTimestamp();
    var header_end: usize = 0;

    while (header_end == 0) {
        if (std.time.milliTimestamp() - start_recv > 3000) {
            return_to_pool = false;
            return ctx.response.apply(.{ .status = .@"Gateway Timeout", .mime = http.Mime.TEXT, .body = "Timeout" });
        }
        const n = sock.recv(ctx.runtime, &recv_buffer) catch {
            return_to_pool = false;
            return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.TEXT, .body = "Read failed" });
        };
        if (n == 0) { return_to_pool = false; return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.TEXT, .body = "Empty" }); }
        try header_buffer.appendSlice(alloc, recv_buffer[0..n]);
        if (simd_parse.findHeaderEnd(header_buffer.items)) |pos| header_end = pos + 4;
    }

    // Parse status
    const headers = header_buffer.items[0..header_end];
    const line_end = simd_parse.findLineEnd(headers) orelse return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.TEXT, .body = "Invalid" });
    const space = std.mem.indexOf(u8, headers[0..line_end], " ") orelse return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.TEXT, .body = "Invalid" });
    const status_code = std.fmt.parseInt(u16, headers[space + 1 ..][0..3], 10) catch 200;
    const msg_len = http_utils.determineMessageLength("GET", status_code, headers, false);

    if (std.mem.indexOf(u8, headers, "Connection: close") != null) return_to_pool = false;

    // Build response headers
    var resp = try std.ArrayList(u8).initCapacity(alloc, 512);
    var w = resp.writer(alloc);
    const status: http.Status = @enumFromInt(status_code);
    try w.print("HTTP/1.1 {d} {s}\r\nServer: zzz-lb-mp\r\nConnection: keep-alive\r\n", .{ status_code, @tagName(status) });

    // Forward headers (O(1) skip lookup)
    const skip = std.StaticStringMap(void).initComptime(.{
        .{ "connection", {} }, .{ "keep-alive", {} }, .{ "transfer-encoding", {} }, .{ "server", {} },
    });
    var pos: usize = line_end + 2;
    while (pos < header_end - 2) {
        const end = std.mem.indexOfPos(u8, headers, pos, "\r\n") orelse break;
        const line = headers[pos..end];
        if (std.mem.indexOf(u8, line, ":")) |c| {
            var lb: [64]u8 = undefined;
            const len = @min(line[0..c].len, 64);
            for (line[0..len], 0..) |ch, i| lb[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            if (skip.get(lb[0..len]) == null) try w.print("{s}\r\n", .{line});
        }
        pos = end + 2;
    }
    if (msg_len.type == .content_length) try w.print("Content-Length: {d}\r\n", .{msg_len.length});
    try w.writeAll("\r\n");
    if (header_buffer.items.len > header_end) try resp.appendSlice(alloc, header_buffer.items[header_end..]);

    _ = try ctx.socket.send_all(ctx.runtime, resp.items);
    var sent = header_buffer.items.len - header_end;

    // Stream body
    if (msg_len.type == .content_length) {
        while (sent < msg_len.length) {
            const n = sock.recv(ctx.runtime, &recv_buffer) catch break;
            if (n == 0) { return_to_pool = false; break; }
            _ = ctx.socket.send(ctx.runtime, recv_buffer[0..n]) catch break;
            sent += n;
        }
    } else if (msg_len.type == .chunked or msg_len.type == .close_delimited) {
        while (true) {
            const n = sock.recv(ctx.runtime, &recv_buffer) catch break;
            if (n == 0) { return_to_pool = false; break; }
            _ = ctx.socket.send(ctx.runtime, recv_buffer[0..n]) catch break;
            sent += n;
            if (msg_len.type == .chunked and simd_parse.findChunkEnd(recv_buffer[0..n]) != null) break;
        }
    }

    metrics.global_metrics.recordRequest(std.time.milliTimestamp() - start_time, status_code);
    return .responded;
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
