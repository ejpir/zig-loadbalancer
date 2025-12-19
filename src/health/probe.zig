/// Multi-Process Health Probing
///
/// Periodic health probes check backend availability in background thread.
/// Uses UltraSock for full HTTP/HTTPS support including DNS and TLS.
///
/// UNIFIED HEALTH MODEL:
/// Health probes feed INTO the circuit breaker - they don't manipulate state directly.
/// All health transitions go through circuit breaker thresholds:
///   - Probe success → recordSuccess() → may recover backend after threshold
///   - Probe failure → recordFailure() → may trip circuit breaker after threshold
///   - Request success → recordSuccess() → same path as probe success
///   - Request failure → recordFailure() → same path as probe failure
///
/// This ensures a single source of truth for backend health with no disagreement
/// between probe state and circuit breaker state.
const std = @import("std");
const log = std.log.scoped(.health);
const posix = std.posix;
const Io = std.Io;

const types = @import("../core/types.zig");
const config_mod = @import("../core/config.zig");
const WorkerState = @import("../lb/worker.zig").WorkerState;
const Config = @import("../lb/worker.zig").Config;
const ultra_sock_mod = @import("../http/ultra_sock.zig");
const UltraSock = ultra_sock_mod.UltraSock;
const TlsOptions = ultra_sock_mod.TlsOptions;

/// Start health probing in a background thread
pub fn startHealthProbes(state: *WorkerState, worker_id: usize) !std.Thread {
    return try std.Thread.spawn(.{}, healthProbeLoop, .{ state, worker_id });
}

/// Health probe loop - runs in dedicated thread with its own Io runtime
fn healthProbeLoop(state: *WorkerState, worker_id: usize) void {
    const backends = state.backends;
    const config = state.config;

    log.info(
        "Worker {d}: Health probe thread started (interval: {d}ms)",
        .{ worker_id, config.probe_interval_ms },
    );

    // Create Io runtime for this thread (handles DNS, TLS, etc.)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Initial delay before first probe
    posix.nanosleep(1, 0);

    while (true) {
        for (backends.items, 0..) |*backend, idx| {
            const probe_result = probeBackend(backend, config, io);

            // Feed probe results into circuit breaker
            // Circuit breaker handles all state transitions and logging
            if (probe_result) {
                state.recordSuccess(idx);
            } else {
                state.recordFailure(idx);
            }

            state.updateProbeTime(idx);
        }

        // Sleep until next probe interval
        const delay_s = config.probe_interval_ms / 1000;
        const delay_ns = (config.probe_interval_ms % 1000) * 1_000_000;
        posix.nanosleep(delay_s, delay_ns);
    }
}

/// Probe a single backend using UltraSock (handles HTTP/HTTPS, DNS, TLS)
fn probeBackend(backend: *const types.BackendServer, config: Config, io: Io) bool {
    const host = backend.getHost();
    const is_https = backend.isHttps();

    log.debug("Probing {s}:{d} (https={})", .{ host, backend.port, is_https });

    // Create UltraSock from backend (uses runtime TLS config for --insecure flag)
    var sock = UltraSock.fromBackendServer(backend);
    defer sock.close_blocking();

    // Connect (handles DNS resolution and TLS handshake)
    sock.connect(io) catch |err| {
        log.debug("Probe connect failed for {s}:{d}: {}", .{ host, backend.port, err });
        return false;
    };

    // Send HTTP health check request
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
        .{ config.health_path, host, backend.port },
    ) catch return false;

    _ = sock.send_all(io, request) catch |err| {
        log.debug("Probe send failed for {s}:{d}: {}", .{ host, backend.port, err });
        return false;
    };

    // Read response
    var buffer: [512]u8 = undefined;
    const n = sock.recv(io, &buffer) catch |err| {
        log.debug("Probe recv failed for {s}:{d}: {}", .{ host, backend.port, err });
        return false;
    };

    if (n == 0) return false;

    // Check for 2xx status
    const response = buffer[0..n];
    const is_healthy = std.mem.indexOf(u8, response, " 200 ") != null or
        std.mem.indexOf(u8, response, " 201 ") != null or
        std.mem.indexOf(u8, response, " 204 ") != null;

    if (is_healthy) {
        log.debug("Probe success for {s}:{d}", .{ host, backend.port });
    } else {
        log.debug("Probe failed for {s}:{d}: non-2xx response", .{ host, backend.port });
    }

    return is_healthy;
}

// ============================================================================
// Tests
// ============================================================================

test "probeBackend: BackendServer with HTTPS creates TLS UltraSock" {
    const testing = std.testing;

    // Create a backend with HTTPS (port 443)
    const host = "example.com";
    var backend = types.BackendServer.init(host, 443, 1);

    // Verify backend is detected as HTTPS
    try testing.expect(backend.isHttps());
    try testing.expectEqualStrings("example.com", backend.getHost());

    // Create UltraSock from backend (uses runtime config for TLS options)
    var sock = UltraSock.fromBackendServer(&backend);
    defer sock.deinit();

    // Verify UltraSock has correct protocol
    try testing.expectEqual(ultra_sock_mod.Protocol.https, sock.protocol);
    try testing.expectEqualStrings("example.com", sock.host);
    try testing.expectEqual(@as(u16, 443), sock.port);

    // Verify TLS options are set (uses runtime config)
    const tls_opts = sock.tls_options;
    if (config_mod.isInsecureTls()) {
        // If --insecure flag, should skip verification
        try testing.expect(tls_opts.isInsecure());
        try testing.expectEqual(@as(TlsOptions.CaVerification, .none), tls_opts.ca);
        try testing.expectEqual(@as(TlsOptions.HostVerification, .none), tls_opts.host);
    } else {
        // Otherwise, should use production settings
        try testing.expect(!tls_opts.isInsecure());
        try testing.expectEqual(@as(TlsOptions.CaVerification, .system), tls_opts.ca);
        try testing.expectEqual(@as(TlsOptions.HostVerification, .from_connection), tls_opts.host);
    }
}

test "probeBackend: BackendServer with https:// prefix creates TLS UltraSock" {
    const testing = std.testing;

    // Create a backend with https:// prefix and non-443 port
    const host = "https://secure.example.com";
    var backend = types.BackendServer.init(host, 8443, 1);

    // Verify backend is detected as HTTPS
    try testing.expect(backend.isHttps());
    try testing.expectEqualStrings("secure.example.com", backend.getHost());

    // Create UltraSock from backend
    var sock = UltraSock.fromBackendServer(&backend);
    defer sock.deinit();

    // Verify UltraSock has correct protocol (should strip https:// prefix)
    try testing.expectEqual(ultra_sock_mod.Protocol.https, sock.protocol);
    try testing.expectEqualStrings("secure.example.com", sock.host);
    try testing.expectEqual(@as(u16, 8443), sock.port);
}

test "probeBackend: BackendServer with HTTP creates non-TLS UltraSock" {
    const testing = std.testing;

    // Create a backend with HTTP
    const host = "http://plain.example.com";
    var backend = types.BackendServer.init(host, 80, 1);

    // Verify backend is NOT HTTPS
    try testing.expect(!backend.isHttps());
    try testing.expectEqualStrings("plain.example.com", backend.getHost());

    // Create UltraSock from backend
    var sock = UltraSock.fromBackendServer(&backend);
    defer sock.deinit();

    // Verify UltraSock has correct protocol
    try testing.expectEqual(ultra_sock_mod.Protocol.http, sock.protocol);
    try testing.expectEqualStrings("plain.example.com", sock.host);
    try testing.expectEqual(@as(u16, 80), sock.port);
}

test "probeBackend: request format is correct for HTTPS backends" {
    const testing = std.testing;

    // Create mock config
    const test_config = Config{
        .circuit_breaker_config = .{},
        .probe_interval_ms = 1000,
        .probe_timeout_ms = 5000,
        .health_path = "/health",
    };

    // Create HTTPS backend
    var backend = types.BackendServer.init("api.example.com", 443, 1);

    // Verify request format
    var request_buf: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buf,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
        .{ test_config.health_path, backend.getHost(), backend.port },
    );

    const expected = "GET /health HTTP/1.1\r\nHost: api.example.com:443\r\nConnection: close\r\n\r\n";
    try testing.expectEqualStrings(expected, request);
}

test "probeBackend: custom health path in request" {
    const testing = std.testing;

    // Create config with custom health path
    const test_config = Config{
        .circuit_breaker_config = .{},
        .probe_interval_ms = 1000,
        .probe_timeout_ms = 5000,
        .health_path = "/api/health/check",
    };

    // Create backend
    var backend = types.BackendServer.init("service.local", 8080, 1);

    // Verify custom health path in request
    var request_buf: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buf,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
        .{ test_config.health_path, backend.getHost(), backend.port },
    );

    const expected = "GET /api/health/check HTTP/1.1\r\nHost: service.local:8080\r\nConnection: close\r\n\r\n";
    try testing.expectEqualStrings(expected, request);
}

test "probeBackend: TLS options with insecure mode" {
    const testing = std.testing;

    // Create backend with HTTPS
    var backend = types.BackendServer.init("localhost", 8443, 1);

    // Create UltraSock with insecure TLS options
    const insecure_opts = TlsOptions.insecure();
    var sock = UltraSock.fromBackendServerWithTls(&backend, insecure_opts);
    defer sock.deinit();

    // Verify insecure options
    try testing.expect(sock.tls_options.isInsecure());
    try testing.expectEqual(@as(TlsOptions.CaVerification, .none), sock.tls_options.ca);
    try testing.expectEqual(@as(TlsOptions.HostVerification, .none), sock.tls_options.host);
}

test "probeBackend: TLS options with production mode" {
    const testing = std.testing;

    // Create backend with HTTPS
    var backend = types.BackendServer.init("secure-api.com", 443, 1);

    // Create UltraSock with production TLS options
    const prod_opts = TlsOptions.production();
    var sock = UltraSock.fromBackendServerWithTls(&backend, prod_opts);
    defer sock.deinit();

    // Verify production options
    try testing.expect(!sock.tls_options.isInsecure());
    try testing.expectEqual(@as(TlsOptions.CaVerification, .system), sock.tls_options.ca);
    try testing.expectEqual(@as(TlsOptions.HostVerification, .from_connection), sock.tls_options.host);
}

test "probeBackend: multiple backends with mixed protocols" {
    const testing = std.testing;

    // Create backends with different protocols
    var http_backend = types.BackendServer.init("http://plain.example.com", 80, 1);
    var https_backend = types.BackendServer.init("https://secure.example.com", 443, 1);
    var port443_backend = types.BackendServer.init("api.example.com", 443, 1);
    var custom_backend = types.BackendServer.init("service.local", 8080, 1);

    // Verify protocol detection
    try testing.expect(!http_backend.isHttps());
    try testing.expect(https_backend.isHttps());
    try testing.expect(port443_backend.isHttps());
    try testing.expect(!custom_backend.isHttps());

    // Create UltraSocks and verify protocols
    var http_sock = UltraSock.fromBackendServer(&http_backend);
    defer http_sock.deinit();
    try testing.expectEqual(ultra_sock_mod.Protocol.http, http_sock.protocol);

    var https_sock = UltraSock.fromBackendServer(&https_backend);
    defer https_sock.deinit();
    try testing.expectEqual(ultra_sock_mod.Protocol.https, https_sock.protocol);

    var port443_sock = UltraSock.fromBackendServer(&port443_backend);
    defer port443_sock.deinit();
    try testing.expectEqual(ultra_sock_mod.Protocol.https, port443_sock.protocol);

    var custom_sock = UltraSock.fromBackendServer(&custom_backend);
    defer custom_sock.deinit();
    try testing.expectEqual(ultra_sock_mod.Protocol.http, custom_sock.protocol);
}

test "probeBackend: host extraction from various formats" {
    const testing = std.testing;

    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
        is_https: bool,
    }{
        .{ .input = "example.com", .expected = "example.com", .is_https = false },
        .{ .input = "http://example.com", .expected = "example.com", .is_https = false },
        .{ .input = "https://example.com", .expected = "example.com", .is_https = true },
        .{ .input = "api.example.com", .expected = "api.example.com", .is_https = false },
        .{ .input = "https://api.example.com", .expected = "api.example.com", .is_https = true },
    };

    for (test_cases) |tc| {
        const port: u16 = if (tc.is_https) 443 else 80;
        var backend = types.BackendServer.init(tc.input, port, 1);

        try testing.expectEqualStrings(tc.expected, backend.getHost());
        try testing.expectEqual(tc.is_https, backend.isHttps());
    }
}

test "probeBackend: WorkerState config passed to probeBackend" {
    const testing = std.testing;

    // Create test config with custom values
    const test_config = Config{
        .circuit_breaker_config = .{
            .unhealthy_threshold = 3,
            .healthy_threshold = 2,
        },
        .probe_interval_ms = 2000,
        .probe_timeout_ms = 3000,
        .health_path = "/api/v1/health",
    };

    // Verify config values
    try testing.expectEqual(@as(u32, 3), test_config.unhealthy_threshold());
    try testing.expectEqual(@as(u32, 2), test_config.healthy_threshold());
    try testing.expectEqual(@as(u64, 2000), test_config.probe_interval_ms);
    try testing.expectEqual(@as(u64, 3000), test_config.probe_timeout_ms);
    try testing.expectEqualStrings("/api/v1/health", test_config.health_path);
}

test "probeBackend: default config values from config.zig" {
    const testing = std.testing;

    // Create config with defaults
    const default_config = Config{};

    // Verify defaults match config.zig constants
    try testing.expectEqual(config_mod.DEFAULT_UNHEALTHY_THRESHOLD, default_config.unhealthy_threshold());
    try testing.expectEqual(config_mod.DEFAULT_HEALTHY_THRESHOLD, default_config.healthy_threshold());
    try testing.expectEqual(config_mod.DEFAULT_PROBE_INTERVAL_MS, default_config.probe_interval_ms);
    try testing.expectEqual(config_mod.DEFAULT_PROBE_TIMEOUT_MS, default_config.probe_timeout_ms);
    try testing.expectEqualStrings(config_mod.DEFAULT_HEALTH_PATH, default_config.health_path);
}
