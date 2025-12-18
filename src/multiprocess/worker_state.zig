/// Worker State
///
/// Composite state for a single-threaded worker process.
/// Combines health tracking, circuit breaker, backend selection,
/// and connection pooling.
const std = @import("std");
const posix = std.posix;

const types = @import("../core/types.zig");
const metrics = @import("../utils/metrics.zig");

/// Get current time in milliseconds using monotonic clock
fn currentTimeMillis() i64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
const simple_pool = @import("../memory/simple_connection_pool.zig");

pub const health_state = @import("health_state.zig");
pub const circuit_breaker = @import("circuit_breaker.zig");
pub const backend_selector = @import("backend_selector.zig");

pub const HealthState = health_state.HealthState;
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
pub const BackendSelector = backend_selector.BackendSelector;
pub const MAX_BACKENDS = health_state.MAX_BACKENDS;

/// Configuration for worker state
pub const Config = struct {
    /// Consecutive failures before marking unhealthy
    unhealthy_threshold: u32 = 3,
    /// Consecutive successes before marking healthy
    healthy_threshold: u32 = 2,
    /// Health probe interval in milliseconds
    probe_interval_ms: u64 = 5000,
    /// Health probe timeout in milliseconds
    probe_timeout_ms: u64 = 2000,
    /// Health check path
    health_path: []const u8 = "/",
};

/// Complete worker state for request handling
pub const WorkerState = struct {
    backends: *const types.BackendsList,
    connection_pool: *simple_pool.SimpleConnectionPool,
    circuit_breaker: CircuitBreaker,
    config: Config,
    worker_id: usize = 0,

    // Round-robin state (not a counter - tracks next backend to try)
    rr_state: usize = 0,
    // Actual request count for metrics
    total_requests: usize = 0,
    last_check_time: [MAX_BACKENDS]i64 = [_]i64{0} ** MAX_BACKENDS,
    // Random state for load balancing (seeded once at init)
    random_state: u64 = 0,

    /// Initialize worker state with backends
    pub fn init(
        backends: *const types.BackendsList,
        pool: *simple_pool.SimpleConnectionPool,
        config: Config,
    ) WorkerState {
        // Seed random state from monotonic clock
        const seed = blk: {
            if (posix.clock_gettime(.MONOTONIC)) |ts| {
                const nsec = @as(u64, @intCast(ts.nsec));
                const sec = @as(u64, @intCast(ts.sec));
                break :blk nsec ^ sec;
            } else |_| {
                break :blk 12345; // Fallback seed
            }
        };

        var state = WorkerState{
            .backends = backends,
            .connection_pool = pool,
            .circuit_breaker = .{
                .config = .{
                    .unhealthy_threshold = config.unhealthy_threshold,
                    .healthy_threshold = config.healthy_threshold,
                },
            },
            .config = config,
            .random_state = if (seed == 0) 1 else seed,
        };

        // Mark all backends healthy initially
        state.circuit_breaker.initBackends(backends.items.len);

        // Initialize backend health metrics
        const backend_count: u32 = @intCast(backends.items.len);
        metrics.global_metrics.updateBackendHealth(backend_count, 0);

        return state;
    }

    /// Set worker ID (called from main after init)
    /// Also mixes worker_id into random_state for unique sequences per worker
    pub fn setWorkerId(self: *WorkerState, id: usize) void {
        self.worker_id = id;
        // Mix worker_id into the high bits to ensure different workers get different sequences
        const id_bits: u64 = @intCast(id);
        self.random_state ^= (id_bits << 32);
        // Ensure non-zero
        if (self.random_state == 0) self.random_state = 1;
    }

    /// Select a backend using the specified strategy
    /// Hot path - comptime strategy enables zero-cost abstraction
    pub inline fn selectBackend(
        self: *WorkerState,
        comptime strategy: types.LoadBalancerStrategy,
    ) ?usize {
        std.debug.assert(self.backends.items.len <= MAX_BACKENDS);
        if (self.backends.items.len == 0) return null;

        var selector = BackendSelector{
            .health = &self.circuit_breaker.health,
            .backend_count = self.backends.items.len,
            .rr_counter = self.rr_state,
            .random_state = self.random_state,
        };

        // Copy backend weights for weighted round-robin
        if (strategy == .weighted_round_robin) {
            for (self.backends.items, 0..) |backend, i| {
                selector.weights[i] = backend.weight;
            }
        }

        const selected = selector.select(strategy);

        // Update state (round-robin counter, random state) and request count
        self.rr_state = selector.rr_counter;
        self.random_state = selector.random_state;
        self.total_requests +%= 1;

        return selected;
    }

    /// Record a successful request
    /// Hot path - inlined
    pub inline fn recordSuccess(self: *WorkerState, backend_idx: usize) void {
        const was_healthy = self.circuit_breaker.isHealthy(backend_idx);
        self.circuit_breaker.recordSuccess(backend_idx);

        // Update metrics if health state changed (backend recovered)
        if (!was_healthy and self.circuit_breaker.isHealthy(backend_idx)) {
            self.updateHealthMetrics();
        }
    }

    /// Record a failed request
    /// Hot path - inlined
    pub inline fn recordFailure(self: *WorkerState, backend_idx: usize) void {
        const was_healthy = self.circuit_breaker.isHealthy(backend_idx);
        self.circuit_breaker.recordFailure(backend_idx);

        // Update metrics if health state changed (backend failed)
        if (was_healthy and !self.circuit_breaker.isHealthy(backend_idx)) {
            self.updateHealthMetrics();
        }
    }

    /// Update backend health metrics
    fn updateHealthMetrics(self: *const WorkerState) void {
        const total = self.backends.items.len;
        const healthy = self.circuit_breaker.countHealthy();
        const unhealthy = if (total > healthy) total - healthy else 0;
        const healthy_u32: u32 = @intCast(healthy);
        const unhealthy_u32: u32 = @intCast(unhealthy);
        metrics.global_metrics.updateBackendHealth(healthy_u32, unhealthy_u32);
    }

    /// Check if a backend is healthy
    /// Hot path - inlined, single bitmap check
    pub inline fn isHealthy(self: *const WorkerState, backend_idx: usize) bool {
        return self.circuit_breaker.isHealthy(backend_idx);
    }

    /// Count healthy backends
    /// Uses CPU popcount intrinsic
    pub inline fn countHealthy(self: *const WorkerState) usize {
        return self.circuit_breaker.countHealthy();
    }

    /// Find a healthy backend for failover, excluding the specified one
    /// Uses CPU ctz intrinsic
    pub inline fn findHealthyBackend(self: *const WorkerState, exclude_idx: usize) ?usize {
        return self.circuit_breaker.findHealthyBackend(exclude_idx);
    }

    /// Get backend by index
    pub fn getBackend(self: *const WorkerState, idx: usize) ?*const types.BackendServer {
        std.debug.assert(self.backends.items.len <= MAX_BACKENDS);
        if (idx >= self.backends.items.len) return null;
        return &self.backends.items[idx];
    }

    /// Get total requests processed (for metrics)
    pub fn getRequestCount(self: *const WorkerState) usize {
        return self.total_requests;
    }

    /// Check if it's time to probe a backend
    pub fn shouldProbe(self: *const WorkerState, backend_idx: usize) bool {
        if (backend_idx >= MAX_BACKENDS) return false;
        const now = currentTimeMillis();
        const last = self.last_check_time[backend_idx];
        const interval: i64 = @intCast(self.config.probe_interval_ms);
        return (now - last) >= interval;
    }

    /// Update last probe time
    pub fn updateProbeTime(self: *WorkerState, backend_idx: usize) void {
        if (backend_idx >= MAX_BACKENDS) return;
        self.last_check_time[backend_idx] = currentTimeMillis();
    }

    /// Force a backend healthy (manual override)
    pub fn forceHealthy(self: *WorkerState, backend_idx: usize) void {
        self.circuit_breaker.forceHealthy(backend_idx);
    }

    /// Force a backend unhealthy (manual override)
    pub fn forceUnhealthy(self: *WorkerState, backend_idx: usize) void {
        self.circuit_breaker.forceUnhealthy(backend_idx);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WorkerState: initialization marks all backends healthy" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8002, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8003, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    const state = WorkerState.init(&backends, &pool, .{});

    try std.testing.expectEqual(@as(usize, 3), state.countHealthy());
    try std.testing.expect(state.isHealthy(0));
    try std.testing.expect(state.isHealthy(1));
    try std.testing.expect(state.isHealthy(2));
}

test "WorkerState: selectBackend round-robin" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8002, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});

    try std.testing.expectEqual(@as(?usize, 0), state.selectBackend(.round_robin));
    try std.testing.expectEqual(@as(?usize, 1), state.selectBackend(.round_robin));
    try std.testing.expectEqual(@as(?usize, 0), state.selectBackend(.round_robin));
}

test "WorkerState: round-robin counter increments correctly" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8002, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});

    // Counter starts at 0
    try std.testing.expectEqual(@as(usize, 0), state.getRequestCount());

    // After first selection, counter should be 1
    _ = state.selectBackend(.round_robin);
    try std.testing.expectEqual(@as(usize, 1), state.getRequestCount());

    // After second selection, counter should be 2
    _ = state.selectBackend(.round_robin);
    try std.testing.expectEqual(@as(usize, 2), state.getRequestCount());

    // Verify alternating pattern over many requests
    for (0..10) |i| {
        // +2 offset because we already did 2 selections above
        const expected_backend = (i + 2) % 2;
        const selected = state.selectBackend(.round_robin);
        try std.testing.expectEqual(@as(?usize, expected_backend), selected);
    }
    try std.testing.expectEqual(@as(usize, 12), state.getRequestCount());
}

test "WorkerState: selectBackend skips unhealthy" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8002, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8003, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});

    // Force backend 1 unhealthy
    state.forceUnhealthy(1);

    // Should skip 1
    try std.testing.expectEqual(@as(?usize, 0), state.selectBackend(.round_robin));
    try std.testing.expectEqual(@as(?usize, 2), state.selectBackend(.round_robin));
    try std.testing.expectEqual(@as(?usize, 0), state.selectBackend(.round_robin));
}

test "WorkerState: recordFailure trips circuit breaker" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{ .unhealthy_threshold = 2 });

    try std.testing.expect(state.isHealthy(0));

    state.recordFailure(0);
    try std.testing.expect(state.isHealthy(0));

    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));
}

test "WorkerState: recordSuccess recovers backend" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{ .healthy_threshold = 2 });
    state.forceUnhealthy(0);

    try std.testing.expect(!state.isHealthy(0));

    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));

    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));
}

test "WorkerState: findHealthyBackend for failover" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8002, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8003, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});
    state.forceUnhealthy(0);

    // Exclude 1, should find 2
    try std.testing.expectEqual(@as(?usize, 2), state.findHealthyBackend(1));

    // Exclude 2, should find 1
    try std.testing.expectEqual(@as(?usize, 1), state.findHealthyBackend(2));

    // Exclude 0 (unhealthy anyway), should find 1
    try std.testing.expectEqual(@as(?usize, 1), state.findHealthyBackend(0));
}

test "WorkerState: getBackend bounds check" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    const state = WorkerState.init(&backends, &pool, .{});

    try std.testing.expect(state.getBackend(0) != null);
    try std.testing.expect(state.getBackend(1) == null);
    try std.testing.expect(state.getBackend(100) == null);
}

test "WorkerState: empty backends" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});

    try std.testing.expect(state.selectBackend(.round_robin) == null);
    try std.testing.expectEqual(@as(usize, 0), state.countHealthy());
}

test "WorkerState: random_state initialized on init" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    const state = WorkerState.init(&backends, &pool, .{});

    // Random state should be non-zero after init
    try std.testing.expect(state.random_state != 0);
}

test "WorkerState: random_state persists across selections" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8002, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8003, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});
    const initial_state = state.random_state;

    // Make a random selection
    _ = state.selectBackend(.random);

    // Random state should have changed (xorshift updated it)
    try std.testing.expect(state.random_state != initial_state);
    try std.testing.expect(state.random_state != 0);

    const second_state = state.random_state;

    // Make another selection
    _ = state.selectBackend(.random);

    // State should change again
    try std.testing.expect(state.random_state != second_state);
    try std.testing.expect(state.random_state != 0);
}

test "WorkerState: random selection produces varied results" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    for (0..10) |port| {
        try backends.append(allocator, types.BackendServer.init(host, 8000 + @as(u16, @intCast(port)), 1));
    }

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});

    // Run many selections and verify distribution
    var counts = [_]usize{0} ** 10;
    for (0..1000) |_| {
        const selected = state.selectBackend(.random) orelse unreachable;
        counts[selected] += 1;
    }

    // Each backend should be selected at least once (statistical certainty)
    for (counts) |count| {
        try std.testing.expect(count > 0);
    }
}

test "WorkerState: different worker_ids produce different random sequences" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    for (0..5) |port| {
        try backends.append(allocator, types.BackendServer.init(host, 8000 + @as(u16, @intCast(port)), 1));
    }

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    // Create two workers with same initial seed but different IDs
    var state1 = WorkerState.init(&backends, &pool, .{});
    var state2 = WorkerState.init(&backends, &pool, .{});

    // Set different worker IDs
    state1.setWorkerId(1);
    state2.setWorkerId(2);

    // Their random states should be different after setWorkerId
    try std.testing.expect(state1.random_state != state2.random_state);

    // Generate sequences from both
    var seq1: [20]usize = undefined;
    var seq2: [20]usize = undefined;

    for (0..20) |i| {
        seq1[i] = state1.selectBackend(.random) orelse unreachable;
        seq2[i] = state2.selectBackend(.random) orelse unreachable;
    }

    // Sequences should differ (extremely unlikely to be identical)
    var differences: usize = 0;
    for (seq1, seq2) |s1, s2| {
        if (s1 != s2) differences += 1;
    }

    // Expect at least some differences
    try std.testing.expect(differences > 0);
}
