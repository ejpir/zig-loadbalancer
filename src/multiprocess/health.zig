/// Multi-Process Health Probing
///
/// Periodic health probes that check backend availability in a background thread.
/// Uses blocking I/O since probes run independently of the main request handling.
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

    log.info("Worker {d}: Health probe thread started (interval: {d}ms)", .{ worker_id, config.probe_interval_ms });

    // Initial delay before first probe
    posix.nanosleep(1, 0);

    while (true) {
        for (backends.items, 0..) |*backend, idx| {
            const is_healthy = probeBackend(backend, config);

            if (is_healthy) {
                if (!state.isHealthy(idx)) {
                    state.recordSuccess(idx);
                    if (state.isHealthy(idx)) {
                        log.warn("Worker {d}: Backend {d} ({s}:{d}) now HEALTHY", .{
                            worker_id,
                            idx + 1,
                            backend.getFullHost(),
                            backend.port,
                        });
                    }
                } else {
                    // Already healthy, reset failure count
                    state.circuit_breaker.resetCounters(idx);
                }
            } else {
                if (state.isHealthy(idx)) {
                    state.recordFailure(idx);
                    if (!state.isHealthy(idx)) {
                        log.warn("Worker {d}: Backend {d} ({s}:{d}) now UNHEALTHY", .{
                            worker_id,
                            idx + 1,
                            backend.getFullHost(),
                            backend.port,
                        });
                    }
                }
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

    // Parse dotted-decimal IP
    var parts: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (iter.next()) |part| : (i += 1) {
        if (i >= 4) return false;
        parts[i] = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    if (i != 4) return false;

    addr.addr = @as(u32, parts[0]) | (@as(u32, parts[1]) << 8) | (@as(u32, parts[2]) << 16) | (@as(u32, parts[3]) << 24);

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
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

    // Connect
    posix.connect(sock, @ptrCast(addr), @sizeOf(posix.sockaddr.in)) catch return false;

    // Send HTTP request
    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{config.health_path}) catch return false;

    _ = posix.send(sock, request, 0) catch return false;

    // Read response
    var buffer: [512]u8 = undefined;
    const n = posix.recv(sock, &buffer, 0) catch return false;
    if (n == 0) return false;

    // Check for 200 OK
    const response = buffer[0..n];
    return std.mem.indexOf(u8, response, "200") != null;
}
