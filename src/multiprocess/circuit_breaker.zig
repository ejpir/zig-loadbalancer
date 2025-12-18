/// Circuit Breaker - Single Source of Truth for Backend Health
///
/// Threshold-based health state transitions.
/// Backends transition to unhealthy after consecutive failures,
/// and recover after consecutive successes.
///
/// This is the ONLY component that changes backend health state.
/// Both health probes and request handlers feed results into the circuit breaker
/// using recordSuccess() and recordFailure(). This ensures unified health tracking
/// with no disagreement between different systems.
const std = @import("std");
const log = std.log.scoped(.circuit_breaker);

const health_state = @import("health_state.zig");
pub const HealthState = health_state.HealthState;
pub const MAX_BACKENDS = health_state.MAX_BACKENDS;

/// Circuit breaker configuration
pub const Config = struct {
    /// Consecutive failures before marking unhealthy
    unhealthy_threshold: u32 = 3,
    /// Consecutive successes before marking healthy
    healthy_threshold: u32 = 2,
};

/// Circuit breaker with threshold-based state transitions
pub const CircuitBreaker = struct {
    health: HealthState = .{},
    config: Config = .{},
    consecutive_failures: [MAX_BACKENDS]u32 = [_]u32{0} ** MAX_BACKENDS,
    consecutive_successes: [MAX_BACKENDS]u32 = [_]u32{0} ** MAX_BACKENDS,

    /// Record a successful request or health probe to a backend
    /// Resets failure count. If backend was unhealthy, increments success count
    /// and may transition to healthy state after reaching threshold.
    /// Hot path - called on every successful request/probe
    pub inline fn recordSuccess(self: *CircuitBreaker, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;

        self.consecutive_failures[idx] = 0;

        // Fast path: backend is healthy (common case)
        if (self.health.isHealthy(idx)) return;

        // Slow path: backend recovering
        self.consecutive_successes[idx] += 1;
        if (self.consecutive_successes[idx] >= self.config.healthy_threshold) {
            log.info("Backend {d} recovered after {d} consecutive successes", .{
                idx,
                self.consecutive_successes[idx],
            });
            self.health.markHealthy(idx);
            self.consecutive_successes[idx] = 0;
        }
    }

    /// Record a failed request or health probe to a backend
    /// Resets success count. If backend was healthy, increments failure count
    /// and may transition to unhealthy state after reaching threshold.
    /// Hot path - called on every failed request/probe
    pub inline fn recordFailure(self: *CircuitBreaker, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;

        self.consecutive_successes[idx] = 0;
        self.consecutive_failures[idx] += 1;

        if (self.health.isHealthy(idx) and
            self.consecutive_failures[idx] >= self.config.unhealthy_threshold)
        {
            log.warn("Backend {d} marked UNHEALTHY after {d} consecutive failures", .{
                idx,
                self.consecutive_failures[idx],
            });
            self.health.markUnhealthy(idx);
        }
    }

    /// Get current failure count for a backend
    pub fn getFailureCount(self: *const CircuitBreaker, idx: usize) u32 {
        if (idx >= MAX_BACKENDS) return 0;
        return self.consecutive_failures[idx];
    }

    /// Get current success count for a backend
    pub fn getSuccessCount(self: *const CircuitBreaker, idx: usize) u32 {
        if (idx >= MAX_BACKENDS) return 0;
        return self.consecutive_successes[idx];
    }

    /// Check if a backend is healthy
    /// Hot path - inlined, delegates to bitmap check
    pub inline fn isHealthy(self: *const CircuitBreaker, idx: usize) bool {
        return self.health.isHealthy(idx);
    }

    /// Count healthy backends
    /// Uses CPU popcount intrinsic
    pub inline fn countHealthy(self: *const CircuitBreaker) usize {
        return self.health.countHealthy();
    }

    /// Find first healthy backend excluding one
    /// Uses CPU ctz intrinsic
    pub inline fn findHealthyBackend(self: *const CircuitBreaker, exclude_idx: usize) ?usize {
        return self.health.findFirstHealthy(exclude_idx);
    }

    /// Initialize all backends as healthy
    pub fn initBackends(self: *CircuitBreaker, count: usize) void {
        self.health.markAllHealthy(count);
    }

    /// Reset counters for a backend (used after manual health check)
    pub fn resetCounters(self: *CircuitBreaker, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.consecutive_failures[idx] = 0;
        self.consecutive_successes[idx] = 0;
    }

    /// Manually mark a backend healthy and reset counters
    pub fn forceHealthy(self: *CircuitBreaker, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.health.markHealthy(idx);
        self.resetCounters(idx);
    }

    /// Manually mark a backend unhealthy and reset counters
    pub fn forceUnhealthy(self: *CircuitBreaker, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.health.markUnhealthy(idx);
        self.resetCounters(idx);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CircuitBreaker: initial state" {
    const cb = CircuitBreaker{};
    try std.testing.expectEqual(@as(usize, 0), cb.countHealthy());
    try std.testing.expectEqual(@as(u32, 0), cb.getFailureCount(0));
    try std.testing.expectEqual(@as(u32, 0), cb.getSuccessCount(0));
}

test "CircuitBreaker: initBackends marks all healthy" {
    var cb = CircuitBreaker{};
    cb.initBackends(3);
    try std.testing.expectEqual(@as(usize, 3), cb.countHealthy());
    try std.testing.expect(cb.isHealthy(0));
    try std.testing.expect(cb.isHealthy(1));
    try std.testing.expect(cb.isHealthy(2));
    try std.testing.expect(!cb.isHealthy(3));
}

test "CircuitBreaker: recordSuccess on healthy backend" {
    var cb = CircuitBreaker{};
    cb.initBackends(2);

    // Success on healthy backend should reset failures but not affect health
    cb.consecutive_failures[0] = 2;
    cb.recordSuccess(0);

    try std.testing.expect(cb.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 0), cb.getFailureCount(0));
    // Not tracked for healthy backends
    try std.testing.expectEqual(@as(u32, 0), cb.getSuccessCount(0));
}

test "CircuitBreaker: recordFailure transitions to unhealthy at threshold" {
    var cb = CircuitBreaker{
        .config = .{ .unhealthy_threshold = 3 },
    };
    cb.initBackends(2);

    // First two failures: still healthy
    cb.recordFailure(0);
    try std.testing.expect(cb.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 1), cb.getFailureCount(0));

    cb.recordFailure(0);
    try std.testing.expect(cb.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 2), cb.getFailureCount(0));

    // Third failure: transitions to unhealthy
    cb.recordFailure(0);
    try std.testing.expect(!cb.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 3), cb.getFailureCount(0));

    // Other backend unaffected
    try std.testing.expect(cb.isHealthy(1));
}

test "CircuitBreaker: recordSuccess transitions to healthy at threshold" {
    var cb = CircuitBreaker{
        .config = .{ .healthy_threshold = 2 },
    };
    cb.initBackends(1);
    cb.health.markUnhealthy(0); // Start unhealthy

    // First success: not yet healthy
    cb.recordSuccess(0);
    try std.testing.expect(!cb.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 1), cb.getSuccessCount(0));
    try std.testing.expectEqual(@as(u32, 0), cb.getFailureCount(0));

    // Second success: transitions to healthy
    cb.recordSuccess(0);
    try std.testing.expect(cb.isHealthy(0));
    // Reset after transition
    try std.testing.expectEqual(@as(u32, 0), cb.getSuccessCount(0));
}

test "CircuitBreaker: failure resets success count" {
    var cb = CircuitBreaker{
        .config = .{ .healthy_threshold = 3 },
    };
    cb.health.markUnhealthy(0);

    cb.recordSuccess(0);
    cb.recordSuccess(0);
    try std.testing.expectEqual(@as(u32, 2), cb.getSuccessCount(0));

    // Failure resets progress toward recovery
    cb.recordFailure(0);
    try std.testing.expectEqual(@as(u32, 0), cb.getSuccessCount(0));
    try std.testing.expectEqual(@as(u32, 1), cb.getFailureCount(0));
    try std.testing.expect(!cb.isHealthy(0));
}

test "CircuitBreaker: success resets failure count" {
    var cb = CircuitBreaker{
        .config = .{ .unhealthy_threshold = 3 },
    };
    cb.initBackends(1);

    cb.recordFailure(0);
    cb.recordFailure(0);
    try std.testing.expectEqual(@as(u32, 2), cb.getFailureCount(0));

    // Success resets failure progress
    cb.recordSuccess(0);
    try std.testing.expectEqual(@as(u32, 0), cb.getFailureCount(0));
    try std.testing.expect(cb.isHealthy(0));
}

test "CircuitBreaker: already unhealthy backend accumulates failures" {
    var cb = CircuitBreaker{
        .config = .{ .unhealthy_threshold = 2 },
    };
    cb.initBackends(1);

    // Trip the breaker
    cb.recordFailure(0);
    cb.recordFailure(0);
    try std.testing.expect(!cb.isHealthy(0));

    // More failures still accumulate
    cb.recordFailure(0);
    cb.recordFailure(0);
    try std.testing.expectEqual(@as(u32, 4), cb.getFailureCount(0));
    try std.testing.expect(!cb.isHealthy(0));
}

test "CircuitBreaker: findHealthyBackend excludes specified index" {
    var cb = CircuitBreaker{};
    cb.initBackends(3);
    cb.health.markUnhealthy(0); // Only 1 and 2 healthy

    try std.testing.expectEqual(@as(?usize, 1), cb.findHealthyBackend(0));
    try std.testing.expectEqual(@as(?usize, 2), cb.findHealthyBackend(1));
    try std.testing.expectEqual(@as(?usize, 1), cb.findHealthyBackend(2));
}

test "CircuitBreaker: findHealthyBackend returns null when all unhealthy" {
    var cb = CircuitBreaker{};
    try std.testing.expectEqual(@as(?usize, null), cb.findHealthyBackend(0));
}

test "CircuitBreaker: forceHealthy marks healthy and resets" {
    var cb = CircuitBreaker{};
    cb.consecutive_failures[0] = 5;
    cb.consecutive_successes[0] = 3;

    cb.forceHealthy(0);

    try std.testing.expect(cb.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 0), cb.getFailureCount(0));
    try std.testing.expectEqual(@as(u32, 0), cb.getSuccessCount(0));
}

test "CircuitBreaker: forceUnhealthy marks unhealthy and resets" {
    var cb = CircuitBreaker{};
    cb.initBackends(1);
    cb.consecutive_failures[0] = 5;
    cb.consecutive_successes[0] = 3;

    cb.forceUnhealthy(0);

    try std.testing.expect(!cb.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 0), cb.getFailureCount(0));
    try std.testing.expectEqual(@as(u32, 0), cb.getSuccessCount(0));
}

test "CircuitBreaker: out of bounds operations are safe" {
    var cb = CircuitBreaker{};
    cb.initBackends(2);

    // These should not crash
    cb.recordSuccess(64);
    cb.recordSuccess(100);
    cb.recordFailure(64);
    cb.recordFailure(100);
    cb.forceHealthy(64);
    cb.forceUnhealthy(64);

    try std.testing.expectEqual(@as(u32, 0), cb.getFailureCount(64));
    try std.testing.expectEqual(@as(u32, 0), cb.getSuccessCount(64));
    try std.testing.expect(!cb.isHealthy(64));
}

test "CircuitBreaker: threshold of 1 transitions immediately" {
    var cb = CircuitBreaker{
        .config = .{ .unhealthy_threshold = 1, .healthy_threshold = 1 },
    };
    cb.initBackends(1);

    // Single failure trips breaker
    cb.recordFailure(0);
    try std.testing.expect(!cb.isHealthy(0));

    // Single success recovers
    cb.recordSuccess(0);
    try std.testing.expect(cb.isHealthy(0));
}

test "CircuitBreaker: multiple backends independent" {
    var cb = CircuitBreaker{
        .config = .{ .unhealthy_threshold = 2 },
    };
    cb.initBackends(3);

    // Backend 0: 2 failures -> unhealthy
    cb.recordFailure(0);
    cb.recordFailure(0);
    try std.testing.expect(!cb.isHealthy(0));

    // Backend 1: 1 failure -> still healthy
    cb.recordFailure(1);
    try std.testing.expect(cb.isHealthy(1));

    // Backend 2: untouched -> healthy
    try std.testing.expect(cb.isHealthy(2));
    try std.testing.expectEqual(@as(u32, 0), cb.getFailureCount(2));
}

test "CircuitBreaker: recovery requires exact threshold" {
    var cb = CircuitBreaker{
        .config = .{ .healthy_threshold = 3 },
    };
    cb.forceUnhealthy(0);

    cb.recordSuccess(0);
    try std.testing.expect(!cb.isHealthy(0));
    cb.recordSuccess(0);
    try std.testing.expect(!cb.isHealthy(0));
    cb.recordSuccess(0);
    try std.testing.expect(cb.isHealthy(0));
}

test "CircuitBreaker: high threshold values" {
    var cb = CircuitBreaker{
        .config = .{ .unhealthy_threshold = 100, .healthy_threshold = 50 },
    };
    cb.initBackends(1);

    // 99 failures: still healthy
    for (0..99) |_| {
        cb.recordFailure(0);
    }
    try std.testing.expect(cb.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 99), cb.getFailureCount(0));

    // 100th failure: trips
    cb.recordFailure(0);
    try std.testing.expect(!cb.isHealthy(0));

    // 49 successes: still unhealthy
    for (0..49) |_| {
        cb.recordSuccess(0);
    }
    try std.testing.expect(!cb.isHealthy(0));

    // 50th success: recovers
    cb.recordSuccess(0);
    try std.testing.expect(cb.isHealthy(0));
}
