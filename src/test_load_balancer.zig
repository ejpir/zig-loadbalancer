/// Load Balancer Unit Tests
///
/// Central test file that imports all test modules.

const std = @import("std");

// Multiprocess module tests
pub const health_state = @import("multiprocess/health_state.zig");
pub const circuit_breaker = @import("multiprocess/circuit_breaker.zig");
pub const backend_selector = @import("multiprocess/backend_selector.zig");
pub const worker_state = @import("multiprocess/worker_state.zig");

// Memory module tests
pub const simple_connection_pool = @import("memory/simple_connection_pool.zig");

// Run all tests
comptime {
    _ = health_state;
    _ = circuit_breaker;
    _ = backend_selector;
    _ = worker_state;
    _ = simple_connection_pool;
}

test "test_load_balancer: all modules imported" {
    // Sanity check that all modules are accessible
    try std.testing.expect(true);
}
