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

const telemetry = @import("../telemetry/mod.zig");
const main = @import("../../main.zig");
const waf = @import("../waf/mod.zig");

const config = @import("../core/config.zig");
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
const BackendConnection = @import("../http/backend_conn.zig").BackendConnection;

// Simplified H2 pool (TigerBeetle style)
const H2Connection = @import("../http/http2/connection.zig").H2Connection;
const H2ConnectionPool = @import("../http/http2/pool.zig").H2ConnectionPool;

const MAX_BACKENDS = config.MAX_BACKENDS;
const MAX_HEADER_BYTES = config.MAX_HEADER_BYTES;
const MAX_BODY_CHUNK_BYTES = config.MAX_BODY_CHUNK_BYTES;
const NS_PER_MS = config.NS_PER_MS;

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
    PoolExhausted, // Local resource issue, not a backend failure
    InvalidResponse,
    /// HTTP/2 GOAWAY exhausted retries - NOT a backend health failure
    /// Server gracefully closed connection, just need fresh connection
    GoawayRetriesExhausted,
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
    is_http2: bool,
    tls_conn_ptr: ?*tls.Connection,
    status_code: u16,
    bytes_from_backend: u32,
    bytes_to_client: u32,
    body_had_error: bool,
    client_write_error: bool,
    backend_wants_close: bool,
    /// Parent span for tracing (optional, for creating child spans)
    trace_span: ?*telemetry.Span,

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

            // Start a trace span for this request (before WAF so blocked requests are traced)
            const method = ctx.request.method orelse .GET;
            const uri = ctx.request.uri orelse "/";
            var span = telemetry.startServerSpan("proxy_request");
            defer span.end();
            span.setStringAttribute("http.method", @tagName(method));
            span.setStringAttribute("http.url", uri);

            // WAF check - before any backend processing
            if (main.getWafEngine()) |engine_val| {
                // Make a mutable copy since check() requires *WafEngine
                var engine = engine_val;

                // Extract source IP from connection (use 0 if not available)
                // In production, you'd extract this from the socket address
                const source_ip: u32 = 0; // TODO: Extract from ctx.connection when available

                // Build WAF request with body size for content-length validation
                const waf_method = convertHttpMethod(ctx.request.method orelse .GET);
                const body_len: ?usize = if (ctx.request.body) |b| b.len else null;
                const waf_request = if (body_len) |len|
                    waf.Request.withContentLength(
                        waf_method,
                        ctx.request.uri orelse "/",
                        source_ip,
                        len,
                    )
                else
                    waf.Request.init(
                        waf_method,
                        ctx.request.uri orelse "/",
                        source_ip,
                    );

                // Check WAF rules
                const waf_result = engine.check(&waf_request);

                // Add WAF attributes to span
                span.setStringAttribute("waf.decision", if (waf_result.isBlocked()) "block" else if (waf_result.shouldLog()) "log_only" else "allow");
                if (waf_result.reason != .none) {
                    span.setStringAttribute("waf.reason", waf_result.reason.description());
                }
                if (waf_result.rule_name) |rule| {
                    span.setStringAttribute("waf.rule", rule);
                }

                if (waf_result.isBlocked()) {
                    // Request blocked by WAF
                    log.warn("[W{d}] WAF blocked request: reason={s}, rule={s}", .{
                        state.worker_id,
                        waf_result.reason.description(),
                        waf_result.rule_name orelse "N/A",
                    });

                    // Return appropriate status based on block reason
                    const status: http.Status = switch (waf_result.reason) {
                        .rate_limit => .@"Too Many Requests",
                        .body_too_large => .@"Content Too Large",
                        else => .Forbidden,
                    };

                    span.setIntAttribute("http.status_code", @intFromEnum(status));
                    span.setError("WAF blocked");

                    return ctx.response.apply(.{
                        .status = status,
                        .mime = http.Mime.JSON,
                        .body = "{\"error\":\"blocked by WAF\"}",
                    });
                }

                // Log if shadow mode decision was made
                if (waf_result.shouldLog()) {
                    log.info("[W{d}] WAF shadow: reason={s}, rule={s}", .{
                        state.worker_id,
                        waf_result.reason.description(),
                        waf_result.rule_name orelse "N/A",
                    });
                    span.addEvent("waf_shadow_block");
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
                span.setError("No backends configured");
                span.setIntAttribute("http.status_code", 503);
                return ctx.response.apply(.{
                    .status = .@"Service Unavailable",
                    .mime = http.Mime.TEXT,
                    .body = "No backends configured",
                });
            }

            // Backend selection with tracing
            var selection_span = telemetry.startChildSpan(&span, "backend_selection", .Internal);
            selection_span.setIntAttribute("lb.backend_count", @intCast(backend_count));
            selection_span.setIntAttribute("lb.healthy_count", @intCast(state.circuit_breaker.countHealthy()));
            selection_span.setStringAttribute("lb.strategy", @tagName(strategy));

            const backend_idx = state.selectBackend(strategy) orelse {
                selection_span.setError("No healthy backends");
                selection_span.end();
                span.setError("No backends available");
                span.setIntAttribute("http.status_code", 503);
                log.warn("[W{d}] selectBackend returned null", .{state.worker_id});
                return ctx.response.apply(.{
                    .status = .@"Service Unavailable",
                    .mime = http.Mime.TEXT,
                    .body = "No backends available",
                });
            };

            selection_span.setIntAttribute("lb.selected_backend", @intCast(backend_idx));
            selection_span.setOk();
            selection_span.end();

            // Prevent out-of-bounds access to backends array and bitmap.
            std.debug.assert(backend_idx < backend_count);
            std.debug.assert(backend_idx < MAX_BACKENDS);

            log.debug("[W{d}] Selected backend {d}", .{ state.worker_id, backend_idx });
            const result = proxyWithFailover(ctx, @intCast(backend_idx), state, &span);

            // Update parent span with final status
            if (result) |response| {
                span.setOk();
                return response;
            } else |err| {
                span.setError(@errorName(err));
                span.setIntAttribute("http.status_code", 503);
                return err;
            }
        }
    }.handle;
}

/// Proxy with automatic failover.
inline fn proxyWithFailover(
    ctx: *const http.Context,
    primary_idx: u32,
    state: *WorkerState,
    trace_span: *telemetry.Span,
) !http.Respond {
    // Prevent out-of-bounds access to backends array and bitmap.
    std.debug.assert(primary_idx < MAX_BACKENDS);
    const backend_count = state.getBackendCount();
    std.debug.assert(primary_idx < backend_count);

    // Try to get backend from shared region (hot reload) or fall back to local
    if (state.getSharedBackend(primary_idx)) |shared_backend| {
        if (streamingProxyShared(ctx, shared_backend, primary_idx, state, trace_span)) |response| {
            state.recordSuccess(primary_idx);
            trace_span.setIntAttribute("http.status_code", 200);
            return response;
        } else |err| {
            // GOAWAY/PoolExhausted are NOT backend failures - just connection-level issues
            if (err != ProxyError.GoawayRetriesExhausted and err != ProxyError.PoolExhausted) {
                state.recordFailure(primary_idx);
            }
            trace_span.addEvent("primary_backend_failed");
            log.warn("[W{d}] Backend {d} failed: {s}", .{ state.worker_id, primary_idx + 1, @errorName(err) });
        }
    } else {
        // Fall back to local backends list
        const backends = state.backends;
        if (streamingProxy(ctx, &backends.items[primary_idx], primary_idx, state, trace_span)) |response| {
            state.recordSuccess(primary_idx);
            trace_span.setIntAttribute("http.status_code", 200);
            return response;
        } else |err| {
            // GOAWAY/PoolExhausted are NOT backend failures - just connection-level issues
            if (err != ProxyError.GoawayRetriesExhausted and err != ProxyError.PoolExhausted) {
                state.recordFailure(primary_idx);
            }
            trace_span.addEvent("primary_backend_failed");
            log.warn("[W{d}] Backend {d} failed: {s}", .{ state.worker_id, primary_idx + 1, @errorName(err) });
        }
    }

    // Try failover
    if (state.findHealthyBackend(primary_idx)) |failover_idx| {
        // Prevent bitmap overflow in circuit breaker after failover selection.
        std.debug.assert(failover_idx < MAX_BACKENDS);

        log.debug("[W{d}] Failing over to backend {d}", .{ state.worker_id, failover_idx + 1 });
        metrics.global_metrics.recordFailover();
        trace_span.addEvent("failover_started");
        trace_span.setIntAttribute("lb.failover_backend", @intCast(failover_idx));

        const failover_u32: u32 = @intCast(failover_idx);

        if (state.getSharedBackend(failover_idx)) |shared_backend| {
            if (streamingProxyShared(ctx, shared_backend, failover_u32, state, trace_span)) |response| {
                state.recordSuccess(failover_idx);
                trace_span.setIntAttribute("http.status_code", 200);
                return response;
            } else |failover_err| {
                // GOAWAY/PoolExhausted are NOT backend failures
                if (failover_err != ProxyError.GoawayRetriesExhausted and failover_err != ProxyError.PoolExhausted) {
                    state.recordFailure(failover_idx);
                }
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
            if (streamingProxy(ctx, backend, failover_u32, state, trace_span)) |response| {
                state.recordSuccess(failover_idx);
                trace_span.setIntAttribute("http.status_code", 200);
                return response;
            } else |failover_err| {
                // GOAWAY/PoolExhausted are NOT backend failures
                if (failover_err != ProxyError.GoawayRetriesExhausted and failover_err != ProxyError.PoolExhausted) {
                    state.recordFailure(failover_idx);
                }
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
    trace_span: *telemetry.Span,
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

    // For HTTPS backends with new H2 pool, skip acquireConnection entirely
    // This avoids creating connections in BOTH old and new pools
    if (backend.isHttps() and state.h2_pool != null) {
        var proxy_state = ProxyState{
            .sock = undefined,
            .from_pool = false,
            .can_return_to_pool = false,
            .is_tls = true,
            .is_http2 = true,
            .tls_conn_ptr = null,
            .status_code = 0,
            .bytes_from_backend = 0,
            .bytes_to_client = 0,
            .body_had_error = false,
            .client_write_error = false,
            .backend_wants_close = false,
            .trace_span = trace_span,
        };
        return streamingProxyHttp2(ctx, backend, &proxy_state, state, backend_idx, start_ns, req_id);
    }

    // Phase 1: Acquire connection (HTTP/1.1 path only now) with tracing.
    var conn_span = telemetry.startChildSpan(trace_span, "backend_connection", .Client);
    conn_span.setStringAttribute("backend.host", backend.getHost());
    conn_span.setIntAttribute("backend.port", @intCast(backend.port));
    conn_span.setBoolAttribute("backend.tls", backend.isHttps());

    var proxy_state = proxy_connection.acquireConnection(
        types.BackendServer,
        ctx,
        backend,
        backend_idx,
        state,
        req_id,
        &conn_span,
    ) catch |err| {
        conn_span.setError(@errorName(err));
        conn_span.end();
        return err;
    };

    conn_span.setBoolAttribute("connection.from_pool", proxy_state.from_pool);
    conn_span.setOk();
    conn_span.end();

    // Fix pointers after struct copy - TLS connection and stream reader/writer
    // have internal pointers that become dangling when UltraSock is copied by value.
    proxy_state.sock.fixAllPointersAfterCopy(ctx.io);
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
    proxy_state.trace_span = trace_span;

    // TigerStyle: validate state after acquisition.
    proxy_state.assertValid();

    // Route to HTTP/2 handler if ALPN negotiated h2 (fallback for non-HTTPS H2)
    if (proxy_state.is_http2) {
        return streamingProxyHttp2(ctx, backend, &proxy_state, state, backend_idx, start_ns, req_id);
    }

    // Phase 2-5: Backend request/response with tracing
    var request_span = telemetry.startChildSpan(trace_span, "backend_request", .Client);
    request_span.setStringAttribute("http.method", @tagName(ctx.request.method orelse .GET));
    request_span.setStringAttribute("http.url", ctx.request.uri orelse "/");

    // Phase 2: Send request (HTTP/1.1 path).
    proxy_request.sendRequest(
        types.BackendServer,
        ctx,
        backend,
        &proxy_state,
        req_id,
    ) catch |err| {
        request_span.setError(@errorName(err));
        request_span.end();
        proxy_state.sock.close_blocking();
        return err;
    };

    request_span.addEvent("request_sent");

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
        request_span.setError(@errorName(err));
        request_span.end();
        proxy_state.sock.close_blocking();
        return err;
    };

    request_span.addEvent("headers_received");
    request_span.setIntAttribute("http.status_code", @intCast(proxy_state.status_code));

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
        request_span.setError(@errorName(err));
        request_span.end();
        proxy_state.sock.close_blocking();
        return err;
    };

    // Phase 5: Stream body with tracing.
    var body_span = telemetry.startChildSpan(&request_span, "response_streaming", .Internal);
    body_span.setStringAttribute("http.body.type", @tagName(msg_len.type));
    if (msg_len.type == .content_length) {
        body_span.setIntAttribute("http.body.expected_length", @intCast(msg_len.length));
    }

    proxy_io.streamBody(ctx, &proxy_state, header_end, header_len, msg_len, req_id);

    body_span.setIntAttribute("http.body.bytes_transferred", @intCast(proxy_state.bytes_from_backend));
    body_span.setBoolAttribute("http.body.had_error", proxy_state.body_had_error);
    if (proxy_state.body_had_error) {
        body_span.setError("body_transfer_error");
    } else {
        body_span.setOk();
    }
    body_span.end();

    request_span.setIntAttribute("http.response_content_length", @intCast(proxy_state.bytes_from_backend));
    request_span.setOk();
    request_span.end();

    // Phase 6: Finalize and return connection.
    return streamingProxy_finalize(ctx, &proxy_state, state, backend_idx, start_ns, req_id);
}

/// Streaming proxy implementation for SharedBackend (hot reload support).
inline fn streamingProxyShared(
    ctx: *const http.Context,
    backend: *const shared_region.SharedBackend,
    backend_idx: u32,
    state: *WorkerState,
    trace_span: *telemetry.Span,
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

    // For HTTPS backends with new H2 pool, skip acquireConnection entirely
    // This avoids creating connections in BOTH old and new pools
    if (backend.isHttps() and state.h2_pool != null) {
        var proxy_state = ProxyState{
            .sock = undefined,
            .from_pool = false,
            .can_return_to_pool = false,
            .is_tls = true,
            .is_http2 = true,
            .tls_conn_ptr = null,
            .status_code = 0,
            .bytes_from_backend = 0,
            .bytes_to_client = 0,
            .body_had_error = false,
            .client_write_error = false,
            .backend_wants_close = false,
            .trace_span = trace_span,
        };
        return streamingProxyHttp2(ctx, backend, &proxy_state, state, backend_idx, start_ns, req_id);
    }

    // Phase 1: Acquire connection (HTTP/1.1 path only now) with tracing.
    var conn_span = telemetry.startChildSpan(trace_span, "backend_connection", .Client);
    conn_span.setStringAttribute("backend.host", backend.getHost());
    conn_span.setIntAttribute("backend.port", @intCast(backend.port));
    conn_span.setBoolAttribute("backend.tls", backend.isHttps());

    var proxy_state = proxy_connection.acquireConnection(
        shared_region.SharedBackend,
        ctx,
        backend,
        backend_idx,
        state,
        req_id,
        &conn_span,
    ) catch |err| {
        conn_span.setError(@errorName(err));
        conn_span.end();
        return err;
    };

    conn_span.setBoolAttribute("connection.from_pool", proxy_state.from_pool);
    conn_span.setOk();
    conn_span.end();

    // Fix pointers after struct copy - TLS connection and stream reader/writer
    // have internal pointers that become dangling when UltraSock is copied by value.
    proxy_state.sock.fixAllPointersAfterCopy(ctx.io);
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
    proxy_state.trace_span = trace_span;

    proxy_state.assertValid();

    // Route to HTTP/2 handler if ALPN negotiated h2 (fallback for non-HTTPS H2)
    if (proxy_state.is_http2) {
        return streamingProxyHttp2(ctx, backend, &proxy_state, state, backend_idx, start_ns, req_id);
    }

    // Phase 2-5: Backend request/response with tracing
    var request_span = telemetry.startChildSpan(trace_span, "backend_request", .Client);
    request_span.setStringAttribute("http.method", @tagName(ctx.request.method orelse .GET));
    request_span.setStringAttribute("http.url", ctx.request.uri orelse "/");

    // Phase 2: Send request (HTTP/1.1 path).
    proxy_request.sendRequest(
        shared_region.SharedBackend,
        ctx,
        backend,
        &proxy_state,
        req_id,
    ) catch |err| {
        request_span.setError(@errorName(err));
        request_span.end();
        proxy_state.sock.close_blocking();
        return err;
    };

    request_span.addEvent("request_sent");

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
        request_span.setError(@errorName(err));
        request_span.end();
        proxy_state.sock.close_blocking();
        return err;
    };

    request_span.addEvent("headers_received");
    request_span.setIntAttribute("http.status_code", @intCast(proxy_state.status_code));

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
        request_span.setError(@errorName(err));
        request_span.end();
        proxy_state.sock.close_blocking();
        return err;
    };

    // Stream body with tracing
    var body_span = telemetry.startChildSpan(&request_span, "response_streaming", .Internal);
    body_span.setStringAttribute("http.body.type", @tagName(msg_len.type));
    if (msg_len.type == .content_length) {
        body_span.setIntAttribute("http.body.expected_length", @intCast(msg_len.length));
    }

    proxy_io.streamBody(ctx, &proxy_state, header_end, header_len, msg_len, req_id);

    body_span.setIntAttribute("http.body.bytes_transferred", @intCast(proxy_state.bytes_from_backend));
    body_span.setBoolAttribute("http.body.had_error", proxy_state.body_had_error);
    if (proxy_state.body_had_error) {
        body_span.setError("body_transfer_error");
    } else {
        body_span.setOk();
    }
    body_span.end();

    request_span.setIntAttribute("http.response_content_length", @intCast(proxy_state.bytes_from_backend));
    request_span.setOk();
    request_span.end();

    return streamingProxy_finalize(ctx, &proxy_state, state, backend_idx, start_ns, req_id);
}

// ============================================================================
// HTTP/2 Streaming Proxy (uses BackendConnection wrapper)
// ============================================================================

const h2_client_mod = @import("../http/http2/client.zig");
const Http2Client = h2_client_mod.Http2Client;
const H2Response = h2_client_mod.Response;

/// Forward HTTP/2 response to client - shared by pooled and fresh connections
fn forwardH2Response(
    ctx: *const http.Context,
    proxy_state: *ProxyState,
    response: *H2Response,
    backend_idx: u32,
    start_ns: ?std.time.Instant,
    req_id: u32,
    parent_span: *telemetry.Span,
) ProxyError!http.Respond {
    const body = response.getBody();

    // Create response streaming span
    var body_span = telemetry.startChildSpan(parent_span, "response_streaming", .Internal);
    defer body_span.end();
    body_span.setStringAttribute("http.body.type", "h2_buffered");
    body_span.setIntAttribute("http.body.length", @intCast(body.len));

    // Update proxy state with response info
    proxy_state.status_code = response.status;
    proxy_state.bytes_from_backend = @intCast(body.len);

    // Handle invalid/missing status code
    if (response.status == 0) {
        log.err("[REQ {d}] HTTP/2 response has invalid status: 0", .{req_id});
        return ProxyError.InvalidResponse;
    }

    // Forward response to client
    const client_writer = ctx.writer;
    // Convert status code - use 502 for invalid status codes from backend
    const status: http.Status = std.enums.fromInt(http.Status, response.status) orelse .@"Bad Gateway";
    var http_response = ctx.response;
    http_response.status = status;
    http_response.mime = http.Mime.HTML; // Default to HTML for HTTP/2 responses

    // Write response headers
    http_response.headers_into_writer_opts(client_writer, body.len, true) catch {
        proxy_state.client_write_error = true;
        return ProxyError.SendFailed;
    };

    // Write response body
    if (body.len > 0) {
        client_writer.writeAll(body) catch {
            proxy_state.client_write_error = true;
        };
    }
    client_writer.flush() catch {
        proxy_state.client_write_error = true;
    };

    proxy_state.bytes_to_client = @intCast(body.len);

    log.debug("[REQ {d}] HTTP/2 response: status={d} body={d} bytes", .{
        req_id,
        response.status,
        body.len,
    });

    // Record metrics
    const duration_ns: u64 = if (start_ns) |start| blk: {
        const end_ns = std.time.Instant.now() catch break :blk 0;
        break :blk end_ns.since(start);
    } else 0;
    const duration_ms: i64 = @intCast(duration_ns / 1_000_000);
    _ = backend_idx;

    metrics.global_metrics.recordRequest(duration_ms, proxy_state.status_code);

    // Update span with result
    body_span.setIntAttribute("http.body.bytes_written", @intCast(proxy_state.bytes_to_client));
    body_span.setBoolAttribute("http.body.had_error", proxy_state.client_write_error);

    // Return response type
    if (proxy_state.client_write_error) {
        log.debug("[REQ {d}] => .close (client write error)", .{req_id});
        return .close;
    }
    log.debug("[REQ {d}] => .responded", .{req_id});
    return .responded;
}

/// HTTP/2 proxy implementation - uses BackendConnection for h2 framing.
/// Generic over backend type to support both BackendServer and SharedBackend.
/// Simplified HTTP/2 proxy using new pool API
/// TigerBeetle style: minimal handler, complexity hidden in pool/connection
fn streamingProxyHttp2(
    ctx: *const http.Context,
    backend: anytype,
    proxy_state: *ProxyState,
    state: *WorkerState,
    backend_idx: u32,
    start_ns: ?std.time.Instant,
    req_id: u32,
) ProxyError!http.Respond {
    log.debug("[REQ {d}] HTTP/2 request to backend {d}", .{ req_id, backend_idx });

    // Start HTTP/2 request span if we have a trace context
    var h2_span = if (proxy_state.trace_span) |trace_span|
        telemetry.startChildSpan(trace_span, "backend_request_h2", .Client)
    else
        telemetry.Span{ .inner = null, .tracer = null, .allocator = undefined };
    defer h2_span.end();

    h2_span.setStringAttribute("http.method", @tagName(ctx.request.method orelse .GET));
    h2_span.setStringAttribute("http.url", ctx.request.uri orelse "/");
    h2_span.setStringAttribute("http.flavor", "2.0");
    h2_span.setStringAttribute("backend.host", backend.getFullHost());

    // Get pool (must exist)
    const pool = state.h2_pool orelse {
        h2_span.setError("No H2 pool");
        return ProxyError.ConnectionFailed;
    };

    // Retry loop for TooManyStreams (connection full, not broken)
    const h2_conn = @import("../http/http2/connection.zig");
    const h2_client = @import("../http/http2/client.zig");
    var response: h2_client.Response = undefined;
    var used_conn: *h2_conn.H2Connection = undefined;
    var attempts: u32 = 0;
    var last_was_goaway: bool = false; // Track if exhaustion was due to GOAWAY
    while (attempts < 5) : (attempts += 1) {
        // Micro-backoff for GOAWAY retries (prevents thundering herd without latency cost)
        // 0µs, 100µs, 200µs, 400µs, 800µs - just enough to spread out retries
        if (last_was_goaway and attempts > 0) {
            const backoff_ns: u64 = @as(u64, 100_000) << @intCast(attempts - 1);
            std.Io.sleep(ctx.io, .{ .nanoseconds = @intCast(backoff_ns) }, .awake) catch {};
        }
        last_was_goaway = false;

        // Get or create connection (pool handles everything: TLS, handshake, retry)
        const conn = pool.getOrCreate(backend_idx, ctx.io, &h2_span) catch |err| {
            log.warn("[REQ {d}] H2 pool getOrCreate failed: {}", .{ req_id, err });
            h2_span.setError("Pool getOrCreate failed");
            // PoolExhausted is a local resource issue, not a backend failure
            if (err == error.PoolExhausted) {
                return ProxyError.PoolExhausted;
            }
            return ProxyError.ConnectionFailed;
        };

        h2_span.addEvent("connection_acquired");

        // Make request (connection handles: send, reader spawn, await)
        response = conn.request(
            @tagName(ctx.request.method orelse .GET),
            ctx.request.uri orelse "/",
            backend.getFullHost(),
            ctx.request.body,
            ctx.io,
        ) catch |err| {
            if (err == error.TooManyStreams) {
                // Connection full (all 8 slots busy) - release as healthy and retry
                log.debug("[REQ {d}] Connection full, retrying...", .{req_id});
                h2_span.addEvent("retry_too_many_streams");
                pool.release(conn, true, ctx.io);
                continue;
            }
            if (err == error.RetryNeeded or err == error.ConnectionGoaway) {
                // GOAWAY received - get fresh connection and retry
                // NOT a failure - just graceful connection shutdown
                log.debug("[REQ {d}] GOAWAY, retrying on fresh connection", .{req_id});
                h2_span.addEvent("retry_goaway");
                pool.release(conn, false, ctx.io); // Destroy this conn, but NOT a backend failure
                last_was_goaway = true;
                continue;
            }
            // Other errors - connection is broken
            log.warn("[REQ {d}] H2 request failed: {}", .{ req_id, err });
            h2_span.setError(@errorName(err));
            pool.release(conn, false, ctx.io);
            return ProxyError.SendFailed;
        };

        // Success - save connection for release after response forwarding
        used_conn = conn;
        break;
    } else {
        // All retries exhausted
        if (last_was_goaway) {
            // GOAWAY exhausted retries - NOT a backend health failure
            // Server is healthy, just aggressively closing connections under load
            log.debug("[REQ {d}] GOAWAY exhausted retries (not a failure)", .{req_id});
            h2_span.setError("GOAWAY retries exhausted");
            return ProxyError.GoawayRetriesExhausted;
        }
        log.warn("[REQ {d}] H2 request failed after {d} retries", .{ req_id, attempts });
        return ProxyError.SendFailed;
    }
    defer response.deinit();
    defer pool.release(used_conn, true, ctx.io);

    // Update proxy state
    proxy_state.status_code = response.status;
    proxy_state.bytes_from_backend = @intCast(response.body.items.len);

    // Update span with response info
    h2_span.setIntAttribute("http.status_code", @intCast(response.status));
    h2_span.setIntAttribute("http.response_content_length", @intCast(response.body.items.len));
    h2_span.setIntAttribute("h2.retry_count", @intCast(attempts));
    h2_span.setOk();

    // Forward response to client (connection released via defer above)
    return forwardH2Response(ctx, proxy_state, &response, backend_idx, start_ns, req_id, &h2_span);
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

// ============================================================================
// WAF Helper Functions
// ============================================================================

/// Convert zzz HTTP method to WAF HTTP method
fn convertHttpMethod(method: http.Method) waf.HttpMethod {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .DELETE => .DELETE,
        .PATCH => .PATCH,
        .HEAD => .HEAD,
        .OPTIONS => .OPTIONS,
        .TRACE => .TRACE,
        .CONNECT => .CONNECT,
    };
}
