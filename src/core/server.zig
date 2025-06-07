/// Asynchronous HTTP Server with Comptime Router Specialization
/// 
/// This module provides the main HTTP server implementation with advanced
/// performance optimizations and runtime features:
/// 
/// ## Comptime Router Generation
/// 
/// Instead of runtime dispatch, routers are specialized at compile time for
/// each load balancing strategy, generating optimal assembly code paths:
/// 
/// - `createSpecializedRouter()`: Comptime router for known strategies
/// - `createOptimizedRouter()`: Runtime dispatcher to specialized routers
/// - Strategy-specific handler generation eliminates virtual calls
/// 
/// ## Async I/O Architecture
/// 
/// Built on zzz's tardy async runtime:
/// - Multi-threaded event loop with work stealing
/// - Zero-copy network operations where possible
/// - Efficient connection management with keep-alive
/// - Non-blocking I/O for maximum throughput
/// 
/// ## Performance Tuning
/// 
/// Server is configured for high-performance scenarios:
/// - 8MB stack size for deep call chains (TLS, compression)
/// - 16KB socket buffers for large HTTP payloads
/// - 10,000 max concurrent connections
/// - 100 keep-alive connections per socket
/// - 4096 listen backlog for burst traffic
/// 
/// ## Service Coordination
/// 
/// The server coordinates multiple background services:
/// - HTTP request handling on worker threads
/// - Health checking on dedicated thread
/// - Configuration file watching (optional)
/// - Metrics collection and reporting
/// - Connection pool management
/// 
/// ## Thread Safety
/// 
/// All shared state uses atomic operations or lock-free data structures:
/// - Backend health state (atomic flags)
/// - Configuration updates (atomic swaps)
/// - Connection pools (lock-free stacks)
/// - Metrics counters (atomic increments)
const std = @import("std");
const log = std.log.scoped(.@"server");

const zzz = @import("zzz");
const http = zzz.HTTP;
const tardy = zzz.tardy;

const Socket = tardy.Socket;
const Runtime = tardy.Runtime;
const Router = http.Router;
const Server = http.Server;
const Route = http.Route;
const Context = http.Context;

const proxy = @import("proxy.zig");
const types = @import("types.zig");
const health_runner = @import("../health/health_runner.zig");
const config_module = @import("../config/config.zig");
const config_updater = @import("../config/config_updater.zig");
const health_check_mod = @import("../health/health_check.zig");
const connection_pool_mod = @import("../memory/connection_pool.zig");
const metrics = @import("../utils/metrics.zig");

/// Create a comptime-specialized router for optimal assembly generation
pub fn createSpecializedRouter(allocator: std.mem.Allocator, proxy_config: *types.ProxyConfig, comptime strategy: types.LoadBalancerStrategy) !Router {
    const specialized_handler = proxy.generateSpecializedHandler(strategy);
    
    const router = try Router.init(allocator, &.{
        Route.init("/metrics").get({}, metrics.metricsHandler).layer(),
        Route.init("/").all(proxy_config, specialized_handler).layer(),
    }, .{});
    
    return router;
}

/// Runtime dispatcher that selects the appropriate specialized router
pub fn createOptimizedRouter(allocator: std.mem.Allocator, proxy_config: *types.ProxyConfig) !Router {
    // Use comptime dispatch to select the optimal handler at runtime
    return switch (proxy_config.strategy) {
        inline .round_robin => createSpecializedRouter(allocator, proxy_config, .round_robin),
        inline .weighted_round_robin => createSpecializedRouter(allocator, proxy_config, .weighted_round_robin),
        inline .random => createSpecializedRouter(allocator, proxy_config, .random),
        inline .sticky => createSpecializedRouter(allocator, proxy_config, .sticky),
    };
}

/// Legacy router creation (kept for compatibility)
pub fn createRouter(allocator: std.mem.Allocator, proxy_config: *types.ProxyConfig) !Router {
    const router = try Router.init(allocator, &.{
        Route.init("/metrics").get({}, metrics.metricsHandler).layer(),
        Route.init("/").all(proxy_config, proxy.loadBalanceHandler).layer(),
    }, .{});
    
    return router;
}

// Create and bind socket for the HTTP server
pub fn createSocket(host: []const u8, port: u16) !Socket {
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    try socket.bind();
    try socket.listen(4096); // Significantly increased listen backlog for load testing
    
    return socket;
}

pub const ServerContext = struct {
    router: *const Router,
    socket: Socket, 
    health_checker: *health_check_mod.HealthChecker,
    config_watcher: ?*config_module.ConfigWatcher,
    connection_pool: *connection_pool_mod.LockFreeConnectionPool,
};

// Entry function for tardy runtime
pub fn entryFunction(rt: *Runtime, p: ServerContext) !void {
    switch (rt.id) {
        0 => {
            try p.health_checker.start(rt);
            try rt.spawn(.{ 
                rt, 
                health_runner.HealthCheckerContext{
                    .checker = p.health_checker,
                    .connection_pool = p.connection_pool,
                }
            }, health_runner.runHealthChecks, 1024 * 1024 * 8);
            
            // Start config watcher if enabled
            if (p.config_watcher) |watcher| {
                log.info("Starting config file watcher", .{});
                try watcher.start(rt);
            }
        },
        else => {
            log.info("Starting http server", .{});
            var server = Server.init(.{
                .stack_size = 1024 * 1024 * 8, // Doubled stack size for request handling
                .socket_buffer_bytes = 1024 * 16, // Increased buffer size for larger requests
                .keepalive_count_max = 100, // Set a reasonable keepalive limit
                .connection_count_max = 10000, // Increased max connections to handle load tests
            });
            server.serve(rt, p.router, .{ .normal = p.socket }) catch |err| {
                log.err("Server failed to serve: {s}", .{@errorName(err)});
            };
        },
    }
}