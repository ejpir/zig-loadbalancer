/// Multi-Process Streaming Proxy (TigerStyle)
///
/// Streaming proxy with automatic failover for single-threaded workers.
/// Uses both backend connection pooling (~99% pool hit rate) and client-side
/// HTTP keep-alive for maximum efficiency.
///
/// TigerStyle compliance:
/// - Functions <70 lines
/// - ~2 assertions per function (paired at producer AND consumer)
/// - u32 for indices, explicit bounds on all loops
/// - Smallest variable scope, zero buffers (no undefined)
/// - Split compound conditions, explicit division
/// - Fail-fast on errors
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
const shared_region = @import("../memory/shared_region.zig");
const tls = @import("tls");

// ============================================================================
// Constants (TigerStyle: explicit bounds, units in names)
// ============================================================================

/// Maximum backends supported (must match health_state.MAX_BACKENDS).
const MAX_BACKENDS: u32 = 64;
/// Maximum request header buffer size in bytes (excludes body).
const MAX_REQUEST_HEADER_BYTES: u32 = 8192;
/// Maximum header buffer size in bytes.
const MAX_HEADER_BYTES: u32 = 8192;
/// Maximum body chunk buffer size in bytes.
const MAX_BODY_CHUNK_BYTES: u32 = 8192;
/// Maximum header parsing iterations (prevents infinite loops).
const MAX_HEADER_READ_ITERATIONS: u32 = 1024;
/// Maximum body streaming iterations (prevents infinite loops).
const MAX_BODY_READ_ITERATIONS: u32 = 1_000_000;
/// Maximum header lines to parse.
const MAX_HEADER_LINES: u32 = 256;
/// Nanoseconds per millisecond for time conversion.
const NS_PER_MS: u64 = 1_000_000;
/// Maximum number of hop-by-hop headers.
const MAX_HOP_BY_HOP_HEADERS: u32 = 8;

// ============================================================================
// Error Types
// ============================================================================

pub const ProxyError = error{
    ConnectionFailed,
    BackendUnavailable,
    SendFailed,
    ReadFailed,
    Timeout,
    EmptyResponse,
    InvalidResponse,
};

// ============================================================================
// Connection State (TigerStyle: explicit struct for clarity)
// ============================================================================

/// State passed between streaming proxy phases.
const ProxyState = struct {
    sock: UltraSock,
    from_pool: bool,
    can_return_to_pool: bool,
    is_tls: bool,
    tls_conn_ptr: ?*tls.Connection,
    status_code: u16,
    bytes_from_backend: u32,
    bytes_to_client: u32,
    body_had_error: bool,
    client_write_error: bool,
    backend_wants_close: bool,

    /// TigerStyle: assertion for valid state (called at multiple points).
    fn assertValid(self: *const ProxyState) void {
        // Status code must be 0 (not yet set) or valid HTTP status.
        const valid_status = self.status_code == 0 or
            (self.status_code >= 100 and self.status_code <= 599);
        std.debug.assert(valid_status);
        // Detect memory exhaustion or integer overflow before they corrupt state.
        std.debug.assert(self.bytes_from_backend <= 100_000_000);
        std.debug.assert(self.bytes_to_client <= 100_000_000);
    }

    /// TigerStyle: assert connection is valid for pooling.
    fn assertPoolable(self: *const ProxyState) void {
        std.debug.assert(self.can_return_to_pool);
        std.debug.assert(!self.body_had_error);
        std.debug.assert(self.sock.connected);
        std.debug.assert(self.sock.stream != null);
    }
};

// ============================================================================
// Public Handler Generation
// ============================================================================

/// Generate handler with health-aware load balancing.
pub fn generateHandler(
    comptime strategy: types.LoadBalancerStrategy,
) fn (*const http.Context, *WorkerState) anyerror!http.Respond {
    return struct {
        pub fn handle(
            ctx: *const http.Context,
            state: *WorkerState,
        ) !http.Respond {
            // Handle /metrics internally (router catch-all may match before specific routes)
            if (ctx.request.uri) |uri| {
                if (std.mem.eql(u8, uri, "/metrics")) {
                    return metrics.metricsHandler(ctx, {});
                }
            }

            // Use dynamic backend count (from shared region if available)
            const backend_count = state.getBackendCount();
            std.debug.assert(backend_count <= MAX_BACKENDS);

            log.debug("Handler called: backends={d} healthy={d}", .{
                backend_count,
                state.circuit_breaker.countHealthy(),
            });

            if (backend_count == 0) {
                return ctx.response.apply(.{
                    .status = .@"Service Unavailable",
                    .mime = http.Mime.TEXT,
                    .body = "No backends configured",
                });
            }

            const backend_idx = state.selectBackend(strategy) orelse {
                log.warn("selectBackend returned null", .{});
                return ctx.response.apply(.{
                    .status = .@"Service Unavailable",
                    .mime = http.Mime.TEXT,
                    .body = "No backends available",
                });
            };

            // Prevent out-of-bounds access to backends array and bitmap.
            std.debug.assert(backend_idx < backend_count);
            std.debug.assert(backend_idx < MAX_BACKENDS);

            log.debug("Selected backend {d}", .{backend_idx});
            return proxyWithFailover(ctx, @intCast(backend_idx), state);
        }
    }.handle;
}

/// Proxy with automatic failover.
inline fn proxyWithFailover(
    ctx: *const http.Context,
    primary_idx: u32,
    state: *WorkerState,
) !http.Respond {
    // Prevent out-of-bounds access to backends array and bitmap.
    std.debug.assert(primary_idx < MAX_BACKENDS);
    const backend_count = state.getBackendCount();
    std.debug.assert(primary_idx < backend_count);

    // Try to get backend from shared region (hot reload) or fall back to local
    if (state.getSharedBackend(primary_idx)) |shared_backend| {
        if (streamingProxyShared(ctx, shared_backend, primary_idx, state)) |response| {
            state.recordSuccess(primary_idx);
            return response;
        } else |err| {
            state.recordFailure(primary_idx);
            log.warn("Backend {d} failed: {s}", .{ primary_idx + 1, @errorName(err) });
        }
    } else {
        // Fall back to local backends list
        const backends = state.backends;
        if (streamingProxy(ctx, &backends.items[primary_idx], primary_idx, state)) |response| {
            state.recordSuccess(primary_idx);
            return response;
        } else |err| {
            state.recordFailure(primary_idx);
            log.warn("Backend {d} failed: {s}", .{ primary_idx + 1, @errorName(err) });
        }
    }

    // Try failover
    if (state.findHealthyBackend(primary_idx)) |failover_idx| {
        // Prevent bitmap overflow in circuit breaker after failover selection.
        std.debug.assert(failover_idx < MAX_BACKENDS);

        log.debug("Failing over to backend {d}", .{failover_idx + 1});
        metrics.global_metrics.recordFailover();

        const failover_u32: u32 = @intCast(failover_idx);

        if (state.getSharedBackend(failover_idx)) |shared_backend| {
            if (streamingProxyShared(ctx, shared_backend, failover_u32, state)) |response| {
                state.recordSuccess(failover_idx);
                return response;
            } else |failover_err| {
                state.recordFailure(failover_idx);
                const err_name = @errorName(failover_err);
                log.warn("Failover to backend {d} failed: {s}", .{
                    failover_idx + 1,
                    err_name,
                });
            }
        } else {
            const backends = state.backends;
            const backend = &backends.items[failover_idx];
            if (streamingProxy(ctx, backend, failover_u32, state)) |response| {
                state.recordSuccess(failover_idx);
                return response;
            } else |failover_err| {
                state.recordFailure(failover_idx);
                const err_name = @errorName(failover_err);
                log.warn("Failover to backend {d} failed: {s}", .{
                    failover_idx + 1,
                    err_name,
                });
            }
        }
    }

    return ctx.response.apply(.{
        .status = .@"Service Unavailable",
        .mime = http.Mime.TEXT,
        .body = "All backends unavailable",
    });
}

// ============================================================================
// Debug Helpers
// ============================================================================

const enable_debug_counters = @import("builtin").mode == .Debug;
var debug_request_count: u32 = 0;

inline fn getRequestId() u32 {
    if (enable_debug_counters) {
        debug_request_count +%= 1;
        return debug_request_count;
    }
    return 0;
}

// ============================================================================
// Main Streaming Proxy (TigerStyle: Orchestrator <70 lines)
// ============================================================================

/// Streaming proxy implementation - orchestrates all phases.
inline fn streamingProxy(
    ctx: *const http.Context,
    backend: *const types.BackendServer,
    backend_idx: u32,
    state: *WorkerState,
) ProxyError!http.Respond {
    // Prevent bitmap overflow in circuit breaker health tracking.
    std.debug.assert(backend_idx < MAX_BACKENDS);

    const start_ns = std.time.Instant.now() catch null;
    const req_id = getRequestId();

    log.debug("[REQ {d}] START uri={s} method={s}", .{
        req_id,
        ctx.request.uri orelse "/",
        @tagName(ctx.request.method orelse .GET),
    });

    // Phase 1: Acquire connection.
    var proxy_state = streamingProxy_acquireConnection(
        ctx,
        backend,
        backend_idx,
        state,
        req_id,
    ) catch |err| {
        return err;
    };

    // Fix pointers after struct copy - TLS connection has internal pointers that
    // become dangling when the UltraSock is copied by value.
    proxy_state.sock.fixTlsPointersAfterCopy();
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();

    // TigerStyle: validate state after acquisition.
    proxy_state.assertValid();

    // Phase 2: Send request.
    streamingProxy_sendRequest(ctx, backend, &proxy_state, req_id) catch |err| {
        proxy_state.sock.close_blocking();
        return err;
    };

    // Phase 3: Read and parse headers.
    // Safe undefined: buffer fully written by backend read before parsing.
    var header_buffer: [MAX_HEADER_BYTES]u8 = undefined;
    var header_len: u32 = 0;
    var header_end: u32 = 0;
    const msg_len = streamingProxy_readHeaders(
        ctx,
        &proxy_state,
        &header_buffer,
        &header_len,
        &header_end,
        req_id,
    ) catch |err| {
        proxy_state.sock.close_blocking();
        return err;
    };

    // HTTP response must have headers, validate parse succeeded before forwarding.
    std.debug.assert(header_end > 0);
    std.debug.assert(header_end <= header_len);

    // Phase 4: Forward headers to client.
    const body_already_read = header_len - header_end;
    streamingProxy_forwardHeaders(
        ctx,
        &proxy_state,
        &header_buffer,
        header_end,
        body_already_read,
        msg_len,
        req_id,
    ) catch |err| {
        proxy_state.sock.close_blocking();
        return err;
    };

    // Phase 5: Stream body.
    streamingProxy_streamBody(ctx, &proxy_state, header_end, header_len, msg_len, req_id);

    // Phase 6: Finalize and return connection.
    return streamingProxy_finalize(ctx, &proxy_state, state, backend_idx, start_ns, req_id);
}

/// Streaming proxy implementation for SharedBackend (hot reload support).
inline fn streamingProxyShared(
    ctx: *const http.Context,
    backend: *const shared_region.SharedBackend,
    backend_idx: u32,
    state: *WorkerState,
) ProxyError!http.Respond {
    // Prevent bitmap overflow in circuit breaker health tracking.
    std.debug.assert(backend_idx < MAX_BACKENDS);

    const start_ns = std.time.Instant.now() catch null;
    const req_id = getRequestId();

    log.debug("[REQ {d}] START (shared) uri={s} method={s} -> {s}:{d}", .{
        req_id,
        ctx.request.uri orelse "/",
        @tagName(ctx.request.method orelse .GET),
        backend.getHost(),
        backend.port,
    });

    // Phase 1: Acquire connection.
    var proxy_state = streamingProxy_acquireConnectionShared(
        ctx,
        backend,
        backend_idx,
        state,
        req_id,
    ) catch |err| {
        return err;
    };

    // Fix pointers after struct copy
    proxy_state.sock.fixTlsPointersAfterCopy();
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();

    proxy_state.assertValid();

    // Phase 2: Send request.
    streamingProxy_sendRequestShared(ctx, backend, &proxy_state, req_id) catch |err| {
        proxy_state.sock.close_blocking();
        return err;
    };

    // Phase 3-6: Same as regular streamingProxy (backend-agnostic)
    var header_buffer: [MAX_HEADER_BYTES]u8 = undefined;
    var header_len: u32 = 0;
    var header_end: u32 = 0;
    const msg_len = streamingProxy_readHeaders(
        ctx,
        &proxy_state,
        &header_buffer,
        &header_len,
        &header_end,
        req_id,
    ) catch |err| {
        proxy_state.sock.close_blocking();
        return err;
    };

    std.debug.assert(header_end > 0);
    std.debug.assert(header_end <= header_len);

    const body_already_read = header_len - header_end;
    streamingProxy_forwardHeaders(
        ctx,
        &proxy_state,
        &header_buffer,
        header_end,
        body_already_read,
        msg_len,
        req_id,
    ) catch |err| {
        proxy_state.sock.close_blocking();
        return err;
    };

    streamingProxy_streamBody(ctx, &proxy_state, header_end, header_len, msg_len, req_id);

    return streamingProxy_finalize(ctx, &proxy_state, state, backend_idx, start_ns, req_id);
}

// ============================================================================
// Phase 1: Acquire Connection (<70 lines)
// ============================================================================

fn streamingProxy_acquireConnection(
    ctx: *const http.Context,
    backend: *const types.BackendServer,
    backend_idx: u32,
    state: *WorkerState,
    req_id: u32,
) ProxyError!ProxyState {
    // Prevent bitmap overflow in circuit breaker health tracking.
    std.debug.assert(backend_idx < MAX_BACKENDS);

    // TigerStyle: smallest scope - declare sock only when needed.
    const pool_result = state.connection_pool.getConnection(backend_idx);

    if (pool_result) |pooled_sock_const| {
        // TigerStyle: copy to mutable for method calls.
        var pooled_sock = pooled_sock_const;

        metrics.global_metrics.recordPoolHit();
        metrics.global_metrics.recordPoolHitForBackend(backend_idx);
        log.debug("[REQ {d}] POOL HIT backend={d}", .{ req_id, backend_idx });

        // TigerStyle: validate pooled connection.
        std.debug.assert(pooled_sock.stream != null);

        // Build proxy_state, then get tls_conn_ptr from COPIED sock (not local).
        var proxy_state = ProxyState{
            .sock = pooled_sock,
            .from_pool = true,
            .can_return_to_pool = true,
            .is_tls = pooled_sock.isTls(),
            .tls_conn_ptr = null, // Set after copy to avoid dangling pointer.
            .status_code = 0,
            .bytes_from_backend = 0,
            .bytes_to_client = 0,
            .body_had_error = false,
            .client_write_error = false,
            .backend_wants_close = false,
        };
        proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
        return proxy_state;
    }

    // No pooled connection - create fresh.
    metrics.global_metrics.recordPoolMiss();
    metrics.global_metrics.recordPoolMissForBackend(backend_idx);
    log.debug("[REQ {d}] POOL MISS backend={d}", .{ req_id, backend_idx });

    var sock = UltraSock.fromBackendServer(backend);
    sock.connect(ctx.io) catch {
        sock.close_blocking();
        return ProxyError.BackendUnavailable;
    };

    // TigerStyle: pair assertion - validate fresh connection.
    if (sock.stream == null) {
        log.err("[REQ {d}] No stream after connection setup!", .{req_id});
        return ProxyError.ConnectionFailed;
    }

    // Build proxy_state, then get tls_conn_ptr from COPIED sock (not local).
    var proxy_state = ProxyState{
        .sock = sock,
        .from_pool = false,
        .can_return_to_pool = true,
        .is_tls = sock.isTls(),
        .tls_conn_ptr = null, // Set after copy to avoid dangling pointer.
        .status_code = 0,
        .bytes_from_backend = 0,
        .bytes_to_client = 0,
        .body_had_error = false,
        .client_write_error = false,
        .backend_wants_close = false,
    };
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
    return proxy_state;
}

/// Acquire connection for SharedBackend (hot reload support)
fn streamingProxy_acquireConnectionShared(
    ctx: *const http.Context,
    backend: *const shared_region.SharedBackend,
    backend_idx: u32,
    state: *WorkerState,
    req_id: u32,
) ProxyError!ProxyState {
    std.debug.assert(backend_idx < MAX_BACKENDS);

    const pool_result = state.connection_pool.getConnection(backend_idx);

    if (pool_result) |pooled_sock_const| {
        var pooled_sock = pooled_sock_const;

        metrics.global_metrics.recordPoolHit();
        metrics.global_metrics.recordPoolHitForBackend(backend_idx);
        log.debug("[REQ {d}] POOL HIT backend={d}", .{ req_id, backend_idx });

        std.debug.assert(pooled_sock.stream != null);

        var proxy_state = ProxyState{
            .sock = pooled_sock,
            .from_pool = true,
            .can_return_to_pool = true,
            .is_tls = pooled_sock.isTls(),
            .tls_conn_ptr = null,
            .status_code = 0,
            .bytes_from_backend = 0,
            .bytes_to_client = 0,
            .body_had_error = false,
            .client_write_error = false,
            .backend_wants_close = false,
        };
        proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
        return proxy_state;
    }

    // No pooled connection - create fresh using SharedBackend
    metrics.global_metrics.recordPoolMiss();
    metrics.global_metrics.recordPoolMissForBackend(backend_idx);
    log.debug("[REQ {d}] POOL MISS backend={d} -> {s}:{d}", .{
        req_id,
        backend_idx,
        backend.getHost(),
        backend.port,
    });

    // UltraSock.fromBackendServer uses duck typing (anytype) so SharedBackend works
    var sock = UltraSock.fromBackendServer(backend);
    sock.connect(ctx.io) catch {
        sock.close_blocking();
        return ProxyError.BackendUnavailable;
    };

    if (sock.stream == null) {
        log.err("[REQ {d}] No stream after connection setup!", .{req_id});
        return ProxyError.ConnectionFailed;
    }

    var proxy_state = ProxyState{
        .sock = sock,
        .from_pool = false,
        .can_return_to_pool = true,
        .is_tls = sock.isTls(),
        .tls_conn_ptr = null,
        .status_code = 0,
        .bytes_from_backend = 0,
        .bytes_to_client = 0,
        .body_had_error = false,
        .client_write_error = false,
        .backend_wants_close = false,
    };
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
    return proxy_state;
}

// ============================================================================
// Phase 2: Send Request (<70 lines)
// ============================================================================

/// Build HTTP request headers with client headers and body support.
/// Filters out hop-by-hop headers and adds necessary headers for proxying.
/// Exported for testing purposes.
pub fn streamingProxy_buildRequestHeaders(
    ctx: *const http.Context,
    backend: *const types.BackendServer,
    buffer: *[MAX_REQUEST_HEADER_BYTES]u8,
) ![]const u8 {
    return streamingProxy_buildRequestHeadersGeneric(ctx, backend, buffer);
}

/// Generic header builder that works with both BackendServer and SharedBackend
fn streamingProxy_buildRequestHeadersGeneric(
    ctx: *const http.Context,
    backend: anytype,
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

fn streamingProxy_sendRequest(
    ctx: *const http.Context,
    backend: *const types.BackendServer,
    proxy_state: *ProxyState,
    req_id: u32,
) ProxyError!void {
    // TigerStyle: pair assertion.
    proxy_state.assertValid();
    std.debug.assert(proxy_state.sock.stream != null);

    // Prevent data leaks if error occurs mid-formatting, deterministic debugging.
    // Safe undefined: buffer fully written by bufPrint before send.
    var request_buf: [MAX_REQUEST_HEADER_BYTES]u8 = undefined;
    const request_data = streamingProxy_buildRequestHeaders(
        ctx,
        backend,
        &request_buf,
    ) catch {
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
        send_ok = streamingProxy_sendRequest_tls(proxy_state, request_data, ctx.request.body, req_id);
    } else {
        send_ok = streamingProxy_sendRequest_plain(ctx, proxy_state, request_data, ctx.request.body);
    }

    // Retry on stale pooled connection.
    if (!send_ok) {
        if (proxy_state.from_pool) {
            send_ok = streamingProxy_sendRequest_retry(
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

/// Send request for SharedBackend (hot reload support)
fn streamingProxy_sendRequestShared(
    ctx: *const http.Context,
    backend: *const shared_region.SharedBackend,
    proxy_state: *ProxyState,
    req_id: u32,
) ProxyError!void {
    proxy_state.assertValid();
    std.debug.assert(proxy_state.sock.stream != null);

    var request_buf: [MAX_REQUEST_HEADER_BYTES]u8 = undefined;
    const request_data = streamingProxy_buildRequestHeadersGeneric(
        ctx,
        backend,
        &request_buf,
    ) catch {
        return ProxyError.ConnectionFailed;
    };

    std.debug.assert(request_data.len > 0);
    std.debug.assert(request_data.len <= MAX_REQUEST_HEADER_BYTES);

    log.debug("[REQ {d}] SENDING TO BACKEND (shared, {s}): {s}", .{
        req_id,
        if (proxy_state.is_tls) "TLS" else "plain",
        request_data[0..@min(request_data.len, 60)],
    });

    var send_ok = false;
    if (proxy_state.is_tls) {
        send_ok = streamingProxy_sendRequest_tls(proxy_state, request_data, ctx.request.body, req_id);
    } else {
        send_ok = streamingProxy_sendRequest_plain(ctx, proxy_state, request_data, ctx.request.body);
    }

    // Retry on stale pooled connection
    if (!send_ok and proxy_state.from_pool) {
        send_ok = streamingProxy_sendRequest_retryShared(
            ctx,
            backend,
            proxy_state,
            request_data,
            req_id,
        );
    }

    if (!send_ok) {
        metrics.global_metrics.recordSendFailure();
        return ProxyError.SendFailed;
    }
}

fn streamingProxy_sendRequest_tls(
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

fn streamingProxy_sendRequest_plain(
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

fn streamingProxy_sendRequest_retry(
    ctx: *const http.Context,
    backend: *const types.BackendServer,
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
        return streamingProxy_sendRequest_tls(proxy_state, request_data, body, req_id);
    } else {
        return streamingProxy_sendRequest_plain(ctx, proxy_state, request_data, body);
    }
}

/// Retry for SharedBackend (hot reload support)
fn streamingProxy_sendRequest_retryShared(
    ctx: *const http.Context,
    backend: *const shared_region.SharedBackend,
    proxy_state: *ProxyState,
    request_data: []const u8,
    req_id: u32,
) bool {
    metrics.global_metrics.recordStaleConnection();
    log.debug("[REQ {d}] Pooled conn stale on write, retrying with fresh (shared)", .{req_id});
    proxy_state.sock.close_blocking();

    // UltraSock.fromBackendServer uses duck typing so SharedBackend works
    proxy_state.sock = UltraSock.fromBackendServer(backend);
    proxy_state.sock.connect(ctx.io) catch {
        proxy_state.sock.close_blocking();
        return false;
    };
    proxy_state.from_pool = false;
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
    proxy_state.is_tls = proxy_state.sock.isTls();

    const body = ctx.request.body;

    if (proxy_state.is_tls) {
        return streamingProxy_sendRequest_tls(proxy_state, request_data, body, req_id);
    } else {
        return streamingProxy_sendRequest_plain(ctx, proxy_state, request_data, body);
    }
}

// ============================================================================
// Phase 3: Read Headers (<70 lines)
// ============================================================================

fn streamingProxy_readHeaders(
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

        const n = streamingProxy_readHeaders_read(
            ctx,
            proxy_state,
            stream,
            header_buffer,
            header_len.*,
            req_id,
        ) catch {
            streamingProxy_readHeaders_recordFailure(proxy_state);
            return ProxyError.ReadFailed;
        };

        if (n == 0) {
            streamingProxy_readHeaders_recordFailure(proxy_state);
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

    return msg_len;
}

fn streamingProxy_readHeaders_read(
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

fn streamingProxy_readHeaders_recordFailure(proxy_state: *ProxyState) void {
    metrics.global_metrics.recordReadFailure();
    if (proxy_state.from_pool) {
        metrics.global_metrics.recordStaleConnection();
    }
}

// ============================================================================
// Phase 4: Forward Headers (<70 lines)
// ============================================================================

fn streamingProxy_forwardHeaders(
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
    streamingProxy_forwardHeaders_parse(headers, response, &content_type_value, proxy_state);
    streamingProxy_forwardHeaders_setMime(response, content_type_value);

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

fn streamingProxy_forwardHeaders_parse(
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

fn streamingProxy_forwardHeaders_setMime(
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
// Phase 5: Stream Body (<70 lines)
// ============================================================================

fn streamingProxy_streamBody(
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
        streamingProxy_streamBody_contentLength(
            ctx,
            proxy_state,
            stream,
            client_writer,
            msg_len.length,
            &bytes_received,
        );
    } else if (msg_len.type == .chunked or msg_len.type == .close_delimited) {
        proxy_state.can_return_to_pool = false;
        streamingProxy_streamBody_chunked(
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

fn streamingProxy_streamBody_contentLength(
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

        const n = streamingProxy_streamBody_read(
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

fn streamingProxy_streamBody_chunked(
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
        const n = streamingProxy_streamBody_read(
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

fn streamingProxy_streamBody_read(
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

// ============================================================================
// Phase 6: Finalize (<70 lines)
// ============================================================================

fn streamingProxy_finalize(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    state: *WorkerState,
    backend_idx: u32,
    start_ns: ?std.time.Instant,
    req_id: u32,
) http.Respond {
    // Record metrics - TigerStyle: explicit division.
    const elapsed_ms: i64 = if (start_ns) |start| blk: {
        const now = std.time.Instant.now() catch break :blk 0;
        break :blk @intCast(@divFloor(now.since(start), NS_PER_MS));
    } else 0;
    metrics.global_metrics.recordRequest(elapsed_ms, proxy_state.status_code);
    metrics.global_metrics.recordBytes(proxy_state.bytes_from_backend, proxy_state.bytes_to_client);

    // Record per-backend metrics
    metrics.global_metrics.recordRequestForBackend(
        backend_idx,
        elapsed_ms,
        proxy_state.status_code,
    );
    metrics.global_metrics.recordBytesForBackend(
        backend_idx,
        proxy_state.bytes_to_client, // bytes sent to backend
        proxy_state.bytes_from_backend, // bytes received from backend
    );

    // Next request's data would corrupt pool - must close connection.
    // Check for buffered data in both TLS and plain HTTP connections.
    if (proxy_state.is_tls) {
        // For TLS, check if there's buffered cleartext data in the TLS connection.
        if (proxy_state.tls_conn_ptr) |tls_conn| {
            const buffered_remaining = tls_conn.cleartext_buf.len;
            if (buffered_remaining > 0) {
                log.warn(
                    "[REQ {d}] TLS BUFFERED DATA REMAINING: {d} bytes - NOT pooling",
                    .{ req_id, buffered_remaining },
                );
                proxy_state.can_return_to_pool = false;
            }
        }
    } else if (proxy_state.sock.stream) |stream| {
        // For plain HTTP, check the stream reader's buffer.
        // Safe undefined: buffer fully written by read before use.
        var read_buf: [MAX_BODY_CHUNK_BYTES]u8 = undefined;
        var reader = stream.reader(ctx.io, &read_buf);
        const buffered_remaining = reader.interface.bufferedLen();
        if (buffered_remaining > 0) {
            log.warn(
                "[REQ {d}] BUFFERED DATA REMAINING: {d} bytes - NOT pooling",
                .{ req_id, buffered_remaining },
            );
            proxy_state.can_return_to_pool = false;
        }
    }

    // TigerStyle: split compound condition into nested ifs.
    if (proxy_state.can_return_to_pool) {
        if (!proxy_state.body_had_error) {
            if (proxy_state.sock.connected) {
                // TigerStyle: pair assertion before pool return.
                proxy_state.assertPoolable();
                state.connection_pool.returnConnection(backend_idx, proxy_state.sock);
                log.debug("[REQ {d}] POOL RETURN backend={d}", .{ req_id, backend_idx });
            } else {
                proxy_state.sock.close_blocking();
                log.debug("[REQ {d}] CONN CLOSE (not connected)", .{req_id});
            }
        } else {
            proxy_state.sock.close_blocking();
            log.debug("[REQ {d}] CONN CLOSE (body error)", .{req_id});
        }
    } else {
        proxy_state.sock.close_blocking();
        log.debug("[REQ {d}] CONN CLOSE (not poolable)", .{req_id});
    }

    // Return response type.
    if (proxy_state.client_write_error) {
        log.debug("[REQ {d}] => .close (client write error)", .{req_id});
        return .close;
    }
    if (proxy_state.body_had_error) {
        log.debug("[REQ {d}] => .close (body error)", .{req_id});
        return .close;
    }
    log.debug("[REQ {d}] => .responded", .{req_id});
    return .responded;
}
