//! Test utilities for integration tests.
//!
//! Provides:
//! - Port availability waiting
//! - HTTP request helpers
//! - JSON response parsing

const std = @import("std");
const posix = std.posix;

pub const TEST_HOST = "127.0.0.1";
pub const BACKEND1_PORT: u16 = 19001;
pub const BACKEND2_PORT: u16 = 19002;
pub const BACKEND3_PORT: u16 = 19003;
pub const LB_PORT: u16 = 18080;

/// Wait for a port to accept connections
pub fn waitForPort(port: u16, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    const deadline = start + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() < deadline) {
        if (tryConnect(port)) {
            return;
        }
        std.time.sleep(100 * std.time.ns_per_ms);
    }
    return error.PortTimeout;
}

fn tryConnect(port: u16) bool {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(sock);

    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
}

/// Make an HTTP request and return the response body
pub fn httpRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    port: u16,
    path: []const u8,
    headers: ?[]const [2][]const u8,
    body: ?[]const u8,
) ![]const u8 {
    // Build request
    var request = std.ArrayList(u8).init(allocator);
    defer request.deinit();

    try request.writer().print("{s} {s} HTTP/1.1\r\n", .{ method, path });
    try request.writer().print("Host: {s}:{d}\r\n", .{ TEST_HOST, port });

    if (headers) |hdrs| {
        for (hdrs) |h| {
            try request.writer().print("{s}: {s}\r\n", .{ h[0], h[1] });
        }
    }

    if (body) |b| {
        try request.writer().print("Content-Length: {d}\r\n", .{b.len});
    }

    try request.appendSlice("Connection: close\r\n\r\n");

    if (body) |b| {
        try request.appendSlice(b);
    }

    // Connect and send
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    try posix.connect(sock, &addr.any, addr.getOsSockLen());

    var sent: usize = 0;
    while (sent < request.items.len) {
        const n = try posix.send(sock, request.items[sent..], 0);
        sent += n;
    }

    // Read response
    var response = std.ArrayList(u8).init(allocator);
    errdefer response.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.recv(sock, &buf, 0);
        if (n == 0) break;
        try response.appendSlice(buf[0..n]);
    }

    return response.toOwnedSlice();
}

/// Extract JSON body from HTTP response
pub fn extractJsonBody(response: []const u8) ![]const u8 {
    const separator = "\r\n\r\n";
    const idx = std.mem.indexOf(u8, response, separator) orelse return error.NoBodyFound;
    return response[idx + separator.len ..];
}

/// Parse JSON response and get a string field
pub fn getJsonString(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const value = parsed.value.object.get(field) orelse return error.FieldNotFound;
    return switch (value) {
        .string => |s| allocator.dupe(u8, s),
        else => error.FieldNotString,
    };
}

/// Parse JSON response and get an integer field
pub fn getJsonInt(allocator: std.mem.Allocator, json: []const u8, field: []const u8) !i64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const value = parsed.value.object.get(field) orelse return error.FieldNotFound;
    return value.integer;
}

/// Check if a header exists in the JSON headers object
pub fn hasHeader(allocator: std.mem.Allocator, json: []const u8, header: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const headers_val = parsed.value.object.get("headers") orelse return error.NoHeaders;
    const headers = headers_val.object;

    // Case-insensitive check
    var iter = headers.iterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, header)) {
            return true;
        }
    }
    return false;
}

/// Get header value (case-insensitive)
pub fn getHeader(allocator: std.mem.Allocator, json: []const u8, header: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const headers_val = parsed.value.object.get("headers") orelse return error.NoHeaders;
    const headers = headers_val.object;

    var iter = headers.iterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, header)) {
            return switch (entry.value_ptr.*) {
                .string => |s| allocator.dupe(u8, s),
                else => error.HeaderNotString,
            };
        }
    }
    return error.HeaderNotFound;
}
