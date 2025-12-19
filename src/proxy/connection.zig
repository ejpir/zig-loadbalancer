/// Connection Acquisition for Streaming Proxy (TigerStyle)
///
/// Handles connection acquisition from pool or fresh creation.
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

const ultra_sock_mod = @import("../http/ultra_sock.zig");
const UltraSock = ultra_sock_mod.UltraSock;
const metrics = @import("../metrics/mod.zig");
const WorkerState = @import("../lb/worker.zig").WorkerState;

// Re-export ProxyState for convenience
pub const ProxyState = @import("handler.zig").ProxyState;
pub const ProxyError = @import("handler.zig").ProxyError;

/// Maximum backends supported (must match shared_region.MAX_BACKENDS).
const MAX_BACKENDS: u32 = 64;

// ============================================================================
// Generic Connection Acquisition
// ============================================================================

/// Acquire connection for any backend type (BackendServer or SharedBackend).
/// Uses duck typing - backend must have: .getHost(), .port, .isHttps()
pub fn acquireConnection(
    comptime BackendT: type,
    ctx: *const http.Context,
    backend: *const BackendT,
    backend_idx: u32,
    state: *WorkerState,
    req_id: u32,
) ProxyError!ProxyState {
    // Prevent bitmap overflow in circuit breaker health tracking.
    std.debug.assert(backend_idx < MAX_BACKENDS);

    // Try pool first
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

    // UltraSock.fromBackendServer uses duck typing (anytype) so any backend type works
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
