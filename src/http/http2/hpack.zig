//! HPACK Header Compression (RFC 7541)
//!
//! Simplified implementation for HTTP/2 client use cases.
//! Uses static table indexing for common headers.

const std = @import("std");
const log = std.log.scoped(.hpack);

/// HPACK encoder/decoder
pub const Hpack = struct {
    /// Encode a request using indexed headers where possible
    pub fn encodeRequest(
        buffer: []u8,
        method: []const u8,
        path: []const u8,
        authority: []const u8,
        extra_headers: []const Header,
    ) !usize {
        var offset: usize = 0;

        // :method (indexed from static table)
        if (std.mem.eql(u8, method, "GET")) {
            buffer[offset] = 0x82; // Index 2: :method GET
            offset += 1;
        } else if (std.mem.eql(u8, method, "POST")) {
            buffer[offset] = 0x83; // Index 3: :method POST
            offset += 1;
        } else {
            offset += try encodeLiteralIndexed(buffer[offset..], 2, method);
        }

        // :scheme https (indexed)
        buffer[offset] = 0x87; // Index 7: :scheme https
        offset += 1;

        // :path (indexed if "/" otherwise literal)
        if (std.mem.eql(u8, path, "/")) {
            buffer[offset] = 0x84; // Index 4: :path /
            offset += 1;
        } else if (std.mem.eql(u8, path, "/index.html")) {
            buffer[offset] = 0x85; // Index 5: :path /index.html
            offset += 1;
        } else {
            offset += try encodeLiteralIndexed(buffer[offset..], 4, path);
        }

        // :authority (literal with indexed name)
        offset += try encodeLiteralIndexed(buffer[offset..], 1, authority);

        // Extra headers
        for (extra_headers) |header| {
            offset += try encodeLiteralNeverIndexed(buffer[offset..], header.name, header.value);
        }

        return offset;
    }

    /// Decode response headers from HPACK payload
    pub fn decodeHeaders(
        payload: []const u8,
        headers: []Header,
    ) !usize {
        var offset: usize = 0;
        var count: usize = 0;

        if (payload.len > 0) {
            log.debug("HPACK decoding: payload len={d}, first byte: 0x{x:0>2}", .{
                payload.len,
                payload[0],
            });
        }

        while (offset < payload.len and count < headers.len) {
            const first = payload[offset];
            log.debug("HPACK: offset={d}, first=0x{x:0>2}", .{ offset, first });

            if ((first & 0x80) != 0) {
                // Indexed header field (7-bit prefix)
                const int_result = try decodeInteger(payload[offset..], 7);
                const index = int_result.value;

                if (index == 0) {
                    log.err("HPACK: Invalid index 0 at offset {d}", .{offset});
                    return error.InvalidIndex;
                }

                if (index > 61) {
                    log.debug("HPACK: Index {d} beyond static table, skipping (dynamic table not supported)", .{index});
                    offset += int_result.consumed;
                    continue;
                }

                const entry = StaticTable.get(index - 1);
                log.debug("HPACK indexed: index={d}, name={s}, value={s}", .{ index, entry.name, entry.value });
                headers[count] = .{ .name = entry.name, .value = entry.value };
                count += 1;
                offset += int_result.consumed;
            } else if ((first & 0x40) != 0) {
                // Literal with incremental indexing
                const result = try decodeLiteral(payload[offset..], first & 0x3F, 6);
                headers[count] = .{ .name = result.name, .value = result.value };
                count += 1;
                offset += result.consumed;
            } else if ((first & 0x20) != 0) {
                // Dynamic table size update - skip
                const int_result = try decodeInteger(payload[offset..], 5);
                offset += int_result.consumed;
            } else {
                // Literal without indexing or never indexed
                const mask: u8 = if ((first & 0x10) != 0) 0x0F else 0x0F;
                const result = try decodeLiteral(payload[offset..], first & mask, 4);
                headers[count] = .{ .name = result.name, .value = result.value };
                count += 1;
                offset += result.consumed;
            }
        }

        return count;
    }

    /// Get :status from decoded headers
    pub fn getStatus(headers: []const Header) ?u16 {
        for (headers) |h| {
            if (std.mem.eql(u8, h.name, ":status")) {
                return std.fmt.parseInt(u16, h.value, 10) catch null;
            }
        }
        return null;
    }

    // --- Encoding helpers ---

    fn encodeLiteralIndexed(buffer: []u8, name_index: u8, value: []const u8) !usize {
        if (buffer.len < 2 + value.len) return error.BufferTooSmall;

        var offset: usize = 0;

        // Literal with indexed name (0x40 prefix)
        buffer[offset] = 0x40 | name_index;
        offset += 1;

        // Value length + value
        offset += try encodeString(buffer[offset..], value, false);

        return offset;
    }

    fn encodeLiteralNeverIndexed(buffer: []u8, name: []const u8, value: []const u8) !usize {
        if (buffer.len < 2 + name.len + value.len) return error.BufferTooSmall;

        var offset: usize = 0;

        // Never indexed (0x10 prefix, index 0 = new name)
        buffer[offset] = 0x10;
        offset += 1;

        // Name
        offset += try encodeString(buffer[offset..], name, false);

        // Value
        offset += try encodeString(buffer[offset..], value, false);

        return offset;
    }

    fn encodeString(buffer: []u8, str: []const u8, huffman: bool) !usize {
        _ = huffman; // Not using Huffman for simplicity
        if (buffer.len < 1 + str.len) return error.BufferTooSmall;

        // Length (no Huffman)
        if (str.len < 127) {
            buffer[0] = @intCast(str.len);
            @memcpy(buffer[1..][0..str.len], str);
            return 1 + str.len;
        } else {
            // Multi-byte length encoding
            buffer[0] = 0x7F;
            var remaining = str.len - 127;
            var offset: usize = 1;
            while (remaining >= 128) {
                buffer[offset] = @intCast((remaining & 0x7F) | 0x80);
                remaining >>= 7;
                offset += 1;
            }
            buffer[offset] = @intCast(remaining);
            offset += 1;
            @memcpy(buffer[offset..][0..str.len], str);
            return offset + str.len;
        }
    }

    // --- Decoding helpers ---

    const DecodeResult = struct {
        name: []const u8,
        value: []const u8,
        consumed: usize,
    };

    const IntResult = struct {
        value: usize,
        consumed: usize,
    };

    fn decodeLiteral(data: []const u8, index_bits: u8, prefix_bits: u3) !DecodeResult {
        // Decode the name index using proper integer encoding
        const int_result = try decodeInteger(data, prefix_bits);
        const name_index = int_result.value;
        var offset: usize = int_result.consumed;

        // Get name
        var name: []const u8 = undefined;
        if (name_index == 0) {
            // New name - read it from the data
            const name_result = try decodeString(data[offset..]);
            name = name_result.str;
            offset += name_result.consumed;
        } else if (name_index <= StaticTable.entries.len) {
            // Indexed name from static table
            name = StaticTable.entries[name_index - 1].name;
        } else {
            // Dynamic table reference - use placeholder since we don't track dynamic table
            log.debug("HPACK literal: name_index={d} in dynamic table, using placeholder", .{name_index});
            name = "dynamic-table-entry";
        }
        _ = index_bits; // Unused after refactoring

        // Get value
        const value_result = try decodeString(data[offset..]);
        offset += value_result.consumed;

        return DecodeResult{
            .name = name,
            .value = value_result.str,
            .consumed = offset,
        };
    }

    const StringResult = struct {
        str: []const u8,
        consumed: usize,
    };

    fn decodeString(data: []const u8) !StringResult {
        if (data.len == 0) return error.InvalidEncoding;

        const huffman = (data[0] & 0x80) != 0;
        const int_result = try decodeInteger(data, 7);
        const length = int_result.value;
        const header_len = int_result.consumed;

        if (data.len < header_len + length) return error.InvalidEncoding;

        const str_data = data[header_len..][0..length];

        if (huffman) {
            // TODO: Huffman decoding - for now, return as-is
            return StringResult{ .str = str_data, .consumed = header_len + length };
        }

        return StringResult{ .str = str_data, .consumed = header_len + length };
    }

    fn decodeInteger(data: []const u8, prefix_bits: u3) !IntResult {
        if (data.len == 0) return error.InvalidEncoding;

        const max_prefix: u8 = (@as(u8, 1) << prefix_bits) - 1;
        var value: usize = data[0] & max_prefix;

        if (value < max_prefix) {
            return IntResult{ .value = value, .consumed = 1 };
        }

        var offset: usize = 1;
        var shift: u6 = 0;

        while (offset < data.len) {
            const b = data[offset];
            value += @as(usize, b & 0x7F) << shift;
            offset += 1;

            if ((b & 0x80) == 0) break;
            shift += 7;
        }

        return IntResult{ .value = value, .consumed = offset };
    }
};

/// Header name-value pair
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// HPACK Static Table (RFC 7541 Appendix A)
pub const StaticTable = struct {
    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const entries = [_]Entry{
        .{ .name = ":authority", .value = "" }, // 1
        .{ .name = ":method", .value = "GET" }, // 2
        .{ .name = ":method", .value = "POST" }, // 3
        .{ .name = ":path", .value = "/" }, // 4
        .{ .name = ":path", .value = "/index.html" }, // 5
        .{ .name = ":scheme", .value = "http" }, // 6
        .{ .name = ":scheme", .value = "https" }, // 7
        .{ .name = ":status", .value = "200" }, // 8
        .{ .name = ":status", .value = "204" }, // 9
        .{ .name = ":status", .value = "206" }, // 10
        .{ .name = ":status", .value = "304" }, // 11
        .{ .name = ":status", .value = "400" }, // 12
        .{ .name = ":status", .value = "404" }, // 13
        .{ .name = ":status", .value = "500" }, // 14
        .{ .name = "accept-charset", .value = "" }, // 15
        .{ .name = "accept-encoding", .value = "gzip, deflate" }, // 16
        .{ .name = "accept-language", .value = "" }, // 17
        .{ .name = "accept-ranges", .value = "" }, // 18
        .{ .name = "accept", .value = "" }, // 19
        .{ .name = "access-control-allow-origin", .value = "" }, // 20
        .{ .name = "age", .value = "" }, // 21
        .{ .name = "allow", .value = "" }, // 22
        .{ .name = "authorization", .value = "" }, // 23
        .{ .name = "cache-control", .value = "" }, // 24
        .{ .name = "content-disposition", .value = "" }, // 25
        .{ .name = "content-encoding", .value = "" }, // 26
        .{ .name = "content-language", .value = "" }, // 27
        .{ .name = "content-length", .value = "" }, // 28
        .{ .name = "content-location", .value = "" }, // 29
        .{ .name = "content-range", .value = "" }, // 30
        .{ .name = "content-type", .value = "" }, // 31
        .{ .name = "cookie", .value = "" }, // 32
        .{ .name = "date", .value = "" }, // 33
        .{ .name = "etag", .value = "" }, // 34
        .{ .name = "expect", .value = "" }, // 35
        .{ .name = "expires", .value = "" }, // 36
        .{ .name = "from", .value = "" }, // 37
        .{ .name = "host", .value = "" }, // 38
        .{ .name = "if-match", .value = "" }, // 39
        .{ .name = "if-modified-since", .value = "" }, // 40
        .{ .name = "if-none-match", .value = "" }, // 41
        .{ .name = "if-range", .value = "" }, // 42
        .{ .name = "if-unmodified-since", .value = "" }, // 43
        .{ .name = "last-modified", .value = "" }, // 44
        .{ .name = "link", .value = "" }, // 45
        .{ .name = "location", .value = "" }, // 46
        .{ .name = "max-forwards", .value = "" }, // 47
        .{ .name = "proxy-authenticate", .value = "" }, // 48
        .{ .name = "proxy-authorization", .value = "" }, // 49
        .{ .name = "range", .value = "" }, // 50
        .{ .name = "referer", .value = "" }, // 51
        .{ .name = "refresh", .value = "" }, // 52
        .{ .name = "retry-after", .value = "" }, // 53
        .{ .name = "server", .value = "" }, // 54
        .{ .name = "set-cookie", .value = "" }, // 55
        .{ .name = "strict-transport-security", .value = "" }, // 56
        .{ .name = "transfer-encoding", .value = "" }, // 57
        .{ .name = "user-agent", .value = "" }, // 58
        .{ .name = "vary", .value = "" }, // 59
        .{ .name = "via", .value = "" }, // 60
        .{ .name = "www-authenticate", .value = "" }, // 61
    };

    pub fn get(index: usize) Entry {
        if (index >= entries.len) {
            return .{ .name = "", .value = "" };
        }
        return entries[index];
    }
};

test "encode GET request" {
    var buffer: [256]u8 = undefined;
    const len = try Hpack.encodeRequest(
        &buffer,
        "GET",
        "/api/test",
        "example.com",
        &[_]Header{},
    );
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(@as(u8, 0x82), buffer[0]); // :method GET indexed
}

test "encode POST request" {
    var buffer: [256]u8 = undefined;
    const len = try Hpack.encodeRequest(
        &buffer,
        "POST",
        "/",
        "api.example.com",
        &[_]Header{
            .{ .name = "content-type", .value = "application/json" },
        },
    );
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(@as(u8, 0x83), buffer[0]); // :method POST indexed
}

test "static table entries" {
    const entry = StaticTable.get(1); // :method GET
    try std.testing.expectEqualStrings(":method", entry.name);
    try std.testing.expectEqualStrings("GET", entry.value);
}

test "static table :status entries" {
    // Index 7 = :status 200
    const status_200 = StaticTable.get(7);
    try std.testing.expectEqualStrings(":status", status_200.name);
    try std.testing.expectEqualStrings("200", status_200.value);

    // Index 13 = :status 500
    const status_500 = StaticTable.get(13);
    try std.testing.expectEqualStrings(":status", status_500.name);
    try std.testing.expectEqualStrings("500", status_500.value);
}

test "decode indexed header" {
    // 0x88 = indexed header, index 8 (:status 200)
    const payload = [_]u8{0x88};
    var headers: [8]Header = undefined;

    const count = try Hpack.decodeHeaders(&payload, &headers);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings(":status", headers[0].name);
    try std.testing.expectEqualStrings("200", headers[0].value);
}

test "decode multiple indexed headers" {
    // 0x82 = :method GET, 0x87 = :scheme https, 0x84 = :path /
    const payload = [_]u8{ 0x82, 0x87, 0x84 };
    var headers: [8]Header = undefined;

    const count = try Hpack.decodeHeaders(&payload, &headers);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings(":method", headers[0].name);
    try std.testing.expectEqualStrings("GET", headers[0].value);
    try std.testing.expectEqualStrings(":scheme", headers[1].name);
    try std.testing.expectEqualStrings("https", headers[1].value);
    try std.testing.expectEqualStrings(":path", headers[2].name);
    try std.testing.expectEqualStrings("/", headers[2].value);
}

test "get status from headers" {
    var headers = [_]Header{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/json" },
    };

    const status = Hpack.getStatus(&headers);
    try std.testing.expectEqual(@as(u16, 200), status.?);
}

test "get status returns null when missing" {
    var headers = [_]Header{
        .{ .name = "content-type", .value = "text/html" },
    };

    const status = Hpack.getStatus(&headers);
    try std.testing.expect(status == null);
}

test "encode request with extra headers" {
    var buffer: [512]u8 = undefined;
    const extra = [_]Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "*/*" },
    };

    const len = try Hpack.encodeRequest(
        &buffer,
        "POST",
        "/api/v1/data",
        "api.example.com:443",
        &extra,
    );

    try std.testing.expect(len > 0);
    // POST is indexed as 0x83
    try std.testing.expectEqual(@as(u8, 0x83), buffer[0]);
}

test "encode request with root path uses index" {
    var buffer: [256]u8 = undefined;
    const len = try Hpack.encodeRequest(&buffer, "GET", "/", "example.com", &[_]Header{});

    try std.testing.expect(len > 0);
    // GET = 0x82, https = 0x87, / = 0x84
    try std.testing.expectEqual(@as(u8, 0x82), buffer[0]); // :method GET
    try std.testing.expectEqual(@as(u8, 0x87), buffer[1]); // :scheme https
    try std.testing.expectEqual(@as(u8, 0x84), buffer[2]); // :path /
}
