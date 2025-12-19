/// Component Integration Tests
///
/// Tests that verify multiprocess components work correctly together:
/// - WorkerState + BackendSelector + CircuitBreaker interactions
/// - Health probing + circuit breaker coordination
/// - Request distribution across multiple backends
///
/// These tests simulate real usage patterns without requiring actual backends.
/// For full end-to-end tests with real HTTP, see tests/integration_test.zig
const std = @import("std");

const types = @import("../core/types.zig");
const simple_pool = @import("../memory/pool.zig");
const worker_state = @import("../lb/worker.zig");
const WorkerState = worker_state.WorkerState;
const SharedHealthState = worker_state.SharedHealthState;

/// Simulates the proxy handler's request flow
fn simulateRequest(state: *WorkerState, comptime strategy: types.LoadBalancerStrategy) ?usize {
    // This mirrors what proxy.zig does:
    // 1. Select backend
    // 2. (proxy to backend - not simulated)
    // 3. Record success/failure

    const backend_idx = state.selectBackend(strategy) orelse return null;
    // Test focuses on selection logic, not actual backend interaction
    state.recordSuccess(backend_idx);
    return backend_idx;
}

test "integration: round-robin distributes requests evenly" {
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

    // Verify even distribution across all backends
    var counts = [_]usize{0} ** 3;
    const num_requests = 99; // Evenly divisible to test perfect distribution

    for (0..num_requests) |_| {
        const backend = simulateRequest(&state, .round_robin) orelse unreachable;
        counts[backend] += 1;
    }

    // Round-robin guarantees equal distribution
    try std.testing.expectEqual(@as(usize, 33), counts[0]);
    try std.testing.expectEqual(@as(usize, 33), counts[1]);
    try std.testing.expectEqual(@as(usize, 33), counts[2]);

    // Ensure selector increments counter correctly
    try std.testing.expectEqual(@as(usize, 99), state.getRequestCount());
}

test "integration: failover redirects to healthy backend" {
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
    var state = WorkerState.init(&backends, &pool, &health, .{ .unhealthy_threshold = 2 });

    // Trigger circuit breaker with consecutive failures
    _ = state.selectBackend(.round_robin);
    state.recordFailure(0);
    _ = state.selectBackend(.round_robin);
    state.recordFailure(0);

    try std.testing.expect(!state.isHealthy(0));
    try std.testing.expect(state.isHealthy(1));

    // Failover prevents routing to unhealthy backend
    for (0..10) |_| {
        const backend = state.selectBackend(.round_robin) orelse unreachable;
        try std.testing.expectEqual(@as(usize, 1), backend);
    }
}

test "integration: recovery after consecutive successes" {
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
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 2,
        .healthy_threshold = 3,
    });

    // Trigger circuit breaker with consecutive failures
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // Recovery requires meeting threshold
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));

    // Threshold met; backend returns to service
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));
}

test "integration: request count tracks actual requests" {
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

    try std.testing.expectEqual(@as(usize, 0), state.getRequestCount());

    // Verify counter increments atomically per selection
    for (1..101) |i| {
        _ = state.selectBackend(.round_robin);
        try std.testing.expectEqual(i, state.getRequestCount());
    }
}

test "integration: all backends unhealthy returns null" {
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
    var state = WorkerState.init(&backends, &pool, &health, .{ .unhealthy_threshold = 1 });

    // Trigger circuit breaker on all backends
    state.recordFailure(0);
    state.recordFailure(1);
    state.recordFailure(2);

    try std.testing.expect(!state.isHealthy(0));
    try std.testing.expect(!state.isHealthy(1));
    try std.testing.expect(!state.isHealthy(2));
    try std.testing.expectEqual(@as(usize, 0), state.countHealthy());

    // No healthy backends available for routing
    const result = state.selectBackend(.round_robin);
    try std.testing.expect(result == null);
}

test "integration: failure during recovery resets success counter" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 2,
        .healthy_threshold = 3,
    });

    // Trigger circuit breaker with consecutive failures
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // Begin recovery with partial successes
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));

    // Failure resets success counter to prevent premature recovery
    state.recordFailure(0);

    // Must meet full threshold again after reset
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));
}

test "integration: single backend down and recovery" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 2,
        .healthy_threshold = 2,
    });

    // Verify initial healthy state
    try std.testing.expect(state.selectBackend(.round_robin) != null);

    // Trigger circuit breaker with consecutive failures
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // All backends unhealthy; requests cannot be routed
    try std.testing.expect(state.selectBackend(.round_robin) == null);

    // Meet recovery threshold to restore service
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));

    // Service restored after recovery
    try std.testing.expect(state.selectBackend(.round_robin) != null);
}

test "integration: mixed success/failure pattern" {
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
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 3,
        .healthy_threshold = 2,
    });

    // Simulate realistic pattern: mostly successes with occasional failures
    // Backend 0: success, success, fail, success, success, fail, fail, fail -> unhealthy
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));

    state.recordFailure(0);
    try std.testing.expect(state.isHealthy(0));

    // Success resets failure counter to prevent spurious trips
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));

    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));

    // Consecutive failures trigger circuit breaker
    state.recordFailure(0);
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // Only healthy backend receives all traffic
    for (0..5) |_| {
        const selected = state.selectBackend(.round_robin);
        try std.testing.expectEqual(@as(?usize, 1), selected);
    }
}

test "integration: findHealthyBackend for failover excludes current" {
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

    // Failover must skip the failed backend
    const failover1 = state.findHealthyBackend(0);
    try std.testing.expect(failover1 != null);
    try std.testing.expect(failover1.? != 0);

    // Remove backend 1 from available pool
    state.forceUnhealthy(1);

    // Failover skips both excluded and unhealthy backends
    const failover2 = state.findHealthyBackend(0);
    try std.testing.expectEqual(@as(?usize, 2), failover2);

    // Remove backend 2 from available pool
    state.forceUnhealthy(2);

    // No failover target when all alternatives are unhealthy
    const failover3 = state.findHealthyBackend(0);
    try std.testing.expect(failover3 == null);
}

// ============================================================================
// Unified Health Probe + Circuit Breaker Tests
// ============================================================================

test "integration: unified health - probe success recovers circuit-breaker-tripped backend" {
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
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 3,
        .healthy_threshold = 2,
    });

    // Backend goes down due to request failures
    state.recordFailure(0);
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 3), state.circuit_breaker.getFailureCount(0));

    // Health probe detects recovery - simulating probe success
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 1), state.circuit_breaker.getSuccessCount(0));
    try std.testing.expectEqual(@as(u32, 0), state.circuit_breaker.getFailureCount(0));

    // Second probe success recovers backend
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 0), state.circuit_breaker.getSuccessCount(0));

    // Real requests now routed to recovered backend
    const selected = state.selectBackend(.round_robin);
    try std.testing.expect(selected != null);
}

test "integration: unified health - probe failure trips circuit breaker" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 3,
    });

    // Backend is healthy
    try std.testing.expect(state.isHealthy(0));

    // Health probe detects failures - simulating probe failures
    state.recordFailure(0);
    try std.testing.expect(state.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 1), state.circuit_breaker.getFailureCount(0));

    state.recordFailure(0);
    try std.testing.expect(state.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 2), state.circuit_breaker.getFailureCount(0));

    // Third probe failure trips circuit breaker
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 3), state.circuit_breaker.getFailureCount(0));

    // No backends available for requests
    const selected = state.selectBackend(.round_robin);
    try std.testing.expect(selected == null);
}

test "integration: unified health - no state disagreement" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 2,
        .healthy_threshold = 2,
    });

    // Request failures trip circuit breaker
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // Probe success counts toward recovery
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 1), state.circuit_breaker.getSuccessCount(0));

    // Request success completes recovery (mixed probe+request)
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));

    // No disagreement - single source of truth
    try std.testing.expectEqual(@as(u32, 0), state.circuit_breaker.getFailureCount(0));
    try std.testing.expectEqual(@as(u32, 0), state.circuit_breaker.getSuccessCount(0));
}

test "integration: unified health - probe and request failures both count toward threshold" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 3,
    });

    // Mix of probe and request failures
    state.recordFailure(0); // probe failure
    try std.testing.expect(state.isHealthy(0));

    state.recordFailure(0); // request failure
    try std.testing.expect(state.isHealthy(0));

    state.recordFailure(0); // probe failure
    try std.testing.expect(!state.isHealthy(0));

    // All failures counted equally, threshold reached
    try std.testing.expectEqual(@as(u32, 3), state.circuit_breaker.getFailureCount(0));
}

test "integration: unified health - probe success during healthy doesn't affect counters" {
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

    // Backend starts healthy
    try std.testing.expect(state.isHealthy(0));

    // Probe successes on healthy backend don't accumulate success count
    state.recordSuccess(0);
    state.recordSuccess(0);
    state.recordSuccess(0);

    try std.testing.expect(state.isHealthy(0));
    try std.testing.expectEqual(@as(u32, 0), state.circuit_breaker.getSuccessCount(0));
    try std.testing.expectEqual(@as(u32, 0), state.circuit_breaker.getFailureCount(0));
}

test "integration: unified health - probe failure resets success progress" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    defer pool.deinit();

    var health = SharedHealthState{};
    health.markAllUnhealthy();
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 2,
        .healthy_threshold = 3,
    });

    // Trip circuit breaker
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // Begin recovery with probe successes
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expectEqual(@as(u32, 2), state.circuit_breaker.getSuccessCount(0));
    try std.testing.expect(!state.isHealthy(0));

    // Probe failure resets progress
    state.recordFailure(0);
    try std.testing.expectEqual(@as(u32, 0), state.circuit_breaker.getSuccessCount(0));
    try std.testing.expectEqual(@as(u32, 1), state.circuit_breaker.getFailureCount(0));

    // Must restart recovery from scratch
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));
}

test "integration: unified health - mixed probe and request recovery" {
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
    var state = WorkerState.init(&backends, &pool, &health, .{
        .unhealthy_threshold = 3,
        .healthy_threshold = 2,
    });

    // Backend 0 goes down via request failures
    state.recordFailure(0);
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // All traffic goes to backend 1
    for (0..5) |_| {
        const selected = state.selectBackend(.round_robin);
        try std.testing.expectEqual(@as(?usize, 1), selected);
    }

    // Probe detects backend 0 recovering
    state.recordSuccess(0); // probe success
    try std.testing.expect(!state.isHealthy(0));

    // Real request completes recovery
    state.recordSuccess(0); // request success
    try std.testing.expect(state.isHealthy(0));

    // Traffic now distributed across both backends
    try std.testing.expectEqual(@as(?usize, 0), state.selectBackend(.round_robin));
    try std.testing.expectEqual(@as(?usize, 1), state.selectBackend(.round_robin));
    try std.testing.expectEqual(@as(?usize, 0), state.selectBackend(.round_robin));
}
