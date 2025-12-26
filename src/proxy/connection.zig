/// Connection Acquisition for Streaming Proxy (TigerStyle)
///
/// Handles HTTP/1.1 connection acquisition from pool or fresh creation.
/// HTTP/2 connections are handled separately via streamingProxyHttp2.
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
const WorkerState = @import("../lb/worker.zig").WorkerState;
const telemetry = @import("../telemetry/mod.zig");

// Re-export ProxyState for convenience
pub const ProxyState = @import("handler.zig").ProxyState;
pub const ProxyError = @import("handler.zig").ProxyError;

const MAX_BACKENDS = config.MAX_BACKENDS;

// ============================================================================
// Generic Connection Acquisition (HTTP/1.1 only)
// ============================================================================

/// Acquire connection for any backend type (BackendServer or SharedBackend).
/// Uses duck typing - backend must have: .getHost(), .port, .isHttps()
/// Note: HTTPS/HTTP2 backends should use streamingProxyHttp2 directly.
pub fn acquireConnection(
    comptime BackendT: type,
    ctx: *const http.Context,
    backend: *const BackendT,
    backend_idx: u32,
    state: *WorkerState,
    req_id: u32,
    trace_span: ?*telemetry.Span,
) ProxyError!ProxyState {
    // Prevent bitmap overflow in circuit breaker health tracking.
    std.debug.assert(backend_idx < MAX_BACKENDS);

    // Try HTTP/1.1 pool first
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
            .is_http2 = pooled_sock.isHttp2(),
            .tls_conn_ptr = null, // Set after copy to avoid dangling pointer.
            .status_code = 0,
            .bytes_from_backend = 0,
            .bytes_to_client = 0,
            .body_had_error = false,
            .client_write_error = false,
            .backend_wants_close = false,
            .trace_span = null, // Set by handler after acquisition.
        };
        proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
        return proxy_state;
    }

    // No pooled connection - create fresh.
    metrics.global_metrics.recordPoolMiss();
    metrics.global_metrics.recordPoolMissForBackend(backend_idx);
    log.debug("[REQ {d}] POOL MISS backend={d}", .{ req_id, backend_idx });

    // Create fresh connection
    var sock = UltraSock.fromBackendServerWithHttp2(backend);
    // Set trace span for detailed connection phase tracing (DNS, TCP, TLS)
    sock.trace_span = trace_span;
    sock.connect(ctx.io) catch {
        sock.close_blocking();
        return ProxyError.BackendUnavailable;
    };

    // Enable TCP keepalive to detect dead connections (replaces SO_RCVTIMEO)
    sock.enableKeepalive() catch {};

    // Log negotiated protocol
    if (sock.isHttp2()) {
        log.debug("[REQ {d}] HTTP/2 negotiated (non-pooled) with backend {d}", .{ req_id, backend_idx });
    }

    // TigerStyle: pair assertion - validate fresh connection.
    if (sock.stream == null) {
        log.err("[REQ {d}] No stream after connection setup!", .{req_id});
        return ProxyError.ConnectionFailed;
    }

    // Build proxy_state for HTTP/1.1 or non-pooled HTTP/2
    const negotiated_http2 = sock.isHttp2();
    var proxy_state = ProxyState{
        .sock = sock,
        .from_pool = false,
        .can_return_to_pool = !negotiated_http2, // HTTP/2 without pool can't go to HTTP/1.1 pool
        .is_tls = sock.isTls(),
        .is_http2 = negotiated_http2,
        .tls_conn_ptr = null, // Set after copy to avoid dangling pointer.
        .status_code = 0,
        .bytes_from_backend = 0,
        .bytes_to_client = 0,
        .body_had_error = false,
        .client_write_error = false,
        .backend_wants_close = false,
        .trace_span = null, // Set by handler after acquisition.
    };
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
    return proxy_state;
}
