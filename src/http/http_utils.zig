/// HTTP Protocol Utilities
///
/// HTTP message length detection per RFC 7230 rules.
const std = @import("std");

/// Determines message length according to RFC 7230 rules
pub fn determineMessageLength(
    method: []const u8,
    status_code: u16,
    headers: []const u8,
    is_request: bool,
) MessageLength {
    // 1. HEAD requests, 1xx/204/304 responses have no body
    if (std.mem.eql(u8, method, "HEAD") or
        (status_code >= 100 and status_code < 200) or
        status_code == 204 or
        status_code == 304)
    {
        return .{ .type = .no_body };
    }

    // 2. Successful CONNECT responses become a tunnel
    if (std.mem.eql(u8, method, "CONNECT") and status_code >= 200 and status_code < 300) {
        return .{ .type = .tunnel };
    }

    // 3. Transfer-Encoding takes precedence if present
    var line_iter = std.mem.splitSequence(u8, headers, "\r\n");
    while (line_iter.next()) |line| {
        if (std.ascii.indexOfIgnoreCase(line, "transfer-encoding:")) |pos| {
            const value_start = pos + "transfer-encoding:".len;
            const value_str = std.mem.trim(u8, line[value_start..], " \t");

            // Check if chunked is the final encoding
            if (std.mem.lastIndexOfScalar(u8, value_str, ',')) |comma_pos| {
                const final_encoding =
                    std.mem.trim(u8, value_str[comma_pos + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(final_encoding, "chunked")) {
                    return .{ .type = .chunked };
                }
            } else if (std.ascii.eqlIgnoreCase(value_str, "chunked")) {
                return .{ .type = .chunked };
            }

            // Non-chunked transfer encoding
            if (is_request) {
                return .{ .type = .invalid };
            } else {
                return .{ .type = .close_delimited };
            }
        }
    }

    // 4. Check for conflicting Content-Length headers
    if (hasConflictingContentLength(headers)) {
        return .{ .type = .invalid };
    }

    // 5. Use Content-Length if present
    if (getContentLength(headers)) |length| {
        return .{ .type = .content_length, .length = length };
    }

    // 6. Requests without a body have zero length
    if (is_request) {
        return .{ .type = .no_body };
    }

    // 7. Responses without declared length read until connection closes
    return .{ .type = .close_delimited };
}

pub const LengthType = enum {
    no_body,
    content_length,
    chunked,
    close_delimited,
    tunnel,
    invalid,
};

pub const MessageLength = struct {
    type: LengthType,
    length: usize = 0,
};

/// Extract Content-Length from headers
fn getContentLength(data: []const u8) ?usize {
    var line_iter = std.mem.splitSequence(u8, data, "\r\n");
    while (line_iter.next()) |line| {
        if (std.ascii.indexOfIgnoreCase(line, "content-length:")) |pos| {
            const value_start = pos + "content-length:".len;
            const value_str =
                std.mem.trim(u8, line[value_start..], " \t");
            return std.fmt.parseInt(usize, value_str, 10) catch null;
        }
    }
    return null;
}

/// Detects if there are multiple conflicting Content-Length headers
fn hasConflictingContentLength(data: []const u8) bool {
    var seen_content_length: ?usize = null;
    var line_iter = std.mem.splitSequence(u8, data, "\r\n");
    while (line_iter.next()) |line| {
        if (std.ascii.indexOfIgnoreCase(line, "content-length:")) |pos| {
            const value_start = pos + "content-length:".len;
            const value_str =
                std.mem.trim(u8, line[value_start..], " \t");
            const length = std.fmt.parseInt(usize, value_str, 10) catch {
                return true;
            };

            if (seen_content_length) |previous| {
                if (previous != length) {
                    return true;
                }
            } else {
                seen_content_length = length;
            }
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "determineMessageLength: HEAD request - no body" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n";
    const result = determineMessageLength("HEAD", 200, headers, false);
    try std.testing.expectEqual(LengthType.no_body, result.type);
}

test "determineMessageLength: 204 No Content - no body" {
    const headers = "HTTP/1.1 204 No Content\r\n\r\n";
    const result = determineMessageLength("GET", 204, headers, false);
    try std.testing.expectEqual(LengthType.no_body, result.type);
}

test "determineMessageLength: chunked encoding" {
    const headers = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
    const result = determineMessageLength("GET", 200, headers, false);
    try std.testing.expectEqual(LengthType.chunked, result.type);
}

test "determineMessageLength: Content-Length header" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n";
    const result = determineMessageLength("GET", 200, headers, false);
    try std.testing.expectEqual(LengthType.content_length, result.type);
    try std.testing.expectEqual(@as(usize, 1234), result.length);
}

test "determineMessageLength: no length headers response - close delimited" {
    const headers = "HTTP/1.1 200 OK\r\n\r\n";
    const result = determineMessageLength("GET", 200, headers, false);
    try std.testing.expectEqual(LengthType.close_delimited, result.type);
}
