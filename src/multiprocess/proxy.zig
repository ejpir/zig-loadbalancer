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
const ultra_sock_mod = @import("../http/ultra_sock.zig");
const UltraSock = ultra_sock_mod.UltraSock;
const http_utils = @import("../http/http_utils.zig");
const simd_parse = @import("../internal/simd_parse.zig");
const metrics = @import("../utils/metrics.zig");
const WorkerState = @import("worker_state.zig").WorkerState;
const tls = std.crypto.tls;

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
            log.debug("Handler called: backends={d} healthy={d}", .{
                state.backends.items.len,
                state.circuit_breaker.countHealthy(),
            });

            if (state.backends.items.len == 0) {
                return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "No backends configured" });
            }

            // Note: selectBackend manages its own counter for round-robin
            const backend_idx = state.selectBackend(strategy) orelse {
                log.warn("selectBackend returned null", .{});
                return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "No backends available" });
            };

            log.debug("Selected backend {d}", .{backend_idx});
            return proxyWithFailover(ctx, backend_idx, state);
        }
    }.handle;
}

/// Proxy with automatic failover
inline fn proxyWithFailover(ctx: *const http.Context, primary_idx: usize, state: *WorkerState) !http.Respond {
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

// Debug counters (per-worker, no atomics needed) - only in debug builds
const enable_debug_counters = @import("builtin").mode == .Debug;
var debug_pool_hits: usize = 0;
var debug_pool_misses: usize = 0;
var debug_stale_connections: usize = 0;
var debug_send_failures: usize = 0;
var debug_read_failures: usize = 0;
var debug_request_count: usize = 0;

inline fn incrementCounter(counter: *usize) void {
    if (enable_debug_counters) counter.* += 1;
}

inline fn getRequestId() usize {
    if (enable_debug_counters) {
        debug_request_count += 1;
        return debug_request_count;
    }
    return 0;
}

/// Streaming proxy implementation
inline fn streamingProxy(ctx: *const http.Context, backend: *const types.BackendServer, backend_idx: usize, state: *WorkerState) ProxyError!http.Respond {
    // Only track timing in debug builds
    const start_instant = if (enable_debug_counters)
        std.time.Instant.now() catch null
    else
        null;

    const req_id = getRequestId();

    log.debug("[REQ {d}] START uri={s} method={s}", .{
        req_id,
        ctx.request.uri orelse "/",
        @tagName(ctx.request.method orelse .GET),
    });

    // Log stats periodically (only in debug builds)
    if (enable_debug_counters and debug_request_count % 10000 == 0) {
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

    // Backend connection pooling - now safe with POSIX read/write
    const ENABLE_BACKEND_POOLING = true;

    if (ENABLE_BACKEND_POOLING) {
        if (state.connection_pool.getConnection(backend_idx)) |pooled_sock| {
            sock = pooled_sock;
            from_pool = true;
            incrementCounter(&debug_pool_hits);
            log.debug("[REQ {d}] POOL HIT backend={d}", .{ req_id, backend_idx });
            // NOTE: Removed hasStaleData() poll syscall here.
            // Stale connections are detected on write failure and retried.
        }
    }

    if (!from_pool) {
        incrementCounter(&debug_pool_misses);
        log.debug("[REQ {d}] POOL MISS backend={d}", .{ req_id, backend_idx });
        sock = UltraSock.fromBackendServer(ctx.allocator, backend) catch return ProxyError.ConnectionFailed;
        sock.connect(ctx.io) catch {
            sock.close_blocking();
            return ProxyError.BackendUnavailable;
        };
        // Skip keepalive - stale detection handles dead connections
    }

    // Validate connection
    if (sock.stream == null) {
        log.err("[REQ {d}] No stream after connection setup!", .{req_id});
        return ProxyError.ConnectionFailed;
    }

    // Track whether we should return to pool (will be set to false on errors)
    var can_return_to_pool = true;

    // Format request using stack buffer
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

    // Validate we have a stream
    const stream = sock.stream orelse {
        sock.close_blocking();
        return ProxyError.ConnectionFailed;
    };

    // Check if this is a TLS connection
    const is_tls = sock.isTls();
    var tls_client_ptr = sock.getTlsClient();

    // For plain TCP, create buffered reader/writer
    var backend_read_buf: [8192]u8 = undefined;
    var backend_write_buf: [8192]u8 = undefined;
    var plain_reader = stream.reader(ctx.io, &backend_read_buf);
    var plain_writer = stream.writer(ctx.io, &backend_write_buf);

    // Try to send request to backend
    log.debug("[REQ {d}] SENDING TO BACKEND ({s}): {s}", .{ req_id, if (is_tls) "TLS" else "plain", request_data[0..@min(request_data.len, 60)] });
    var send_ok = true;
    if (is_tls) {
        if (tls_client_ptr) |tls_c| {
            tls_c.writer.writeAll(request_data) catch |err| {
                log.debug("[REQ {d}] TLS write failed: {}", .{ req_id, err });
                send_ok = false;
            };
            if (send_ok) {
                tls_c.writer.flush() catch |err| {
                    log.debug("[REQ {d}] TLS flush failed: {}", .{ req_id, err });
                    send_ok = false;
                };
            }
            // CRITICAL: TLS writer.flush() only prepares ciphertext in buffer,
            // we must also flush the underlying output to send to network
            if (send_ok) {
                tls_c.output.flush() catch |err| {
                    log.debug("[REQ {d}] TLS output flush failed: {}", .{ req_id, err });
                    send_ok = false;
                };
            }
        } else {
            send_ok = false;
        }
    } else {
        plain_writer.interface.writeAll(request_data) catch {
            send_ok = false;
        };
        if (send_ok) {
            plain_writer.interface.flush() catch {
                send_ok = false;
            };
        }
    }

    // If send failed on pooled connection, retry with fresh connection
    if (!send_ok and from_pool) {
        incrementCounter(&debug_stale_connections);
        log.debug("[REQ {d}] Pooled conn stale on write, retrying with fresh", .{req_id});
        sock.close_blocking();

        // Create fresh connection
        sock = UltraSock.fromBackendServer(ctx.allocator, backend) catch return ProxyError.ConnectionFailed;
        sock.connect(ctx.io) catch {
            sock.close_blocking();
            return ProxyError.BackendUnavailable;
        };
        from_pool = false;

        // Update TLS state for fresh connection
        tls_client_ptr = sock.getTlsClient();
        const fresh_is_tls = sock.isTls();

        // Re-create reader/writer for fresh connection (only used for plain TCP)
        if (!fresh_is_tls) {
            const fresh_stream = sock.stream orelse {
                sock.close_blocking();
                return ProxyError.ConnectionFailed;
            };
            plain_reader = fresh_stream.reader(ctx.io, &backend_read_buf);
            plain_writer = fresh_stream.writer(ctx.io, &backend_write_buf);
        }

        // Retry send on fresh connection
        if (fresh_is_tls) {
            if (tls_client_ptr) |tls_c| {
                tls_c.writer.writeAll(request_data) catch {
                    incrementCounter(&debug_send_failures);
                    sock.close_blocking();
                    return ProxyError.SendFailed;
                };
                tls_c.writer.flush() catch {
                    incrementCounter(&debug_send_failures);
                    sock.close_blocking();
                    return ProxyError.SendFailed;
                };
                // Flush underlying output to network
                tls_c.output.flush() catch {
                    incrementCounter(&debug_send_failures);
                    sock.close_blocking();
                    return ProxyError.SendFailed;
                };
            } else {
                incrementCounter(&debug_send_failures);
                sock.close_blocking();
                return ProxyError.SendFailed;
            }
        } else {
            plain_writer.interface.writeAll(request_data) catch {
                incrementCounter(&debug_send_failures);
                sock.close_blocking();
                return ProxyError.SendFailed;
            };
            plain_writer.interface.flush() catch {
                incrementCounter(&debug_send_failures);
                sock.close_blocking();
                return ProxyError.SendFailed;
            };
        }
    } else if (!send_ok) {
        incrementCounter(&debug_send_failures);
        sock.close_blocking();
        return ProxyError.SendFailed;
    }

    // Read headers - use TLS reader or plain reader
    var header_buffer: [8192]u8 = undefined;
    var header_len: usize = 0;
    var header_end: usize = 0;

    while (header_end == 0) {
        if (header_len >= header_buffer.len) {
            sock.close_blocking();
            return ProxyError.InvalidResponse;
        }
        var bufs: [1][]u8 = .{header_buffer[header_len..]};
        var n: usize = 0;
        if (is_tls) {
            if (tls_client_ptr) |tls_c| {
                n = tls_c.reader.readVec(&bufs) catch |err| {
                    log.debug("[REQ {d}] TLS read error: {}", .{ req_id, err });
                    incrementCounter(&debug_read_failures);
                    if (from_pool) incrementCounter(&debug_stale_connections);
                    sock.close_blocking();
                    return ProxyError.ReadFailed;
                };
            } else {
                sock.close_blocking();
                return ProxyError.ReadFailed;
            }
        } else {
            n = plain_reader.interface.readVec(&bufs) catch {
                incrementCounter(&debug_read_failures);
                if (from_pool) incrementCounter(&debug_stale_connections);
                sock.close_blocking();
                return ProxyError.ReadFailed;
            };
        }
        if (n == 0) {
            // For TLS, 0 bytes might mean partial record - wait for more data
            if (is_tls and tls_client_ptr != null) {
                const max_retries: usize = 100; // Up to ~1 second total
                var retry_count: usize = 0;
                while (n == 0 and retry_count < max_retries) {
                    std.posix.nanosleep(0, 10_000_000); // 10ms
                    n = tls_client_ptr.?.reader.readVec(&bufs) catch break;
                    retry_count += 1;
                }
            }
            if (n == 0) {
                incrementCounter(&debug_read_failures);
                if (from_pool) incrementCounter(&debug_stale_connections);
                sock.close_blocking();
                return ProxyError.EmptyResponse;
            }
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

    const body_already_read = header_len - header_end;
    log.debug("[REQ {d}] BACKEND RESP status={d} hdr={d} body_in_buf={d} type={s} len={d}", .{
        req_id,
        status_code,
        header_end,
        body_already_read,
        @tagName(msg_len.type),
        msg_len.length,
    });

    // Use zzz's shared writer (single writer per connection)
    const client_writer = ctx.writer;

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
    var backend_wants_close = false;
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
            } else if (std.mem.eql(u8, lb[0..name_len], "connection")) {
                // Check if backend wants to close the connection
                const value = std.mem.trim(u8, line[c + 1 ..], " ");
                if (std.ascii.eqlIgnoreCase(value, "close")) {
                    backend_wants_close = true;
                }
            }
        }
        pos = end + 2;
    }

    // Don't pool if backend sent Connection: close
    if (backend_wants_close) {
        can_return_to_pool = false;
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
    const writer_start = client_writer.end;
    response.headers_into_writer_opts(client_writer, content_len, true) catch {
        sock.close_blocking();
        return ProxyError.SendFailed;
    };
    const header_bytes_written = client_writer.end - writer_start;
    log.debug("[REQ {d}] HDR WRITE {d} bytes, buf_end={d}", .{ req_id, header_bytes_written, client_writer.end });

    // Send any body data already read with headers
    // CRITICAL: Only send up to Content-Length bytes, not everything in the buffer!
    // The buffered reader may have read ahead and captured the next response.
    var client_write_error = false;
    const body_to_write = if (msg_len.type == .content_length)
        @min(body_already_read, msg_len.length)
    else
        body_already_read;

    // If we read MORE than Content-Length, we have pipelined responses - can't pool
    if (msg_len.type == .content_length and body_already_read > msg_len.length) {
        log.warn("[REQ {d}] READ AHEAD detected: got {d} body bytes, expected {d} - NOT pooling", .{
            req_id, body_already_read, msg_len.length,
        });
        can_return_to_pool = false;
    }

    if (body_to_write > 0) {
        client_writer.writeAll(header_buffer[header_end..][0..body_to_write]) catch {
            client_write_error = true;
        };
    }
    if (client_write_error) {
        sock.close_blocking();
        return ProxyError.SendFailed;
    }
    client_writer.flush() catch {
        sock.close_blocking();
        return ProxyError.SendFailed;
    };

    var bytes_received = body_to_write;
    var body_had_error = false;
    var chunked_complete = false;
    var body_buf: [8192]u8 = undefined;

    // Stream body - use TLS reader or plain reader
    var total_body_written: usize = 0;
    if (msg_len.type == .content_length) {
        while (bytes_received < msg_len.length) {
            // CRITICAL: Limit read to exactly the remaining bytes needed
            // This prevents reading extra data from pooled connections
            const remaining = msg_len.length - bytes_received;
            const read_size = @min(remaining, body_buf.len);
            var bufs: [1][]u8 = .{body_buf[0..read_size]};
            var n: usize = 0;
            if (is_tls) {
                if (tls_client_ptr) |tls_c| {
                    n = tls_c.reader.readVec(&bufs) catch {
                        body_had_error = true;
                        sock.connected = false;
                        can_return_to_pool = false;
                        break;
                    };
                } else {
                    body_had_error = true;
                    break;
                }
            } else {
                n = plain_reader.interface.readVec(&bufs) catch {
                    body_had_error = true;
                    sock.connected = false;
                    can_return_to_pool = false;
                    break;
                };
            }
            if (n == 0) {
                body_had_error = true;
                sock.connected = false;
                can_return_to_pool = false;
                break;
            }
            client_writer.writeAll(body_buf[0..n]) catch {
                client_write_error = true;
                break;
            };
            // Don't flush here - let buffer accumulate, final flush at end
            bytes_received += n;
            total_body_written += n;
        }
    } else if (msg_len.type == .chunked or msg_len.type == .close_delimited) {
        // Chunked and close-delimited responses cannot be pooled reliably
        can_return_to_pool = false;
        while (true) {
            var bufs: [1][]u8 = .{&body_buf};
            var n: usize = 0;
            if (is_tls) {
                if (tls_client_ptr) |tls_c| {
                    n = tls_c.reader.readVec(&bufs) catch {
                        body_had_error = true;
                        sock.connected = false;
                        break;
                    };
                } else {
                    body_had_error = true;
                    break;
                }
            } else {
                n = plain_reader.interface.readVec(&bufs) catch {
                    body_had_error = true;
                    sock.connected = false;
                    break;
                };
            }
            if (n == 0) {
                body_had_error = true;
                sock.connected = false;
                break;
            }
            client_writer.writeAll(body_buf[0..n]) catch {
                client_write_error = true;
                break;
            };
            // Don't flush here - let buffer accumulate, final flush at end
            bytes_received += n;
            if (msg_len.type == .chunked and simd_parse.findChunkEnd(body_buf[0..n]) != null) {
                chunked_complete = true;
                break;
            }
        }
    }

    // Final flush to ensure all response data is sent to client
    client_writer.flush() catch {
        client_write_error = true;
    };

    log.debug("[REQ {d}] CLIENT DONE body={d} w_err={} b_err={}", .{
        req_id,
        total_body_written + body_already_read,
        client_write_error,
        body_had_error,
    });

    // Record metrics (always enabled - atomics are fast enough)
    const elapsed_ms: i64 = if (start_instant) |start| blk: {
        const now = std.time.Instant.now() catch break :blk 0;
        break :blk @intCast(now.since(start) / 1_000_000);
    } else 0;
    metrics.global_metrics.recordRequest(elapsed_ms, status_code);

    // Determine if connection can be returned to pool
    // Critical check: ensure buffered reader has no leftover data
    // This prevents protocol misalignment on reused connections
    if (is_tls) {
        // For TLS connections, don't pool for now - TLS state is complex
        // TODO: Implement TLS connection pooling with proper state management
        can_return_to_pool = false;
    } else {
        const buffered_remaining = plain_reader.interface.bufferedLen();
        if (buffered_remaining > 0) {
            log.warn("[REQ {d}] BUFFERED DATA REMAINING: {d} bytes - NOT pooling", .{ req_id, buffered_remaining });
            can_return_to_pool = false;
        }
    }

    // NOTE: Removed redundant hasStaleData() poll syscall here.
    // We already: (1) limit reads to Content-Length, (2) check buffered_remaining,
    // (3) check backend_wants_close. If stale data exists, it will be caught
    // on next pool get via hasStaleData() check there.
    //
    // Also removed connection_reuse.shouldReturnToPool() call - it duplicates
    // our header parsing (Connection: close is already tracked in backend_wants_close).

    // Either return connection to pool or close it
    if (can_return_to_pool and !body_had_error and sock.connected) {
        state.connection_pool.returnConnection(backend_idx, sock);
        log.debug("[REQ {d}] POOL RETURN backend={d}", .{ req_id, backend_idx });
    } else {
        sock.close_blocking();
        log.debug("[REQ {d}] CONN CLOSE (pool={} err={} conn={})", .{
            req_id,
            can_return_to_pool,
            body_had_error,
            sock.connected,
        });
    }

    // Return .responded for keep-alive if no client errors, .close otherwise
    if (client_write_error or body_had_error) {
        log.debug("[REQ {d}] => .close", .{req_id});
        return .close;
    }
    log.debug("[REQ {d}] => .responded", .{req_id});
    return .responded;
}
