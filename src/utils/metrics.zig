/// Lock-Free Metrics Collection and Prometheus Export
///
/// Thread-safe metrics collection using atomic counters for high-performance monitoring.
const std = @import("std");
const log = std.log.scoped(.metrics);
const zzz = @import("zzz");
const http = zzz.HTTP;
const Context = http.Context;
const Respond = http.Respond;

/// Global metrics collector with atomic counters
pub const MetricsCollector = struct {
    // === Request Metrics ===
    /// Total requests processed
    requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Total request duration in milliseconds
    request_duration_total_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Successful requests (2xx status)
    requests_success: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Client errors (4xx status)
    requests_client_error: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Server errors (5xx status)
    requests_server_error: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // === Connection Pool Metrics ===
    /// Pool hits (reused connections)
    pool_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Pool misses (new connections)
    pool_misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Stale connections detected
    stale_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // === Backend Metrics ===
    /// Backend send failures
    backend_send_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Backend read failures
    backend_read_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Backend failovers triggered
    backend_failovers: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Current healthy backend count
    backends_healthy: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Current unhealthy backend count
    backends_unhealthy: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // === Bytes Metrics ===
    /// Total bytes received from backends
    bytes_from_backend: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Total bytes sent to clients
    bytes_to_client: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Record a completed request
    pub fn recordRequest(self: *MetricsCollector, duration_ms: i64, status_code: u16) void {
        _ = self.requests_total.fetchAdd(1, .monotonic);
        if (duration_ms > 0) {
            _ = self.request_duration_total_ms.fetchAdd(@intCast(duration_ms), .monotonic);
        }

        if (status_code >= 200 and status_code < 300) {
            _ = self.requests_success.fetchAdd(1, .monotonic);
        } else if (status_code >= 400 and status_code < 500) {
            _ = self.requests_client_error.fetchAdd(1, .monotonic);
        } else if (status_code >= 500) {
            _ = self.requests_server_error.fetchAdd(1, .monotonic);
        }
    }

    /// Record connection pool hit
    pub fn recordPoolHit(self: *MetricsCollector) void {
        _ = self.pool_hits.fetchAdd(1, .monotonic);
    }

    /// Record connection pool miss
    pub fn recordPoolMiss(self: *MetricsCollector) void {
        _ = self.pool_misses.fetchAdd(1, .monotonic);
    }

    /// Record stale connection
    pub fn recordStaleConnection(self: *MetricsCollector) void {
        _ = self.stale_connections.fetchAdd(1, .monotonic);
    }

    /// Record backend send failure
    pub fn recordSendFailure(self: *MetricsCollector) void {
        _ = self.backend_send_failures.fetchAdd(1, .monotonic);
    }

    /// Record backend read failure
    pub fn recordReadFailure(self: *MetricsCollector) void {
        _ = self.backend_read_failures.fetchAdd(1, .monotonic);
    }

    /// Record backend failover
    pub fn recordFailover(self: *MetricsCollector) void {
        _ = self.backend_failovers.fetchAdd(1, .monotonic);
    }

    /// Record bytes transferred
    pub fn recordBytes(self: *MetricsCollector, from_backend: u64, to_client: u64) void {
        if (from_backend > 0) {
            _ = self.bytes_from_backend.fetchAdd(from_backend, .monotonic);
        }
        if (to_client > 0) {
            _ = self.bytes_to_client.fetchAdd(to_client, .monotonic);
        }
    }

    /// Update backend health counts
    pub fn updateBackendHealth(self: *MetricsCollector, healthy: u64, unhealthy: u64) void {
        self.backends_healthy.store(healthy, .release);
        self.backends_unhealthy.store(unhealthy, .release);
    }

    /// Generate Prometheus format metrics
    pub fn toPrometheusFormat(self: *MetricsCollector, allocator: std.mem.Allocator) ![]u8 {
        const requests_total = self.requests_total.load(.acquire);
        const duration_total = self.request_duration_total_ms.load(.acquire);
        const requests_success = self.requests_success.load(.acquire);
        const requests_client_error = self.requests_client_error.load(.acquire);
        const requests_server_error = self.requests_server_error.load(.acquire);
        const pool_hits = self.pool_hits.load(.acquire);
        const pool_misses = self.pool_misses.load(.acquire);
        const stale_conns = self.stale_connections.load(.acquire);
        const send_failures = self.backend_send_failures.load(.acquire);
        const read_failures = self.backend_read_failures.load(.acquire);
        const failovers = self.backend_failovers.load(.acquire);
        const healthy = self.backends_healthy.load(.acquire);
        const unhealthy = self.backends_unhealthy.load(.acquire);
        const bytes_in = self.bytes_from_backend.load(.acquire);
        const bytes_out = self.bytes_to_client.load(.acquire);

        // Calculate derived metrics
        const avg_duration_ms: f64 = if (requests_total > 0)
            @as(f64, @floatFromInt(duration_total)) / @as(f64, @floatFromInt(requests_total))
        else
            0.0;

        const pool_total = pool_hits + pool_misses;
        const pool_hit_rate: f64 = if (pool_total > 0)
            @as(f64, @floatFromInt(pool_hits)) / @as(f64, @floatFromInt(pool_total)) * 100.0
        else
            0.0;

        return std.fmt.allocPrint(allocator,
            \\# HELP zzz_lb_requests_total Total requests processed
            \\# TYPE zzz_lb_requests_total counter
            \\zzz_lb_requests_total {d}
            \\
            \\# HELP zzz_lb_requests_success Successful requests (2xx)
            \\# TYPE zzz_lb_requests_success counter
            \\zzz_lb_requests_success {d}
            \\
            \\# HELP zzz_lb_requests_client_error Client errors (4xx)
            \\# TYPE zzz_lb_requests_client_error counter
            \\zzz_lb_requests_client_error {d}
            \\
            \\# HELP zzz_lb_requests_server_error Server errors (5xx)
            \\# TYPE zzz_lb_requests_server_error counter
            \\zzz_lb_requests_server_error {d}
            \\
            \\# HELP zzz_lb_request_duration_avg_ms Average request duration in milliseconds
            \\# TYPE zzz_lb_request_duration_avg_ms gauge
            \\zzz_lb_request_duration_avg_ms {d:.2}
            \\
            \\# HELP zzz_lb_pool_hits Connection pool hits (reused)
            \\# TYPE zzz_lb_pool_hits counter
            \\zzz_lb_pool_hits {d}
            \\
            \\# HELP zzz_lb_pool_misses Connection pool misses (new)
            \\# TYPE zzz_lb_pool_misses counter
            \\zzz_lb_pool_misses {d}
            \\
            \\# HELP zzz_lb_pool_hit_rate Connection pool hit rate percentage
            \\# TYPE zzz_lb_pool_hit_rate gauge
            \\zzz_lb_pool_hit_rate {d:.1}
            \\
            \\# HELP zzz_lb_stale_connections Stale connections detected
            \\# TYPE zzz_lb_stale_connections counter
            \\zzz_lb_stale_connections {d}
            \\
            \\# HELP zzz_lb_backend_send_failures Backend send failures
            \\# TYPE zzz_lb_backend_send_failures counter
            \\zzz_lb_backend_send_failures {d}
            \\
            \\# HELP zzz_lb_backend_read_failures Backend read failures
            \\# TYPE zzz_lb_backend_read_failures counter
            \\zzz_lb_backend_read_failures {d}
            \\
            \\# HELP zzz_lb_backend_failovers Backend failovers triggered
            \\# TYPE zzz_lb_backend_failovers counter
            \\zzz_lb_backend_failovers {d}
            \\
            \\# HELP zzz_lb_backends_healthy Current healthy backends
            \\# TYPE zzz_lb_backends_healthy gauge
            \\zzz_lb_backends_healthy {d}
            \\
            \\# HELP zzz_lb_backends_unhealthy Current unhealthy backends
            \\# TYPE zzz_lb_backends_unhealthy gauge
            \\zzz_lb_backends_unhealthy {d}
            \\
            \\# HELP zzz_lb_bytes_from_backend Total bytes received from backends
            \\# TYPE zzz_lb_bytes_from_backend counter
            \\zzz_lb_bytes_from_backend {d}
            \\
            \\# HELP zzz_lb_bytes_to_client Total bytes sent to clients
            \\# TYPE zzz_lb_bytes_to_client counter
            \\zzz_lb_bytes_to_client {d}
            \\
        , .{
            requests_total,
            requests_success,
            requests_client_error,
            requests_server_error,
            avg_duration_ms,
            pool_hits,
            pool_misses,
            pool_hit_rate,
            stale_conns,
            send_failures,
            read_failures,
            failovers,
            healthy,
            unhealthy,
            bytes_in,
            bytes_out,
        });
    }
};

/// Global metrics instance
pub var global_metrics = MetricsCollector{};

/// Metrics endpoint handler
pub fn metricsHandler(ctx: *const Context, data: void) !Respond {
    _ = data;
    const metrics_output = global_metrics.toPrometheusFormat(ctx.allocator) catch |err| {
        log.err("Failed to generate metrics: {s}", .{@errorName(err)});
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Failed to generate metrics",
        });
    };

    return ctx.response.apply(.{
        .status = .@"OK",
        .mime = http.Mime.TEXT,
        .body = metrics_output,
    });
}
