/// Multi-Process Health Probing
///
/// Periodic health probes check backend availability in background thread.
/// Uses blocking I/O since probes run independently of request handling.
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

const types = @import("../core/types.zig");
const WorkerState = @import("worker_state.zig").WorkerState;
const Config = @import("worker_state.zig").Config;

/// Start health probing in a background thread
pub fn startHealthProbes(state: *WorkerState, worker_id: usize) !std.Thread {
    return try std.Thread.spawn(.{}, healthProbeLoop, .{ state, worker_id });
}

/// Health probe loop - runs in dedicated thread
fn healthProbeLoop(state: *WorkerState, worker_id: usize) void {
    const backends = state.backends;
    const config = state.config;

    log.info(
        "Worker {d}: Health probe thread started (interval: {d}ms)",
        .{ worker_id, config.probe_interval_ms },
    );

    // Initial delay before first probe
    posix.nanosleep(1, 0);

    while (true) {
        for (backends.items, 0..) |*backend, idx| {
            const probe_result = probeBackend(backend, config);

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

/// Probe a single backend using blocking TCP connection
fn probeBackend(backend: *const types.BackendServer, config: Config) bool {
    // Parse IP address directly using posix
    const host = backend.getFullHost();

    // Try to parse as IPv4
    var addr: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, backend.port),
        .addr = 0,
    };

    // Parse dotted-decimal IP (IPv4 = 4 octets)
    const MAX_IP_OCTETS = 4;
    var parts: [MAX_IP_OCTETS]u8 = [_]u8{0} ** MAX_IP_OCTETS;
    var iter = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (iter.next()) |part| : (i += 1) {
        if (i >= MAX_IP_OCTETS) return false;
        parts[i] = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    if (i != MAX_IP_OCTETS) return false;

    addr.addr = @as(u32, parts[0]) |
        (@as(u32, parts[1]) << 8) |
        (@as(u32, parts[2]) << 16) |
        (@as(u32, parts[3]) << 24);

    return probeAddressRaw(&addr, config);
}

fn probeAddressRaw(addr: *const posix.sockaddr.in, config: Config) bool {
    // Create socket
    const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(sock);

    // Set connect timeout
    const timeout_us = @as(i64, @intCast(config.probe_timeout_ms)) * 1000;
    const timeout = posix.timeval{
        .sec = @intCast(@divTrunc(timeout_us, 1_000_000)),
        .usec = @intCast(@mod(timeout_us, 1_000_000)),
    };
    const timeout_bytes = std.mem.asBytes(&timeout);
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, timeout_bytes) catch {};
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, timeout_bytes) catch {};

    // Connect
    const addr_size = @sizeOf(posix.sockaddr.in);
    posix.connect(sock, @ptrCast(addr), addr_size) catch return false;

    // Send HTTP request
    var request_buf: [256]u8 = [_]u8{0} ** 256;
    const fmt_str = "GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const request = std.fmt.bufPrint(
        &request_buf,
        fmt_str,
        .{config.health_path},
    ) catch return false;

    _ = posix.send(sock, request, 0) catch return false;

    // Read response
    var buffer: [512]u8 = [_]u8{0} ** 512;
    const n = posix.recv(sock, &buffer, 0) catch return false;
    if (n == 0) return false;

    // Check for 200 OK
    const response = buffer[0..n];
    return std.mem.indexOf(u8, response, "200") != null;
}
