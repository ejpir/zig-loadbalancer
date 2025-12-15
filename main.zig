const std = @import("std");
const log = std.log.scoped(.@"examples/load_balancer");

// Override the root log level for all release builds to ensure debug/info messages are visible
pub const std_options: std.Options = .{
    .log_level = .err, // Use .info for debugging, .err for benchmarks
    .logFn = @import("src/utils/logging.zig").customLog,
};

const zzz = @import("zzz");
const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Socket = tardy.Socket;

// Import modules
const cli = @import("src/utils/cli.zig");
const logging = @import("src/utils/logging.zig");
const connection_pool_mod = @import("src/memory/connection_pool.zig");
const types = @import("src/core/types.zig");
const config_module = @import("src/config/config.zig");
const config_updater = @import("src/config/config_updater.zig");
const health_runner = @import("src/health/health_runner.zig");
const server_mod = @import("src/core/server.zig");

// Use types from modules
const LockFreeConnectionPool = connection_pool_mod.LockFreeConnectionPool;
const ConfigWatcher = config_module.ConfigWatcher;

// Global connection pool - exported for proxy module to access
pub var connection_pool = LockFreeConnectionPool{
    .pools = undefined,
    .allocator = undefined,
    .initialized = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Parse command line arguments
    const config = try cli.parseArgs(allocator);
    defer {
        // Free all allocated strings in config
        allocator.free(config.host);
        allocator.free(config.sticky_session_cookie_name);
        if (config.config_file_path) |path| allocator.free(path);
        // backends are freed in config_updater.deinitConfig()
    }

    // Initialize logging
    const log_filename = try logging.initLogging(allocator, config.log_file);
    defer {
        logging.deinitLogging();
        allocator.free(log_filename);
    }

    log.info("Load balancer starting", .{});

    // Initialize the lock-free connection pool
    try connection_pool.init(allocator);
    defer connection_pool.deinit();

    // Add backends to the connection pool
    try connection_pool.addBackends(config.backends.items.len);

    // Initialize tardy runtime with higher limits for better concurrency
    var t = try Tardy.init(allocator, .{
        .threading = .{ .multi = 50 },
        .pooling = .grow,
        .size_tasks_initial = 4096, // More task slots
        .size_aio_reap_max = 4096, // Process more I/O events per cycle
    });
    defer t.deinit();

    // Set up request queues for pipelining (one per backend for thread safety)
    const request_queues = try allocator.alloc(types.RequestQueue, config.backends.items.len);
    defer {
        for (request_queues) |*queue| {
            queue.deinit();
        }
        allocator.free(request_queues);
    }

    // Initialize each queue
    for (request_queues) |*queue| {
        queue.* = types.RequestQueue.init(allocator);
    }

    log.info("HTTP pipelining: Initialized {d} request queues", .{request_queues.len});

    // Initialize global configuration
    try config_updater.initConfig(allocator, config.backends, &connection_pool, config.strategy, config.sticky_session_cookie_name, request_queues);
    defer config_updater.deinitConfig(allocator);

    // Initialize health checker
    const health_checker = try health_runner.initHealthChecker(allocator, config.backends.items, null);
    defer allocator.destroy(health_checker);

    // Register health_checker with the config updater
    config_updater.setHealthChecker(health_checker);

    // Create optimized router with comptime-specialized handlers for the HTTP server
    var router = try server_mod.createOptimizedRouter(allocator, config_updater.proxy_config);
    defer router.deinit(allocator);

    // Create socket for the HTTP server
    var socket = try server_mod.createSocket(config.host, config.port);
    defer socket.close_blocking();

    // Initialize config watcher if enabled
    var config_watcher: ?*ConfigWatcher = null;
    defer if (config_watcher) |watcher| watcher.deinit();

    if (config.watch_config and config.config_file_path != null) {
        log.info("Initializing config file watcher", .{});
        config_watcher = try ConfigWatcher.init(allocator, config.config_file_path.?, config.watch_interval_ms, config_updater.onConfigChanged);
    }

    // Setup summary
    log.info("Load balancer is ready:", .{});
    log.info("  - Listening on: {s}:{d}", .{ config.host, config.port });
    log.info("  - Backends count: {d}", .{config.backends.items.len});
    log.info("  - Strategy: {s}", .{@tagName(config.strategy)});
    log.info("  - Connection pool: {d} connections per backend (total capacity: {d})", .{ LockFreeConnectionPool.MAX_IDLE_CONNS, LockFreeConnectionPool.MAX_IDLE_CONNS * config.backends.items.len });

    // Log connection pool settings details
    log.info("  - Connection pool details:", .{});
    log.info("    - Max idle connections per backend: {d}", .{LockFreeConnectionPool.MAX_IDLE_CONNS});
    log.info("    - Max backends supported: {d}", .{LockFreeConnectionPool.MAX_BACKENDS});
    log.info("    - Pool implementation: Lock-free static size pool", .{});

    // Log the initial connection pool status
    connection_pool.logPoolStatus() catch |err| {
        log.err("Failed to log initial pool status: {s}", .{@errorName(err)});
    };

    if (config.strategy == .sticky) {
        log.info("  - Sticky session cookie: {s}", .{config.sticky_session_cookie_name});
    }

    // Start the server
    try t.entry(
        server_mod.ServerContext{
            .router = &router,
            .socket = socket,
            .health_checker = health_checker,
            .config_watcher = config_watcher,
            .connection_pool = &connection_pool,
        },
        server_mod.entryFunction,
    );
}
