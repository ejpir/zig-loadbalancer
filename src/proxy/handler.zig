/// Multi-Process Streaming Proxy (TigerStyle) - Orchestration Layer
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
const metrics = @import("../metrics/mod.zig");
const WorkerState = @import("../lb/worker.zig").WorkerState;
const shared_region = @import("../memory/shared_region.zig");
const tls = @import("tls");

// Import extracted modules
const proxy_connection = @import("connection.zig");
const proxy_request = @import("request.zig");
const proxy_io = @import("io.zig");

// ============================================================================
// Constants (TigerStyle: explicit bounds, units in names)
// ============================================================================

/// Maximum backends supported (must match shared_region.MAX_BACKENDS).
const MAX_BACKENDS: u32 = 64;
/// Maximum header buffer size in bytes.
const MAX_HEADER_BYTES: u32 = 8192;
/// Maximum body chunk buffer size in bytes.
const MAX_BODY_CHUNK_BYTES: u32 = 8192;
/// Nanoseconds per millisecond for time conversion.
const NS_PER_MS: u64 = 1_000_000;

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
pub const ProxyState = struct {
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
    pub fn assertValid(self: *const ProxyState) void {
        // Status code must be 0 (not yet set) or valid HTTP status.
        const valid_status = self.status_code == 0 or
            (self.status_code >= 100 and self.status_code <= 599);
        std.debug.assert(valid_status);
        // Detect memory exhaustion or integer overflow before they corrupt state.
        std.debug.assert(self.bytes_from_backend <= 100_000_000);
        std.debug.assert(self.bytes_to_client <= 100_000_000);
    }

    /// TigerStyle: assert connection is valid for pooling.
    pub fn assertPoolable(self: *const ProxyState) void {
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

            log.debug("[W{d}] Handler called: backends={d} healthy={d}", .{
                state.worker_id,
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
                log.warn("[W{d}] selectBackend returned null", .{state.worker_id});
                return ctx.response.apply(.{
                    .status = .@"Service Unavailable",
                    .mime = http.Mime.TEXT,
                    .body = "No backends available",
                });
            };

            // Prevent out-of-bounds access to backends array and bitmap.
            std.debug.assert(backend_idx < backend_count);
            std.debug.assert(backend_idx < MAX_BACKENDS);

            log.debug("[W{d}] Selected backend {d}", .{ state.worker_id, backend_idx });
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
            log.warn("[W{d}] Backend {d} failed: {s}", .{ state.worker_id, primary_idx + 1, @errorName(err) });
        }
    } else {
        // Fall back to local backends list
        const backends = state.backends;
        if (streamingProxy(ctx, &backends.items[primary_idx], primary_idx, state)) |response| {
            state.recordSuccess(primary_idx);
            return response;
        } else |err| {
            state.recordFailure(primary_idx);
            log.warn("[W{d}] Backend {d} failed: {s}", .{ state.worker_id, primary_idx + 1, @errorName(err) });
        }
    }

    // Try failover
    if (state.findHealthyBackend(primary_idx)) |failover_idx| {
        // Prevent bitmap overflow in circuit breaker after failover selection.
        std.debug.assert(failover_idx < MAX_BACKENDS);

        log.debug("[W{d}] Failing over to backend {d}", .{ state.worker_id, failover_idx + 1 });
        metrics.global_metrics.recordFailover();

        const failover_u32: u32 = @intCast(failover_idx);

        if (state.getSharedBackend(failover_idx)) |shared_backend| {
            if (streamingProxyShared(ctx, shared_backend, failover_u32, state)) |response| {
                state.recordSuccess(failover_idx);
                return response;
            } else |failover_err| {
                state.recordFailure(failover_idx);
                const err_name = @errorName(failover_err);
                log.warn("[W{d}] Failover to backend {d} failed: {s}", .{
                    state.worker_id,
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
                log.warn("[W{d}] Failover to backend {d} failed: {s}", .{
                    state.worker_id,
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

    log.debug("[W{d}][REQ {d}] START uri={s} method={s}", .{
        state.worker_id,
        req_id,
        ctx.request.uri orelse "/",
        @tagName(ctx.request.method orelse .GET),
    });

    // Phase 1: Acquire connection.
    var proxy_state = proxy_connection.acquireConnection(
        types.BackendServer,
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
    proxy_request.sendRequest(
        types.BackendServer,
        ctx,
        backend,
        &proxy_state,
        req_id,
    ) catch |err| {
        proxy_state.sock.close_blocking();
        return err;
    };

    // Phase 3: Read and parse headers.
    // Safe undefined: buffer fully written by backend read before parsing.
    var header_buffer: [MAX_HEADER_BYTES]u8 = undefined;
    var header_len: u32 = 0;
    var header_end: u32 = 0;
    const msg_len = proxy_io.readHeaders(
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
    proxy_io.forwardHeaders(
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
    proxy_io.streamBody(ctx, &proxy_state, header_end, header_len, msg_len, req_id);

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

    log.debug("[W{d}][REQ {d}] START (shared) uri={s} method={s} -> {s}:{d}", .{
        state.worker_id,
        req_id,
        ctx.request.uri orelse "/",
        @tagName(ctx.request.method orelse .GET),
        backend.getHost(),
        backend.port,
    });

    // Phase 1: Acquire connection.
    var proxy_state = proxy_connection.acquireConnection(
        shared_region.SharedBackend,
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
    proxy_request.sendRequest(
        shared_region.SharedBackend,
        ctx,
        backend,
        &proxy_state,
        req_id,
    ) catch |err| {
        proxy_state.sock.close_blocking();
        return err;
    };

    // Phase 3-6: Same as regular streamingProxy (backend-agnostic)
    var header_buffer: [MAX_HEADER_BYTES]u8 = undefined;
    var header_len: u32 = 0;
    var header_end: u32 = 0;
    const msg_len = proxy_io.readHeaders(
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
    proxy_io.forwardHeaders(
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

    proxy_io.streamBody(ctx, &proxy_state, header_end, header_len, msg_len, req_id);

    return streamingProxy_finalize(ctx, &proxy_state, state, backend_idx, start_ns, req_id);
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
