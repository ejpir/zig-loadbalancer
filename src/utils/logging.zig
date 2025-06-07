const std = @import("std");

// File logger variables
var log_file: ?std.fs.File = null;
var file_mutex = std.Thread.Mutex{};

// Global flag to indicate if file logging is enabled
pub var file_logging_enabled = false;

// Global variables for file logging
var log_buffer: [8192]u8 = undefined; // Buffer for file IO

// Custom log function to write logs to both stdout and file
pub fn customLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // First log to stderr (standard behavior)
    std.log.defaultLog(level, scope, format, args);

    // Early return if file logging is not enabled
    if (!file_logging_enabled) return;

    // Create log message
    var full_msg_buf: [2048]u8 = undefined;

    // Format timestamp and log level
    const timestamp = std.time.timestamp();
    const prefix = std.fmt.bufPrint(full_msg_buf[0..256], "[{d}] [{s}] [{s}] ", .{
        timestamp,
        @tagName(level),
        @tagName(scope),
    }) catch return;

    // Format the message with args
    const msg = std.fmt.bufPrint(full_msg_buf[prefix.len..], format, args) catch return;

    // Add newline
    full_msg_buf[prefix.len + msg.len] = '\n';

    // Get total message length
    const total_len = prefix.len + msg.len + 1;

    // Synchronous file write
    file_mutex.lock();
    defer file_mutex.unlock();

    if (log_file) |file| {
        // Use direct write with len parameter
        _ = file.writeAll(full_msg_buf[0..total_len]) catch {};
    }
}

pub fn initLogging(allocator: std.mem.Allocator, custom_log_file: ?[]const u8) ![]const u8 {
    const log = std.log.scoped(.logging);
    const log_dir = "logs";
    
    std.fs.cwd().makePath(log_dir) catch |err| {
        std.debug.print("Error creating log directory: {s}\n", .{@errorName(err)});
    };

    // Determine log file path - use command line arg if provided, otherwise use default
    var log_filename_buffer: [128]u8 = undefined;
    const log_filename = if (custom_log_file) |custom_path|
        try allocator.dupe(u8, custom_path)
    else blk: {
        // Create a log file with timestamp in the name
        const timestamp = std.time.timestamp();
        const default_filename = try std.fmt.bufPrint(&log_filename_buffer, "{s}/lb-{d}.log", .{ log_dir, timestamp });
        break :blk try allocator.dupe(u8, default_filename);
    };

    log_file = blk: {
        // Open file with buffered writing enabled
        const file = std.fs.cwd().createFile(log_filename, .{}) catch |err| {
            std.debug.print("Failed to open log file: {s}\n", .{@errorName(err)});
            // Continue without file logging if file creation fails
            break :blk null;
        };

        // Set up buffered writing for better performance
        file.setEndPos(0) catch {}; // Truncate file if it exists
        file.seekTo(0) catch {}; // Go to beginning of file

        break :blk file;
    };

    if (log_file) |*file| {
        log.info("Logging to file: {s}", .{log_filename});

        // Set flag to enable file logging
        file_logging_enabled = true;

        // Test direct file write
        var test_buffer: [128]u8 = undefined;
        const timestamp = std.time.timestamp();
        const test_msg = std.fmt.bufPrint(&test_buffer, "[INIT] Log file initialized successfully - timestamp: {d}\n", .{timestamp}) catch "Log file initialized.\n";

        _ = file.writeAll(test_msg) catch |err| {
            log.err("Failed to write to log file: {s}", .{@errorName(err)});
            file_logging_enabled = false;
        };

        // Force a flush
        file.sync() catch {};
    } else {
        log.warn("No log file available, file logging disabled", .{});
    }
    
    return log_filename;
}

pub fn deinitLogging() void {
    if (log_file) |file| {
        file_logging_enabled = false;
        file.close();
    }
}