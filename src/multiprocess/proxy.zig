/// Multi-Process Streaming Proxy
///
/// Streaming proxy with automatic failover for single-threaded workers.
/// Uses both backend connection pooling (~99% pool hit rate) and client-side
/// HTTP keep-alive for maximum efficiency.
const std = @import("std");
const log = std.log.scoped(.mp);

const zzz = @import("zzz");
const http = zzz.HTTP;

const types = @import("../core/types.zig");
const UltraSock = @import("../http/ultra_sock.zig").UltraSock;
const http_utils = @import("../http/http_utils.zig");
const simd_parse = @import("../internal/simd_parse.zig");
const metrics = @import("../utils/metrics.zig");
const WorkerState = @import("worker_state.zig").WorkerState;
const connection_reuse = @import("connection_reuse.zig");

pub const ProxyError = error{
    ConnectionFailed,
    BackendUnavailable,
    SendFailed,
    ReadFailed,
    Timeout,
    EmptyResponse,
    InvalidResponse,
};

/// Generate handler with health-aware load balancing
pub fn generateHandler(comptime strategy: types.LoadBalancerStrategy) fn (*const http.Context, *WorkerState) anyerror!http.Respond {
    return struct {
        pub fn handle(ctx: *const http.Context, state: *WorkerState) !http.Respond {
            if (state.backends.items.len == 0) {
                return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "No backends configured" });
            }

            // Note: selectBackend manages its own counter for round-robin
            const backend_idx = state.selectBackend(strategy) orelse {
                return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "No backends available" });
            };

            return proxyWithFailover(ctx, backend_idx, state);
        }
    }.handle;
}

/// Proxy with automatic failover
fn proxyWithFailover(ctx: *const http.Context, primary_idx: usize, state: *WorkerState) !http.Respond {
    const backends = state.backends;

    if (streamingProxy(ctx, &backends.items[primary_idx], primary_idx, state)) |response| {
        state.recordSuccess(primary_idx);
        return response;
    } else |err| {
        state.recordFailure(primary_idx);
        log.warn("Backend {d} failed: {s}", .{ primary_idx + 1, @errorName(err) });

        if (state.findHealthyBackend(primary_idx)) |failover_idx| {
            log.debug("Failing over to backend {d}", .{failover_idx + 1});

            if (streamingProxy(ctx, &backends.items[failover_idx], failover_idx, state)) |response| {
                state.recordSuccess(failover_idx);
                return response;
            } else |failover_err| {
                state.recordFailure(failover_idx);
                log.warn("Failover to backend {d} failed: {s}", .{ failover_idx + 1, @errorName(failover_err) });
            }
        }

        return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "All backends unavailable" });
    }
}

// Debug counters (per-worker, no atomics needed)
var debug_pool_hits: usize = 0;
var debug_pool_misses: usize = 0;
var debug_stale_connections: usize = 0;
var debug_send_failures: usize = 0;
var debug_read_failures: usize = 0;
var debug_request_count: usize = 0;

/// Streaming proxy implementation
fn streamingProxy(ctx: *const http.Context, backend: *const types.BackendServer, backend_idx: usize, state: *WorkerState) ProxyError!http.Respond {
    const start_instant = std.time.Instant.now() catch null;

    debug_request_count += 1;

    // Log stats every 1000 requests
    if (debug_request_count % 1000 == 0) {
        log.warn("Worker {d}: reqs={d} pool_hits={d} pool_misses={d} stale={d} send_fail={d} read_fail={d}", .{
            state.worker_id,
            debug_request_count,
            debug_pool_hits,
            debug_pool_misses,
            debug_stale_connections,
            debug_send_failures,
            debug_read_failures,
        });
    }

    // Try to get a pooled connection first, or create a fresh one
    var sock: UltraSock = undefined;
    var from_pool = false;

    if (state.connection_pool.getConnection(backend_idx)) |pooled_sock| {
        sock = pooled_sock;
        from_pool = true;
        debug_pool_hits += 1;
    } else {
        debug_pool_misses += 1;
        sock = UltraSock.fromBackendServer(ctx.allocator, backend) catch return ProxyError.ConnectionFailed;
        sock.connect(ctx.io) catch {
            sock.close_blocking();
            return ProxyError.BackendUnavailable;
        };
    }

    // Track whether we should return to pool (will be set to false on errors)
    var can_return_to_pool = true;

    const stream = sock.stream orelse {
        sock.close_blocking();
        return ProxyError.ConnectionFailed;
    };

    // Send request using stack buffer (no heap allocation)
    var write_buf: [2048]u8 = undefined;
    var backend_writer = stream.writer(ctx.io, &write_buf);

    var request_buf: [1024]u8 = undefined;
    const request_data = std.fmt.bufPrint(&request_buf, "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: keep-alive\r\n\r\n", .{
        @tagName(ctx.request.method orelse .GET),
        ctx.request.uri orelse "/",
        backend.getFullHost(),
        backend.port,
    }) catch {
        sock.close_blocking();
        return ProxyError.ConnectionFailed;
    };

    backend_writer.interface.writeAll(request_data) catch {
        debug_send_failures += 1;
        sock.connected = false;
        if (from_pool) debug_stale_connections += 1;
        sock.close_blocking();
        return ProxyError.SendFailed;
    };
    backend_writer.interface.flush() catch {
        debug_send_failures += 1;
        sock.connected = false;
        if (from_pool) debug_stale_connections += 1;
        sock.close_blocking();
        return ProxyError.SendFailed;
    };

    // Create a single reader for all backend reads (smaller buffer)
    var read_buf: [4096]u8 = undefined;
    var backend_reader = stream.reader(ctx.io, &read_buf);

    // Read headers using stack buffer
    var header_buffer: [8192]u8 = undefined;
    var header_len: usize = 0;
    var header_end: usize = 0;

    while (header_end == 0) {
        if (header_len >= header_buffer.len) {
            sock.close_blocking();
            return ProxyError.InvalidResponse;
        }
        var bufs: [1][]u8 = .{header_buffer[header_len..]};
        const n = backend_reader.interface.readVec(&bufs) catch {
            debug_read_failures += 1;
            sock.connected = false;
            if (from_pool) debug_stale_connections += 1;
            sock.close_blocking();
            return ProxyError.ReadFailed;
        };
        if (n == 0) {
            debug_read_failures += 1;
            sock.connected = false;
            if (from_pool) debug_stale_connections += 1;
            sock.close_blocking();
            return ProxyError.EmptyResponse;
        }
        header_len += n;
        if (simd_parse.findHeaderEnd(header_buffer[0..header_len])) |pos| header_end = pos + 4;
    }

    // Parse status
    const headers = header_buffer[0..header_end];
    const line_end = simd_parse.findLineEnd(headers) orelse {
        sock.close_blocking();
        return ProxyError.InvalidResponse;
    };
    const space = std.mem.indexOf(u8, headers[0..line_end], " ") orelse {
        sock.close_blocking();
        return ProxyError.InvalidResponse;
    };
    const status_code = std.fmt.parseInt(u16, headers[space + 1 ..][0..3], 10) catch 200;
    const msg_len = http_utils.determineMessageLength("GET", status_code, headers, false);

    // Create client writer for response
    var client_write_buf: [8192]u8 = undefined;
    var client_writer = ctx.stream.writer(ctx.io, &client_write_buf);

    // Use zzz's response API for proper keep-alive handling
    const status: http.Status = @enumFromInt(status_code);
    var response = ctx.response;
    response.status = status;

    // Forward headers from backend (skip hop-by-hop)
    const skip = std.StaticStringMap(void).initComptime(.{
        .{ "connection", {} },
        .{ "keep-alive", {} },
        .{ "transfer-encoding", {} },
        .{ "server", {} },
        .{ "content-length", {} },
        .{ "content-type", {} }, // We'll set mime instead
    });

    var content_type_value: ?[]const u8 = null;
    var pos: usize = line_end + 2;
    while (pos < header_end - 2) {
        const end = std.mem.indexOfPos(u8, headers, pos, "\r\n") orelse break;
        const line = headers[pos..end];
        if (std.mem.indexOf(u8, line, ":")) |c| {
            var lb: [64]u8 = undefined;
            const name_len = @min(line[0..c].len, 64);
            for (line[0..name_len], 0..) |ch, i| lb[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            if (skip.get(lb[0..name_len]) == null) {
                // Add to response headers
                const name = line[0..c];
                const value = std.mem.trim(u8, line[c + 1 ..], " ");
                response.headers.put(name, value) catch {};
            } else if (std.mem.eql(u8, lb[0..name_len], "content-type")) {
                content_type_value = std.mem.trim(u8, line[c + 1 ..], " ");
            }
        }
        pos = end + 2;
    }

    // Set mime based on content-type from backend
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

    // Write headers using zzz's API with keep-alive enabled
    const content_len: ?usize = if (msg_len.type == .content_length) msg_len.length else null;
    response.headers_into_writer_opts(&client_writer.interface, content_len, true) catch {
        sock.close_blocking();
        return ProxyError.SendFailed;
    };

    // Send any body data already read with headers
    var client_write_error = false;
    if (header_len > header_end) {
        client_writer.interface.writeAll(header_buffer[header_end..header_len]) catch {
            client_write_error = true;
        };
    }
    if (client_write_error) {
        sock.close_blocking();
        return ProxyError.SendFailed;
    }
    client_writer.interface.flush() catch {
        sock.close_blocking();
        return ProxyError.SendFailed;
    };

    var bytes_received = header_len - header_end;
    var body_had_error = false;
    var chunked_complete = false;
    var body_buf: [8192]u8 = undefined;

    // Stream body using the same backend_reader
    var total_body_written: usize = 0;
    if (msg_len.type == .content_length) {
        while (bytes_received < msg_len.length) {
            // CRITICAL: Limit read to exactly the remaining bytes needed
            // This prevents reading extra data from pooled connections
            const remaining = msg_len.length - bytes_received;
            const read_size = @min(remaining, body_buf.len);
            var bufs: [1][]u8 = .{body_buf[0..read_size]};
            const n = backend_reader.interface.readVec(&bufs) catch {
                body_had_error = true;
                sock.connected = false;
                can_return_to_pool = false;
                break;
            };
            if (n == 0) {
                body_had_error = true;
                sock.connected = false;
                can_return_to_pool = false;
                break;
            }
            client_writer.interface.writeAll(body_buf[0..n]) catch {
                client_write_error = true;
                break;
            };
            client_writer.interface.flush() catch {
                client_write_error = true;
                break;
            };
            bytes_received += n;
            total_body_written += n;
        }
    } else if (msg_len.type == .chunked or msg_len.type == .close_delimited) {
        // Chunked and close-delimited responses cannot be pooled reliably
        can_return_to_pool = false;
        while (true) {
            var bufs: [1][]u8 = .{&body_buf};
            const n = backend_reader.interface.readVec(&bufs) catch {
                body_had_error = true;
                sock.connected = false;
                break;
            };
            if (n == 0) {
                body_had_error = true;
                sock.connected = false;
                break;
            }
            client_writer.interface.writeAll(body_buf[0..n]) catch {
                client_write_error = true;
                break;
            };
            client_writer.interface.flush() catch {
                client_write_error = true;
                break;
            };
            bytes_received += n;
            if (msg_len.type == .chunked and simd_parse.findChunkEnd(body_buf[0..n]) != null) {
                chunked_complete = true;
                break;
            }
        }
    }

    // Final flush to ensure all response data is sent to client
    client_writer.interface.flush() catch {
        client_write_error = true;
    };

    // Record metrics using elapsed time from start
    const elapsed_ms: i64 = if (start_instant) |start| blk: {
        const now = std.time.Instant.now() catch break :blk 0;
        break :blk @intCast(now.since(start) / 1_000_000);
    } else 0;
    metrics.global_metrics.recordRequest(elapsed_ms, status_code);

    // Determine if connection can be returned to pool
    // Critical check: ensure buffered reader has no leftover data
    // This prevents protocol misalignment on reused connections
    const buffered_remaining = backend_reader.interface.bufferedLen();
    if (buffered_remaining > 0) {
        can_return_to_pool = false;
    }

    // Additional safety check using connection_reuse module
    if (can_return_to_pool and !body_had_error) {
        const reuse_ok = connection_reuse.shouldReturnToPool(
            headers,
            msg_len.type,
            msg_len.length,
            bytes_received,
            body_had_error,
        );
        if (!reuse_ok) {
            can_return_to_pool = false;
        }
    }

    // Either return connection to pool or close it
    if (can_return_to_pool and !body_had_error and sock.connected) {
        state.connection_pool.returnConnection(backend_idx, sock);
    } else {
        sock.close_blocking();
    }

    // Return .responded for keep-alive if no client errors, .close otherwise
    if (client_write_error or body_had_error) {
        return .close;
    }
    return .responded;
}
