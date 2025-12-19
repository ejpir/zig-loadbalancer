/// Request Building and Sending for Streaming Proxy (TigerStyle)
///
/// Handles HTTP request construction and transmission to backends.
/// Uses generic implementation to deduplicate BackendServer vs SharedBackend paths.
///
/// TigerStyle compliance:
/// - Functions <70 lines
/// - ~2 assertions per function
/// - u32 for indices, explicit bounds
/// - Smallest variable scope
/// - Duck-typing via anytype for backend compatibility
const std = @import("std");
const log = std.log.scoped(.mp);

const zzz = @import("zzz");
const http = zzz.HTTP;

const config = @import("../core/config.zig");
const ultra_sock_mod = @import("../http/ultra_sock.zig");
const UltraSock = ultra_sock_mod.UltraSock;
const metrics = @import("../metrics/mod.zig");

// Re-export types for convenience
pub const ProxyState = @import("handler.zig").ProxyState;
pub const ProxyError = @import("handler.zig").ProxyError;

const MAX_REQUEST_HEADER_BYTES = config.MAX_HEADER_BYTES;
const MAX_HEADER_LINES = config.MAX_HEADER_LINES;
const MAX_BODY_CHUNK_BYTES = config.MAX_BODY_CHUNK_BYTES;

// ============================================================================
// Generic Request Building
// ============================================================================

/// Build HTTP request headers with client headers and body support.
/// Filters out hop-by-hop headers and adds necessary headers for proxying.
/// Works with any backend type that has: .getFullHost(), .port
pub fn buildRequestHeaders(
    comptime BackendT: type,
    ctx: *const http.Context,
    backend: *const BackendT,
    buffer: *[MAX_REQUEST_HEADER_BYTES]u8,
) ![]const u8 {
    // TigerStyle: explicit bounds checking.
    var pos: u32 = 0;

    // Write request line: METHOD URI HTTP/1.1\r\n
    const method_str = @tagName(ctx.request.method orelse .GET);
    const uri_str = ctx.request.uri orelse "/";
    const request_line = try std.fmt.bufPrint(
        buffer[pos..],
        "{s} {s} HTTP/1.1\r\n",
        .{ method_str, uri_str },
    );
    pos += @intCast(request_line.len);

    // Write Host header
    const host_header = try std.fmt.bufPrint(
        buffer[pos..],
        "Host: {s}:{d}\r\n",
        .{ backend.getFullHost(), backend.port },
    );
    pos += @intCast(host_header.len);

    // Hop-by-hop headers to skip (RFC 2616 Section 13.5.1)
    const hop_by_hop = std.StaticStringMap(void).initComptime(.{
        .{ "connection", {} },
        .{ "keep-alive", {} },
        .{ "transfer-encoding", {} },
        .{ "te", {} },
        .{ "trailer", {} },
        .{ "upgrade", {} },
        .{ "proxy-authorization", {} },
        .{ "proxy-connection", {} },
    });

    // Forward client headers (except hop-by-hop)
    var header_iter = ctx.request.headers.iterator();
    var header_count: u32 = 0;
    while (header_iter.next()) |entry| {
        if (header_count >= MAX_HEADER_LINES) break;

        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Convert to lowercase for comparison
        var name_lower: [64]u8 = undefined;
        const name_len: u32 = @min(@as(u32, @intCast(name.len)), 64);
        for (name[0..name_len], 0..) |ch, i| {
            name_lower[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        }

        // Skip hop-by-hop headers and Host (already added)
        if (hop_by_hop.get(name_lower[0..name_len]) != null) continue;
        if (std.mem.eql(u8, name_lower[0..name_len], "host")) continue;

        // Write header
        const header = try std.fmt.bufPrint(
            buffer[pos..],
            "{s}: {s}\r\n",
            .{ name, value },
        );
        pos += @intCast(header.len);
        header_count += 1;
    }

    // Add Content-Length if body exists
    if (ctx.request.body) |body| {
        const content_len_header = try std.fmt.bufPrint(
            buffer[pos..],
            "Content-Length: {d}\r\n",
            .{body.len},
        );
        pos += @intCast(content_len_header.len);
    }

    // Write Connection: keep-alive
    const conn_header = "Connection: keep-alive\r\n";
    @memcpy(buffer[pos..][0..conn_header.len], conn_header);
    pos += conn_header.len;

    // End headers with \r\n
    buffer[pos] = '\r';
    buffer[pos + 1] = '\n';
    pos += 2;

    // TigerStyle: pair assertion on output.
    std.debug.assert(pos > 0);
    std.debug.assert(pos <= MAX_REQUEST_HEADER_BYTES);

    return buffer[0..pos];
}

// ============================================================================
// Generic Request Sending
// ============================================================================

/// Send request to backend (generic - works with any backend type).
/// Handles TLS and plain connections, with automatic retry for stale pooled connections.
pub fn sendRequest(
    comptime BackendT: type,
    ctx: *const http.Context,
    backend: *const BackendT,
    proxy_state: *ProxyState,
    req_id: u32,
) ProxyError!void {
    // TigerStyle: pair assertion.
    proxy_state.assertValid();
    std.debug.assert(proxy_state.sock.stream != null);

    // Prevent data leaks if error occurs mid-formatting, deterministic debugging.
    // Safe undefined: buffer fully written by bufPrint before send.
    var request_buf: [MAX_REQUEST_HEADER_BYTES]u8 = undefined;
    const request_data = buildRequestHeaders(BackendT, ctx, backend, &request_buf) catch {
        return ProxyError.ConnectionFailed;
    };

    // TigerStyle: pair assertion on output.
    std.debug.assert(request_data.len > 0);
    std.debug.assert(request_data.len <= MAX_REQUEST_HEADER_BYTES);

    log.debug("[REQ {d}] SENDING TO BACKEND ({s}): {s}", .{
        req_id,
        if (proxy_state.is_tls) "TLS" else "plain",
        request_data[0..@min(request_data.len, 60)],
    });

    // TigerStyle: smallest scope - only create writer when needed.
    var send_ok = false;
    if (proxy_state.is_tls) {
        send_ok = sendRequest_tls(proxy_state, request_data, ctx.request.body, req_id);
    } else {
        send_ok = sendRequest_plain(ctx, proxy_state, request_data, ctx.request.body);
    }

    // Retry on stale pooled connection.
    if (!send_ok) {
        if (proxy_state.from_pool) {
            send_ok = sendRequest_retry(
                BackendT,
                ctx,
                backend,
                proxy_state,
                request_data,
                req_id,
            );
        }
    }

    if (!send_ok) {
        metrics.global_metrics.recordSendFailure();
        return ProxyError.SendFailed;
    }
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn sendRequest_tls(
    proxy_state: *ProxyState,
    request_data: []const u8,
    body: ?[]const u8,
    req_id: u32,
) bool {
    if (proxy_state.tls_conn_ptr) |tls_conn| {
        const total_len = request_data.len + if (body) |b| b.len else 0;
        log.debug("[REQ {d}] TLS writeAll {d} bytes (hdr={d} body={d})...", .{
            req_id,
            total_len,
            request_data.len,
            if (body) |b| b.len else 0,
        });

        // Send headers
        tls_conn.writeAll(request_data) catch |err| {
            log.debug("[REQ {d}] TLS header write failed: {}", .{ req_id, err });
            return false;
        };

        // Send body if exists
        if (body) |body_data| {
            tls_conn.writeAll(body_data) catch |err| {
                log.debug("[REQ {d}] TLS body write failed: {}", .{ req_id, err });
                return false;
            };
        }

        log.debug("[REQ {d}] TLS send complete", .{req_id});
        return true;
    }
    return false;
}

fn sendRequest_plain(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    request_data: []const u8,
    body: ?[]const u8,
) bool {
    const stream = proxy_state.sock.stream orelse return false;
    // Prevent data leaks if error occurs mid-write, deterministic debugging.
    // Safe undefined: buffer fully written by I/O before use.
    var write_buf: [MAX_BODY_CHUNK_BYTES]u8 = undefined;
    var writer = stream.writer(ctx.io, &write_buf);

    // Send headers
    writer.interface.writeAll(request_data) catch return false;

    // Send body if exists
    if (body) |body_data| {
        writer.interface.writeAll(body_data) catch return false;
    }

    writer.interface.flush() catch return false;
    return true;
}

fn sendRequest_retry(
    comptime BackendT: type,
    ctx: *const http.Context,
    backend: *const BackendT,
    proxy_state: *ProxyState,
    request_data: []const u8,
    req_id: u32,
) bool {
    // Only retry pooled connections - fresh connection failure indicates real backend problem.
    metrics.global_metrics.recordStaleConnection();
    log.debug("[REQ {d}] Pooled conn stale on write, retrying with fresh", .{req_id});
    proxy_state.sock.close_blocking();

    proxy_state.sock = UltraSock.fromBackendServer(backend);
    proxy_state.sock.connect(ctx.io) catch {
        proxy_state.sock.close_blocking();
        return false;
    };
    proxy_state.from_pool = false;
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
    proxy_state.is_tls = proxy_state.sock.isTls();

    // Get body from ctx for retry
    const body = ctx.request.body;

    if (proxy_state.is_tls) {
        return sendRequest_tls(proxy_state, request_data, body, req_id);
    } else {
        return sendRequest_plain(ctx, proxy_state, request_data, body);
    }
}
