//! Minimal Jest-like test harness for Zig integration tests.
//!
//! Provides describe/it semantics with beforeAll/afterAll hooks.
//! Built on top of std.testing for seamless integration.

const std = @import("std");
const testing = std.testing;

pub const TestFn = *const fn (std.mem.Allocator) anyerror!void;

pub const TestCase = struct {
    name: []const u8,
    func: TestFn,
};

pub const Suite = struct {
    name: []const u8,
    tests: []const TestCase,
    before_all: ?TestFn = null,
    after_all: ?TestFn = null,
    before_each: ?TestFn = null,
    after_each: ?TestFn = null,
};

/// Run a test suite with optional lifecycle hooks
pub fn runSuite(allocator: std.mem.Allocator, suite: Suite) !void {
    std.debug.print("\n\x1b[1m{s}\x1b[0m\n", .{suite.name});

    // beforeAll
    if (suite.before_all) |before| {
        try before(allocator);
    }

    var passed: usize = 0;
    var failed: usize = 0;

    for (suite.tests) |t| {
        // beforeEach
        if (suite.before_each) |before| {
            before(allocator) catch |err| {
                std.debug.print("  \x1b[31m✗\x1b[0m {s} (beforeEach failed: {})\n", .{ t.name, err });
                failed += 1;
                continue;
            };
        }

        // Run test
        if (t.func(allocator)) |_| {
            std.debug.print("  \x1b[32m✓\x1b[0m {s}\n", .{t.name});
            passed += 1;
        } else |err| {
            std.debug.print("  \x1b[31m✗\x1b[0m {s} ({})\n", .{ t.name, err });
            failed += 1;
        }

        // afterEach
        if (suite.after_each) |after| {
            after(allocator) catch |err| {
                std.debug.print("    \x1b[33m⚠\x1b[0m afterEach failed: {}\n", .{err});
            };
        }
    }

    // afterAll
    if (suite.after_all) |after| {
        after(allocator) catch |err| {
            std.debug.print("  \x1b[33m⚠\x1b[0m afterAll failed: {}\n", .{err});
        };
    }

    std.debug.print("\n  {d} passed, {d} failed\n", .{ passed, failed });

    if (failed > 0) {
        return error.TestsFailed;
    }
}

/// Helper to create a test case inline
pub fn it(name: []const u8, func: TestFn) TestCase {
    return .{ .name = name, .func = func };
}
