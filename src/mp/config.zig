/// Multi-Process Configuration
///
/// Health-aware proxy config for single-threaded workers.
/// No atomics needed - each worker is independent.
const std = @import("std");
const log = std.log.scoped(.mp);

const types = @import("../core/types.zig");
const simple_pool = @import("../memory/simple_connection_pool.zig");

pub const MAX_BACKENDS: usize = 64;

/// Health check settings
pub const HealthConfig = struct {
    unhealthy_threshold: u32 = 3,
    healthy_threshold: u32 = 2,
    probe_interval_ms: u64 = 5000,
    probe_timeout_ms: u64 = 2000,
    health_path: []const u8 = "/",
};

/// Proxy config with health state and circuit breaker
pub const Config = struct {
    backends: *const types.BackendsList,
    connection_pool: *simple_pool.SimpleConnectionPool,
    strategy: types.LoadBalancerStrategy = .round_robin,
    health: HealthConfig = .{},

    // Health state (no atomics - single-threaded!)
    healthy_bitmap: u64 = 0,
    consecutive_failures: [MAX_BACKENDS]u32 = [_]u32{0} ** MAX_BACKENDS,
    consecutive_successes: [MAX_BACKENDS]u32 = [_]u32{0} ** MAX_BACKENDS,
    last_check_time: [MAX_BACKENDS]i64 = [_]i64{0} ** MAX_BACKENDS,

    // Load balancing state
    rr_counter: usize = 0,
    request_count: usize = 0,

    // -------------------------------------------------------------------------
    // Health State
    // -------------------------------------------------------------------------

    pub fn markHealthy(self: *Config, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.healthy_bitmap |= @as(u64, 1) << @intCast(idx);
        self.consecutive_failures[idx] = 0;
    }

    pub fn markUnhealthy(self: *Config, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.healthy_bitmap &= ~(@as(u64, 1) << @intCast(idx));
        self.consecutive_successes[idx] = 0;
    }

    pub fn isHealthy(self: *const Config, idx: usize) bool {
        if (idx >= MAX_BACKENDS) return false;
        return (self.healthy_bitmap & (@as(u64, 1) << @intCast(idx))) != 0;
    }

    pub fn countHealthy(self: *const Config) usize {
        return @popCount(self.healthy_bitmap);
    }

    pub fn findHealthyBackend(self: *const Config, exclude_idx: usize) ?usize {
        var mask = self.healthy_bitmap;
        if (exclude_idx < MAX_BACKENDS) {
            mask &= ~(@as(u64, 1) << @intCast(exclude_idx));
        }
        if (mask == 0) return null;
        return @ctz(mask);
    }

    // -------------------------------------------------------------------------
    // Circuit Breaker
    // -------------------------------------------------------------------------

    pub fn recordSuccess(self: *Config, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.consecutive_failures[idx] = 0;

        if (!self.isHealthy(idx)) {
            self.consecutive_successes[idx] += 1;
            if (self.consecutive_successes[idx] >= self.health.healthy_threshold) {
                log.warn("Backend {d} recovered after {d} successes", .{ idx + 1, self.consecutive_successes[idx] });
                self.markHealthy(idx);
            }
        }
    }

    pub fn recordFailure(self: *Config, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.consecutive_successes[idx] = 0;
        self.consecutive_failures[idx] += 1;

        if (self.isHealthy(idx) and self.consecutive_failures[idx] >= self.health.unhealthy_threshold) {
            log.warn("Backend {d} marked UNHEALTHY after {d} failures", .{ idx + 1, self.consecutive_failures[idx] });
            self.markUnhealthy(idx);
        }
    }

    // -------------------------------------------------------------------------
    // Backend Selection
    // -------------------------------------------------------------------------

    pub fn selectBackend(self: *Config, comptime strategy: types.LoadBalancerStrategy) ?usize {
        const backend_count = self.backends.items.len;
        if (backend_count == 0) return null;

        if (self.healthy_bitmap == 0) {
            return self.rr_counter % backend_count;
        }

        return switch (strategy) {
            .round_robin, .weighted_round_robin => self.selectRoundRobin(backend_count),
            .random => self.selectRandom(backend_count),
            .sticky => 0,
        };
    }

    fn selectRoundRobin(self: *Config, backend_count: usize) usize {
        var attempts: usize = 0;
        while (attempts < backend_count) : (attempts += 1) {
            const candidate = (self.rr_counter +% attempts) % backend_count;
            if (self.isHealthy(candidate)) {
                self.rr_counter = candidate +% 1;
                return candidate;
            }
        }
        const fallback = self.rr_counter % backend_count;
        self.rr_counter +%= 1;
        return fallback;
    }

    fn selectRandom(self: *Config, backend_count: usize) usize {
        const healthy_count = self.countHealthy();
        if (healthy_count == 0) return 0;

        const rand_val = @as(usize, @intCast(std.time.nanoTimestamp() & 0xFFFFFFFF));
        var target = rand_val % healthy_count;
        var idx: usize = 0;
        while (idx < backend_count) : (idx += 1) {
            if (self.isHealthy(idx)) {
                if (target == 0) return idx;
                target -= 1;
            }
        }
        return 0;
    }
};
