/// Integration Tests
///
/// Tests that verify components work correctly together,
/// simulating real usage patterns rather than isolated unit behavior.
const std = @import("std");

const types = @import("../core/types.zig");
const simple_pool = @import("../memory/simple_connection_pool.zig");
const WorkerState = @import("worker_state.zig").WorkerState;

/// Simulates the proxy handler's request flow
fn simulateRequest(state: *WorkerState, comptime strategy: types.LoadBalancerStrategy) ?usize {
    // This mirrors what proxy.zig does:
    // 1. Select backend
    // 2. (proxy to backend - not simulated)
    // 3. Record success/failure

    const backend_idx = state.selectBackend(strategy) orelse return null;
    // Simulate success
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
    pool.init();
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});

    // Track which backends were selected
    var counts = [_]usize{0} ** 3;
    const num_requests = 99; // Divisible by 3

    for (0..num_requests) |_| {
        const backend = simulateRequest(&state, .round_robin) orelse unreachable;
        counts[backend] += 1;
    }

    // Each backend should get exactly 1/3 of requests
    try std.testing.expectEqual(@as(usize, 33), counts[0]);
    try std.testing.expectEqual(@as(usize, 33), counts[1]);
    try std.testing.expectEqual(@as(usize, 33), counts[2]);

    // Request count should match
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
    pool.init();
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{ .unhealthy_threshold = 2 });

    // Simulate: backend 0 fails twice, trips circuit breaker
    _ = state.selectBackend(.round_robin); // selects 0
    state.recordFailure(0);
    _ = state.selectBackend(.round_robin); // selects 1
    state.recordFailure(0); // backend 0 now unhealthy

    try std.testing.expect(!state.isHealthy(0));
    try std.testing.expect(state.isHealthy(1));

    // Now all requests should go to backend 1
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
    pool.init();
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{
        .unhealthy_threshold = 2,
        .healthy_threshold = 3,
    });

    // Trip circuit breaker on backend 0
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // 2 successes: still unhealthy
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));

    // 3rd success: recovered
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
    pool.init();
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});

    try std.testing.expectEqual(@as(usize, 0), state.getRequestCount());

    // Each selectBackend should increment count by exactly 1
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
    pool.init();
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{ .unhealthy_threshold = 1 });

    // Mark all backends unhealthy
    state.recordFailure(0);
    state.recordFailure(1);
    state.recordFailure(2);

    try std.testing.expect(!state.isHealthy(0));
    try std.testing.expect(!state.isHealthy(1));
    try std.testing.expect(!state.isHealthy(2));
    try std.testing.expectEqual(@as(usize, 0), state.countHealthy());

    // selectBackend should return null
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
    pool.init();
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{
        .unhealthy_threshold = 2,
        .healthy_threshold = 3,
    });

    // Trip circuit breaker
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // Start recovery: 2 successes
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0)); // Still unhealthy

    // Failure interrupts recovery - resets success counter
    state.recordFailure(0);

    // Now we need 3 more successes (not just 1)
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));
    state.recordSuccess(0);
    try std.testing.expect(!state.isHealthy(0));
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0)); // Now recovered
}

test "integration: single backend down and recovery" {
    const allocator = std.testing.allocator;
    var backends: types.BackendsList = .empty;
    defer backends.deinit(allocator);

    const host = "localhost";
    try backends.append(allocator, types.BackendServer.init(host, 8001, 1));

    var pool = simple_pool.SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{
        .unhealthy_threshold = 2,
        .healthy_threshold = 2,
    });

    // Single backend works initially
    try std.testing.expect(state.selectBackend(.round_robin) != null);

    // Backend goes down
    state.recordFailure(0);
    state.recordFailure(0);
    try std.testing.expect(!state.isHealthy(0));

    // No backends available
    try std.testing.expect(state.selectBackend(.round_robin) == null);

    // Backend recovers
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));

    // Backend available again
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
    pool.init();
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{
        .unhealthy_threshold = 3,
        .healthy_threshold = 2,
    });

    // Simulate realistic pattern: mostly successes with occasional failures
    // Backend 0: success, success, fail, success, success, fail, fail, fail -> unhealthy
    state.recordSuccess(0);
    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));

    state.recordFailure(0); // 1 failure
    try std.testing.expect(state.isHealthy(0));

    state.recordSuccess(0); // Resets failure counter
    try std.testing.expect(state.isHealthy(0));

    state.recordSuccess(0);
    try std.testing.expect(state.isHealthy(0));

    state.recordFailure(0); // 1 failure
    state.recordFailure(0); // 2 failures
    state.recordFailure(0); // 3 failures -> unhealthy
    try std.testing.expect(!state.isHealthy(0));

    // Backend 1 still healthy, should handle all traffic
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
    pool.init();
    defer pool.deinit();

    var state = WorkerState.init(&backends, &pool, .{});

    // All healthy: exclude 0 should find 1
    const failover1 = state.findHealthyBackend(0);
    try std.testing.expect(failover1 != null);
    try std.testing.expect(failover1.? != 0);

    // Make backend 1 unhealthy
    state.forceUnhealthy(1);

    // Exclude 0 should now find 2 (skipping unhealthy 1)
    const failover2 = state.findHealthyBackend(0);
    try std.testing.expectEqual(@as(?usize, 2), failover2);

    // Make backend 2 also unhealthy
    state.forceUnhealthy(2);

    // Exclude 0 should find nothing (1 and 2 unhealthy)
    const failover3 = state.findHealthyBackend(0);
    try std.testing.expect(failover3 == null);
}
