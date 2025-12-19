/// I/O Operations for Streaming Proxy (TigerStyle)
///
/// Handles reading headers, forwarding headers, and streaming body.
/// Backend-agnostic - works with any backend type after connection is established.
///
/// TigerStyle compliance:
/// - Functions <70 lines
/// - ~2 assertions per function
/// - u32 for indices, explicit bounds
/// - Smallest variable scope
const std = @import("std");
const log = std.log.scoped(.mp);

const zzz = @import("zzz");
const http = zzz.HTTP;

const config = @import("../core/config.zig");
const http_utils = @import("../http/http_utils.zig");
const simd_parse = @import("../internal/simd_parse.zig");
const metrics = @import("../metrics/mod.zig");

// Re-export types for convenience
pub const ProxyState = @import("handler.zig").ProxyState;
pub const ProxyError = @import("handler.zig").ProxyError;

const MAX_HEADER_BYTES = config.MAX_HEADER_BYTES;
const MAX_BODY_CHUNK_BYTES = config.MAX_BODY_CHUNK_BYTES;
const MAX_HEADER_READ_ITERATIONS = config.MAX_HEADER_READ_ITERATIONS;
const MAX_BODY_READ_ITERATIONS = config.MAX_BODY_READ_ITERATIONS;
const MAX_HEADER_LINES = config.MAX_HEADER_LINES;

// ============================================================================
// Phase 3: Read Headers
// ============================================================================

pub fn readHeaders(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    header_buffer: *[MAX_HEADER_BYTES]u8,
    header_len: *u32,
    header_end: *u32,
    req_id: u32,
) ProxyError!http_utils.MessageLength {
    // TigerStyle: pair assertions.
    std.debug.assert(header_len.* == 0);
    std.debug.assert(header_end.* == 0);
    std.debug.assert(proxy_state.sock.stream != null);

    const stream = proxy_state.sock.stream orelse return ProxyError.ConnectionFailed;

    // Prevent slowloris attacks - limit read iterations to detect malicious drip-feed.
    var iterations: u32 = 0;
    while (header_end.* == 0) {
        // Fail-fast before excessive CPU/memory consumption from attack.
        if (iterations >= MAX_HEADER_READ_ITERATIONS) {
            log.err("[REQ {d}] Header read exceeded max iterations", .{req_id});
            return ProxyError.InvalidResponse;
        }
        // Prevent memory exhaustion from huge headers sent by malicious client/backend.
        if (header_len.* >= MAX_HEADER_BYTES) {
            return ProxyError.InvalidResponse;
        }

        const n = readHeaders_read(
            ctx,
            proxy_state,
            stream,
            header_buffer,
            header_len.*,
            req_id,
        ) catch {
            readHeaders_recordFailure(proxy_state);
            return ProxyError.ReadFailed;
        };

        if (n == 0) {
            readHeaders_recordFailure(proxy_state);
            return ProxyError.EmptyResponse;
        }

        header_len.* += @intCast(n);
        if (simd_parse.findHeaderEnd(header_buffer[0..header_len.*])) |pos| {
            header_end.* = @intCast(pos + 4);
        }

        iterations += 1;
    }

    // HTTP response must have headers, validate parse succeeded before processing.
    std.debug.assert(header_end.* > 0);
    std.debug.assert(header_end.* <= header_len.*);

    // Parse status line - TigerStyle: fail-fast on parse error.
    const headers = header_buffer[0..header_end.*];
    const line_end = simd_parse.findLineEnd(headers) orelse
        return ProxyError.InvalidResponse;
    const space = std.mem.indexOf(u8, headers[0..line_end], " ") orelse
        return ProxyError.InvalidResponse;

    // TigerStyle: fail-fast - don't use default on parse error.
    proxy_state.status_code = std.fmt.parseInt(u16, headers[space + 1 ..][0..3], 10) catch {
        log.err("[REQ {d}] Failed to parse status code", .{req_id});
        return ProxyError.InvalidResponse;
    };

    // TigerStyle: pair assertion - validate parsed status.
    std.debug.assert(proxy_state.status_code >= 100 and
        proxy_state.status_code <= 599);

    const msg_len = http_utils.determineMessageLength(
        "GET",
        proxy_state.status_code,
        headers,
        false,
    );

    log.debug("[REQ {d}] BACKEND RESP status={d} hdr={d} type={s} len={d}", .{
        req_id,
        proxy_state.status_code,
        header_end.*,
        @tagName(msg_len.type),
        msg_len.length,
    });

    // Trace: dump response headers (inline check avoids function call overhead)
    if (config.isTraceEnabled()) {
        config.hexDump("RESPONSE HEADERS FROM BACKEND", header_buffer[0..header_end.*]);
    }

    return msg_len;
}

fn readHeaders_read(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    stream: anytype,
    header_buffer: *[MAX_HEADER_BYTES]u8,
    header_len: u32,
    req_id: u32,
) !usize {
    if (proxy_state.is_tls) {
        if (proxy_state.tls_conn_ptr) |tls_conn| {
            log.debug("[REQ {d}] TLS reading (header_len={d})...", .{ req_id, header_len });
            const n = try tls_conn.read(header_buffer[header_len..]);
            log.debug("[REQ {d}] TLS read got {d} bytes", .{ req_id, n });
            return n;
        }
        return error.NoTlsConnection;
    } else {
        // Prevent data leaks if error occurs mid-read, deterministic debugging.
        // Safe undefined: buffer fully written by read before use.
        var read_buf: [MAX_BODY_CHUNK_BYTES]u8 = undefined;
        var reader = stream.reader(ctx.io, &read_buf);
        var bufs: [1][]u8 = .{header_buffer[header_len..]};
        return try reader.interface.readVec(&bufs);
    }
}

fn readHeaders_recordFailure(proxy_state: *ProxyState) void {
    metrics.global_metrics.recordReadFailure();
    if (proxy_state.from_pool) {
        metrics.global_metrics.recordStaleConnection();
    }
}

// ============================================================================
// Phase 4: Forward Headers
// ============================================================================

pub fn forwardHeaders(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    header_buffer: *[MAX_HEADER_BYTES]u8,
    header_end: u32,
    body_already_read: u32,
    msg_len: http_utils.MessageLength,
    req_id: u32,
) ProxyError!void {
    // TigerStyle: pair assertions.
    std.debug.assert(header_end > 0);
    std.debug.assert(proxy_state.status_code >= 100 and proxy_state.status_code <= 599);

    const headers = header_buffer[0..header_end];
    const client_writer = ctx.writer;
    const status: http.Status = @enumFromInt(proxy_state.status_code);
    var response = ctx.response;
    response.status = status;

    // Parse and forward headers.
    var content_type_value: ?[]const u8 = null;
    forwardHeaders_parse(headers, response, &content_type_value, proxy_state);
    forwardHeaders_setMime(response, content_type_value);

    // Write headers to client.
    const content_len: ?usize = if (msg_len.type == .content_length) msg_len.length else null;
    const writer_start = client_writer.end;
    response.headers_into_writer_opts(client_writer, content_len, true) catch {
        return ProxyError.SendFailed;
    };
    proxy_state.bytes_to_client = @intCast(client_writer.end - writer_start);

    // Next request's data would corrupt pool - must close connection.
    if (msg_len.type == .content_length) {
        if (body_already_read > msg_len.length) {
            log.warn(
                "[REQ {d}] READ AHEAD detected: " ++
                    "got {d} body bytes, expected {d} - NOT pooling",
                .{ req_id, body_already_read, msg_len.length },
            );
            proxy_state.can_return_to_pool = false;
        }
    }

    // Send body data already in header buffer.
    const body_to_write: u32 = if (msg_len.type == .content_length)
        @min(body_already_read, @as(u32, @intCast(msg_len.length)))
    else
        body_already_read;

    if (body_to_write > 0) {
        // Trace: dump body data that arrived with headers
        if (config.isTraceEnabled()) {
            config.hexDump("RESPONSE BODY (with headers)", header_buffer[header_end..][0..body_to_write]);
        }

        client_writer.writeAll(header_buffer[header_end..][0..body_to_write]) catch {
            return ProxyError.SendFailed;
        };
    }
    client_writer.flush() catch {
        return ProxyError.SendFailed;
    };

    proxy_state.bytes_from_backend = header_end + body_to_write;
    proxy_state.bytes_to_client += body_to_write;

    log.debug("[REQ {d}] HDR WRITE {d} bytes", .{ req_id, proxy_state.bytes_to_client });
}

fn forwardHeaders_parse(
    headers: []const u8,
    response: *http.Response,
    content_type_value: *?[]const u8,
    proxy_state: *ProxyState,
) void {
    const skip = std.StaticStringMap(void).initComptime(.{
        .{ "connection", {} },
        .{ "keep-alive", {} },
        .{ "transfer-encoding", {} },
        .{ "server", {} },
        .{ "content-length", {} },
        .{ "content-type", {} },
    });

    const line_end = simd_parse.findLineEnd(headers) orelse return;
    var pos: u32 = @intCast(line_end + 2);
    var line_count: u32 = 0;

    // Prevent memory exhaustion from huge header count sent by malicious client/backend.
    while (pos < headers.len -| 2) {
        if (line_count >= MAX_HEADER_LINES) break;

        const end = std.mem.indexOfPos(u8, headers, pos, "\r\n") orelse break;
        const line = headers[pos..end];

        if (std.mem.indexOf(u8, line, ":")) |c| {
            var lb: [64]u8 = undefined;
            const name_len: u32 = @min(@as(u32, @intCast(line[0..c].len)), 64);
            for (line[0..name_len], 0..) |ch, i| {
                lb[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            }

            if (skip.get(lb[0..name_len]) == null) {
                const name = line[0..c];
                const value = std.mem.trim(u8, line[c + 1 ..], " ");
                response.headers.put(name, value) catch |err| {
                    // TigerStyle: fail-fast - log instead of silent ignore.
                    log.warn("Header put failed: {}", .{err});
                };
            } else if (std.mem.eql(u8, lb[0..name_len], "content-type")) {
                content_type_value.* = std.mem.trim(u8, line[c + 1 ..], " ");
            } else if (std.mem.eql(u8, lb[0..name_len], "connection")) {
                const value = std.mem.trim(u8, line[c + 1 ..], " ");
                if (std.ascii.eqlIgnoreCase(value, "close")) {
                    proxy_state.backend_wants_close = true;
                    proxy_state.can_return_to_pool = false;
                }
            }
        }
        pos = @intCast(end + 2);
        line_count += 1;
    }
}

fn forwardHeaders_setMime(
    response: *http.Response,
    content_type_value: ?[]const u8,
) void {
    if (content_type_value) |ct| {
        if (std.mem.startsWith(u8, ct, "text/html")) {
            response.mime = http.Mime.HTML;
        } else if (std.mem.startsWith(u8, ct, "text/plain")) {
            response.mime = http.Mime.TEXT;
        } else if (std.mem.startsWith(u8, ct, "application/json")) {
            response.mime = http.Mime.JSON;
        } else {
            response.mime = http.Mime.BIN;
        }
    } else {
        response.mime = http.Mime.BIN;
    }
}

// ============================================================================
// Phase 5: Stream Body
// ============================================================================

pub fn streamBody(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    header_end: u32,
    header_len: u32,
    msg_len: http_utils.MessageLength,
    req_id: u32,
) void {
    const stream = proxy_state.sock.stream orelse {
        proxy_state.body_had_error = true;
        return;
    };

    const client_writer = ctx.writer;
    const body_already_read = header_len - header_end;

    var bytes_received: u32 = if (msg_len.type == .content_length)
        @min(body_already_read, @as(u32, @intCast(msg_len.length)))
    else
        body_already_read;

    if (msg_len.type == .content_length) {
        streamBody_contentLength(
            ctx,
            proxy_state,
            stream,
            client_writer,
            msg_len.length,
            &bytes_received,
        );
    } else if (msg_len.type == .chunked or msg_len.type == .close_delimited) {
        proxy_state.can_return_to_pool = false;
        streamBody_chunked(
            ctx,
            proxy_state,
            stream,
            client_writer,
            msg_len.type == .chunked,
            &bytes_received,
        );
    }

    // Final flush.
    client_writer.flush() catch {
        proxy_state.client_write_error = true;
    };

    proxy_state.bytes_from_backend += bytes_received;

    log.debug("[REQ {d}] CLIENT DONE body={d} w_err={} b_err={}", .{
        req_id, bytes_received, proxy_state.client_write_error, proxy_state.body_had_error,
    });
}

fn streamBody_contentLength(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    stream: anytype,
    client_writer: anytype,
    content_length: usize,
    bytes_received: *u32,
) void {
    // Prevent data leaks if error occurs mid-read, deterministic debugging.
    // Safe undefined: buffer fully written by read before forwarding.
    var body_buf: [MAX_BODY_CHUNK_BYTES]u8 = undefined;

    // Prevent infinite loops from malicious backends sending endless body data.
    var iterations: u32 = 0;
    while (bytes_received.* < content_length) {
        if (iterations >= MAX_BODY_READ_ITERATIONS) break;

        const remaining: u32 = @intCast(content_length - bytes_received.*);
        const read_size = @min(remaining, MAX_BODY_CHUNK_BYTES);

        const n = streamBody_read(
            ctx,
            proxy_state,
            stream,
            &body_buf,
            read_size,
        ) catch {
            proxy_state.body_had_error = true;
            proxy_state.sock.connected = false;
            proxy_state.can_return_to_pool = false;
            break;
        };

        if (n == 0) {
            proxy_state.body_had_error = true;
            proxy_state.sock.connected = false;
            proxy_state.can_return_to_pool = false;
            break;
        }

        // Trace: dump body chunk (inline check avoids function call overhead)
        if (config.isTraceEnabled()) {
            config.hexDump("RESPONSE BODY CHUNK", body_buf[0..n]);
        }

        client_writer.writeAll(body_buf[0..n]) catch {
            proxy_state.client_write_error = true;
            break;
        };

        bytes_received.* += @intCast(n);
        proxy_state.bytes_to_client += @intCast(n);
        iterations += 1;
    }

    // TigerStyle: pair assertion - validate bytes received.
    std.debug.assert(bytes_received.* <= content_length or proxy_state.body_had_error);
}

fn streamBody_chunked(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    stream: anytype,
    client_writer: anytype,
    is_chunked: bool,
    bytes_received: *u32,
) void {
    // Prevent data leaks if error occurs mid-read, deterministic debugging.
    // Safe undefined: buffer fully written by read before forwarding.
    var body_buf: [MAX_BODY_CHUNK_BYTES]u8 = undefined;

    // Prevent infinite loops from malicious backends sending endless chunked data.
    var iterations: u32 = 0;
    while (iterations < MAX_BODY_READ_ITERATIONS) {
        const n = streamBody_read(
            ctx,
            proxy_state,
            stream,
            &body_buf,
            MAX_BODY_CHUNK_BYTES,
        ) catch {
            proxy_state.body_had_error = true;
            proxy_state.sock.connected = false;
            break;
        };

        if (n == 0) {
            proxy_state.body_had_error = true;
            proxy_state.sock.connected = false;
            break;
        }

        // Trace: dump body chunk (inline check avoids function call overhead)
        if (config.isTraceEnabled()) {
            config.hexDump("RESPONSE BODY CHUNK", body_buf[0..n]);
        }

        client_writer.writeAll(body_buf[0..n]) catch {
            proxy_state.client_write_error = true;
            break;
        };

        bytes_received.* += @intCast(n);
        proxy_state.bytes_to_client += @intCast(n);

        if (is_chunked) {
            if (simd_parse.findChunkEnd(body_buf[0..n]) != null) {
                break;
            }
        }

        iterations += 1;
    }
}

fn streamBody_read(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    stream: anytype,
    body_buf: *[MAX_BODY_CHUNK_BYTES]u8,
    read_size: u32,
) !usize {
    if (proxy_state.is_tls) {
        if (proxy_state.tls_conn_ptr) |tls_conn| {
            return try tls_conn.read(body_buf[0..read_size]);
        }
        return error.NoTlsConnection;
    } else {
        // Prevent data leaks if error occurs mid-read, deterministic debugging.
        // Safe undefined: buffer fully written by read before use.
        var read_buf: [MAX_BODY_CHUNK_BYTES]u8 = undefined;
        var reader = stream.reader(ctx.io, &read_buf);
        var bufs: [1][]u8 = .{body_buf[0..read_size]};
        return try reader.interface.readVec(&bufs);
    }
}
