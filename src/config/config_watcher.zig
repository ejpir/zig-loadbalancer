/// Config File Watcher with Hot Reload
///
/// Watches a JSON config file for changes and triggers hot reload of backends.
/// Uses kqueue on macOS/BSD, inotify on Linux.
///
/// Config file format (backends.json):
/// ```json
/// {
///   "backends": [
///     {"host": "127.0.0.1", "port": 9001, "weight": 1},
///     {"host": "127.0.0.1", "port": 9002, "weight": 2, "tls": true}
///   ]
/// }
/// ```
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const log = std.log.scoped(.config_watcher);

const config_mod = @import("../core/config.zig");
const BackendDef = config_mod.BackendDef;
const shared_region = @import("../memory/shared_region.zig");

const MAX_BACKENDS = config_mod.MAX_BACKENDS;
const MAX_CONFIG_SIZE = config_mod.MAX_CONFIG_SIZE;

/// Parsed config from JSON file
pub const ParsedConfig = struct {
    backends: []BackendDef,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedConfig) void {
        for (self.backends) |b| {
            self.allocator.free(b.host);
        }
        self.allocator.free(self.backends);
    }
};

/// Parse backends from JSON config file
pub fn parseConfigFile(allocator: std.mem.Allocator, path: []const u8) !ParsedConfig {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read file using blocking read
    var content = try allocator.alloc(u8, MAX_CONFIG_SIZE);
    defer allocator.free(content);

    var total_read: usize = 0;
    while (total_read < MAX_CONFIG_SIZE) {
        const bytes_read = file.read(content[total_read..]) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }

    return parseConfigJson(allocator, content[0..total_read]);
}

/// Parse backends from JSON string
pub fn parseConfigJson(allocator: std.mem.Allocator, json: []const u8) !ParsedConfig {
    const parsed = std.json.parseFromSlice(
        struct { backends: []const JsonBackend },
        allocator,
        json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return error.InvalidConfig;
    };
    defer parsed.deinit();

    var backends = try std.ArrayList(BackendDef).initCapacity(allocator, parsed.value.backends.len);
    errdefer {
        for (backends.items) |b| allocator.free(b.host);
        backends.deinit(allocator);
    }

    for (parsed.value.backends) |jb| {
        const host = try allocator.dupe(u8, jb.host);
        errdefer allocator.free(host);

        try backends.append(allocator, .{
            .host = host,
            .port = jb.port,
            .weight = jb.weight,
            .use_tls = jb.tls,
        });
    }

    return .{
        .backends = try backends.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// JSON backend definition (matches file format)
const JsonBackend = struct {
    host: []const u8,
    port: u16,
    weight: u16 = 1,
    tls: bool = false,
};

// ============================================================================
// File Watcher
// ============================================================================

/// Cross-platform file watcher
pub const FileWatcher = struct {
    fd: posix.fd_t,
    watch_fd: posix.fd_t,
    path: []const u8,

    const Self = @This();

    /// Initialize file watcher for the given path
    pub fn init(path: []const u8) !Self {
        if (comptime builtin.os.tag == .linux) {
            return initInotify(path);
        } else if (comptime builtin.os.tag == .macos or builtin.os.tag.isBSD()) {
            return initKqueue(path);
        } else {
            @compileError("Unsupported platform for file watching");
        }
    }

    /// Initialize kqueue-based watcher (macOS/BSD)
    fn initKqueue(path: []const u8) !Self {
        const kq = try posix.kqueue();
        errdefer posix.close(kq);

        const file_fd = try posix.open(
            path,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            0,
        );
        errdefer posix.close(file_fd);

        // Watch for writes and renames
        var changelist: [1]posix.Kevent = .{.{
            .ident = @intCast(file_fd),
            .filter = posix.system.EVFILT.VNODE,
            .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
            .fflags = posix.system.NOTE.WRITE | posix.system.NOTE.RENAME | posix.system.NOTE.DELETE,
            .data = 0,
            .udata = 0,
        }};

        var empty_events: [0]posix.Kevent = .{};
        _ = try posix.kevent(kq, &changelist, &empty_events, null);

        return .{
            .fd = kq,
            .watch_fd = file_fd,
            .path = path,
        };
    }

    /// Initialize inotify-based watcher (Linux)
    fn initInotify(path: []const u8) !Self {
        const inotify_fd = try posix.inotify_init1(std.os.linux.IN.CLOEXEC);
        errdefer posix.close(inotify_fd);

        const mask: u32 = std.os.linux.IN.MODIFY | std.os.linux.IN.MOVE_SELF | std.os.linux.IN.DELETE_SELF;
        const watch_fd = try posix.inotify_add_watch(inotify_fd, path, mask);

        return .{
            .fd = inotify_fd,
            .watch_fd = @intCast(watch_fd),
            .path = path,
        };
    }

    /// Wait for file change event (blocking)
    pub fn waitForChange(self: *Self) !void {
        if (comptime builtin.os.tag == .linux) {
            return self.waitInotify();
        } else {
            return self.waitKqueue();
        }
    }

    fn waitKqueue(self: *Self) !void {
        var events: [1]posix.Kevent = undefined;
        var empty_changelist: [0]posix.Kevent = .{};

        const count = try posix.kevent(self.fd, &empty_changelist, &events, null);

        if (count == 0) {
            return; // No events
        }

        // File was deleted or renamed - need to re-open
        if (events[0].fflags & (posix.system.NOTE.DELETE | posix.system.NOTE.RENAME) != 0) {
            try self.reopenFile();
        }
    }

    fn waitInotify(self: *Self) !void {
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        const bytes_read = try posix.read(self.fd, &buf);
        if (bytes_read == 0) {
            return error.InotifyReadFailed;
        }
        // Event received - file was modified
    }

    /// Re-open file after delete/rename (for atomic writes via rename)
    fn reopenFile(self: *Self) !void {
        posix.close(self.watch_fd);

        // Brief delay for atomic rename to complete
        posix.nanosleep(0, 50 * std.time.ns_per_ms);

        self.watch_fd = try posix.open(
            self.path,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            0,
        );

        // Re-register with kqueue
        var changelist: [1]posix.Kevent = .{.{
            .ident = @intCast(self.watch_fd),
            .filter = posix.system.EVFILT.VNODE,
            .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
            .fflags = posix.system.NOTE.WRITE | posix.system.NOTE.RENAME | posix.system.NOTE.DELETE,
            .data = 0,
            .udata = 0,
        }};

        var empty_events: [0]posix.Kevent = .{};
        _ = posix.kevent(self.fd, &changelist, &empty_events, null) catch {};
    }

    pub fn deinit(self: *Self) void {
        if (comptime builtin.os.tag != .linux) {
            posix.close(self.watch_fd);
        }
        posix.close(self.fd);
    }
};

// ============================================================================
// Config Watcher Thread
// ============================================================================

/// Reload callback function type
pub const ReloadFn = *const fn (*shared_region.SharedRegion, []const BackendDef) void;

/// Config watcher context passed to thread
pub const WatcherContext = struct {
    region: *shared_region.SharedRegion,
    config_path: []const u8,
    allocator: std.mem.Allocator,
    reload_fn: ReloadFn,
};

/// Start config watcher thread
pub fn startConfigWatcher(
    region: *shared_region.SharedRegion,
    config_path: []const u8,
    allocator: std.mem.Allocator,
    reload_fn: ReloadFn,
) !std.Thread {
    const ctx = try allocator.create(WatcherContext);
    ctx.* = .{
        .region = region,
        .config_path = config_path,
        .allocator = allocator,
        .reload_fn = reload_fn,
    };

    return try std.Thread.spawn(.{}, watcherThread, .{ctx});
}

fn watcherThread(ctx: *WatcherContext) void {
    log.info("Config watcher started: {s}", .{ctx.config_path});

    var watcher = FileWatcher.init(ctx.config_path) catch |err| {
        log.err("Failed to init file watcher: {s}", .{@errorName(err)});
        return;
    };
    defer watcher.deinit();

    while (true) {
        watcher.waitForChange() catch |err| {
            log.err("Watcher error: {s}", .{@errorName(err)});
            posix.nanosleep(1, 0);
            continue;
        };

        // Debounce: wait for writes to complete
        posix.nanosleep(0, 100 * std.time.ns_per_ms);

        reloadConfig(ctx) catch |err| {
            log.err("Reload failed: {s}", .{@errorName(err)});
        };
    }
}

fn reloadConfig(ctx: *WatcherContext) !void {
    var config = try parseConfigFile(ctx.allocator, ctx.config_path);
    defer config.deinit();

    if (config.backends.len == 0) {
        log.warn("Config has no backends, skipping reload", .{});
        return;
    }

    if (config.backends.len > MAX_BACKENDS) {
        log.warn("Config has {d} backends, truncating to {d}", .{
            config.backends.len,
            MAX_BACKENDS,
        });
    }

    ctx.reload_fn(ctx.region, config.backends);
}

// ============================================================================
// Tests
// ============================================================================

test "parseConfigJson: valid config" {
    const json =
        \\{"backends": [
        \\  {"host": "127.0.0.1", "port": 9001},
        \\  {"host": "10.0.0.1", "port": 8080, "weight": 5, "tls": true}
        \\]}
    ;

    var config = try parseConfigJson(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.backends.len);
    try std.testing.expectEqualStrings("127.0.0.1", config.backends[0].host);
    try std.testing.expectEqual(@as(u16, 9001), config.backends[0].port);
    try std.testing.expectEqual(@as(u16, 1), config.backends[0].weight);
    try std.testing.expectEqual(false, config.backends[0].use_tls);

    try std.testing.expectEqualStrings("10.0.0.1", config.backends[1].host);
    try std.testing.expectEqual(@as(u16, 8080), config.backends[1].port);
    try std.testing.expectEqual(@as(u16, 5), config.backends[1].weight);
    try std.testing.expectEqual(true, config.backends[1].use_tls);
}

test "parseConfigJson: empty backends" {
    const json = \\{"backends": []}
    ;

    var config = try parseConfigJson(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 0), config.backends.len);
}

test "parseConfigJson: ignores unknown fields" {
    const json =
        \\{"backends": [{"host": "localhost", "port": 80}], "unknown": "ignored"}
    ;

    var config = try parseConfigJson(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.backends.len);
}

test "parseConfigJson: invalid json returns error" {
    const json = \\{invalid json}
    ;

    const result = parseConfigJson(std.testing.allocator, json);
    try std.testing.expectError(error.InvalidConfig, result);
}
