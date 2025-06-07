const std = @import("std");
const log = std.log.scoped(.@"health_runner");

const tardy = @import("zzz").tardy;
const Runtime = tardy.Runtime;
const Timer = tardy.Timer;

const health_check_mod = @import("health_check.zig");
const HealthChecker = health_check_mod.HealthChecker;
const connection_pool_mod = @import("../memory/connection_pool.zig");

// Health checker context type for type-safety
pub const HealthCheckerContext = struct {
    checker: *HealthChecker,
    connection_pool: *connection_pool_mod.LockFreeConnectionPool,
};

// Note: Global health checker reference removed - use proper dependency injection instead
// Health checker is now passed via HealthCheckerContext and ConfigContext patterns

// Health check routine that runs periodically
pub fn runHealthChecks(rt: *Runtime, context: HealthCheckerContext) !void {
    log.info("Started health check routine", .{});

    // Initial delay to allow server startup
    try Timer.delay(rt, .{ .seconds = 1, .nanos = 0 });
    log.info("Initial delay complete, beginning health checks", .{});

    // Variable to track elapsed time for connection pool status logging
    var last_pool_status_time: i64 = std.time.milliTimestamp();
    const POOL_STATUS_INTERVAL_MS: i64 = 10000; // Log pool status every 10 seconds

    // Perform health checks in a loop
    while (true) {
        // Wrap health check in an error catch block to avoid crashing the thread
        context.checker.checkHealth(rt) catch |err| {
            log.err("Health check failed: {s}. Will retry later.", .{@errorName(err)});
        };

        // Log connection pool status periodically
        const current_time = std.time.milliTimestamp();
        if (current_time - last_pool_status_time >= POOL_STATUS_INTERVAL_MS) {
            // Wrap in a catch block to prevent crashes
            if (context.connection_pool.logPoolStatus()) {
                // Success
            } else |err| {
                log.err("Failed to log pool status: {s}", .{@errorName(err)});
            }
            last_pool_status_time = current_time;
        }

        // Short delay between health check cycles - use a longer delay for now to reduce CPU usage
        try Timer.delay(rt, .{ .seconds = 2, .nanos = 0 });
    }
}

pub fn initHealthChecker(
    allocator: std.mem.Allocator, 
    backends: []const @import("../core/types.zig").BackendServer,
    health_check_config: ?health_check_mod.HealthCheckConfig
) !*HealthChecker {
    const checker_ptr = try allocator.create(HealthChecker);
    errdefer allocator.destroy(checker_ptr);
    
    checker_ptr.* = try HealthChecker.init(
        allocator, 
        backends, 
        null, 
        health_check_config orelse .{
            .path = "/",
            .interval_ms = 5000,
            .timeout_ms = 2000,
            .healthy_threshold = 2,
            .unhealthy_threshold = 3,
        }
    );
    
    // Note: Health checker reference is returned and managed via proper dependency injection
    // No global state needed - caller handles registration with ConfigContext
    
    return checker_ptr;
}