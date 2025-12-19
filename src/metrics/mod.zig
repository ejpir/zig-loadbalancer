/// Lock-Free Metrics Collection and Prometheus Export
///
/// Thread-safe metrics collection using atomic counters for high-performance monitoring.
const std = @import("std");
const log = std.log.scoped(.metrics);
const zzz = @import("zzz");
const http = zzz.HTTP;
const Context = http.Context;
const Respond = http.Respond;

/// Maximum backends supported (must match proxy MAX_BACKENDS)
const MAX_BACKENDS: u32 = 64;

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

    // === Per-Backend Metrics ===
    /// Total requests per backend
    requests_per_backend: [MAX_BACKENDS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** MAX_BACKENDS,
    /// Successful requests per backend (2xx)
    success_per_backend: [MAX_BACKENDS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** MAX_BACKENDS,
    /// Error responses per backend (4xx, 5xx) or failures
    errors_per_backend: [MAX_BACKENDS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** MAX_BACKENDS,
    /// Pool hits per backend
    pool_hits_per_backend: [MAX_BACKENDS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** MAX_BACKENDS,
    /// Pool misses per backend
    pool_misses_per_backend: [MAX_BACKENDS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** MAX_BACKENDS,
    /// Total latency per backend (milliseconds)
    latency_total_ms_per_backend: [MAX_BACKENDS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** MAX_BACKENDS,
    /// Total bytes sent to backend
    bytes_to_backend: [MAX_BACKENDS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** MAX_BACKENDS,
    /// Total bytes received from backend
    bytes_from_backend_per_backend: [MAX_BACKENDS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** MAX_BACKENDS,

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

    /// Record a completed request for a specific backend
    pub fn recordRequestForBackend(
        self: *MetricsCollector,
        backend_idx: u32,
        duration_ms: i64,
        status_code: u16,
    ) void {
        // Bounds check to prevent out-of-bounds access
        if (backend_idx >= MAX_BACKENDS) return;

        _ = self.requests_per_backend[backend_idx].fetchAdd(1, .monotonic);

        if (duration_ms > 0) {
            _ = self.latency_total_ms_per_backend[backend_idx].fetchAdd(@intCast(duration_ms), .monotonic);
        }

        if (status_code >= 200 and status_code < 300) {
            _ = self.success_per_backend[backend_idx].fetchAdd(1, .monotonic);
        } else if (status_code >= 400) {
            _ = self.errors_per_backend[backend_idx].fetchAdd(1, .monotonic);
        }
    }

    /// Record pool hit for specific backend
    pub fn recordPoolHitForBackend(self: *MetricsCollector, backend_idx: u32) void {
        if (backend_idx >= MAX_BACKENDS) return;
        _ = self.pool_hits_per_backend[backend_idx].fetchAdd(1, .monotonic);
    }

    /// Record pool miss for specific backend
    pub fn recordPoolMissForBackend(self: *MetricsCollector, backend_idx: u32) void {
        if (backend_idx >= MAX_BACKENDS) return;
        _ = self.pool_misses_per_backend[backend_idx].fetchAdd(1, .monotonic);
    }

    /// Record bytes transferred for specific backend
    pub fn recordBytesForBackend(
        self: *MetricsCollector,
        backend_idx: u32,
        to_backend: u64,
        from_backend: u64,
    ) void {
        if (backend_idx >= MAX_BACKENDS) return;

        if (to_backend > 0) {
            _ = self.bytes_to_backend[backend_idx].fetchAdd(to_backend, .monotonic);
        }
        if (from_backend > 0) {
            _ = self.bytes_from_backend_per_backend[backend_idx].fetchAdd(from_backend, .monotonic);
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

    /// Generate Prometheus format metrics into a fixed buffer (zero allocation)
    pub fn toPrometheusFormat(self: *MetricsCollector, buffer: []u8) ![]u8 {
        const snapshot = self.loadSnapshot();
        const derived = calculateDerivedMetrics(snapshot);

        var pos: usize = 0;

        // Global metrics
        const global_metrics_text = try std.fmt.bufPrint(buffer[pos..],
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
            \\
        , .{
            snapshot.requests_total,
            snapshot.requests_success,
            snapshot.requests_client_error,
            snapshot.requests_server_error,
            derived.avg_duration_ms,
            snapshot.pool_hits,
            snapshot.pool_misses,
            derived.pool_hit_rate,
            snapshot.stale_conns,
            snapshot.send_failures,
            snapshot.read_failures,
            snapshot.failovers,
            snapshot.healthy,
            snapshot.unhealthy,
            snapshot.bytes_in,
            snapshot.bytes_out,
        });
        pos += global_metrics_text.len;

        // Per-backend metrics
        const per_backend_start = try std.fmt.bufPrint(buffer[pos..],
            \\# HELP zzz_lb_backend_requests_total Total requests per backend
            \\# TYPE zzz_lb_backend_requests_total counter
            \\
        , .{});
        pos += per_backend_start.len;

        // Export metrics for each backend with data
        var backend_idx: u32 = 0;
        while (backend_idx < MAX_BACKENDS) : (backend_idx += 1) {
            const requests = self.requests_per_backend[backend_idx].load(.acquire);
            if (requests > 0) {
                const line = try std.fmt.bufPrint(
                    buffer[pos..],
                    "zzz_lb_backend_requests_total{{backend=\"{d}\"}} {d}\n",
                    .{ backend_idx, requests },
                );
                pos += line.len;
            }
        }

        // Success per backend
        const success_header = try std.fmt.bufPrint(buffer[pos..],
            \\
            \\# HELP zzz_lb_backend_requests_success Successful requests per backend
            \\# TYPE zzz_lb_backend_requests_success counter
            \\
        , .{});
        pos += success_header.len;

        backend_idx = 0;
        while (backend_idx < MAX_BACKENDS) : (backend_idx += 1) {
            const success = self.success_per_backend[backend_idx].load(.acquire);
            if (success > 0) {
                const line = try std.fmt.bufPrint(
                    buffer[pos..],
                    "zzz_lb_backend_requests_success{{backend=\"{d}\"}} {d}\n",
                    .{ backend_idx, success },
                );
                pos += line.len;
            }
        }

        // Errors per backend
        const errors_header = try std.fmt.bufPrint(buffer[pos..],
            \\
            \\# HELP zzz_lb_backend_requests_error Error requests per backend
            \\# TYPE zzz_lb_backend_requests_error counter
            \\
        , .{});
        pos += errors_header.len;

        backend_idx = 0;
        while (backend_idx < MAX_BACKENDS) : (backend_idx += 1) {
            const errors = self.errors_per_backend[backend_idx].load(.acquire);
            if (errors > 0) {
                const line = try std.fmt.bufPrint(
                    buffer[pos..],
                    "zzz_lb_backend_requests_error{{backend=\"{d}\"}} {d}\n",
                    .{ backend_idx, errors },
                );
                pos += line.len;
            }
        }

        // Latency per backend
        const latency_header = try std.fmt.bufPrint(buffer[pos..],
            \\
            \\# HELP zzz_lb_backend_latency_total_ms Total latency per backend
            \\# TYPE zzz_lb_backend_latency_total_ms counter
            \\
        , .{});
        pos += latency_header.len;

        backend_idx = 0;
        while (backend_idx < MAX_BACKENDS) : (backend_idx += 1) {
            const latency = self.latency_total_ms_per_backend[backend_idx].load(.acquire);
            if (latency > 0) {
                const line = try std.fmt.bufPrint(
                    buffer[pos..],
                    "zzz_lb_backend_latency_total_ms{{backend=\"{d}\"}} {d}\n",
                    .{ backend_idx, latency },
                );
                pos += line.len;
            }
        }

        // Pool hits per backend
        const pool_hits_header = try std.fmt.bufPrint(buffer[pos..],
            \\
            \\# HELP zzz_lb_backend_pool_hits Pool hits per backend
            \\# TYPE zzz_lb_backend_pool_hits counter
            \\
        , .{});
        pos += pool_hits_header.len;

        backend_idx = 0;
        while (backend_idx < MAX_BACKENDS) : (backend_idx += 1) {
            const hits = self.pool_hits_per_backend[backend_idx].load(.acquire);
            if (hits > 0) {
                const line = try std.fmt.bufPrint(
                    buffer[pos..],
                    "zzz_lb_backend_pool_hits{{backend=\"{d}\"}} {d}\n",
                    .{ backend_idx, hits },
                );
                pos += line.len;
            }
        }

        // Pool misses per backend
        const pool_misses_header = try std.fmt.bufPrint(buffer[pos..],
            \\
            \\# HELP zzz_lb_backend_pool_misses Pool misses per backend
            \\# TYPE zzz_lb_backend_pool_misses counter
            \\
        , .{});
        pos += pool_misses_header.len;

        backend_idx = 0;
        while (backend_idx < MAX_BACKENDS) : (backend_idx += 1) {
            const misses = self.pool_misses_per_backend[backend_idx].load(.acquire);
            if (misses > 0) {
                const line = try std.fmt.bufPrint(
                    buffer[pos..],
                    "zzz_lb_backend_pool_misses{{backend=\"{d}\"}} {d}\n",
                    .{ backend_idx, misses },
                );
                pos += line.len;
            }
        }

        // Bytes to backend
        const bytes_to_header = try std.fmt.bufPrint(buffer[pos..],
            \\
            \\# HELP zzz_lb_backend_bytes_sent Bytes sent to backend
            \\# TYPE zzz_lb_backend_bytes_sent counter
            \\
        , .{});
        pos += bytes_to_header.len;

        backend_idx = 0;
        while (backend_idx < MAX_BACKENDS) : (backend_idx += 1) {
            const bytes = self.bytes_to_backend[backend_idx].load(.acquire);
            if (bytes > 0) {
                const line = try std.fmt.bufPrint(
                    buffer[pos..],
                    "zzz_lb_backend_bytes_sent{{backend=\"{d}\"}} {d}\n",
                    .{ backend_idx, bytes },
                );
                pos += line.len;
            }
        }

        // Bytes from backend
        const bytes_from_header = try std.fmt.bufPrint(buffer[pos..],
            \\
            \\# HELP zzz_lb_backend_bytes_received Bytes received from backend
            \\# TYPE zzz_lb_backend_bytes_received counter
            \\
        , .{});
        pos += bytes_from_header.len;

        backend_idx = 0;
        while (backend_idx < MAX_BACKENDS) : (backend_idx += 1) {
            const bytes = self.bytes_from_backend_per_backend[backend_idx].load(.acquire);
            if (bytes > 0) {
                const line = try std.fmt.bufPrint(
                    buffer[pos..],
                    "zzz_lb_backend_bytes_received{{backend=\"{d}\"}} {d}\n",
                    .{ backend_idx, bytes },
                );
                pos += line.len;
            }
        }

        return buffer[0..pos];
    }

    /// Atomic snapshot of all metrics values
    const MetricsSnapshot = struct {
        requests_total: u64,
        requests_success: u64,
        requests_client_error: u64,
        requests_server_error: u64,
        duration_total: u64,
        pool_hits: u64,
        pool_misses: u64,
        stale_conns: u64,
        send_failures: u64,
        read_failures: u64,
        failovers: u64,
        healthy: u64,
        unhealthy: u64,
        bytes_in: u64,
        bytes_out: u64,
    };

    /// Load atomic snapshot of all metrics
    fn loadSnapshot(self: *MetricsCollector) MetricsSnapshot {
        return .{
            .requests_total = self.requests_total.load(.acquire),
            .requests_success = self.requests_success.load(.acquire),
            .requests_client_error = self.requests_client_error.load(.acquire),
            .requests_server_error = self.requests_server_error.load(.acquire),
            .duration_total = self.request_duration_total_ms.load(.acquire),
            .pool_hits = self.pool_hits.load(.acquire),
            .pool_misses = self.pool_misses.load(.acquire),
            .stale_conns = self.stale_connections.load(.acquire),
            .send_failures = self.backend_send_failures.load(.acquire),
            .read_failures = self.backend_read_failures.load(.acquire),
            .failovers = self.backend_failovers.load(.acquire),
            .healthy = self.backends_healthy.load(.acquire),
            .unhealthy = self.backends_unhealthy.load(.acquire),
            .bytes_in = self.bytes_from_backend.load(.acquire),
            .bytes_out = self.bytes_to_client.load(.acquire),
        };
    }

    /// Derived metrics calculated from snapshot
    const DerivedMetrics = struct {
        avg_duration_ms: f64,
        pool_hit_rate: f64,
    };

    /// Calculate derived metrics from snapshot
    fn calculateDerivedMetrics(snapshot: MetricsSnapshot) DerivedMetrics {
        const avg_duration_ms: f64 = if (snapshot.requests_total > 0)
            @as(f64, @floatFromInt(snapshot.duration_total)) /
                @as(f64, @floatFromInt(snapshot.requests_total))
        else
            0.0;

        const pool_total = snapshot.pool_hits + snapshot.pool_misses;
        const pool_hit_rate: f64 = if (pool_total > 0)
            @as(f64, @floatFromInt(snapshot.pool_hits)) /
                @as(f64, @floatFromInt(pool_total)) * 100.0
        else
            0.0;

        return .{
            .avg_duration_ms = avg_duration_ms,
            .pool_hit_rate = pool_hit_rate,
        };
    }
};

/// Global metrics instance
pub var global_metrics = MetricsCollector{};

/// Stack buffer for metrics output (zero allocation)
/// Increased size to accommodate per-backend metrics (64 backends * ~200 bytes/backend)
threadlocal var metrics_buffer: [16384]u8 = undefined;

/// Metrics endpoint handler (zero allocation)
pub fn metricsHandler(ctx: *const Context, data: void) !Respond {
    _ = data;
    const metrics_output = global_metrics.toPrometheusFormat(&metrics_buffer) catch |err| {
        log.err("Failed to generate metrics: {s}", .{@errorName(err)});
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Failed to generate metrics",
        });
    };

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.TEXT,
        .body = metrics_output,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "per-backend metrics initialization" {
    var collector = MetricsCollector{};

    // Verify all per-backend counters are initialized to 0
    var idx: u32 = 0;
    while (idx < MAX_BACKENDS) : (idx += 1) {
        try std.testing.expectEqual(@as(u64, 0), collector.requests_per_backend[idx].load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), collector.success_per_backend[idx].load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), collector.errors_per_backend[idx].load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), collector.pool_hits_per_backend[idx].load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), collector.pool_misses_per_backend[idx].load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), collector.latency_total_ms_per_backend[idx].load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), collector.bytes_to_backend[idx].load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), collector.bytes_from_backend_per_backend[idx].load(.acquire));
    }
}

test "per-backend request recording" {
    var collector = MetricsCollector{};

    // Record some requests for backend 0
    collector.recordRequestForBackend(0, 100, 200);
    collector.recordRequestForBackend(0, 150, 200);
    collector.recordRequestForBackend(0, 200, 500);

    // Verify backend 0 metrics
    try std.testing.expectEqual(@as(u64, 3), collector.requests_per_backend[0].load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), collector.success_per_backend[0].load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), collector.errors_per_backend[0].load(.acquire));
    try std.testing.expectEqual(@as(u64, 450), collector.latency_total_ms_per_backend[0].load(.acquire));

    // Verify other backends are still 0
    try std.testing.expectEqual(@as(u64, 0), collector.requests_per_backend[1].load(.acquire));
}

test "per-backend pool metrics" {
    var collector = MetricsCollector{};

    // Record pool hits and misses for different backends
    collector.recordPoolHitForBackend(0);
    collector.recordPoolHitForBackend(0);
    collector.recordPoolHitForBackend(0);
    collector.recordPoolMissForBackend(0);

    collector.recordPoolHitForBackend(1);
    collector.recordPoolMissForBackend(1);
    collector.recordPoolMissForBackend(1);

    // Verify backend 0
    try std.testing.expectEqual(@as(u64, 3), collector.pool_hits_per_backend[0].load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), collector.pool_misses_per_backend[0].load(.acquire));

    // Verify backend 1
    try std.testing.expectEqual(@as(u64, 1), collector.pool_hits_per_backend[1].load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), collector.pool_misses_per_backend[1].load(.acquire));

    // Verify backend 2 is still 0
    try std.testing.expectEqual(@as(u64, 0), collector.pool_hits_per_backend[2].load(.acquire));
}

test "per-backend bytes tracking" {
    var collector = MetricsCollector{};

    // Record bytes for different backends
    collector.recordBytesForBackend(0, 1024, 2048);
    collector.recordBytesForBackend(0, 512, 1024);
    collector.recordBytesForBackend(1, 4096, 8192);

    // Verify backend 0
    try std.testing.expectEqual(@as(u64, 1536), collector.bytes_to_backend[0].load(.acquire));
    try std.testing.expectEqual(@as(u64, 3072), collector.bytes_from_backend_per_backend[0].load(.acquire));

    // Verify backend 1
    try std.testing.expectEqual(@as(u64, 4096), collector.bytes_to_backend[1].load(.acquire));
    try std.testing.expectEqual(@as(u64, 8192), collector.bytes_from_backend_per_backend[1].load(.acquire));
}

test "per-backend bounds checking" {
    var collector = MetricsCollector{};

    // Try to record metrics for out-of-bounds backend (should be ignored)
    collector.recordRequestForBackend(MAX_BACKENDS, 100, 200);
    collector.recordRequestForBackend(MAX_BACKENDS + 1, 100, 200);
    collector.recordPoolHitForBackend(MAX_BACKENDS);
    collector.recordPoolMissForBackend(MAX_BACKENDS + 10);
    collector.recordBytesForBackend(MAX_BACKENDS, 1024, 2048);

    // Verify no counters were incremented (all should still be 0)
    var idx: u32 = 0;
    while (idx < MAX_BACKENDS) : (idx += 1) {
        try std.testing.expectEqual(@as(u64, 0), collector.requests_per_backend[idx].load(.acquire));
    }
}

test "prometheus format includes per-backend metrics" {
    var collector = MetricsCollector{};

    // Record metrics for backends 0 and 1
    collector.recordRequestForBackend(0, 100, 200);
    collector.recordRequestForBackend(0, 150, 200);
    collector.recordRequestForBackend(1, 200, 500);
    collector.recordPoolHitForBackend(0);
    collector.recordPoolMissForBackend(1);

    // Generate Prometheus output
    var buffer: [16384]u8 = undefined;
    const output = try collector.toPrometheusFormat(&buffer);

    // Verify per-backend metrics are present
    try std.testing.expect(std.mem.indexOf(u8, output, "zzz_lb_backend_requests_total{backend=\"0\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zzz_lb_backend_requests_total{backend=\"1\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zzz_lb_backend_requests_success{backend=\"0\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zzz_lb_backend_requests_error{backend=\"1\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zzz_lb_backend_pool_hits{backend=\"0\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zzz_lb_backend_pool_misses{backend=\"1\"} 1") != null);
}

test "prometheus format only includes backends with data" {
    var collector = MetricsCollector{};

    // Only record metrics for backend 0
    collector.recordRequestForBackend(0, 100, 200);

    // Generate Prometheus output
    var buffer: [16384]u8 = undefined;
    const output = try collector.toPrometheusFormat(&buffer);

    // Verify backend 0 is present
    try std.testing.expect(std.mem.indexOf(u8, output, "backend=\"0\"") != null);

    // Verify other backends are not present (except in global metrics)
    try std.testing.expect(std.mem.indexOf(u8, output, "backend=\"1\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "backend=\"2\"") == null);
}

test "global and per-backend metrics work together" {
    var collector = MetricsCollector{};

    // Record both global and per-backend metrics
    collector.recordRequest(100, 200);
    collector.recordRequestForBackend(0, 100, 200);

    collector.recordRequest(150, 500);
    collector.recordRequestForBackend(1, 150, 500);

    // Verify global metrics
    try std.testing.expectEqual(@as(u64, 2), collector.requests_total.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), collector.requests_success.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), collector.requests_server_error.load(.acquire));

    // Verify per-backend metrics
    try std.testing.expectEqual(@as(u64, 1), collector.requests_per_backend[0].load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), collector.success_per_backend[0].load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), collector.requests_per_backend[1].load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), collector.errors_per_backend[1].load(.acquire));
}
