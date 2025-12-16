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
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const HealthConfig = config_mod.HealthConfig;

/// Context for health probe task
pub const ProbeContext = struct {
    config: *Config,
    allocator: std.mem.Allocator,
    worker_id: usize,
    runtime: *Runtime,
};

/// Async health probe task - runs in event loop
pub fn probeTask(ctx: ProbeContext) !void {
    const config = ctx.config;
    const backends = config.backends;
    const health = config.health;

    log.debug("Worker {d}: Health probe started (interval: {d}ms)", .{ ctx.worker_id, health.probe_interval_ms });

    // Initial delay
    Timer.delay(ctx.runtime, .{ .seconds = 1, .nanos = 0 }) catch {};

    while (true) {
        for (backends.items, 0..) |*backend, idx| {
            const is_healthy = probeBackend(ctx.allocator, backend, health, ctx.runtime);
            log.debug("Worker {d}: Probe backend {d} = {s}", .{
                ctx.worker_id,
                idx + 1,
                if (is_healthy) "OK" else "FAIL",
            });

            updateHealthState(config, idx, is_healthy, ctx.worker_id, backend);
            config.last_check_time[idx] = std.time.milliTimestamp();
        }

        // Wait for next interval (non-blocking)
        const delay_ms = health.probe_interval_ms;
        Timer.delay(ctx.runtime, .{
            .seconds = @intCast(delay_ms / 1000),
            .nanos = @intCast((delay_ms % 1000) * 1_000_000),
        }) catch {};
    }
}

fn updateHealthState(config: *Config, idx: usize, is_healthy: bool, worker_id: usize, backend: *const types.BackendServer) void {
    if (is_healthy) {
        if (!config.isHealthy(idx)) {
            config.consecutive_successes[idx] += 1;
            if (config.consecutive_successes[idx] >= config.health.healthy_threshold) {
                log.warn("Worker {d}: Backend {d} ({s}:{d}) now HEALTHY", .{
                    worker_id,
                    idx + 1,
                    backend.getFullHost(),
                    backend.port,
                });
                config.markHealthy(idx);
            }
        } else {
            config.consecutive_failures[idx] = 0;
        }
    } else {
        if (config.isHealthy(idx)) {
            config.consecutive_failures[idx] += 1;
            if (config.consecutive_failures[idx] >= config.health.unhealthy_threshold) {
                log.warn("Worker {d}: Backend {d} ({s}:{d}) now UNHEALTHY", .{
                    worker_id,
                    idx + 1,
                    backend.getFullHost(),
                    backend.port,
                });
                config.markUnhealthy(idx);
            }
        }
    }
}

fn probeBackend(allocator: std.mem.Allocator, backend: *const types.BackendServer, health: HealthConfig, rt: *Runtime) bool {
    var sock = Socket.init(.{ .tcp = .{
        .host = backend.getFullHost(),
        .port = backend.port,
    } }) catch return false;
    defer sock.close_blocking();

    sock.connect(rt) catch return false;

    const request = std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{
        health.health_path,
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
