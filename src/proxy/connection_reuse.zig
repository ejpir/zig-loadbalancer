/// Connection Reuse Logic
///
/// Pure functions for determining when HTTP connections can be safely
/// returned to the connection pool for reuse.
///
/// HTTP/1.1 connection reuse rules (RFC 7230):
/// - Connection: close header means connection must be closed
/// - Incomplete body means connection state is unknown
/// - close-delimited responses consume the connection
const std = @import("std");
const http_utils = @import("../http/http_utils.zig");

/// Reasons why a connection cannot be reused
pub const NoReuseReason = enum {
    /// Connection: close header was present
    connection_close_header,
    /// Body was not fully received (bytes_received < content_length)
    incomplete_body,
    /// Response uses close-delimited framing (no Content-Length, not chunked)
    close_delimited,
    /// An error occurred during the request
    had_error,
};

/// Result of connection reuse check
pub const ReuseResult = union(enum) {
    /// Connection can be reused
    reusable,
    /// Connection cannot be reused, with reason
    not_reusable: NoReuseReason,

    pub fn canReuse(self: ReuseResult) bool {
        return self == .reusable;
    }
};

/// Determine if a connection can be returned to the pool based on response headers.
///
/// This is the first check - call before reading the body.
/// Returns whether the connection is potentially reusable based on headers alone.
pub fn checkHeadersForReuse(headers: []const u8) ReuseResult {
    // Case-insensitive search for "Connection: close"
    // The header could appear as "Connection: close" or "connection: close" etc.
    if (hasConnectionClose(headers)) {
        return .{ .not_reusable = .connection_close_header };
    }
    return .reusable;
}

/// Determine if a connection can be returned to pool after body transfer.
///
/// Call this after the body has been (attempted to be) read.
///
/// Parameters:
/// - length_type: The message framing type from determineMessageLength()
/// - content_length: Expected body length (only relevant for .content_length type)
/// - bytes_received: Actual bytes received for the body
/// - had_error: Whether any error occurred during transfer
pub fn checkBodyForReuse(
    length_type: http_utils.LengthType,
    content_length: usize,
    bytes_received: usize,
    had_error: bool,
) ReuseResult {
    if (had_error) {
        return .{ .not_reusable = .had_error };
    }

    return switch (length_type) {
        .content_length => {
            if (bytes_received < content_length) {
                return .{ .not_reusable = .incomplete_body };
            }
            return .reusable;
        },
        .chunked => {
            // Chunked is reusable if we received the terminating chunk
            // The caller should set had_error=true if terminator wasn't found
            return .reusable;
        },
        .close_delimited => {
            // Close-delimited responses consume the connection by definition
            return .{ .not_reusable = .close_delimited };
        },
        .no_body => .reusable,
        .tunnel => .{ .not_reusable = .close_delimited }, // Tunnels consume connection
        .invalid => .{ .not_reusable = .had_error },
    };
}

/// Combined check for connection reuse.
///
/// Convenience function that checks both headers and body completion.
pub fn shouldReturnToPool(
    headers: []const u8,
    length_type: http_utils.LengthType,
    content_length: usize,
    bytes_received: usize,
    had_error: bool,
) bool {
    // Check headers first
    const header_result = checkHeadersForReuse(headers);
    if (!header_result.canReuse()) return false;

    // Check body completion
    const body_result = checkBodyForReuse(length_type, content_length, bytes_received, had_error);
    return body_result.canReuse();
}

/// Check if headers contain "Connection: close" (case-insensitive)
fn hasConnectionClose(headers: []const u8) bool {
    // Look for "connection:" header (case-insensitive)
    var i: usize = 0;
    while (i < headers.len) {
        // Find start of a header line
        const line_start = i;

        // Find end of line
        const line_end = std.mem.indexOfPos(u8, headers, i, "\r\n") orelse
            headers.len;
        const line = headers[line_start..line_end];

        // Check if this is a Connection header
        if (startsWithIgnoreCase(line, "connection:")) {
            const value_start = "connection:".len;
            const value = std.mem.trim(u8, line[value_start..], " \t");

            // Check if value contains "close"
            if (containsIgnoreCase(value, "close")) {
                return true;
            }
        }

        // Move to next line
        i = if (line_end + 2 <= headers.len)
            line_end + 2
        else
            headers.len;
    }
    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        const h_lower = if (h >= 'A' and h <= 'Z') h + 32 else h;
        const n_lower = if (n >= 'A' and n <= 'Z') n + 32 else n;
        if (h_lower != n_lower) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "checkHeadersForReuse: no Connection header - reusable" {
    const headers =
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 100\r\n\r\n";
    const result = checkHeadersForReuse(headers);
    try std.testing.expect(result.canReuse());
}

test "checkHeadersForReuse: Connection: keep-alive - reusable" {
    const headers =
        "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 100\r\n\r\n";
    const result = checkHeadersForReuse(headers);
    try std.testing.expect(result.canReuse());
}

test "checkHeadersForReuse: Connection: close - not reusable" {
    const headers =
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 100\r\n\r\n";
    const result = checkHeadersForReuse(headers);
    try std.testing.expect(!result.canReuse());
    try std.testing.expectEqual(
        NoReuseReason.connection_close_header,
        result.not_reusable,
    );
}

test "checkHeadersForReuse: CONNECTION: CLOSE (uppercase) - not reusable" {
    const headers =
        "HTTP/1.1 200 OK\r\nCONNECTION: CLOSE\r\nContent-Length: 100\r\n\r\n";
    const result = checkHeadersForReuse(headers);
    try std.testing.expect(!result.canReuse());
}

test "checkHeadersForReuse: connection: Close (mixed case) - not reusable" {
    const headers =
        "HTTP/1.1 200 OK\r\nconnection: Close\r\nContent-Length: 100\r\n\r\n";
    const result = checkHeadersForReuse(headers);
    try std.testing.expect(!result.canReuse());
}

test "checkBodyForReuse: content-length complete - reusable" {
    const result = checkBodyForReuse(.content_length, 100, 100, false);
    try std.testing.expect(result.canReuse());
}

test "checkBodyForReuse: content-length incomplete - not reusable" {
    const result = checkBodyForReuse(.content_length, 100, 50, false);
    try std.testing.expect(!result.canReuse());
    try std.testing.expectEqual(
        NoReuseReason.incomplete_body,
        result.not_reusable,
    );
}

test "checkBodyForReuse: content-length with error - not reusable" {
    const result = checkBodyForReuse(.content_length, 100, 100, true);
    try std.testing.expect(!result.canReuse());
    try std.testing.expectEqual(
        NoReuseReason.had_error,
        result.not_reusable,
    );
}

test "checkBodyForReuse: chunked without error - reusable" {
    const result = checkBodyForReuse(.chunked, 0, 500, false);
    try std.testing.expect(result.canReuse());
}

test "checkBodyForReuse: chunked with error - not reusable" {
    const result = checkBodyForReuse(.chunked, 0, 500, true);
    try std.testing.expect(!result.canReuse());
}

test "checkBodyForReuse: close_delimited - not reusable" {
    const result = checkBodyForReuse(.close_delimited, 0, 500, false);
    try std.testing.expect(!result.canReuse());
    try std.testing.expectEqual(
        NoReuseReason.close_delimited,
        result.not_reusable,
    );
}

test "checkBodyForReuse: no_body - reusable" {
    const result = checkBodyForReuse(.no_body, 0, 0, false);
    try std.testing.expect(result.canReuse());
}

test "checkBodyForReuse: tunnel - not reusable" {
    const result = checkBodyForReuse(.tunnel, 0, 0, false);
    try std.testing.expect(!result.canReuse());
}

test "checkBodyForReuse: invalid - not reusable" {
    const result = checkBodyForReuse(.invalid, 0, 0, false);
    try std.testing.expect(!result.canReuse());
}

test "shouldReturnToPool: complete response - true" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n";
    const result = shouldReturnToPool(headers, .content_length, 100, 100, false);
    try std.testing.expect(result);
}

test "shouldReturnToPool: Connection: close - false" {
    const headers = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 100\r\n\r\n";
    const result = shouldReturnToPool(headers, .content_length, 100, 100, false);
    try std.testing.expect(!result);
}

test "shouldReturnToPool: incomplete body - false" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n";
    const result = shouldReturnToPool(headers, .content_length, 100, 50, false);
    try std.testing.expect(!result);
}

test "shouldReturnToPool: error occurred - false" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n";
    const result = shouldReturnToPool(headers, .content_length, 100, 100, true);
    try std.testing.expect(!result);
}

test "shouldReturnToPool: close-delimited - false" {
    const headers = "HTTP/1.1 200 OK\r\n\r\n";
    const result = shouldReturnToPool(headers, .close_delimited, 0, 500, false);
    try std.testing.expect(!result);
}

test "shouldReturnToPool: 204 no body - true" {
    const headers = "HTTP/1.1 204 No Content\r\n\r\n";
    const result = shouldReturnToPool(headers, .no_body, 0, 0, false);
    try std.testing.expect(result);
}

test "hasConnectionClose: close in middle of header list" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" ++
        "Connection: close\r\nServer: test\r\n\r\n";
    try std.testing.expect(hasConnectionClose(headers));
}

test "hasConnectionClose: connection but not close value" {
    const headers = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\n";
    try std.testing.expect(!hasConnectionClose(headers));
}

test "hasConnectionClose: no connection header" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n";
    try std.testing.expect(!hasConnectionClose(headers));
}
