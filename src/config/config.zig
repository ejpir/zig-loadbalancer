/// Configuration Management with Hot Reloading Support
/// 
/// YAML-based configuration with file watching for runtime backend updates.
/// Supports live configuration changes without service interruption.
const std = @import("std");
const types = @import("../core/types.zig");
const yaml = @import("yaml");
const tardy = @import("zzz").tardy;
const Runtime = tardy.Runtime;
const Timer = tardy.Timer;

const BackendServer = types.BackendServer;
const BackendsList = types.BackendsList;
const Yaml = yaml.Yaml;

/// YAML-compatible definition of a backend that can be loaded from config
pub const BackendConfig = struct {
    host: []const u8,
    port: u16,
    weight: ?u16 = null, // Optional in YAML
};

/// Configuration for the load balancer
pub const Config = struct {
    host: []const u8,
    port: u16,
    backends: BackendsList,
    strategy: types.LoadBalancerStrategy = .random,
    sticky_session_cookie_name: []const u8 = "ZZZ_BACKEND_ID",
    log_file: ?[]const u8 = null,
    config_file_path: ?[]const u8 = null, // Store config file path for hot reloading
    watch_config: bool = false, // Enable config file watching
    watch_interval_ms: u32 = 2000, // Check interval in milliseconds
};

/// Parse a host:port string into a BackendServer struct
pub fn parseBackendAddress(allocator: std.mem.Allocator, addr: []const u8) !BackendServer {
    const colon_index = std.mem.indexOf(u8, addr, ":") orelse return error.InvalidFormat;

    const host = addr[0..colon_index];
    const port_str = addr[colon_index + 1 ..];

    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;

    const host_copy = try allocator.dupe(u8, host);
    errdefer allocator.free(host_copy);

    return BackendServer.init(host_copy, port, 1);
}

/// Parse a YAML file into a list of backend servers
pub fn parseYamlConfig(allocator: std.mem.Allocator, file_path: []const u8) !BackendsList {
    const log = std.log.scoped(.@"yaml_config");
    log.info("Loading YAML configuration from file: {s}", .{file_path});
    
    var backends = try BackendsList.initCapacity(allocator, 0);
    errdefer {
        // Free all allocated host strings on error
        for (backends.items) |backend| {
            allocator.free(backend.getFullHost());
        }
        backends.deinit(allocator);
    }
    
    // Open file
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    // Read file contents
    const file_content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(file_content);
    
    log.debug("YAML file size: {d} bytes", .{file_content.len});
    
    // Parse YAML using the library
    var yaml_parser = Yaml{ .source = file_content };
    defer yaml_parser.deinit(allocator);
    
    // Load and parse the YAML document
    try yaml_parser.load(allocator);
    
    // Verify we have at least one document
    if (yaml_parser.docs.items.len == 0) return error.NoDocuments;
    
    // Get the root document map
    const root_value = yaml_parser.docs.items[0];
    if (root_value != .map) return error.InvalidFormat;
    
    // Get the backends array
    const root_map = root_value.map;
    if (!root_map.contains("backends")) return error.BackendsNotFound;
    
    const backends_value = root_map.get("backends").?;
    if (backends_value != .list) return error.BackendsNotSequence;
    
    // Process each backend in the list
    for (backends_value.list) |backend_item| {
        if (backend_item != .map) continue;
        
        const backend_map = backend_item.map;
        
        // Get host - required field
        if (!backend_map.contains("host")) continue;
        const host_value = backend_map.get("host").?;
        if (host_value != .scalar) continue;
        const host = host_value.scalar;
        
        // Get port - required field
        if (!backend_map.contains("port")) continue;
        const port_value = backend_map.get("port").?;
        if (port_value != .scalar) continue;
        
        // Parse port value as integer
        const port = std.fmt.parseInt(u16, port_value.scalar, 10) catch continue;
        
        // Get weight - optional field
        var weight: u16 = 1; // Default weight
        if (backend_map.contains("weight")) {
            const weight_value = backend_map.get("weight").?;
            if (weight_value == .scalar) {
                weight = std.fmt.parseInt(u16, weight_value.scalar, 10) catch 1;
            }
        }
        
        // Add the backend to the list
        const host_copy = try allocator.dupe(u8, host);
        errdefer allocator.free(host_copy);
        
        try backends.append(allocator, BackendServer.init(host_copy, port, weight));
    }
    
    // Check if we found any backends
    if (backends.items.len == 0) {
        log.err("No valid backends found in YAML configuration", .{});
        return error.NoBackendsFound;
    }
    
    // Log summary of backends found
    log.info("Successfully loaded {d} backend(s) from YAML configuration:", .{backends.items.len});
    for (backends.items, 0..) |backend, i| {
        log.info("  Backend {d}: {s}:{d} (weight: {d})", .{
            i + 1, backend.getFullHost(), backend.port, backend.weight
        });
    }
    
    return backends;
}

/// Configuration watcher that monitors a YAML file for changes and updates the backends list
pub const ConfigWatcher = struct {
    allocator: std.mem.Allocator,
    config_file_path: []const u8,
    config_file_path_owned: bool,
    last_modified_time: i128,
    interval_ms: u32,
    on_config_change: *const fn (*Runtime, *ConfigWatcher, BackendsList) anyerror!void,
    is_running: std.atomic.Value(bool),
    
    pub fn init(
        allocator: std.mem.Allocator, 
        config_file_path: []const u8, 
        interval_ms: u32,
        on_config_change: *const fn (*Runtime, *ConfigWatcher, BackendsList) anyerror!void
    ) !*ConfigWatcher {
        const watcher = try allocator.create(ConfigWatcher);
        
        // Make a copy of the config path
        const path_copy = try allocator.dupe(u8, config_file_path);
        
        watcher.* = .{
            .allocator = allocator,
            .config_file_path = path_copy,
            .config_file_path_owned = true,
            .last_modified_time = 0,
            .interval_ms = interval_ms,
            .on_config_change = on_config_change,
            .is_running = std.atomic.Value(bool).init(false),
        };
        
        // Get the initial file timestamp
        watcher.last_modified_time = try watcher.getFileModifiedTime();
        
        return watcher;
    }
    
    pub fn deinit(self: *ConfigWatcher) void {
        self.stop();
        
        if (self.config_file_path_owned) {
            self.allocator.free(self.config_file_path);
        }
        
        self.allocator.destroy(self);
    }
    
    pub fn start(self: *ConfigWatcher, rt: *Runtime) !void {
        const log = std.log.scoped(.@"config_watcher");
        
        // Don't start if already running
        if (self.is_running.load(.acquire)) {
            log.warn("Config watcher already running", .{});
            return;
        }
        
        self.is_running.store(true, .release);
        log.info("Starting config file watcher for: {s}", .{self.config_file_path});
        log.info("Check interval: {d}ms", .{self.interval_ms});
        
        // Spawn a task to watch for config changes
        try rt.spawn(.{rt, self}, watchConfigFile, 1024 * 16);
    }
    
    pub fn stop(self: *ConfigWatcher) void {
        self.is_running.store(false, .release);
    }
    
    fn getFileModifiedTime(self: *ConfigWatcher) !i128 {
        const file = try std.fs.cwd().openFile(self.config_file_path, .{});
        defer file.close();
        
        const stat = try file.stat();
        return stat.mtime;
    }
    
    fn watchConfigFile(rt: *Runtime, watcher: *ConfigWatcher) !void {
        const log = std.log.scoped(.@"config_watcher");
        
        while (watcher.is_running.load(.acquire)) {
            // Check if file has been modified
            const current_mtime = watcher.getFileModifiedTime() catch |err| {
                log.warn("Failed to get config file modified time: {s}", .{@errorName(err)});
                try Timer.delay(rt, .{ .nanos = watcher.interval_ms * 1000 * 1000 });
                continue;
            };
            
            // If modified time changed, reload config
            if (current_mtime > watcher.last_modified_time) {
                log.info("Config file modified, reloading backends", .{});
                
                // Parse the updated config
                const new_backends = parseYamlConfig(watcher.allocator, watcher.config_file_path) catch |err| {
                    log.err("Failed to parse updated config: {s}", .{@errorName(err)});
                    watcher.last_modified_time = current_mtime;
                    try Timer.delay(rt, .{ .nanos = watcher.interval_ms * 1000 * 1000 });
                    continue;
                };
                
                // Call the callback with the new config
                watcher.on_config_change(rt, watcher, new_backends) catch |err| {
                    log.err("Failed to apply updated config: {s}", .{@errorName(err)});
                    // Free the new backends since the callback didn't take ownership
                    for (new_backends.items) |backend| {
                        watcher.allocator.free(backend.getFullHost());
                    }
                    var backends_to_free = new_backends;
                    backends_to_free.deinit(watcher.allocator);
                };
                
                // Update the last modified time
                watcher.last_modified_time = current_mtime;
                log.info("Config reload complete", .{});
            }
            
            // Wait for next check interval
            try Timer.delay(rt, .{ .nanos = watcher.interval_ms * 1000 * 1000 });
        }
        
        log.info("Config watcher stopped", .{});
    }
};