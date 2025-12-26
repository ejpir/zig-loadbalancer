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

const telemetry = @import("src/telemetry/mod.zig");

const Io = std.Io;
const Server = http.Server;
const Router = http.Router;
const Route = http.Route;

const types = @import("src/core/types.zig");
const config_mod = @import("src/core/config.zig");
const simple_pool = @import("src/memory/pool.zig");
const shared_region = @import("src/memory/shared_region.zig");
const config_watcher = @import("src/config/config_watcher.zig");
const metrics = @import("src/metrics/mod.zig");
const mp = @import("src/multiprocess/mod.zig");
const health = @import("src/health/probe.zig");
const H2ConnectionPool = @import("src/http/http2/pool.zig").H2ConnectionPool;

const SharedHealthState = shared_region.SharedHealthState;

/// Runtime log level (can be changed via --loglevel)
var runtime_log_level: std.log.Level = .info;

pub const std_options: std.Options = .{
    .log_level = .debug, // Compile-time max level (allows all)
    .logFn = runtimeLogFn, // Custom log function respects runtime level
};

/// Start time for relative timestamps
var start_time: ?std.time.Instant = null;

/// Custom log function that respects runtime log level and adds relative timestamps
fn runtimeLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;

    // Get relative time in ms since first log
    const rel_ms: u64 = blk: {
        const now = std.time.Instant.now() catch break :blk 0;
        if (start_time == null) {
            start_time = now;
            break :blk 0;
        }
        break :blk now.since(start_time.?) / std.time.ns_per_ms;
    };

    const level_txt = comptime level.asText();
    const scope_txt = if (@tagName(scope).len > 0) @tagName(scope) else "default";

    // Format: [+1234ms] level(scope): message
    std.debug.print("[+{d:>6}ms] {s}({s}): " ++ format ++ "\n", .{
        rel_ms,
        level_txt,
        scope_txt,
    } ++ args);
}

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
    config_path: ?[]const u8 = null, // Path to JSON config file for hot reload
    upgrade_fd: ?posix.fd_t = null, // Inherited socket fd for binary hot reload
    insecure_tls: bool = false, // Skip TLS verification (for testing only)
    trace: bool = false, // Enable hex/ASCII payload tracing
    tls_trace: bool = false, // Enable detailed TLS handshake tracing
    otel_endpoint: ?[]const u8 = null, // OTLP endpoint for OpenTelemetry tracing
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
        \\    -c, --config <PATH>     JSON config file for hot reload
        \\    -l, --loglevel <LEVEL>  Log level: err, warn, info, debug (default: info)
        \\    -k, --insecure          Skip TLS certificate verification (testing only)
        \\    -t, --trace             Dump raw request/response payloads (hex + ASCII)
        \\    --tls-trace             Show detailed TLS handshake info (cipher, version, CA)
        \\    --otel-endpoint <H:P>   OTLP endpoint for OpenTelemetry tracing (e.g. localhost:4318)
        \\    --upgrade-fd <FD>       Inherit socket fd for binary hot reload (internal)
        \\    --help                  Show this help
        \\
        \\HOT RELOAD:
        \\    Send SIGUSR2 to trigger binary upgrade without dropping connections.
        \\    kill -USR2 <pid>
        \\
        \\EXAMPLES:
        \\    load_balancer --mode mp --port 8080 --backend 127.0.0.1:9001
        \\    load_balancer -m sp -p 8080 -b 127.0.0.1:9001 -b 127.0.0.1:9002
        \\    load_balancer -m mp -c backends.json  # Hot reload on file change
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
    var config_path: ?[]const u8 = null;
    var upgrade_fd: ?posix.fd_t = null;
    var insecure_tls: bool = false;
    var trace: bool = false;
    var tls_trace: bool = false;
    var otel_endpoint: ?[]const u8 = null;

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
                    const backend_host = try allocator.dupe(u8, backend_str[0..colon]);
                    const port_str = backend_str[colon + 1 ..];
                    const backend_port = try std.fmt.parseInt(u16, port_str, 10);
                    // Detect https:// scheme for TLS backends
                    const use_tls = std.mem.startsWith(u8, backend_host, "https://") or backend_port == 443;
                    try backend_list.append(
                        allocator,
                        .{ .host = backend_host, .port = backend_port, .use_tls = use_tls },
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
        } else if (std.mem.eql(u8, arg, "--config") or
                   std.mem.eql(u8, arg, "-c")) {
            if (i + 1 < args.len) {
                config_path = try allocator.dupe(u8, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--loglevel") or
                   std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.len) {
                const level_str = args[i + 1];
                if (std.mem.eql(u8, level_str, "err") or std.mem.eql(u8, level_str, "error")) {
                    runtime_log_level = .err;
                } else if (std.mem.eql(u8, level_str, "warn") or std.mem.eql(u8, level_str, "warning")) {
                    runtime_log_level = .warn;
                } else if (std.mem.eql(u8, level_str, "info")) {
                    runtime_log_level = .info;
                } else if (std.mem.eql(u8, level_str, "debug")) {
                    runtime_log_level = .debug;
                } else {
                    std.debug.print("Invalid log level: {s}. Use: err, warn, info, debug\n", .{level_str});
                    return error.InvalidLogLevel;
                }
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--insecure") or
                   std.mem.eql(u8, arg, "-k")) {
            insecure_tls = true;
        } else if (std.mem.eql(u8, arg, "--trace") or
                   std.mem.eql(u8, arg, "-t")) {
            trace = true;
        } else if (std.mem.eql(u8, arg, "--tls-trace")) {
            tls_trace = true;
        } else if (std.mem.eql(u8, arg, "--otel-endpoint")) {
            if (i + 1 < args.len) {
                otel_endpoint = try allocator.dupe(u8, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--upgrade-fd")) {
            if (i + 1 < args.len) {
                upgrade_fd = try std.fmt.parseInt(posix.fd_t, args[i + 1], 10);
                i += 1;
            }
        }
    }

    // Warn if insecure TLS is enabled
    if (insecure_tls) {
        std.debug.print("WARNING: TLS certificate verification disabled. Do not use in production!\n", .{});
    }

    // Notify if trace mode is enabled
    if (trace) {
        std.debug.print("TRACE: Payload hex/ASCII dumps enabled (may impact performance)\n", .{});
    }

    // Notify if TLS trace mode is enabled
    if (tls_trace) {
        std.debug.print("TLS-TRACE: Detailed TLS handshake info enabled\n", .{});
    }

    // Notify if OpenTelemetry tracing is enabled
    if (otel_endpoint) |endpoint| {
        std.debug.print("OTEL: OpenTelemetry tracing enabled, endpoint: {s}\n", .{endpoint});
    }

    // Use default mode if not specified
    const final_mode = mode orelse RunMode.default();

    // Load backends from config file if provided
    if (config_path) |path| {
        var parsed = config_watcher.parseConfigFile(allocator, path) catch |err| {
            std.debug.print("Failed to parse config file '{s}': {s}\n", .{ path, @errorName(err) });
            return error.ConfigParseError;
        };
        defer parsed.deinit();

        // Copy backends from parsed config
        for (parsed.backends) |b| {
            const h = try allocator.dupe(u8, b.host);
            try backend_list.append(allocator, .{
                .host = h,
                .port = b.port,
                .weight = b.weight,
                .use_tls = b.use_tls,
            });
        }
    }

    // Provide defaults when user doesn't specify backends
    if (backend_list.items.len == 0) {
        try backend_list.append(
            allocator,
            .{ .host = try allocator.dupe(u8, "127.0.0.1"), .port = 9001 },
        );
        try backend_list.append(
            allocator,
            .{ .host = try allocator.dupe(u8, "127.0.0.1"), .port = 9002 },
        );
    }

    return .{
        .mode = final_mode,
        .config_path = config_path,
        .upgrade_fd = upgrade_fd,
        .insecure_tls = insecure_tls,
        .trace = trace,
        .tls_trace = tls_trace,
        .otel_endpoint = otel_endpoint,
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
    // Free each allocated backend host string
    for (config.lbConfig.backends) |backend| {
        allocator.free(backend.host);
    }
    allocator.free(config.lbConfig.backends);

    // Free the otel_endpoint if it was allocated
    if (config.otel_endpoint) |endpoint| {
        allocator.free(endpoint);
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    // Store argv for binary hot reload
    upgrade_argv = std.os.argv[0..];
    upgrade_exe_path = std.os.argv[0];

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const config = try parseArgs(allocator);
    defer freeConfig(allocator, config);

    // Set runtime TLS mode (before spawning workers)
    config_mod.setInsecureTls(config.insecure_tls);

    // Set runtime trace mode
    config_mod.setTraceEnabled(config.trace);

    // Set runtime TLS trace mode
    config_mod.setTlsTraceEnabled(config.tls_trace);

    // Initialize OpenTelemetry tracing if endpoint is provided
    if (config.otel_endpoint) |endpoint| {
        telemetry.init(allocator, endpoint) catch |err| {
            log.err("Failed to initialize telemetry: {s}", .{@errorName(err)});
        };
    }
    defer telemetry.deinit();

    // Validate configuration
    try config.lbConfig.validate();

    std.debug.print("=== Load Balancer ({s} mode) ===\n", .{config.mode.toString()});
    log.info("Listen: {s}:{d}, Backends: {d}, Strategy: {s}", .{
        config.lbConfig.host,
        config.lbConfig.port,
        config.lbConfig.backends.len,
        @tagName(config.lbConfig.strategy),
    });

    // Dispatch to appropriate mode
    switch (config.mode) {
        .multiprocess => try runMultiProcess(allocator, config),
        .singleprocess => try runSingleProcess(allocator, config),
    }
}

// ============================================================================
// Multi-Process Mode
// ============================================================================

fn runMultiProcess(allocator: std.mem.Allocator, config: Config) !void {
    var mutable_lb_config = config.lbConfig;

    // Auto-detect worker count if not specified
    if (mutable_lb_config.worker_count == 0) {
        mutable_lb_config.worker_count = try std.Thread.getCpuCount();
    }

    // Create shared memory region (visible to all forked workers)
    var shared_allocator = shared_region.SharedRegionAllocator{};
    const region = try shared_allocator.init();
    defer shared_allocator.deinit();

    // Initialize backends in shared region
    initSharedBackends(region, mutable_lb_config.backends);

    log.info("Workers: {d}", .{mutable_lb_config.worker_count});
    for (mutable_lb_config.backends, 0..) |b, idx| {
        log.info("  Backend {d}: {s}:{d}", .{ idx + 1, b.host, b.port });
    }

    // Start config file watcher for hot reload (if config file provided)
    if (config.config_path) |path| {
        const watcher_thread = try config_watcher.startConfigWatcher(region, path, allocator, reloadSharedBackends);
        _ = watcher_thread; // Thread runs until process exits
        log.info("Config watcher started: {s}", .{path});
    }

    try spawnWorkers(allocator, &mutable_lb_config, region);
}

/// Initialize backends in the shared region's double buffer
fn initSharedBackends(region: *shared_region.SharedRegion, backends: []const BackendDef) void {
    // Write to inactive buffer
    var inactive = region.getInactiveBackends();
    const count = @min(backends.len, shared_region.MAX_BACKENDS);

    for (backends[0..count], 0..) |b, i| {
        inactive[i].setHost(b.host);
        inactive[i].port = b.port;
        inactive[i].weight = b.weight;
        inactive[i].use_tls = b.use_tls;
    }

    // Atomically switch to make them active
    _ = region.control.switchActiveArray(@intCast(count));

    // Initialize health state for all backends
    region.health.markAllHealthy(count);

    log.info("Initialized {d} backends in shared region", .{count});
}

/// Hot-reload backends atomically (for use by config watcher)
/// Workers continue reading from the old buffer until the atomic switch
pub fn reloadSharedBackends(region: *shared_region.SharedRegion, backends: []const BackendDef) void {
    // Write new config to inactive buffer
    var inactive = region.getInactiveBackends();
    const count = @min(backends.len, shared_region.MAX_BACKENDS);

    // Clear inactive buffer first (in case new config has fewer backends)
    for (inactive) |*b| {
        b.* = .{};
    }

    for (backends[0..count], 0..) |b, i| {
        inactive[i].setHost(b.host);
        inactive[i].port = b.port;
        inactive[i].weight = b.weight;
        inactive[i].use_tls = b.use_tls;
    }

    // Atomically switch - workers immediately see new config
    const gen = region.control.switchActiveArray(@intCast(count));

    // Reset health for all backends (new backends start healthy)
    region.health.markAllHealthy(count);

    log.warn("Hot-reloaded {d} backends (generation {d})", .{ count, gen });
}

// Spawn worker processes and monitor for crashes
fn spawnWorkers(
    allocator: std.mem.Allocator,
    config: *const LoadBalancerConfig,
    region: *shared_region.SharedRegion,
) !void {
    var worker_pids = try allocator.alloc(posix.pid_t, config.worker_count);
    defer allocator.free(worker_pids);

    for (0..config.worker_count) |worker_id| {
        worker_pids[worker_id] = try forkWorker(config, region, worker_id);
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
            try restartWorker(config, region, worker_pids, result.pid);
        }
    }
}

// Fork a single worker process
fn forkWorker(
    config: *const LoadBalancerConfig,
    region: *shared_region.SharedRegion,
    worker_id: usize,
) !posix.pid_t {
    const pid = try posix.fork();
    if (pid == 0) {
        // CPU affinity is set INSIDE workerMain, AFTER Io.Threaded.init
        workerMain(config, region, worker_id) catch |err| {
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
    region: *shared_region.SharedRegion,
    worker_pids: []posix.pid_t,
    crashed_pid: posix.pid_t,
) !void {
    for (worker_pids, 0..) |pid, worker_id| {
        if (pid == crashed_pid) {
            log.warn("Worker {d} died, restarting...", .{worker_id});
            worker_pids[worker_id] = try forkWorker(config, region, worker_id);
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

fn workerMain(
    config: *const LoadBalancerConfig,
    region: *shared_region.SharedRegion,
    worker_id: usize,
) !void {
    // Thread-safe allocator since health probes run in separate thread
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Connection pool (with allocator for HTTP/2 multiplexing)
    var connection_pool = simple_pool.SimpleConnectionPool{};
    defer connection_pool.deinit();

    // Backends (still using config for BackendServer list, but health is shared)
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    for (config.backends) |b| {
        try backends.append(allocator, types.BackendServer.init(b.host, b.port, b.weight));
    }
    connection_pool.addBackends(backends.items.len);

    // Use shared health state from mmap'd region
    var worker_state = mp.WorkerState.init(&backends, &connection_pool, &region.health, .{
        .circuit_breaker_config = .{
            .unhealthy_threshold = config.unhealthy_threshold,
            .healthy_threshold = config.healthy_threshold,
        },
        .probe_interval_ms = config.probe_interval_ms,
        .probe_timeout_ms = config.probe_timeout_ms,
        .health_path = config.health_path,
    });
    worker_state.setWorkerId(worker_id);
    worker_state.setSharedRegion(region);

    // Initialize HTTP/2 connection pool (TigerBeetle style)
    var h2_pool_new = H2ConnectionPool.init(backends.items, allocator);
    worker_state.h2_pool = &h2_pool_new;

    log.info("Worker {d}: Starting with {d} backends (shared health)", .{
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

    // CRITICAL: Increase async_limit to prevent synchronous fallback deadlock
    // Default is CPU cores - 1. With HTTP/2 multiplexing, each connection spawns
    // a reader task. If async_limit is exceeded, Io.async runs synchronously,
    // blocking the request coroutine forever (reader waits for data, request
    // never gets to wait on its condition).
    // Set to unlimited so reader tasks always spawn asynchronously.
    threaded.setAsyncLimit(.unlimited);

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

    // Clean up H2 connection pool on shutdown
    h2_pool_new.deinit(io);
}

// ============================================================================
// Single-Process Mode
// ============================================================================

var sp_server: Server = undefined;

/// Stored argv for binary upgrade re-exec
var upgrade_argv: ?[][*:0]u8 = null;
var upgrade_exe_path: ?[*:0]u8 = null;

fn spShutdown(_: std.c.SIG) callconv(.c) void {
    sp_server.stop();
}

fn spUpgrade(_: std.c.SIG) callconv(.c) void {
    const my_pid = std.c.getpid();
    std.debug.print("[PID {d}] SIGUSR2 received, forking...\n", .{my_pid});

    // Fork and exec new binary
    const pid = posix.fork() catch |err| {
        std.debug.print("[PID {d}] Fork failed: {s}\n", .{ my_pid, @errorName(err) });
        return;
    };

    if (pid == 0) {
        // Child: exec new binary
        const child_pid = std.c.getpid();
        std.debug.print("[PID {d}] Child started, execing new binary...\n", .{child_pid});
        if (upgrade_exe_path) |exe| {
            if (upgrade_argv) |argv| {
                const env: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
                const result = posix.execvpeZ(exe, @ptrCast(argv.ptr), env);
                std.debug.print("[PID {d}] Exec failed: {s}\n", .{ child_pid, @errorName(result) });
            }
        }
        posix.exit(1);
    } else {
        // Parent: stop accepting, drain connections
        std.debug.print("[PID {d}] Spawned child PID {d}. Waiting 1s for new process...\n", .{ my_pid, pid });
        // Wait for new process to start listening
        posix.nanosleep(1, 0); // 1 second
        std.debug.print("[PID {d}] Draining connections and exiting...\n", .{my_pid});
        sp_server.stop();
    }
}

fn runSingleProcess(parent_allocator: std.mem.Allocator, config: Config) !void {
    // Thread-safe allocator since health probes run in separate thread
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const lb_config = config.lbConfig;

    for (lb_config.backends, 0..) |b, idx| {
        log.info("  Backend {d}: {s}:{d}", .{ idx + 1, b.host, b.port });
    }

    // Shared region (same as mp mode - enables hot reload and shared RR counter)
    var shared_allocator = shared_region.SharedRegionAllocator{};
    const region = try shared_allocator.init();
    defer shared_allocator.deinit();

    // Initialize backends in shared region
    initSharedBackends(region, lb_config.backends);

    // Start config file watcher for hot reload (if config file provided)
    if (config.config_path) |path| {
        const watcher_thread = try config_watcher.startConfigWatcher(region, path, parent_allocator, reloadSharedBackends);
        _ = watcher_thread; // Thread runs until process exits
        log.info("Config watcher started: {s}", .{path});
    }

    // Connection pool (with allocator for HTTP/2 multiplexing)
    var connection_pool = simple_pool.SimpleConnectionPool{};
    defer connection_pool.deinit();

    // Backends
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    for (lb_config.backends) |b| {
        try backends.append(allocator, types.BackendServer.init(b.host, b.port, b.weight));
    }
    connection_pool.addBackends(backends.items.len);

    var worker_state = mp.WorkerState.init(&backends, &connection_pool, &region.health, .{
        .circuit_breaker_config = .{
            .unhealthy_threshold = lb_config.unhealthy_threshold,
            .healthy_threshold = lb_config.healthy_threshold,
        },
        .probe_interval_ms = lb_config.probe_interval_ms,
        .probe_timeout_ms = lb_config.probe_timeout_ms,
        .health_path = lb_config.health_path,
    });
    worker_state.setWorkerId(0);
    worker_state.setSharedRegion(region);

    // Initialize HTTP/2 connection pool (TigerBeetle style)
    var h2_pool_sp = H2ConnectionPool.init(backends.items, allocator);
    worker_state.h2_pool = &h2_pool_sp;

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

    // CRITICAL: Increase async_limit to prevent synchronous fallback deadlock
    // See comment in workerMain for details.
    threaded.setAsyncLimit(.unlimited);

    // Router
    var router = switch (lb_config.strategy) {
        inline else => |s| try createRouter(allocator, &worker_state, s),
    };
    defer router.deinit(allocator);

    // No SO_REUSEPORT needed for single process
    const addr = try Io.net.IpAddress.parse(lb_config.host, lb_config.port);
    var socket = try addr.listen(io, .{
        .kernel_backlog = 4096,
        .reuse_address = true,
    });
    defer socket.deinit(io);

    log.info("Listening on {s}:{d}", .{ lb_config.host, lb_config.port });

    // Server
    sp_server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 32,
        .keepalive_count_max = null, // unlimited
        .connection_count_max = 10000,
    });
    defer sp_server.deinit();

    try sp_server.serve(io, &router, &socket);

    // Clean up H2 connection pool on shutdown
    h2_pool_sp.deinit(io);
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
    posix.sigaction(posix.SIG.USR2, &.{
        .handler = .{ .handler = spUpgrade },
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
