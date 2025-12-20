//! HTTP/2 Frame Implementation (RFC 7540)
//!
//! Zero-allocation frame building and parsing for HTTP/2 protocol.

const std = @import("std");

/// HTTP/2 frame types
pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,

    pub fn fromU8(value: u8) ?FrameType {
        return switch (value) {
            0x0 => .data,
            0x1 => .headers,
            0x2 => .priority,
            0x3 => .rst_stream,
            0x4 => .settings,
            0x5 => .push_promise,
            0x6 => .ping,
            0x7 => .goaway,
            0x8 => .window_update,
            0x9 => .continuation,
            else => null,
        };
    }
};

/// Frame flags
pub const Flags = struct {
    pub const END_STREAM: u8 = 0x1;
    pub const END_HEADERS: u8 = 0x4;
    pub const PADDED: u8 = 0x8;
    pub const PRIORITY: u8 = 0x20;
    pub const ACK: u8 = 0x1;
};

/// Parsed frame header (9 bytes)
pub const FrameHeader = struct {
    length: u24,
    frame_type: u8,
    flags: u8,
    stream_id: u31,

    pub fn parse(data: []const u8) !FrameHeader {
        if (data.len < 9) return error.InsufficientData;

        const length: u24 = @intCast((@as(u32, data[0]) << 16) |
            (@as(u32, data[1]) << 8) |
            @as(u32, data[2]));

        const stream_id_raw = std.mem.readInt(u32, data[5..9], .big);

        return FrameHeader{
            .length = length,
            .frame_type = data[3],
            .flags = data[4],
            .stream_id = @intCast(stream_id_raw & 0x7FFFFFFF),
        };
    }

    pub fn isEndStream(self: FrameHeader) bool {
        return (self.flags & Flags.END_STREAM) != 0;
    }

    pub fn isEndHeaders(self: FrameHeader) bool {
        return (self.flags & Flags.END_HEADERS) != 0;
    }

    pub fn isAck(self: FrameHeader) bool {
        return (self.flags & Flags.ACK) != 0;
    }

    pub fn totalSize(self: FrameHeader) usize {
        return 9 + @as(usize, self.length);
    }
};

/// Complete frame with header and payload
pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,

    pub fn parse(data: []const u8) !Frame {
        const header = try FrameHeader.parse(data);
        const total = header.totalSize();
        if (data.len < total) return error.InsufficientData;

        return Frame{
            .header = header,
            .payload = data[9..total],
        };
    }
};

/// Frame builder for constructing HTTP/2 frames
pub const FrameBuilder = struct {
    /// Build a SETTINGS frame
    pub fn settings(buffer: []u8, entries: []const SettingsEntry) !usize {
        const payload_len = entries.len * 6;
        if (buffer.len < 9 + payload_len) return error.BufferTooSmall;

        // Frame header
        buffer[0] = @intCast((payload_len >> 16) & 0xFF);
        buffer[1] = @intCast((payload_len >> 8) & 0xFF);
        buffer[2] = @intCast(payload_len & 0xFF);
        buffer[3] = @intFromEnum(FrameType.settings);
        buffer[4] = 0; // No flags
        buffer[5] = 0;
        buffer[6] = 0;
        buffer[7] = 0;
        buffer[8] = 0; // Stream 0

        // Settings entries
        var offset: usize = 9;
        for (entries) |entry| {
            std.mem.writeInt(u16, buffer[offset..][0..2], entry.id, .big);
            std.mem.writeInt(u32, buffer[offset + 2 ..][0..4], entry.value, .big);
            offset += 6;
        }

        return 9 + payload_len;
    }

    /// Build a SETTINGS ACK frame
    pub fn settingsAck(buffer: []u8) !usize {
        if (buffer.len < 9) return error.BufferTooSmall;

        buffer[0] = 0;
        buffer[1] = 0;
        buffer[2] = 0; // Length = 0
        buffer[3] = @intFromEnum(FrameType.settings);
        buffer[4] = Flags.ACK;
        buffer[5] = 0;
        buffer[6] = 0;
        buffer[7] = 0;
        buffer[8] = 0; // Stream 0

        return 9;
    }

    /// Build a HEADERS frame
    pub fn headers(buffer: []u8, stream_id: u31, hpack_payload: []const u8, end_stream: bool) !usize {
        const payload_len = hpack_payload.len;
        if (buffer.len < 9 + payload_len) return error.BufferTooSmall;

        // Frame header
        buffer[0] = @intCast((payload_len >> 16) & 0xFF);
        buffer[1] = @intCast((payload_len >> 8) & 0xFF);
        buffer[2] = @intCast(payload_len & 0xFF);
        buffer[3] = @intFromEnum(FrameType.headers);
        buffer[4] = Flags.END_HEADERS | (if (end_stream) Flags.END_STREAM else 0);
        std.mem.writeInt(u32, buffer[5..9], @as(u32, stream_id), .big);

        // Copy HPACK encoded headers
        @memcpy(buffer[9..][0..payload_len], hpack_payload);

        return 9 + payload_len;
    }

    /// Build a DATA frame
    pub fn data(buffer: []u8, stream_id: u31, payload: []const u8, end_stream: bool) !usize {
        const payload_len = payload.len;
        if (buffer.len < 9 + payload_len) return error.BufferTooSmall;

        // Frame header
        buffer[0] = @intCast((payload_len >> 16) & 0xFF);
        buffer[1] = @intCast((payload_len >> 8) & 0xFF);
        buffer[2] = @intCast(payload_len & 0xFF);
        buffer[3] = @intFromEnum(FrameType.data);
        buffer[4] = if (end_stream) Flags.END_STREAM else 0;
        std.mem.writeInt(u32, buffer[5..9], @as(u32, stream_id), .big);

        // Copy data payload
        @memcpy(buffer[9..][0..payload_len], payload);

        return 9 + payload_len;
    }

    /// Build a WINDOW_UPDATE frame
    pub fn windowUpdate(buffer: []u8, stream_id: u31, increment: u31) !usize {
        if (buffer.len < 13) return error.BufferTooSmall;

        buffer[0] = 0;
        buffer[1] = 0;
        buffer[2] = 4; // Length = 4
        buffer[3] = @intFromEnum(FrameType.window_update);
        buffer[4] = 0; // No flags
        std.mem.writeInt(u32, buffer[5..9], @as(u32, stream_id), .big);
        std.mem.writeInt(u32, buffer[9..13], @as(u32, increment), .big);

        return 13;
    }

    /// Build a PING frame
    pub fn ping(buffer: []u8, payload: [8]u8, ack: bool) !usize {
        if (buffer.len < 17) return error.BufferTooSmall;

        buffer[0] = 0;
        buffer[1] = 0;
        buffer[2] = 8; // Length = 8
        buffer[3] = @intFromEnum(FrameType.ping);
        buffer[4] = if (ack) Flags.ACK else 0;
        buffer[5] = 0;
        buffer[6] = 0;
        buffer[7] = 0;
        buffer[8] = 0; // Stream 0
        @memcpy(buffer[9..17], &payload);

        return 17;
    }

    /// Build a RST_STREAM frame
    pub fn rstStream(buffer: []u8, stream_id: u31, error_code: u32) !usize {
        if (buffer.len < 13) return error.BufferTooSmall;

        buffer[0] = 0;
        buffer[1] = 0;
        buffer[2] = 4; // Length = 4
        buffer[3] = @intFromEnum(FrameType.rst_stream);
        buffer[4] = 0;
        std.mem.writeInt(u32, buffer[5..9], @as(u32, stream_id), .big);
        std.mem.writeInt(u32, buffer[9..13], error_code, .big);

        return 13;
    }

    /// Build a GOAWAY frame
    pub fn goaway(buffer: []u8, last_stream_id: u31, error_code: u32) !usize {
        if (buffer.len < 17) return error.BufferTooSmall;

        buffer[0] = 0;
        buffer[1] = 0;
        buffer[2] = 8; // Length = 8
        buffer[3] = @intFromEnum(FrameType.goaway);
        buffer[4] = 0;
        buffer[5] = 0;
        buffer[6] = 0;
        buffer[7] = 0;
        buffer[8] = 0; // Stream 0
        std.mem.writeInt(u32, buffer[9..13], @as(u32, last_stream_id), .big);
        std.mem.writeInt(u32, buffer[13..17], error_code, .big);

        return 17;
    }
};

/// Settings entry for SETTINGS frame
pub const SettingsEntry = struct {
    id: u16,
    value: u32,
};

/// HTTP/2 error codes (RFC 7540 Section 7)
pub const ErrorCode = struct {
    pub const NO_ERROR: u32 = 0x0;
    pub const PROTOCOL_ERROR: u32 = 0x1;
    pub const INTERNAL_ERROR: u32 = 0x2;
    pub const FLOW_CONTROL_ERROR: u32 = 0x3;
    pub const SETTINGS_TIMEOUT: u32 = 0x4;
    pub const STREAM_CLOSED: u32 = 0x5;
    pub const FRAME_SIZE_ERROR: u32 = 0x6;
    pub const REFUSED_STREAM: u32 = 0x7;
    pub const CANCEL: u32 = 0x8;
    pub const COMPRESSION_ERROR: u32 = 0x9;
    pub const CONNECT_ERROR: u32 = 0xa;
    pub const ENHANCE_YOUR_CALM: u32 = 0xb;
    pub const INADEQUATE_SECURITY: u32 = 0xc;
    pub const HTTP_1_1_REQUIRED: u32 = 0xd;
};

test "frame header parse" {
    // SETTINGS frame: length=12, type=4, flags=0, stream=0
    const data = [_]u8{ 0, 0, 12, 4, 0, 0, 0, 0, 0 };
    const header = try FrameHeader.parse(&data);
    try std.testing.expectEqual(@as(u24, 12), header.length);
    try std.testing.expectEqual(@as(u8, 4), header.frame_type);
    try std.testing.expectEqual(@as(u31, 0), header.stream_id);
}

test "build settings frame" {
    var buffer: [64]u8 = undefined;
    const entries = [_]SettingsEntry{
        .{ .id = 0x3, .value = 100 }, // MAX_CONCURRENT_STREAMS
        .{ .id = 0x4, .value = 65535 }, // INITIAL_WINDOW_SIZE
    };
    const len = try FrameBuilder.settings(&buffer, &entries);
    try std.testing.expectEqual(@as(usize, 9 + 12), len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(FrameType.settings)), buffer[3]);
}

test "build settings ack" {
    var buffer: [16]u8 = undefined;
    const len = try FrameBuilder.settingsAck(&buffer);
    try std.testing.expectEqual(@as(usize, 9), len);
    try std.testing.expectEqual(Flags.ACK, buffer[4]);
}

test "build window update" {
    var buffer: [16]u8 = undefined;
    const len = try FrameBuilder.windowUpdate(&buffer, 1, 32768);
    try std.testing.expectEqual(@as(usize, 13), len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(FrameType.window_update)), buffer[3]);
}

test "build data frame" {
    var buffer: [64]u8 = undefined;
    const payload = "Hello, HTTP/2!";
    const len = try FrameBuilder.data(&buffer, 1, payload, true);

    try std.testing.expectEqual(@as(usize, 9 + payload.len), len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(FrameType.data)), buffer[3]);
    try std.testing.expectEqual(Flags.END_STREAM, buffer[4]);

    // Parse it back
    const header = try FrameHeader.parse(buffer[0..9]);
    try std.testing.expectEqual(@as(u24, payload.len), header.length);
    try std.testing.expect(header.isEndStream());
}

test "build headers frame" {
    var buffer: [64]u8 = undefined;
    const hpack_payload = [_]u8{ 0x82, 0x87, 0x84 }; // Indexed headers
    const len = try FrameBuilder.headers(&buffer, 1, &hpack_payload, false);

    try std.testing.expectEqual(@as(usize, 9 + 3), len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(FrameType.headers)), buffer[3]);
    try std.testing.expectEqual(Flags.END_HEADERS, buffer[4]); // No END_STREAM

    const header = try FrameHeader.parse(buffer[0..9]);
    try std.testing.expect(header.isEndHeaders());
    try std.testing.expect(!header.isEndStream());
}

test "build ping frame" {
    var buffer: [32]u8 = undefined;
    const ping_data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const len = try FrameBuilder.ping(&buffer, ping_data, false);

    try std.testing.expectEqual(@as(usize, 17), len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(FrameType.ping)), buffer[3]);
    try std.testing.expectEqual(@as(u8, 0), buffer[4]); // No ACK

    // Test ping ACK
    const ack_len = try FrameBuilder.ping(&buffer, ping_data, true);
    try std.testing.expectEqual(@as(usize, 17), ack_len);
    try std.testing.expectEqual(Flags.ACK, buffer[4]);
}

test "build goaway frame" {
    var buffer: [32]u8 = undefined;
    const len = try FrameBuilder.goaway(&buffer, 5, ErrorCode.NO_ERROR);

    try std.testing.expectEqual(@as(usize, 17), len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(FrameType.goaway)), buffer[3]);

    // Verify last stream ID
    const last_stream = std.mem.readInt(u32, buffer[9..13], .big);
    try std.testing.expectEqual(@as(u32, 5), last_stream);
}

test "build rst_stream frame" {
    var buffer: [16]u8 = undefined;
    const len = try FrameBuilder.rstStream(&buffer, 3, ErrorCode.CANCEL);

    try std.testing.expectEqual(@as(usize, 13), len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(FrameType.rst_stream)), buffer[3]);

    // Verify stream ID
    const stream_id = std.mem.readInt(u32, buffer[5..9], .big);
    try std.testing.expectEqual(@as(u32, 3), stream_id);

    // Verify error code
    const error_code = std.mem.readInt(u32, buffer[9..13], .big);
    try std.testing.expectEqual(ErrorCode.CANCEL, error_code);
}

test "frame type conversion" {
    try std.testing.expectEqual(FrameType.data, FrameType.fromU8(0x0).?);
    try std.testing.expectEqual(FrameType.headers, FrameType.fromU8(0x1).?);
    try std.testing.expectEqual(FrameType.settings, FrameType.fromU8(0x4).?);
    try std.testing.expectEqual(FrameType.goaway, FrameType.fromU8(0x7).?);
    try std.testing.expect(FrameType.fromU8(0xFF) == null);
}

test "frame header flags" {
    // Headers with END_STREAM | END_HEADERS (0x05)
    const data = [_]u8{ 0, 0, 10, 1, 0x05, 0, 0, 0, 1 };
    const header = try FrameHeader.parse(&data);

    try std.testing.expect(header.isEndStream());
    try std.testing.expect(header.isEndHeaders());
    // Note: ACK flag (0x01) is same bit as END_STREAM, used on SETTINGS/PING only
}

test "settings ack flag" {
    // SETTINGS with ACK flag
    const data = [_]u8{ 0, 0, 0, 4, 0x01, 0, 0, 0, 0 };
    const header = try FrameHeader.parse(&data);

    try std.testing.expect(header.isAck());
    try std.testing.expectEqual(@as(u8, @intFromEnum(FrameType.settings)), header.frame_type);
}

test "parse complete frame" {
    // Build a DATA frame
    var buffer: [64]u8 = undefined;
    const payload = "test data";
    const len = try FrameBuilder.data(&buffer, 7, payload, true);

    // Parse it
    const parsed = try Frame.parse(buffer[0..len]);
    try std.testing.expectEqual(@as(u31, 7), parsed.header.stream_id);
    try std.testing.expectEqualStrings(payload, parsed.payload);
}
