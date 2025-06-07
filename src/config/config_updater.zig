const std = @import("std");
const types = @import("../core/types.zig");
const config_module = @import("config.zig");
const health_check_mod = @import("../health/health_check.zig");
const connection_pool_mod = @import("../memory/connection_pool.zig");
const tardy = @import("zzz").tardy;
const Runtime = tardy.Runtime;

const BackendServer = types.BackendServer;
const BackendsList = types.BackendsList;
const ConfigWatcher = config_module.ConfigWatcher;

// Global variables to track the current configuration
pub var global_backends: *BackendsList = undefined;
pub var proxy_config: *types.ProxyConfig = undefined;

// Central registry of components that need to be updated on config changes
pub const ConfigContext = struct {
    connection_pool: *connection_pool_mod.LockFreeConnectionPool,
    health_checker: ?*health_check_mod.HealthChecker,
};

pub var config_context: ConfigContext = undefined;

/// Task context for asynchronous config updates
/// Runs in a separate spawned task to avoid blocking the config watcher
const ConfigUpdateTask = struct {
    watcher: *ConfigWatcher,
    new_backends: BackendsList,
    allocator: std.mem.Allocator,
    runtime: *Runtime,
};

// Initialize global configuration objects
pub fn initConfig(
    allocator: std.mem.Allocator, 
    backends: BackendsList,
    connection_pool: *connection_pool_mod.LockFreeConnectionPool,
    strategy: types.LoadBalancerStrategy,
    sticky_session_cookie_name: []const u8,
    request_queues: []types.RequestQueue,
) !void {
    // Store configuration context for updates
    config_context = .{
        .connection_pool = connection_pool,
        .health_checker = null,
    };

    // Store backends in a global variable
    global_backends = try allocator.create(BackendsList);
    global_backends.* = backends;

    // Create proxy config struct
    proxy_config = try allocator.create(types.ProxyConfig);
    proxy_config.* = .{
        .backends = global_backends,
        .connection_pool = connection_pool,
        .strategy = strategy,
        .sticky_session_cookie_name = sticky_session_cookie_name,
        .request_queues = request_queues,
    };
}

// Set health checker reference
pub fn setHealthChecker(health_checker: *health_check_mod.HealthChecker) void {
    config_context.health_checker = health_checker;
}

// Cleanup global configuration objects
pub fn deinitConfig(allocator: std.mem.Allocator) void {
    allocator.destroy(global_backends);
    allocator.destroy(proxy_config);
}

/// Async task wrapper for config updates
/// Handles memory management and delegates to the actual update function
fn configUpdateTaskWrapper(task_ptr: *ConfigUpdateTask) !void {
    defer task_ptr.allocator.destroy(task_ptr);
    try configUpdateTaskAsync(task_ptr.*);
}

/// Asynchronous config update function that runs in a separate task
/// This prevents blocking the config watcher during potentially slow operations
fn configUpdateTaskAsync(task: ConfigUpdateTask) !void {
    const cfg_log = std.log.scoped(.@"config_updater_async");
    const allocator = task.allocator;
    const new_backends = task.new_backends;

    cfg_log.info("Async config update started: {d} -> {d} backends", .{
        global_backends.items.len, new_backends.items.len
    });

    // Log the details of the new backends
    for (new_backends.items, 0..) |backend, i| {
        cfg_log.info("  - Backend {d}: {s}:{d} (weight: {d})", .{
            i + 1, backend.getFullHost(), backend.port, backend.weight
        });
    }

    // Create a temporary list to copy the old backends
    var old_backends_copy = BackendsList.init(allocator);
    defer old_backends_copy.deinit();

    // Copy the old backends so we can free them after applying the changes
    for (global_backends.items) |backend| {
        const host_copy = try allocator.dupe(u8, backend.getFullHost());
        const backend_copy = BackendServer.init(host_copy, backend.port, backend.weight);
        try old_backends_copy.append(backend_copy);
    }

    // Create a new array of backends
    try config_context.connection_pool.reconfigureBackends(new_backends.items.len);

    // Apply the new configuration by replacing the global_backends items
    global_backends.deinit();
    global_backends.* = new_backends;

    // Update the proxy config to use the new backends
    proxy_config.backends = global_backends;
    
    // Increment backend version to invalidate cached state (triggers cache refresh)
    const old_version = proxy_config.backend_version.fetchAdd(1, .monotonic);
    cfg_log.info("Backend version updated: {d} -> {d} (cache invalidated)", .{old_version, old_version + 1});
    
    // Update the health checker with the new backends
    if (config_context.health_checker) |hc| {
        try hc.updateBackends(new_backends.items);
    }

    // Free the old backends
    for (old_backends_copy.items) |backend| {
        allocator.free(backend.getFullHost());
    }

    cfg_log.info("Async config update completed successfully", .{});
}

// Handler function called when the config file changes - now spawns async task
pub fn onConfigChanged(rt: *Runtime, watcher: *ConfigWatcher, new_backends: BackendsList) !void {
    const cfg_log = std.log.scoped(.@"config_watcher");
    const allocator = watcher.allocator;

    cfg_log.info("Config change detected: {d} -> {d} backends, spawning async update task", .{
        global_backends.items.len, new_backends.items.len
    });

    // Create a task context on the heap for the async config update
    const task_context = try allocator.create(ConfigUpdateTask);
    task_context.* = .{
        .watcher = watcher,
        .new_backends = new_backends,
        .allocator = allocator,
        .runtime = rt,
    };

    // Spawn the config update task with generous stack space for complex operations
    rt.spawn(.{task_context}, configUpdateTaskWrapper, 1024 * 64) catch |err| {
        cfg_log.err("Failed to spawn config update task: {s}", .{@errorName(err)});
        
        // Clean up the task context since spawn failed
        allocator.destroy(task_context);
        
        // Also clean up the backends since we won't process them
        for (new_backends.items) |backend| {
            allocator.free(backend.getFullHost());
        }
        new_backends.deinit();
        
        return err;
    };

    cfg_log.info("Config update task spawned successfully", .{});
}