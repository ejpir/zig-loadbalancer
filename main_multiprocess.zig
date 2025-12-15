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
    .log_level = .warn, // .debug for verbose, .warn for health changes only, .err for benchmarks
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

    // Start backends as UNHEALTHY - let health probes mark them healthy
    // This is the standard approach: prove healthy, don't assume it
    log.info("Worker {d}: Starting with {d} backends (initially UNHEALTHY, waiting for health probes)", .{
        config.worker_id, backends.items.len
    });

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
            .mp_config = &mp_config,
            .allocator = allocator,
        },
        workerEntry,
    );
}

const WorkerContext = struct {
    router: *const Router,
    socket: Socket,
    worker_id: usize,
    mp_config: *MultiProcessProxyConfig,
    allocator: std.mem.Allocator,
};

fn workerEntry(rt: *Runtime, ctx: WorkerContext) !void {
    log.info("Worker {d}: HTTP server starting", .{ctx.worker_id});

    // Spawn async health probe task (non-blocking, runs in event loop)
    rt.spawn(.{HealthProbeContext{
        .mp_config = ctx.mp_config,
        .allocator = ctx.allocator,
        .worker_id = ctx.worker_id,
        .runtime = rt,
    }}, healthProbeTask, 1024 * 64) catch |err| {
        log.warn("Worker {d}: Failed to spawn health probe task: {s}", .{ctx.worker_id, @errorName(err)});
    };

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

/// Context for health probe async task
const HealthProbeContext = struct {
    mp_config: *MultiProcessProxyConfig,
    allocator: std.mem.Allocator,
    worker_id: usize,
    runtime: *Runtime,
};

/// Async health probe task - runs in event loop, non-blocking
fn healthProbeTask(probe_ctx: HealthProbeContext) !void {
    const config = probe_ctx.mp_config;
    const backends = config.backends;
    const health_config = config.health_config;
    const Timer = tardy.Timer;
    const rt = probe_ctx.runtime;

    log.info("Worker {d}: Health probe task started (interval: {d}ms)", .{
        probe_ctx.worker_id, health_config.probe_interval_ms
    });

    // Initial delay before first probe
    Timer.delay(rt, .{ .seconds = 1, .nanos = 0 }) catch {};

    while (true) {
        const probe_start = std.time.milliTimestamp();

        // Probe each backend
        for (backends.items, 0..) |*backend, idx| {
            const is_healthy = probeBackendHealth(probe_ctx.allocator, backend, health_config, rt);
            log.debug("Worker {d}: Probe backend {d} ({s}:{d}) = {s}", .{
                probe_ctx.worker_id, idx + 1, backend.getFullHost(), backend.port,
                if (is_healthy) "OK" else "FAIL"
            });

            if (is_healthy) {
                if (!config.isHealthy(idx)) {
                    config.consecutive_successes[idx] += 1;
                    if (config.consecutive_successes[idx] >= health_config.healthy_threshold) {
                        log.warn("Worker {d}: Backend {d} ({s}:{d}) now HEALTHY", .{
                            probe_ctx.worker_id, idx + 1, backend.getFullHost(), backend.port
                        });
                        config.markHealthy(idx);
                    }
                } else {
                    config.consecutive_failures[idx] = 0;
                }
            } else {
                if (config.isHealthy(idx)) {
                    config.consecutive_failures[idx] += 1;
                    if (config.consecutive_failures[idx] >= health_config.unhealthy_threshold) {
                        log.warn("Worker {d}: Backend {d} ({s}:{d}) now UNHEALTHY", .{
                            probe_ctx.worker_id, idx + 1, backend.getFullHost(), backend.port
                        });
                        config.markUnhealthy(idx);
                    }
                }
            }

            config.last_check_time[idx] = std.time.milliTimestamp();
        }

        const probe_duration = std.time.milliTimestamp() - probe_start;
        log.debug("Worker {d}: Health probe cycle done in {d}ms ({d}/{d} healthy)", .{
            probe_ctx.worker_id, probe_duration, config.countHealthy(), backends.items.len
        });

        // Wait for next probe interval (non-blocking async delay)
        const delay_ms = health_config.probe_interval_ms;
        Timer.delay(rt, .{
            .seconds = @intCast(delay_ms / 1000),
            .nanos = @intCast((delay_ms % 1000) * 1_000_000),
        }) catch {};
    }
}

/// Probe a single backend's health using async I/O
fn probeBackendHealth(allocator: std.mem.Allocator, backend: *const types.BackendServer, health_config: HealthConfig, rt: *Runtime) bool {
    // Create socket for health check
    var sock = Socket.init(.{ .tcp = .{
        .host = backend.getFullHost(),
        .port = backend.port,
    } }) catch {
        return false;
    };
    defer sock.close_blocking();

    // Connect (async)
    sock.connect(rt) catch {
        return false;
    };

    // Send HTTP health check request
    const request = std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\nUser-Agent: zzz-lb-health/1.0\r\n\r\n", .{
        health_config.health_path, backend.getFullHost(), backend.port
    }) catch {
        return false;
    };
    defer allocator.free(request);

    _ = sock.send_all(rt, request) catch {
        return false;
    };

    // Read response
    var buffer: [1024]u8 = undefined;
    const bytes_read = sock.recv(rt, &buffer) catch {
        return false;
    };

    if (bytes_read == 0) {
        return false;
    }

    // Check for HTTP 200 OK
    const response = buffer[0..bytes_read];
    return std.mem.indexOf(u8, response, "HTTP/1.1 200") != null or
           std.mem.indexOf(u8, response, "HTTP/1.0 200") != null;
}

/// Health check configuration
const HealthConfig = struct {
    /// Number of consecutive failures before marking unhealthy
    unhealthy_threshold: u32 = 3,
    /// Number of consecutive successes before marking healthy
    healthy_threshold: u32 = 2,
    /// Interval between active health probes (ms)
    probe_interval_ms: u64 = 5000,
    /// Timeout for health probe requests (ms)
    probe_timeout_ms: u64 = 2000,
    /// Health check path
    health_path: []const u8 = "/",
};

const MAX_BACKENDS: usize = 64;

/// Multiprocess-specific proxy config (no atomics - single-threaded!)
const MultiProcessProxyConfig = struct {
    backends: *const types.BackendsList,
    connection_pool: *simple_pool.SimpleConnectionPool,
    strategy: types.LoadBalancerStrategy = .round_robin,
    health_config: HealthConfig = .{},

    // Health state (no atomics needed - single-threaded worker!)
    healthy_bitmap: u64 = 0,
    consecutive_failures: [MAX_BACKENDS]u32 = [_]u32{0} ** MAX_BACKENDS,
    consecutive_successes: [MAX_BACKENDS]u32 = [_]u32{0} ** MAX_BACKENDS,
    last_check_time: [MAX_BACKENDS]i64 = [_]i64{0} ** MAX_BACKENDS,

    // Load balancing state
    rr_counter: usize = 0,
    request_count: usize = 0,

    /// Mark backend as healthy
    pub fn markHealthy(self: *MultiProcessProxyConfig, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.healthy_bitmap |= @as(u64, 1) << @intCast(idx);
        self.consecutive_failures[idx] = 0;
    }

    /// Mark backend as unhealthy
    pub fn markUnhealthy(self: *MultiProcessProxyConfig, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.healthy_bitmap &= ~(@as(u64, 1) << @intCast(idx));
        self.consecutive_successes[idx] = 0;
    }

    /// Check if backend is healthy
    pub fn isHealthy(self: *const MultiProcessProxyConfig, idx: usize) bool {
        if (idx >= MAX_BACKENDS) return false;
        return (self.healthy_bitmap & (@as(u64, 1) << @intCast(idx))) != 0;
    }

    /// Record a successful request (circuit breaker recovery)
    pub fn recordSuccess(self: *MultiProcessProxyConfig, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.consecutive_failures[idx] = 0;

        if (!self.isHealthy(idx)) {
            self.consecutive_successes[idx] += 1;
            if (self.consecutive_successes[idx] >= self.health_config.healthy_threshold) {
                log.info("Backend {d} recovered after {d} successes", .{idx + 1, self.consecutive_successes[idx]});
                self.markHealthy(idx);
            }
        }
    }

    /// Record a failed request (circuit breaker trip)
    pub fn recordFailure(self: *MultiProcessProxyConfig, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.consecutive_successes[idx] = 0;
        self.consecutive_failures[idx] += 1;

        if (self.isHealthy(idx) and self.consecutive_failures[idx] >= self.health_config.unhealthy_threshold) {
            log.warn("Backend {d} marked UNHEALTHY after {d} failures", .{idx + 1, self.consecutive_failures[idx]});
            self.markUnhealthy(idx);
        }
    }

    /// Find a healthy backend, excluding the given index
    pub fn findHealthyBackend(self: *const MultiProcessProxyConfig, exclude_idx: usize) ?usize {
        var mask = self.healthy_bitmap;
        if (exclude_idx < MAX_BACKENDS) {
            mask &= ~(@as(u64, 1) << @intCast(exclude_idx));
        }
        if (mask == 0) return null;
        return @ctz(mask);
    }

    /// Count healthy backends
    pub fn countHealthy(self: *const MultiProcessProxyConfig) usize {
        return @popCount(self.healthy_bitmap);
    }

    /// Select backend with health-aware load balancing
    pub fn selectBackend(self: *MultiProcessProxyConfig, comptime strategy: types.LoadBalancerStrategy) ?usize {
        const backends = self.backends;
        if (backends.items.len == 0) return null;

        // If no healthy backends, return any backend (will trigger recovery probe)
        if (self.healthy_bitmap == 0) {
            return self.rr_counter % backends.items.len;
        }

        // Select from healthy backends only
        const idx = switch (strategy) {
            .round_robin, .weighted_round_robin => blk: {
                // Find next healthy backend in round-robin order
                var attempts: usize = 0;
                while (attempts < backends.items.len) : (attempts += 1) {
                    const candidate = (self.rr_counter +% attempts) % backends.items.len;
                    if (self.isHealthy(candidate)) {
                        self.rr_counter = candidate +% 1;
                        break :blk candidate;
                    }
                }
                // Fallback to round-robin if no healthy found
                const fallback = self.rr_counter % backends.items.len;
                self.rr_counter +%= 1;
                break :blk fallback;
            },
            .random => blk: {
                // Random selection from healthy backends
                const healthy_count = self.countHealthy();
                if (healthy_count == 0) break :blk 0;

                const rand_val = @as(usize, @intCast(std.time.nanoTimestamp() & 0xFFFFFFFF));
                var target = rand_val % healthy_count;
                var idx: usize = 0;
                while (idx < backends.items.len) : (idx += 1) {
                    if (self.isHealthy(idx)) {
                        if (target == 0) break :blk idx;
                        target -= 1;
                    }
                }
                break :blk 0;
            },
            .sticky => 0, // TODO: implement sticky with health awareness
        };

        return idx;
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

/// Generate multiprocess-optimized handler with health-aware load balancing
fn generateMultiProcessHandler(comptime strategy: types.LoadBalancerStrategy) fn (*const http.Context, *MultiProcessProxyConfig) anyerror!http.Respond {
    return struct {
        pub fn handle(ctx: *const http.Context, config: *MultiProcessProxyConfig) !http.Respond {
            const backends = config.backends;
            if (backends.items.len == 0) {
                return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "No backends configured" });
            }

            config.request_count +%= 1;

            // Health-aware backend selection
            const backend_idx = config.selectBackend(strategy) orelse {
                return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "No backends available" });
            };

            // Try primary backend with failover
            return proxyWithFailover(ctx, backend_idx, config, strategy);
        }
    }.handle;
}

/// Proxy request with automatic failover on failure
fn proxyWithFailover(
    ctx: *const http.Context,
    primary_idx: usize,
    config: *MultiProcessProxyConfig,
    comptime strategy: types.LoadBalancerStrategy,
) !http.Respond {
    _ = strategy;
    const backends = config.backends;

    // Try primary backend
    const primary_result = multiprocessStreamingProxy(ctx, &backends.items[primary_idx], primary_idx, config);

    if (primary_result) |response| {
        // Success - record it for circuit breaker recovery
        config.recordSuccess(primary_idx);
        return response;
    } else |err| {
        // Failed - record failure for circuit breaker
        config.recordFailure(primary_idx);
        log.warn("Backend {d} failed: {s}, attempting failover", .{primary_idx + 1, @errorName(err)});

        // Try to find a healthy failover backend
        if (config.findHealthyBackend(primary_idx)) |failover_idx| {
            log.info("Failing over to backend {d}", .{failover_idx + 1});

            const failover_result = multiprocessStreamingProxy(ctx, &backends.items[failover_idx], failover_idx, config);

            if (failover_result) |response| {
                config.recordSuccess(failover_idx);
                return response;
            } else |failover_err| {
                config.recordFailure(failover_idx);
                log.err("Failover to backend {d} also failed: {s}", .{failover_idx + 1, @errorName(failover_err)});
            }
        } else {
            log.err("No healthy backends available for failover", .{});
        }

        // All backends failed
        return ctx.response.apply(.{
            .status = .@"Service Unavailable",
            .mime = http.Mime.TEXT,
            .body = "All backends unavailable",
        });
    }
}

/// Proxy errors for circuit breaker
const ProxyError = error{
    ConnectionFailed,
    BackendUnavailable,
    SendFailed,
    ReadFailed,
    Timeout,
    EmptyResponse,
    InvalidResponse,
};

/// Streaming proxy optimized for multiprocess (no atomics, arena allocator)
/// Returns error on failure to enable failover logic
fn multiprocessStreamingProxy(ctx: *const http.Context, backend: *const types.BackendServer, backend_idx: usize, config: *MultiProcessProxyConfig) ProxyError!http.Respond {
    const start_time = std.time.milliTimestamp();
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var return_to_pool = true;

    // Get or create connection (no atomics!)
    var sock = config.connection_pool.getConnection(backend_idx) orelse blk: {
        var ultra_sock = UltraSock.fromBackendServer(alloc, backend) catch {
            return ProxyError.ConnectionFailed;
        };
        ultra_sock.connect(ctx.runtime) catch {
            ultra_sock.close_blocking();
            return ProxyError.BackendUnavailable;
        };
        break :blk ultra_sock;
    };

    if (sock.socket == null or !sock.connected) {
        return_to_pool = false;
        sock = UltraSock.fromBackendServer(alloc, backend) catch {
            return ProxyError.ConnectionFailed;
        };
        sock.connect(ctx.runtime) catch {
            sock.close_blocking();
            return ProxyError.BackendUnavailable;
        };
        return_to_pool = true;
    }

    defer {
        if (return_to_pool) config.connection_pool.returnConnection(backend_idx, sock) else sock.close_blocking();
    }

    // Build and send request
    const request_data = std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: keep-alive\r\n\r\n{s}", .{
        @tagName(ctx.request.method orelse .GET), ctx.request.uri orelse "/",
        backend.getFullHost(), backend.port, ctx.request.body orelse "",
    }) catch return ProxyError.ConnectionFailed;

    _ = sock.send_all(ctx.runtime, request_data) catch {
        return_to_pool = false;
        return ProxyError.SendFailed;
    };

    // Read headers
    var header_buffer = std.ArrayList(u8).initCapacity(alloc, 4096) catch return ProxyError.ConnectionFailed;
    var recv_buffer: [32768]u8 = undefined;
    const start_recv = std.time.milliTimestamp();
    var header_end: usize = 0;

    while (header_end == 0) {
        if (std.time.milliTimestamp() - start_recv > 3000) {
            return_to_pool = false;
            return ProxyError.Timeout;
        }
        const n = sock.recv(ctx.runtime, &recv_buffer) catch {
            return_to_pool = false;
            return ProxyError.ReadFailed;
        };
        if (n == 0) {
            return_to_pool = false;
            return ProxyError.EmptyResponse;
        }
        header_buffer.appendSlice(alloc, recv_buffer[0..n]) catch return ProxyError.ConnectionFailed;
        if (simd_parse.findHeaderEnd(header_buffer.items)) |pos| header_end = pos + 4;
    }

    // Parse status
    const headers = header_buffer.items[0..header_end];
    const line_end = simd_parse.findLineEnd(headers) orelse return ProxyError.InvalidResponse;
    const space = std.mem.indexOf(u8, headers[0..line_end], " ") orelse return ProxyError.InvalidResponse;
    const status_code = std.fmt.parseInt(u16, headers[space + 1 ..][0..3], 10) catch 200;
    const msg_len = http_utils.determineMessageLength("GET", status_code, headers, false);

    if (std.mem.indexOf(u8, headers, "Connection: close") != null) return_to_pool = false;

    // Build response headers
    var resp = std.ArrayList(u8).initCapacity(alloc, 512) catch return ProxyError.ConnectionFailed;
    var w = resp.writer(alloc);
    const status: http.Status = @enumFromInt(status_code);
    w.print("HTTP/1.1 {d} {s}\r\nServer: zzz-lb-mp\r\nConnection: keep-alive\r\n", .{ status_code, @tagName(status) }) catch return ProxyError.ConnectionFailed;

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
            if (skip.get(lb[0..len]) == null) w.print("{s}\r\n", .{line}) catch {};
        }
        pos = end + 2;
    }
    if (msg_len.type == .content_length) w.print("Content-Length: {d}\r\n", .{msg_len.length}) catch {};
    w.writeAll("\r\n") catch {};
    if (header_buffer.items.len > header_end) resp.appendSlice(alloc, header_buffer.items[header_end..]) catch {};

    _ = ctx.socket.send_all(ctx.runtime, resp.items) catch return ProxyError.SendFailed;
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
