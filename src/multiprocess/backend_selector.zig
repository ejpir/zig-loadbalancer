/// Backend Selector
///
/// Load balancing strategies for selecting backends.
/// Health-aware selection that skips unhealthy backends.
const std = @import("std");

const health_state = @import("health_state.zig");
pub const HealthState = health_state.HealthState;
pub const MAX_BACKENDS = health_state.MAX_BACKENDS;

const types = @import("../core/types.zig");
pub const LoadBalancerStrategy = types.LoadBalancerStrategy;

/// Backend selector with pluggable strategies
pub const BackendSelector = struct {
    health: *const HealthState,
    backend_count: usize = 0,
    rr_counter: usize = 0,
    random_state: u64 = 0,
    /// For weighted round-robin: current weights
    current_weights: [MAX_BACKENDS]i32 = [_]i32{0} ** MAX_BACKENDS,
    /// For weighted round-robin: backend weights (copied from BackendServer)
    weights: [MAX_BACKENDS]u16 = [_]u16{0} ** MAX_BACKENDS,

    /// Select a backend using the specified strategy
    /// Hot path - comptime strategy eliminates switch at compile time
    /// Returns null if no healthy backends are available
    pub inline fn select(self: *BackendSelector, comptime strategy: LoadBalancerStrategy) ?usize {
        if (self.backend_count == 0) return null;

        const healthy_count = self.health.countHealthy();

        // No healthy backends available
        if (healthy_count == 0) return null;

        return switch (strategy) {
            .round_robin => self.selectRoundRobin(),
            .weighted_round_robin => self.selectWeightedRoundRobin(),
            .random => self.selectRandomFast(healthy_count),
            .sticky => 0, // Sticky handled externally via cookies
        };
    }

    /// Round-robin selection among healthy backends
    /// Precondition: at least one healthy backend exists
    fn selectRoundRobin(self: *BackendSelector) usize {
        std.debug.assert(self.health.countHealthy() > 0);
        var attempts: usize = 0;
        while (attempts < self.backend_count) : (attempts += 1) {
            const candidate = (self.rr_counter +% attempts) % self.backend_count;
            if (self.health.isHealthy(candidate)) {
                self.rr_counter = candidate +% 1;
                return candidate;
            }
        }
        // Should never reach here if precondition is met
        unreachable;
    }

    /// Weighted round-robin using Smooth WRR algorithm (Nginx-style)
    /// Provides proportional distribution without bursts
    /// Precondition: at least one healthy backend exists
    fn selectWeightedRoundRobin(self: *BackendSelector) usize {
        std.debug.assert(self.health.countHealthy() > 0);
        std.debug.assert(self.backend_count > 0);

        var total_weight: i32 = 0;
        var selected: usize = 0;
        var max_current_weight: i32 = std.math.minInt(i32);

        // Step 1: Add weight to current_weight for each healthy backend
        // Step 2: Find backend with highest current_weight
        for (0..self.backend_count) |i| {
            if (!self.health.isHealthy(i)) continue;

            const weight: i32 = @intCast(self.weights[i]);
            self.current_weights[i] += weight;
            total_weight += weight;

            if (self.current_weights[i] > max_current_weight) {
                max_current_weight = self.current_weights[i];
                selected = i;
            }
        }

        // Step 3: Subtract total_weight from selected backend
        self.current_weights[selected] -= total_weight;

        return selected;
    }

    /// Fast random selection using bit manipulation
    /// O(popcount) instead of O(backend_count) - uses findNthHealthy
    /// Precondition: random_state must be seeded (non-zero) by caller
    inline fn selectRandomFast(self: *BackendSelector, healthy_count: usize) usize {
        std.debug.assert(healthy_count > 0);
        std.debug.assert(self.random_state != 0); // Must be seeded by WorkerState

        // Simple xorshift PRNG - fast and good enough for load balancing
        self.random_state ^= self.random_state << 13;
        self.random_state ^= self.random_state >> 7;
        self.random_state ^= self.random_state << 17;

        const target = self.random_state % healthy_count;
        return self.health.findNthHealthy(target) orelse 0;
    }

    /// Seed the random state (for testing determinism)
    pub fn seedRandom(self: *BackendSelector, seed: u64) void {
        self.random_state = if (seed == 0) 1 else seed;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BackendSelector: select returns null for zero backends" {
    var health = HealthState{};
    var selector = BackendSelector{ .health = &health, .backend_count = 0 };

    try std.testing.expectEqual(@as(?usize, null), selector.select(.round_robin));
    try std.testing.expectEqual(@as(?usize, null), selector.select(.random));
}

test "BackendSelector: round-robin cycles through healthy backends" {
    var health = HealthState{};
    health.markAllHealthy(3);

    var selector = BackendSelector{ .health = &health, .backend_count = 3 };

    try std.testing.expectEqual(@as(?usize, 0), selector.select(.round_robin));
    try std.testing.expectEqual(@as(?usize, 1), selector.select(.round_robin));
    try std.testing.expectEqual(@as(?usize, 2), selector.select(.round_robin));
    try std.testing.expectEqual(@as(?usize, 0), selector.select(.round_robin));
}

test "BackendSelector: round-robin skips unhealthy backends" {
    var health = HealthState{};
    health.markHealthy(0);
    health.markHealthy(2); // Skip 1

    var selector = BackendSelector{ .health = &health, .backend_count = 3 };

    // Should only hit 0 and 2
    const first = selector.select(.round_robin);
    const second = selector.select(.round_robin);
    const third = selector.select(.round_robin);

    try std.testing.expectEqual(@as(?usize, 0), first);
    try std.testing.expectEqual(@as(?usize, 2), second);
    try std.testing.expectEqual(@as(?usize, 0), third);
}

test "BackendSelector: round-robin with single healthy backend" {
    var health = HealthState{};
    health.markHealthy(2);

    var selector = BackendSelector{ .health = &health, .backend_count = 4 };

    // Should always return 2
    try std.testing.expectEqual(@as(?usize, 2), selector.select(.round_robin));
    try std.testing.expectEqual(@as(?usize, 2), selector.select(.round_robin));
    try std.testing.expectEqual(@as(?usize, 2), selector.select(.round_robin));
}

test "BackendSelector: returns null when all unhealthy" {
    var health = HealthState{}; // All unhealthy (bitmap = 0)

    var selector = BackendSelector{ .health = &health, .backend_count = 3 };

    // Should return null - no healthy backends available
    try std.testing.expectEqual(@as(?usize, null), selector.select(.round_robin));
    try std.testing.expectEqual(@as(?usize, null), selector.select(.random));
}

test "BackendSelector: random only selects healthy backends" {
    var health = HealthState{};
    health.markHealthy(1);
    health.markHealthy(3);

    var selector = BackendSelector{ .health = &health, .backend_count = 5 };
    selector.seedRandom(12345);

    // Run many selections, all should be 1 or 3
    for (0..100) |_| {
        const selected = selector.select(.random) orelse unreachable;
        try std.testing.expect(selected == 1 or selected == 3);
    }
}

test "BackendSelector: random with single healthy backend" {
    var health = HealthState{};
    health.markHealthy(4);

    var selector = BackendSelector{ .health = &health, .backend_count = 5 };
    selector.seedRandom(999);

    // Should always return 4
    for (0..20) |_| {
        try std.testing.expectEqual(@as(?usize, 4), selector.select(.random));
    }
}

test "BackendSelector: random distribution is not constant" {
    var health = HealthState{};
    health.markAllHealthy(10);

    var selector = BackendSelector{ .health = &health, .backend_count = 10 };
    selector.seedRandom(42);

    var counts = [_]usize{0} ** 10;
    for (0..1000) |_| {
        const selected = selector.select(.random) orelse unreachable;
        counts[selected] += 1;
    }

    // Each backend should be selected at least once (statistical certainty)
    for (counts) |count| {
        try std.testing.expect(count > 0);
    }
}

test "BackendSelector: sticky returns backend 0" {
    var health = HealthState{};
    health.markAllHealthy(5);

    var selector = BackendSelector{ .health = &health, .backend_count = 5 };

    // Sticky is placeholder, returns 0
    try std.testing.expectEqual(@as(?usize, 0), selector.select(.sticky));
    try std.testing.expectEqual(@as(?usize, 0), selector.select(.sticky));
}

test "BackendSelector: weighted_round_robin respects weight ratios" {
    var health = HealthState{};
    health.markAllHealthy(2);

    var selector = BackendSelector{
        .health = &health,
        .backend_count = 2,
        .weights = [_]u16{3} ++ [_]u16{1} ++ [_]u16{0} ** 62,
    };

    // With weights [3, 1], we expect 3:1 distribution
    // Smooth WRR gives pattern: 0,0,1,0 repeating
    var counts = [_]usize{0} ** 2;
    for (0..40) |_| {
        const selected = selector.select(.weighted_round_robin) orelse unreachable;
        counts[selected] += 1;
    }

    // Backend 0 should get ~30 requests (75%)
    // Backend 1 should get ~10 requests (25%)
    try std.testing.expect(counts[0] == 30);
    try std.testing.expect(counts[1] == 10);
}

test "BackendSelector: weighted_round_robin skips unhealthy backends" {
    var health = HealthState{};
    health.markHealthy(0);
    health.markHealthy(2);

    var selector = BackendSelector{
        .health = &health,
        .backend_count = 3,
        .weights = [_]u16{2} ++ [_]u16{3} ++ [_]u16{1} ++ [_]u16{0} ** 61,
    };

    // Backend 1 is unhealthy, should only select 0 and 2
    var counts = [_]usize{0} ** 3;
    for (0..30) |_| {
        const selected = selector.select(.weighted_round_robin) orelse unreachable;
        counts[selected] += 1;
    }

    // Should redistribute weight from backend 1
    // Backend 0 (weight 2) and backend 2 (weight 1) = 2:1 ratio
    try std.testing.expect(counts[0] == 20);
    try std.testing.expect(counts[1] == 0);
    try std.testing.expect(counts[2] == 10);
}

test "BackendSelector: weighted_round_robin handles equal weights" {
    var health = HealthState{};
    health.markAllHealthy(3);

    var selector = BackendSelector{
        .health = &health,
        .backend_count = 3,
        .weights = [_]u16{1} ** 3 ++ [_]u16{0} ** 61,
    };

    // Equal weights should distribute evenly
    var counts = [_]usize{0} ** 3;
    for (0..30) |_| {
        const selected = selector.select(.weighted_round_robin) orelse unreachable;
        counts[selected] += 1;
    }

    try std.testing.expect(counts[0] == 10);
    try std.testing.expect(counts[1] == 10);
    try std.testing.expect(counts[2] == 10);
}

test "BackendSelector: weighted_round_robin single backend with high weight" {
    var health = HealthState{};
    health.markHealthy(1);

    var selector = BackendSelector{
        .health = &health,
        .backend_count = 3,
        .weights = [_]u16{0} ++ [_]u16{100} ++ [_]u16{0} ++ [_]u16{0} ** 61,
    };

    // Only backend 1 is healthy, should always return it
    for (0..10) |_| {
        try std.testing.expectEqual(@as(?usize, 1), selector.select(.weighted_round_robin));
    }
}

test "BackendSelector: weighted_round_robin smooth distribution" {
    var health = HealthState{};
    health.markAllHealthy(3);

    var selector = BackendSelector{
        .health = &health,
        .backend_count = 3,
        .weights = [_]u16{5} ++ [_]u16{1} ++ [_]u16{1} ++ [_]u16{0} ** 61,
    };

    // Weights [5,1,1] should give smooth pattern, not bursts
    // Total weight = 7, so every 7 requests: 5 to backend 0, 1 to each of 1 and 2
    var sequence: [14]usize = undefined;
    for (0..14) |i| {
        sequence[i] = selector.select(.weighted_round_robin) orelse unreachable;
    }

    // Count occurrences in first 7 selections
    var counts = [_]usize{0} ** 3;
    for (sequence[0..7]) |idx| {
        counts[idx] += 1;
    }

    try std.testing.expect(counts[0] == 5);
    try std.testing.expect(counts[1] == 1);
    try std.testing.expect(counts[2] == 1);

    // Check it doesn't burst (backend 0 shouldn't appear 5 times consecutively)
    var consecutive_zeros: usize = 0;
    var max_consecutive_zeros: usize = 0;
    for (sequence[0..7]) |idx| {
        if (idx == 0) {
            consecutive_zeros += 1;
            if (consecutive_zeros > max_consecutive_zeros) {
                max_consecutive_zeros = consecutive_zeros;
            }
        } else {
            consecutive_zeros = 0;
        }
    }
    // Smooth WRR ensures no backend gets all its requests consecutively
    try std.testing.expect(max_consecutive_zeros < 5);
}

test "BackendSelector: rr_counter wraps around" {
    var health = HealthState{};
    health.markAllHealthy(2);

    var selector = BackendSelector{
        .health = &health,
        .backend_count = 2,
        .rr_counter = std.math.maxInt(usize) - 1,
    };

    _ = selector.select(.round_robin);
    _ = selector.select(.round_robin);
    // Should wrap without panic
    _ = selector.select(.round_robin);
    _ = selector.select(.round_robin);
}

test "BackendSelector: health state changes affect selection" {
    var health = HealthState{};
    health.markAllHealthy(3);

    var selector = BackendSelector{ .health = &health, .backend_count = 3 };

    try std.testing.expectEqual(@as(?usize, 0), selector.select(.round_robin));
    try std.testing.expectEqual(@as(?usize, 1), selector.select(.round_robin));

    // Mark 2 unhealthy mid-sequence
    health.markUnhealthy(2);

    try std.testing.expectEqual(@as(?usize, 0), selector.select(.round_robin));
    try std.testing.expectEqual(@as(?usize, 1), selector.select(.round_robin));
    // Backend 2 skipped
    try std.testing.expectEqual(@as(?usize, 0), selector.select(.round_robin));
}

test "BackendSelector: large backend count" {
    var health = HealthState{};
    health.markAllHealthy(64);

    var selector = BackendSelector{ .health = &health, .backend_count = 64 };

    // Should cycle through all 64
    for (0..64) |i| {
        try std.testing.expectEqual(@as(?usize, i), selector.select(.round_robin));
    }
    // Back to 0
    try std.testing.expectEqual(@as(?usize, 0), selector.select(.round_robin));
}

test "BackendSelector: sparse healthy backends" {
    var health = HealthState{};
    health.markHealthy(0);
    health.markHealthy(31);
    health.markHealthy(63);

    var selector = BackendSelector{ .health = &health, .backend_count = 64 };

    // Random should only hit these three
    selector.seedRandom(777);
    for (0..50) |_| {
        const selected = selector.select(.random) orelse unreachable;
        try std.testing.expect(selected == 0 or selected == 31 or selected == 63);
    }
}
