/// Lock-Free Metrics Collection and Prometheus Export
///
/// Thread-safe metrics collection using atomic counters for high-performance monitoring.
const std = @import("std");
const log = std.log.scoped(.metrics);
const zzz = @import("zzz");
const http = zzz.HTTP;
const Context = http.Context;
const Respond = http.Respond;

/// Simple global metrics collector with atomic counters
pub const MetricsCollector = struct {
    /// Total requests processed
    requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Total request duration in milliseconds
    request_duration_total_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Total successful requests (2xx status)
    requests_success_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Total failed requests (4xx/5xx status)
    requests_error_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Total backend health checks
    health_checks_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Total healthy backends (current count)
    backends_healthy: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Total unhealthy backends (current count)
    backends_unhealthy: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Record a request with duration and status
    pub fn recordRequest(self: *MetricsCollector, duration_ms: i64, status_code: u16) void {
        _ = self.requests_total.fetchAdd(1, .monotonic);
        _ = self.request_duration_total_ms.fetchAdd(@intCast(duration_ms), .monotonic);

        if (status_code >= 200 and status_code < 300) {
            _ = self.requests_success_total.fetchAdd(1, .monotonic);
        } else if (status_code >= 400) {
            _ = self.requests_error_total.fetchAdd(1, .monotonic);
        }
    }

    /// Record a health check
    pub fn recordHealthCheck(self: *MetricsCollector) void {
        _ = self.health_checks_total.fetchAdd(1, .monotonic);
    }

    /// Update healthy and unhealthy backend counts
    pub fn updateHealthyBackends(self: *MetricsCollector, healthy_count: u64, unhealthy_count: u64) void {
        self.backends_healthy.store(healthy_count, .release);
        self.backends_unhealthy.store(unhealthy_count, .release);
    }

    /// Generate Prometheus format metrics
    pub fn toPrometheusFormat(self: *MetricsCollector, allocator: std.mem.Allocator) ![]u8 {
        const requests_total = self.requests_total.load(.acquire);
        const duration_total = self.request_duration_total_ms.load(.acquire);
        const requests_success = self.requests_success_total.load(.acquire);
        const requests_error = self.requests_error_total.load(.acquire);
        const health_checks = self.health_checks_total.load(.acquire);
        const healthy_backends = self.backends_healthy.load(.acquire);
        const unhealthy_backends = self.backends_unhealthy.load(.acquire);

        // Calculate average response time
        const avg_response_time = if (requests_total > 0)
            @as(f64, @floatFromInt(duration_total)) / @as(f64, @floatFromInt(requests_total)) / 1000.0
        else
            0.0;

        return std.fmt.allocPrint(allocator,
            \\# HELP zzz_lb_requests_total Total number of requests processed
            \\# TYPE zzz_lb_requests_total counter
            \\zzz_lb_requests_total {d}
            \\
            \\# HELP zzz_lb_requests_success_total Total number of successful requests (2xx)
            \\# TYPE zzz_lb_requests_success_total counter
            \\zzz_lb_requests_success_total {d}
            \\
            \\# HELP zzz_lb_requests_error_total Total number of error requests (4xx/5xx)
            \\# TYPE zzz_lb_requests_error_total counter
            \\zzz_lb_requests_error_total {d}
            \\
            \\# HELP zzz_lb_request_duration_avg_seconds Average request duration in seconds
            \\# TYPE zzz_lb_request_duration_avg_seconds gauge
            \\zzz_lb_request_duration_avg_seconds {d:.6}
            \\
            \\# HELP zzz_lb_health_checks_total Total number of health checks performed
            \\# TYPE zzz_lb_health_checks_total counter
            \\zzz_lb_health_checks_total {d}
            \\
            \\# HELP zzz_lb_backends_healthy Current number of healthy backends
            \\# TYPE zzz_lb_backends_healthy gauge
            \\zzz_lb_backends_healthy {d}
            \\
            \\# HELP zzz_lb_backends_unhealthy Current number of unhealthy backends
            \\# TYPE zzz_lb_backends_unhealthy gauge
            \\zzz_lb_backends_unhealthy {d}
            \\
        , .{ requests_total, requests_success, requests_error, avg_response_time, health_checks, healthy_backends, unhealthy_backends });
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
