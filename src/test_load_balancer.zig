/// Load Balancer Unit Tests
///
/// Central test file that imports all test modules.

const std = @import("std");

// Health module tests
pub const health_state = @import("health/state.zig");
pub const circuit_breaker = @import("health/circuit_breaker.zig");

// Load balancer module tests
pub const backend_selector = @import("lb/selector.zig");
pub const worker_state = @import("lb/worker.zig");

// Multiprocess tests (remaining in multiprocess/)
pub const connection_reuse = @import("multiprocess/connection_reuse.zig");
pub const proxy_test = @import("multiprocess/proxy_test.zig");
pub const component_integration_test = @import("multiprocess/component_integration_test.zig");

// Memory module tests
pub const connection_pool = @import("memory/pool.zig");
pub const shared_region = @import("memory/shared_region.zig");

// HTTP module tests
pub const http_utils = @import("http/http_utils.zig");

// Internal module tests
pub const simd_parse = @import("internal/simd_parse.zig");

// Core module tests
pub const config = @import("core/config.zig");

// Config module tests
pub const config_watcher = @import("config/config_watcher.zig");

// Run all tests
comptime {
    // Unit tests - reorganized modules
    _ = health_state;
    _ = circuit_breaker;
    _ = backend_selector;
    _ = worker_state;
    _ = connection_reuse;
    _ = proxy_test;
    _ = connection_pool;
    _ = shared_region;
    _ = http_utils;
    _ = simd_parse;
    _ = config;
    _ = config_watcher;

    // Component integration tests
    _ = component_integration_test;
}

test "test_load_balancer: all modules imported" {
    // Sanity check that all modules are accessible
    try std.testing.expect(true);
}
