/// Load Balancer Unit Tests
///
/// Central test file that imports all test modules.

const std = @import("std");

// Multiprocess module tests (unit)
pub const health_state = @import("multiprocess/health_state.zig");
pub const circuit_breaker = @import("multiprocess/circuit_breaker.zig");
pub const backend_selector = @import("multiprocess/backend_selector.zig");
pub const worker_state = @import("multiprocess/worker_state.zig");
pub const connection_reuse = @import("multiprocess/connection_reuse.zig");
pub const proxy_test = @import("multiprocess/proxy_test.zig");

// Multiprocess module tests (integration)
pub const integration_test = @import("multiprocess/integration_test.zig");

// Memory module tests
pub const simple_connection_pool = @import("memory/simple_connection_pool.zig");
pub const shared_region = @import("memory/shared_region.zig");

// HTTP module tests
pub const http_utils = @import("http/http_utils.zig");

// Internal module tests
pub const simd_parse = @import("internal/simd_parse.zig");

// Core module tests
pub const config = @import("core/config.zig");
pub const runmode_test = @import("core/runmode_test.zig");

// Run all tests
comptime {
    // Unit tests
    _ = health_state;
    _ = circuit_breaker;
    _ = backend_selector;
    _ = worker_state;
    _ = connection_reuse;
    _ = proxy_test;
    _ = simple_connection_pool;
    _ = shared_region;
    _ = http_utils;
    _ = simd_parse;
    _ = config;
    _ = runmode_test;

    // Integration tests
    _ = integration_test;
}

test "test_load_balancer: all modules imported" {
    // Sanity check that all modules are accessible
    try std.testing.expect(true);
}
