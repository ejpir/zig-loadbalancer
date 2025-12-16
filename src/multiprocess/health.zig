/// Multi-Process Health Probing
///
/// Async health probes that run in the event loop without blocking requests.
const std = @import("std");
const log = std.log.scoped(.mp);

const zzz = @import("zzz");
const tardy = zzz.tardy;
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;
const Timer = tardy.Timer;

const types = @import("../core/types.zig");
const WorkerState = @import("worker_state.zig").WorkerState;
const Config = @import("worker_state.zig").Config;

/// Context for health probe task
pub const ProbeContext = struct {
    state: *WorkerState,
    allocator: std.mem.Allocator,
    worker_id: usize,
    runtime: *Runtime,
};

/// Async health probe task - runs in event loop
pub fn probeTask(ctx: ProbeContext) !void {
    const state = ctx.state;
    const backends = state.backends;
    const config = state.config;

    log.debug("Worker {d}: Health probe started (interval: {d}ms)", .{ ctx.worker_id, config.probe_interval_ms });

    // Initial delay
    Timer.delay(ctx.runtime, .{ .seconds = 1, .nanos = 0 }) catch {};

    while (true) {
        for (backends.items, 0..) |*backend, idx| {
            const is_healthy = probeBackend(ctx.allocator, backend, config, ctx.runtime);
            log.debug("Worker {d}: Probe backend {d} = {s}", .{
                ctx.worker_id,
                idx + 1,
                if (is_healthy) "OK" else "FAIL",
            });

            updateHealthState(state, idx, is_healthy, ctx.worker_id, backend);
            state.updateProbeTime(idx);
        }

        // Wait for next interval (non-blocking)
        const delay_ms = config.probe_interval_ms;
        Timer.delay(ctx.runtime, .{
            .seconds = @intCast(delay_ms / 1000),
            .nanos = @intCast((delay_ms % 1000) * 1_000_000),
        }) catch {};
    }
}

fn updateHealthState(state: *WorkerState, idx: usize, is_healthy: bool, worker_id: usize, backend: *const types.BackendServer) void {
    if (is_healthy) {
        if (!state.isHealthy(idx)) {
            // Use circuit breaker's recordSuccess for recovery tracking
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
            // Already healthy, just reset failure count
            state.circuit_breaker.resetCounters(idx);
        }
    } else {
        if (state.isHealthy(idx)) {
            // Use circuit breaker's recordFailure for threshold tracking
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
}

fn probeBackend(allocator: std.mem.Allocator, backend: *const types.BackendServer, config: Config, rt: *Runtime) bool {
    var sock = Socket.init(.{ .tcp = .{
        .host = backend.getFullHost(),
        .port = backend.port,
    } }) catch return false;
    defer sock.close_blocking();

    sock.connect(rt) catch return false;

    const request = std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{
        config.health_path,
        backend.getFullHost(),
        backend.port,
    }) catch return false;
    defer allocator.free(request);

    _ = sock.send_all(rt, request) catch return false;

    var buffer: [1024]u8 = undefined;
    const n = sock.recv(rt, &buffer) catch return false;
    if (n == 0) return false;

    const response = buffer[0..n];
    return std.mem.indexOf(u8, response, "HTTP/1.1 200") != null or
        std.mem.indexOf(u8, response, "HTTP/1.0 200") != null;
}
