//! Backend Connection Wrapper
//!
//! Unified interface for HTTP/1.1 and HTTP/2 backend connections.
//! Automatically uses HTTP/2 when negotiated via ALPN, falls back to HTTP/1.1.
//!
//! Usage:
//!   var conn = BackendConnection.init(allocator);
//!   defer conn.deinit();
//!   try conn.connect(&sock, io);
//!   const response = try conn.sendRequest(io, method, path, headers, body);

const std = @import("std");
const log = std.log.scoped(.backend_conn);

const UltraSock = @import("ultra_sock.zig").UltraSock;
const Http2Client = @import("http2/client.zig").Http2Client;
const Http2Response = @import("http2/client.zig").Response;

const Io = std.Io;

/// Backend connection supporting both HTTP/1.1 and HTTP/2
pub const BackendConnection = struct {
    allocator: std.mem.Allocator,
    sock: *UltraSock,
    protocol: Protocol,
    h2_client: ?Http2Client,

    const Self = @This();

    pub const Protocol = enum {
        http1_1,
        http2,
    };

    /// Response from backend
    pub const Response = struct {
        status: u16,
        headers_raw: []const u8,
        body: []const u8,
        protocol: Protocol,

        // For HTTP/2, we need to track the underlying response for cleanup
        h2_response: ?Http2Response = null,

        pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
            if (self.h2_response) |*h2r| {
                h2r.deinit();
            }
            _ = allocator;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .sock = undefined,
            .protocol = .http1_1,
            .h2_client = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.h2_client = null;
    }

    /// Connect to backend, detecting protocol via ALPN
    /// TigerStyle: sock.isHttp2() uses copy-safe enum, no dangling pointers
    pub fn connect(self: *Self, sock: *UltraSock, io: Io) !void {
        self.sock = sock;

        if (sock.isHttp2()) {
            log.info("Backend supports HTTP/2, initializing h2 connection", .{});
            self.protocol = .http2;
            self.h2_client = Http2Client.init(self.allocator);
            try self.h2_client.?.connect(sock, io);
        } else {
            log.debug("Using HTTP/1.1 for backend", .{});
            self.protocol = .http1_1;
            self.h2_client = null;
        }
    }

    /// Send request and receive response
    pub fn sendRequest(
        self: *Self,
        io: Io,
        method: []const u8,
        path: []const u8,
        host: []const u8,
        headers: []const Header,
        body: ?[]const u8,
    ) !Response {
        return switch (self.protocol) {
            .http2 => try self.sendHttp2Request(io, method, path, host, body),
            .http1_1 => try self.sendHttp1Request(io, method, path, host, headers, body),
        };
    }

    /// Send HTTP/2 request
    fn sendHttp2Request(
        self: *Self,
        io: Io,
        method: []const u8,
        path: []const u8,
        authority: []const u8,
        body: ?[]const u8,
    ) !Response {
        var client = &self.h2_client.?;

        const stream_id = try client.sendRequest(
            self.sock,
            io,
            method,
            path,
            authority,
            body,
        );

        var h2_response = try client.readResponse(self.sock, io, stream_id);

        return Response{
            .status = h2_response.status,
            .headers_raw = "", // HTTP/2 headers are structured, not raw
            .body = h2_response.getBody(),
            .protocol = .http2,
            .h2_response = h2_response,
        };
    }

    /// Send HTTP/1.1 request
    fn sendHttp1Request(
        self: *Self,
        io: Io,
        method: []const u8,
        path: []const u8,
        host: []const u8,
        headers: []const Header,
        body: ?[]const u8,
    ) !Response {
        // Build HTTP/1.1 request
        var request_buf: [8192]u8 = undefined;
        var offset: usize = 0;

        // Request line
        offset += (std.fmt.bufPrint(request_buf[offset..], "{s} {s} HTTP/1.1\r\n", .{ method, path }) catch return error.BufferTooSmall).len;

        // Host header
        offset += (std.fmt.bufPrint(request_buf[offset..], "Host: {s}\r\n", .{host}) catch return error.BufferTooSmall).len;

        // Additional headers
        for (headers) |h| {
            offset += (std.fmt.bufPrint(request_buf[offset..], "{s}: {s}\r\n", .{ h.name, h.value }) catch return error.BufferTooSmall).len;
        }

        // Content-Length if body present
        if (body) |b| {
            offset += (std.fmt.bufPrint(request_buf[offset..], "Content-Length: {d}\r\n", .{b.len}) catch return error.BufferTooSmall).len;
        }

        // End headers
        offset += (std.fmt.bufPrint(request_buf[offset..], "\r\n", .{}) catch return error.BufferTooSmall).len;

        // Send request
        _ = try self.sock.send_all(io, request_buf[0..offset]);

        // Send body if present
        if (body) |b| {
            _ = try self.sock.send_all(io, b);
        }

        // Read response (simplified - reads until we get status)
        var response_buf: [16384]u8 = undefined;
        var total_read: usize = 0;

        while (total_read < response_buf.len) {
            const n = try self.sock.recv(io, response_buf[total_read..]);
            if (n == 0) break;
            total_read += n;

            // Check if we have full headers (ends with \r\n\r\n)
            if (std.mem.indexOf(u8, response_buf[0..total_read], "\r\n\r\n")) |_| {
                break;
            }
        }

        // Parse status
        const status = parseHttpStatus(response_buf[0..total_read]) orelse 0;

        return Response{
            .status = status,
            .headers_raw = "", // Would need proper parsing
            .body = "", // Would need proper body handling
            .protocol = .http1_1,
            .h2_response = null,
        };
    }

    /// Close connection gracefully
    pub fn close(self: *Self, io: Io) void {
        if (self.h2_client) |*client| {
            client.close(self.sock, io) catch {};
        }
    }

    /// Check if using HTTP/2 (inlined - simple enum check)
    pub inline fn isHttp2(self: *const Self) bool {
        return self.protocol == .http2;
    }
};

/// HTTP header
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Parse HTTP/1.1 status code from response
fn parseHttpStatus(response: []const u8) ?u16 {
    // HTTP/1.1 200 OK\r\n
    if (response.len < 12) return null;
    if (!std.mem.startsWith(u8, response, "HTTP/")) return null;

    // Find space after version
    const first_space = std.mem.indexOf(u8, response, " ") orelse return null;
    if (first_space + 4 > response.len) return null;

    return std.fmt.parseInt(u16, response[first_space + 1 ..][0..3], 10) catch null;
}

// ============================================================================
// Tests
// ============================================================================

test "BackendConnection: init creates http1 protocol" {
    var conn = BackendConnection.init(std.testing.allocator);
    defer conn.deinit();

    try std.testing.expectEqual(BackendConnection.Protocol.http1_1, conn.protocol);
    try std.testing.expect(conn.h2_client == null);
}

test "parseHttpStatus: parses valid status" {
    try std.testing.expectEqual(@as(?u16, 200), parseHttpStatus("HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(?u16, 404), parseHttpStatus("HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expectEqual(@as(?u16, 500), parseHttpStatus("HTTP/1.1 500 Internal Server Error\r\n"));
}

test "parseHttpStatus: returns null for invalid" {
    try std.testing.expectEqual(@as(?u16, null), parseHttpStatus(""));
    try std.testing.expectEqual(@as(?u16, null), parseHttpStatus("GET /"));
    try std.testing.expectEqual(@as(?u16, null), parseHttpStatus("HTTP"));
}
