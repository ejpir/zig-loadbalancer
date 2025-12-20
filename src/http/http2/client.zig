//! HTTP/2 Client for Load Balancer Backend Connections
//!
//! Provides HTTP/2 protocol support for connecting to backend servers.
//! Integrates with UltraSock for transport (HTTP or HTTPS).
//!
//! Usage:
//!   var client = Http2Client.init(allocator);
//!   try client.connect(&sock, io);
//!   const stream_id = try client.sendRequest(&sock, io, "GET", "/api", "backend.com", null);
//!   const response = try client.readResponse(&sock, io, stream_id);

const std = @import("std");
const log = std.log.scoped(.http2_client);

const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const mod = @import("mod.zig");
const UltraSock = @import("../ultra_sock.zig").UltraSock;

const Io = std.Io;

/// HTTP/2 Client State
pub const Http2Client = struct {
    allocator: std.mem.Allocator,
    next_stream_id: u31 = 1, // Client uses odd stream IDs
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = mod.INITIAL_WINDOW_SIZE,
    max_frame_size: u32 = mod.MAX_FRAME_SIZE_DEFAULT,
    connection_window: i64 = mod.INITIAL_WINDOW_SIZE,
    settings_acked: bool = false,
    preface_sent: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Establish HTTP/2 connection over UltraSock
    /// Sends connection preface and initial SETTINGS
    pub fn connect(self: *Self, sock: *UltraSock, io: Io) !void {
        // Connection preface
        var preface_buf: [64]u8 = undefined;
        @memcpy(preface_buf[0..mod.CONNECTION_PREFACE.len], mod.CONNECTION_PREFACE);

        // Initial SETTINGS frame
        const settings = [_]frame.SettingsEntry{
            .{ .id = mod.Settings.MAX_CONCURRENT_STREAMS, .value = 100 },
            .{ .id = mod.Settings.INITIAL_WINDOW_SIZE, .value = mod.INITIAL_WINDOW_SIZE },
            .{ .id = mod.Settings.MAX_FRAME_SIZE, .value = mod.MAX_FRAME_SIZE_DEFAULT },
        };

        var settings_buf: [64]u8 = undefined;
        const settings_len = try frame.FrameBuilder.settings(&settings_buf, &settings);

        // Send preface + settings
        const total_len = mod.CONNECTION_PREFACE.len + settings_len;
        @memcpy(preface_buf[mod.CONNECTION_PREFACE.len..][0..settings_len], settings_buf[0..settings_len]);

        _ = try sock.send_all(io, preface_buf[0..total_len]);
        self.preface_sent = true;

        log.debug("HTTP/2 connection preface sent", .{});

        // Read server's SETTINGS
        try self.readServerSettings(sock, io);
    }

    /// Send HTTP/2 request, returns stream ID
    pub fn sendRequest(
        self: *Self,
        sock: *UltraSock,
        io: Io,
        method: []const u8,
        path: []const u8,
        authority: []const u8,
        body: ?[]const u8,
    ) !u31 {
        const stream_id = self.nextStreamId();
        log.debug("Sending HTTP/2 request: method={s}, path={s}, authority={s}, stream={d}", .{
            method,
            path,
            authority,
            stream_id,
        });
        const end_stream = (body == null);

        // Encode headers with HPACK
        var hpack_buf: [4096]u8 = undefined;
        const hpack_len = try hpack.Hpack.encodeRequest(
            &hpack_buf,
            method,
            path,
            authority,
            &[_]hpack.Header{},
        );

        // Build HEADERS frame
        var frame_buf: [4096]u8 = undefined;
        const headers_len = try frame.FrameBuilder.headers(
            &frame_buf,
            stream_id,
            hpack_buf[0..hpack_len],
            end_stream,
        );

        _ = try sock.send_all(io, frame_buf[0..headers_len]);
        log.debug("Sent HEADERS frame: stream={d}, end_stream={}", .{ stream_id, end_stream });

        // Send body if present
        if (body) |data| {
            try self.sendData(sock, io, stream_id, data, true);
        }

        return stream_id;
    }

    /// Send DATA frame
    pub fn sendData(
        self: *Self,
        sock: *UltraSock,
        io: Io,
        stream_id: u31,
        data: []const u8,
        end_stream: bool,
    ) !void {
        _ = self;

        // Split into frames if needed
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_size = @min(data.len - offset, mod.MAX_FRAME_SIZE_DEFAULT);
            const is_last = (offset + chunk_size >= data.len) and end_stream;

            var frame_buf: [mod.MAX_FRAME_SIZE_DEFAULT + 9]u8 = undefined;
            const frame_len = try frame.FrameBuilder.data(
                &frame_buf,
                stream_id,
                data[offset..][0..chunk_size],
                is_last,
            );

            _ = try sock.send_all(io, frame_buf[0..frame_len]);
            offset += chunk_size;
        }

        log.debug("Sent DATA: stream={d}, len={d}, end_stream={}", .{ stream_id, data.len, end_stream });
    }

    /// Read response headers and body
    pub fn readResponse(
        self: *Self,
        sock: *UltraSock,
        io: Io,
        stream_id: u31,
    ) !Response {
        var response = Response{
            .status = 0,
            .headers = undefined,
            .header_count = 0,
            .body = std.ArrayList(u8){},
            .allocator = self.allocator,
        };

        var recv_buf: [mod.MAX_FRAME_SIZE_DEFAULT + 9]u8 = undefined;
        var end_stream = false;

        while (!end_stream) {
            // Read frame header
            var header_buf: [9]u8 = undefined;
            var header_read: usize = 0;
            while (header_read < 9) {
                const n = try sock.recv(io, header_buf[header_read..]);
                if (n == 0) return error.ConnectionClosed;
                header_read += n;
            }

            const fh = try frame.FrameHeader.parse(&header_buf);
            // END_STREAM flag (0x01) only applies to DATA and HEADERS frames
            // For SETTINGS, flag 0x01 means ACK (not end_stream)
            const frame_type = frame.FrameType.fromU8(fh.frame_type);
            if (frame_type == .data or frame_type == .headers) {
                if (fh.isEndStream()) {
                    end_stream = true;
                }
            }
            log.debug("Received frame: type={d}, stream={d}, len={d}, flags=0x{x:0>2}, end_stream={}", .{
                fh.frame_type,
                fh.stream_id,
                fh.length,
                fh.flags,
                end_stream,
            });

            // Read payload
            if (fh.length > 0) {
                var payload_read: usize = 0;
                while (payload_read < fh.length) {
                    const n = try sock.recv(io, recv_buf[payload_read..fh.length]);
                    if (n == 0) return error.ConnectionClosed;
                    payload_read += n;
                }

                const payload = recv_buf[0..fh.length];

                // Use the already-computed frame_type from above
                const ft = frame_type orelse continue;
                switch (ft) {
                    .headers => {
                        // Decode HPACK headers
                        response.header_count = try hpack.Hpack.decodeHeaders(
                            payload,
                            &response.headers,
                        );
                        response.status = hpack.Hpack.getStatus(
                            response.headers[0..response.header_count],
                        ) orelse 0;
                        log.debug("Received HEADERS: stream={d}, status={d}", .{ fh.stream_id, response.status });
                    },
                    .data => {
                        if (fh.stream_id == stream_id) {
                            try response.body.appendSlice(self.allocator, payload);
                            log.debug("Received DATA: stream={d}, len={d}", .{ fh.stream_id, fh.length });

                            // Send WINDOW_UPDATE to allow more data (flow control)
                            const data_len = fh.length;
                            if (data_len > 0) {
                                // Update connection window
                                var conn_wu_buf: [13]u8 = undefined;
                                const conn_wu_len = try frame.FrameBuilder.windowUpdate(&conn_wu_buf, 0, data_len);
                                _ = try sock.send_all(io, conn_wu_buf[0..conn_wu_len]);

                                // Update stream window
                                var stream_wu_buf: [13]u8 = undefined;
                                const stream_wu_len = try frame.FrameBuilder.windowUpdate(&stream_wu_buf, stream_id, data_len);
                                _ = try sock.send_all(io, stream_wu_buf[0..stream_wu_len]);
                            }
                        }
                    },
                    .settings => {
                        if (!fh.isAck()) {
                            // Send SETTINGS ACK
                            var ack_buf: [9]u8 = undefined;
                            const ack_len = try frame.FrameBuilder.settingsAck(&ack_buf);
                            _ = try sock.send_all(io, ack_buf[0..ack_len]);
                        }
                    },
                    .window_update => {
                        // Update flow control window
                        if (payload.len >= 4) {
                            const increment = std.mem.readInt(u32, payload[0..4], .big);
                            self.connection_window += increment;
                        }
                    },
                    .ping => {
                        // Respond to PING
                        if (!fh.isAck()) {
                            var ping_buf: [17]u8 = undefined;
                            const ping_len = try frame.FrameBuilder.ping(&ping_buf, payload[0..8].*, true);
                            _ = try sock.send_all(io, ping_buf[0..ping_len]);
                        }
                    },
                    .goaway => {
                        log.warn("Received GOAWAY from server", .{});
                        return error.ConnectionGoaway;
                    },
                    .rst_stream => {
                        if (fh.stream_id == stream_id) {
                            log.warn("Stream {d} reset by server", .{stream_id});
                            return error.StreamReset;
                        }
                    },
                    else => {},
                }
            }
        }

        return response;
    }

    /// Send WINDOW_UPDATE to increase flow control window
    pub fn sendWindowUpdate(self: *Self, sock: *UltraSock, io: Io, stream_id: u31, increment: u31) !void {
        _ = self;
        var buf: [13]u8 = undefined;
        const len = try frame.FrameBuilder.windowUpdate(&buf, stream_id, increment);
        _ = try sock.send_all(io, buf[0..len]);
    }

    /// Close HTTP/2 connection gracefully
    pub fn close(self: *Self, sock: *UltraSock, io: Io) !void {
        var buf: [17]u8 = undefined;
        const len = try frame.FrameBuilder.goaway(&buf, self.next_stream_id -| 2, frame.ErrorCode.NO_ERROR);
        _ = try sock.send_all(io, buf[0..len]);
    }

    // --- Private helpers ---

    fn nextStreamId(self: *Self) u31 {
        const id = self.next_stream_id;
        self.next_stream_id += 2; // Client streams are odd
        return id;
    }

    fn readServerSettings(self: *Self, sock: *UltraSock, io: Io) !void {
        var recv_buf: [256]u8 = undefined;

        // Read frame header
        var header_read: usize = 0;
        while (header_read < 9) {
            const n = try sock.recv(io, recv_buf[header_read..9]);
            if (n == 0) return error.ConnectionClosed;
            header_read += n;
        }

        const fh = try frame.FrameHeader.parse(recv_buf[0..9]);

        if (frame.FrameType.fromU8(fh.frame_type) != .settings) {
            log.warn("Expected SETTINGS, got frame type {d}", .{fh.frame_type});
            return error.ProtocolError;
        }

        // Read settings payload
        if (fh.length > 0) {
            var payload_read: usize = 0;
            while (payload_read < fh.length) {
                const n = try sock.recv(io, recv_buf[9 + payload_read .. 9 + fh.length]);
                if (n == 0) return error.ConnectionClosed;
                payload_read += n;
            }

            // Parse settings
            var offset: usize = 0;
            while (offset + 6 <= fh.length) {
                const id = std.mem.readInt(u16, recv_buf[9 + offset ..][0..2], .big);
                const value = std.mem.readInt(u32, recv_buf[9 + offset + 2 ..][0..4], .big);
                offset += 6;

                switch (id) {
                    mod.Settings.MAX_CONCURRENT_STREAMS => self.max_concurrent_streams = value,
                    mod.Settings.INITIAL_WINDOW_SIZE => self.initial_window_size = value,
                    mod.Settings.MAX_FRAME_SIZE => self.max_frame_size = value,
                    else => {},
                }
            }
        }

        // Send SETTINGS ACK
        var ack_buf: [9]u8 = undefined;
        const ack_len = try frame.FrameBuilder.settingsAck(&ack_buf);
        _ = try sock.send_all(io, ack_buf[0..ack_len]);

        self.settings_acked = true;
        log.debug("HTTP/2 SETTINGS exchanged", .{});
    }
};

/// HTTP/2 Response
pub const Response = struct {
    status: u16,
    headers: [32]hpack.Header,
    header_count: usize,
    body: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.body.deinit(self.allocator);
    }

    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers[0..self.header_count]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }

    pub fn getBody(self: *const Response) []const u8 {
        return self.body.items;
    }
};

test "http2 client init" {
    const client = Http2Client.init(std.testing.allocator);
    try std.testing.expectEqual(@as(u31, 1), client.next_stream_id);
    try std.testing.expectEqual(false, client.preface_sent);
}
