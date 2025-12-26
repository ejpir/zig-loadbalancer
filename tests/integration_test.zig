//! Integration Test Runner
//!
//! Runs all test suites using the describe/it harness.
//! Run with: zig build test-integration

const std = @import("std");
const harness = @import("harness.zig");

// Import all test suites
const basic = @import("suites/basic.zig");
const headers = @import("suites/headers.zig");
const body = @import("suites/body.zig");
const load_balancing = @import("suites/load_balancing.zig");
const http2 = @import("suites/http2.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n\x1b[1;36m╔══════════════════════════════════════╗\x1b[0m\n", .{});
    std.debug.print("\x1b[1;36m║   Load Balancer Integration Tests   ║\x1b[0m\n", .{});
    std.debug.print("\x1b[1;36m╚══════════════════════════════════════╝\x1b[0m\n", .{});

    const suites = [_]harness.Suite{
        basic.suite,
        headers.suite,
        body.suite,
        load_balancing.suite,
        http2.suite,
    };

    var suite_failures: usize = 0;

    for (suites) |suite| {
        harness.runSuite(allocator, suite) catch |err| {
            std.debug.print("  Suite error: {}\n", .{err});
            suite_failures += 1;
        };
    }

    std.debug.print("\n\x1b[1m════════════════════════════════════════\x1b[0m\n", .{});
    if (suite_failures == 0) {
        std.debug.print("\x1b[32m✓ All test suites passed!\x1b[0m\n", .{});
    } else {
        std.debug.print("\x1b[31m✗ {d} suite(s) had failures\x1b[0m\n", .{suite_failures});
        return error.TestSuitesFailed;
    }
}

// Also support zig test
test "run all integration tests" {
    try main();
}
