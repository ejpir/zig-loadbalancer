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
const UltraSock = @import("../http/ultra_sock.zig").UltraSock;

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
