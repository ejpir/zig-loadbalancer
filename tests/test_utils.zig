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
pub const LB_H2_PORT: u16 = 18081; // Load balancer port for HTTP/2 tests
pub const OTLP_PORT: u16 = 14318; // Mock OTLP collector port

/// Wait for a port to accept connections
pub fn waitForPort(port: u16, timeout_ms: u64) !void {
    const start = std.time.Instant.now() catch return error.TimerUnavailable;
    const timeout_ns = timeout_ms * std.time.ns_per_ms;

    while (true) {
        if (tryConnect(port)) {
            return;
        }
        const now = std.time.Instant.now() catch return error.TimerUnavailable;
        if (now.since(start) >= timeout_ns) {
            return error.PortTimeout;
        }
        posix.nanosleep(0, 100 * std.time.ns_per_ms);
    }
}

fn tryConnect(port: u16) bool {
    const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch return false;
    defer posix.close(sock);

    // Create sockaddr_in for 127.0.0.1
    const addr: posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch return false;
    return true;
}

/// Wait for a TLS port to accept connections (same as waitForPort but with longer default wait)
pub fn waitForTlsPort(port: u16, timeout_ms: u64) !void {
    // TLS ports may take longer to become ready
    return waitForPort(port, timeout_ms);
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
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);

    // Request line
    const request_line = try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\n", .{ method, path });
    defer allocator.free(request_line);
    try request.appendSlice(allocator, request_line);

    // Host header
    const host_header = try std.fmt.allocPrint(allocator, "Host: {s}:{d}\r\n", .{ TEST_HOST, port });
    defer allocator.free(host_header);
    try request.appendSlice(allocator, host_header);

    if (headers) |hdrs| {
        for (hdrs) |h| {
            const hdr = try std.fmt.allocPrint(allocator, "{s}: {s}\r\n", .{ h[0], h[1] });
            defer allocator.free(hdr);
            try request.appendSlice(allocator, hdr);
        }
    }

    if (body) |b| {
        const cl = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n", .{b.len});
        defer allocator.free(cl);
        try request.appendSlice(allocator, cl);
    }

    try request.appendSlice(allocator, "Connection: close\r\n\r\n");

    if (body) |b| {
        try request.appendSlice(allocator, b);
    }

    // Connect and send
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(sock);

    // Create sockaddr_in for 127.0.0.1
    const addr: posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };

    try posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

    var sent: usize = 0;
    while (sent < request.items.len) {
        const n = try posix.send(sock, request.items[sent..], 0);
        sent += n;
    }

    // Read response
    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.recv(sock, &buf, 0);
        if (n == 0) break;
        try response.appendSlice(allocator, buf[0..n]);
    }

    return response.toOwnedSlice(allocator);
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

/// Extract HTTP status code from response
pub fn getResponseStatusCode(response: []const u8) !u16 {
    // Find first line: "HTTP/1.1 200 OK\r\n"
    const line_end = std.mem.indexOf(u8, response, "\r\n") orelse return error.InvalidResponse;
    const status_line = response[0..line_end];

    // Find first space after HTTP version
    const first_space = std.mem.indexOf(u8, status_line, " ") orelse return error.InvalidResponse;
    const after_space = status_line[first_space + 1 ..];

    // Find second space (end of status code)
    const second_space = std.mem.indexOf(u8, after_space, " ") orelse after_space.len;
    const status_str = after_space[0..second_space];

    return std.fmt.parseInt(u16, status_str, 10) catch error.InvalidResponse;
}

/// Get response header value (from HTTP headers, not JSON body)
pub fn getResponseHeaderValue(response: []const u8, header_name: []const u8) ![]const u8 {
    const separator = "\r\n\r\n";
    const header_end = std.mem.indexOf(u8, response, separator) orelse return error.NoBodyFound;
    const headers_section = response[0..header_end];

    // Search for the header (case-insensitive)
    var line_start: usize = 0;
    while (std.mem.indexOfPos(u8, headers_section, line_start, "\r\n")) |line_end| {
        const line = headers_section[line_start..line_end];

        // Find colon
        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const name = line[0..colon_pos];
            if (std.ascii.eqlIgnoreCase(name, header_name)) {
                // Skip colon and any leading whitespace
                var value_start = colon_pos + 1;
                while (value_start < line.len and line[value_start] == ' ') {
                    value_start += 1;
                }
                return line[value_start..];
            }
        }

        line_start = line_end + 2;
    }
    return error.HeaderNotFound;
}

/// Get trace count from mock OTLP collector
pub fn getOtlpTraceCount(allocator: std.mem.Allocator) !i64 {
    const response = try httpRequest(allocator, "GET", OTLP_PORT, "/traces", null, null);
    defer allocator.free(response);

    const body = try extractJsonBody(response);
    return try getJsonInt(allocator, body, "trace_count");
}

/// Clear traces in mock OTLP collector
pub fn clearOtlpTraces(allocator: std.mem.Allocator) !void {
    const response = try httpRequest(allocator, "DELETE", OTLP_PORT, "/traces", null, null);
    defer allocator.free(response);

    const status = try getResponseStatusCode(response);
    if (status != 200) {
        return error.ClearFailed;
    }
}

/// Wait for traces to be received by collector
pub fn waitForTraces(allocator: std.mem.Allocator, min_count: i64, timeout_ms: u64) !void {
    const start = std.time.Instant.now() catch return error.TimerUnavailable;
    const timeout_ns = timeout_ms * std.time.ns_per_ms;

    while (true) {
        const count = getOtlpTraceCount(allocator) catch 0;
        if (count >= min_count) {
            return;
        }

        const now = std.time.Instant.now() catch return error.TimerUnavailable;
        if (now.since(start) >= timeout_ns) {
            return error.TraceTimeout;
        }

        posix.nanosleep(0, 100 * std.time.ns_per_ms);
    }
}
