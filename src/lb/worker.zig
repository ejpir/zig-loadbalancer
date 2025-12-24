/// Worker State
///
/// Composite state for a single-threaded worker process.
/// Combines health tracking, circuit breaker, backend selection,
/// and connection pooling.
const std = @import("std");
const posix = std.posix;

const config_mod = @import("../core/config.zig");
const types = @import("../core/types.zig");
const metrics = @import("../metrics/mod.zig");
const simple_pool = @import("../memory/pool.zig");
const shared_region = @import("../memory/shared_region.zig");
const H2ConnectionPool = @import("../http/http2/pool.zig").H2ConnectionPool;

pub const circuit_breaker = @import("../health/circuit_breaker.zig");
pub const backend_selector = @import("selector.zig");

/// Get current time in milliseconds using monotonic clock
fn currentTimeMillis() i64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub const SharedHealthState = shared_region.SharedHealthState;
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
pub const BackendSelector = backend_selector.BackendSelector;
pub const MAX_BACKENDS = shared_region.MAX_BACKENDS;

/// Configuration for worker state (uses defaults from config.zig)
pub const Config = struct {
    circuit_breaker_config: circuit_breaker.Config = .{},
    probe_interval_ms: u64 = config_mod.DEFAULT_PROBE_INTERVAL_MS,
    probe_timeout_ms: u64 = config_mod.DEFAULT_PROBE_TIMEOUT_MS,
    health_path: []const u8 = config_mod.DEFAULT_HEALTH_PATH,

    pub fn unhealthy_threshold(self: Config) u32 {
        return self.circuit_breaker_config.unhealthy_threshold;
    }
    pub fn healthy_threshold(self: Config) u32 {
        return self.circuit_breaker_config.healthy_threshold;
    }
};

/// Complete worker state for request handling
pub const WorkerState = struct {
    // Legacy: local backends list (used in single-process mode and tests)
    backends: *const types.BackendsList,
    // Shared region for hot reload (null in single-process mode)
    shared_region: ?*shared_region.SharedRegion = null,
    connection_pool: *simple_pool.SimpleConnectionPool,
    // HTTP/2 connection pool (TigerBeetle style)
    h2_pool: ?*H2ConnectionPool = null,
    // Allocator for HTTP/2 pooled connections
    allocator: std.mem.Allocator = std.heap.page_allocator,
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

    /// Initialize worker state with backends and shared health state
    pub fn init(
        backends: *const types.BackendsList,
        pool: *simple_pool.SimpleConnectionPool,
        health: *SharedHealthState,
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
                .health = health,
                .config = config.circuit_breaker_config,
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

    /// Set shared region for hot reload support
    pub fn setSharedRegion(self: *WorkerState, region: *shared_region.SharedRegion) void {
        self.shared_region = region;
    }

    /// Get active backend count (from shared region if available)
    pub fn getBackendCount(self: *const WorkerState) usize {
        if (self.shared_region) |region| {
            return region.control.getBackendCount();
        }
        return self.backends.items.len;
    }

    /// Get shared backend by index (from shared region)
    pub fn getSharedBackend(self: *const WorkerState, idx: usize) ?*const shared_region.SharedBackend {
        if (self.shared_region) |region| {
            const active = region.getActiveBackends();
            if (idx < region.control.getBackendCount()) {
                return &active[idx];
            }
            return null;
        }
        return null;
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
        // Use dynamic backend count from shared region if available
        const backend_count = self.getBackendCount();
        std.debug.assert(backend_count <= MAX_BACKENDS);
        if (backend_count == 0) return null;

        // For round-robin with shared region, use shared atomic counter
        // This ensures even distribution across all workers
        const rr_start: usize = if (strategy == .round_robin and self.shared_region != null)
            self.shared_region.?.control.getNextRoundRobin()
        else
            self.rr_state;

        var selector = BackendSelector{
            .health = self.circuit_breaker.health,
            .backend_count = backend_count,
            .rr_counter = rr_start,
            .random_state = self.random_state,
        };

        // Copy backend weights for weighted round-robin
        if (strategy == .weighted_round_robin) {
            if (self.shared_region) |region| {
                const active = region.getActiveBackends();
                for (0..backend_count) |i| {
                    selector.weights[i] = active[i].weight;
                }
            } else {
                for (self.backends.items, 0..) |backend, i| {
                    selector.weights[i] = backend.weight;
                }
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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    const state = WorkerState.init(&backends, &pool, &health, .{});

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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{});

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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{});

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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{});

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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{ .circuit_breaker_config = .{ .unhealthy_threshold = 2 } });

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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{ .circuit_breaker_config = .{ .healthy_threshold = 2 } });
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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{});
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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    const state = WorkerState.init(&backends, &pool, &health, .{});

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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{});

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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    const state = WorkerState.init(&backends, &pool, &health, .{});

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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{});
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

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{});

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
    var health1 = SharedHealthState{};
    health1.markAllUnhealthy();
    var health2 = SharedHealthState{};
    health2.markAllUnhealthy();
    var state1 = WorkerState.init(&backends, &pool, &health1, .{});
    var state2 = WorkerState.init(&backends, &pool, &health2, .{});

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

test "WorkerState: getBackendCount uses shared region when set" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    // Local backends: 2
    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));
    try backends.append(allocator, types.BackendServer.init(host, 8002, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{});

    // Without shared region, uses local backends count
    try std.testing.expectEqual(@as(usize, 2), state.getBackendCount());

    // Set up shared region with 3 backends
    var region = shared_region.SharedRegion{};
    var inactive = region.getInactiveBackends();
    inactive[0].setHost("a.com");
    inactive[0].port = 80;
    inactive[1].setHost("b.com");
    inactive[1].port = 81;
    inactive[2].setHost("c.com");
    inactive[2].port = 82;
    _ = region.control.switchActiveArray(3);

    // With shared region, uses shared region count
    state.setSharedRegion(&region);
    try std.testing.expectEqual(@as(usize, 3), state.getBackendCount());
}

test "WorkerState: getSharedBackend returns null without shared region" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    const state = WorkerState.init(&backends, &pool, &health, .{});

    // Without shared region, getSharedBackend returns null
    try std.testing.expectEqual(@as(?*const shared_region.SharedBackend, null), state.getSharedBackend(0));
}

test "WorkerState: getSharedBackend returns backend from shared region" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{});

    // Set up shared region
    var region = shared_region.SharedRegion{};
    var inactive = region.getInactiveBackends();
    inactive[0].setHost("shared-backend.com");
    inactive[0].port = 9000;
    _ = region.control.switchActiveArray(1);

    state.setSharedRegion(&region);

    // Should return shared backend
    const backend = state.getSharedBackend(0);
    try std.testing.expect(backend != null);
    try std.testing.expectEqualStrings("shared-backend.com", backend.?.getHost());
    try std.testing.expectEqual(@as(u16, 9000), backend.?.port);

    // Out of bounds returns null
    try std.testing.expectEqual(@as(?*const shared_region.SharedBackend, null), state.getSharedBackend(1));
}
