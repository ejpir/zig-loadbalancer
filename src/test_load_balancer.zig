/// Load Balancer Unit Tests
///
/// Central test file that imports all test modules.

const std = @import("std");

// Health module tests
pub const health_state = @import("health/state.zig");
pub const circuit_breaker = @import("health/circuit_breaker.zig");
pub const health_probe = @import("health/probe.zig");

// Load balancer module tests
pub const backend_selector = @import("lb/selector.zig");
pub const worker_state = @import("lb/worker.zig");

// Proxy module tests
pub const connection_reuse = @import("proxy/connection_reuse.zig");
pub const proxy_test = @import("multiprocess/proxy_test.zig");
pub const component_integration_test = @import("multiprocess/component_integration_test.zig");

// Memory module tests
pub const connection_pool = @import("memory/pool.zig");
pub const shared_region = @import("memory/shared_region.zig");

// HTTP module tests
pub const http_utils = @import("http/http_utils.zig");
pub const ultra_sock = @import("http/ultra_sock.zig");
pub const backend_conn = @import("http/backend_conn.zig");

// HTTP/2 module tests
pub const http2_mod = @import("http/http2/mod.zig");
pub const http2_frame = @import("http/http2/frame.zig");
pub const http2_hpack = @import("http/http2/hpack.zig");
pub const http2_client = @import("http/http2/client.zig");

// Internal module tests
pub const simd_parse = @import("internal/simd_parse.zig");

// Core module tests
pub const config = @import("core/config.zig");

// WAF module tests
pub const waf_state = @import("waf/state.zig");

// Config module tests
pub const config_watcher = @import("config/config_watcher.zig");

// Proxy module tests
pub const proxy_io = @import("proxy/io.zig");

// CLI module tests
pub const args_test = @import("cli/args_test.zig");

// Run all tests
comptime {
    // Unit tests - reorganized modules
    _ = health_state;
    _ = circuit_breaker;
    _ = health_probe;
    _ = backend_selector;
    _ = worker_state;
    _ = connection_reuse;
    _ = proxy_test;
    _ = connection_pool;
    _ = shared_region;
    _ = http_utils;
    _ = ultra_sock;
    _ = backend_conn;
    _ = http2_mod;
    _ = http2_frame;
    _ = http2_hpack;
    _ = http2_client;
    _ = simd_parse;
    _ = config;
    _ = waf_state;
    _ = config_watcher;
    _ = component_integration_test;
    _ = proxy_io;
    _ = args_test;
}

test "test_load_balancer: all modules imported" {
    // Sanity check that all modules are accessible
    try std.testing.expect(true);
}
