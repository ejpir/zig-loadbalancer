//! Load balancing tests.
//!
//! Tests round-robin distribution across multiple backends

const std = @import("std");
const harness = @import("../harness.zig");
const utils = @import("../test_utils.zig");
const ProcessManager = @import("../process_manager.zig").ProcessManager;

var pm: ProcessManager = undefined;

fn beforeAll(allocator: std.mem.Allocator) !void {
    pm = ProcessManager.init(allocator);
    try pm.startBackend(utils.BACKEND1_PORT, "backend1");
    try pm.startBackend(utils.BACKEND2_PORT, "backend2");
    try pm.startBackend(utils.BACKEND3_PORT, "backend3");
    try pm.startLoadBalancer(&.{ utils.BACKEND1_PORT, utils.BACKEND2_PORT, utils.BACKEND3_PORT });
}

fn afterAll(_: std.mem.Allocator) !void {
    pm.deinit();
}

fn testRoundRobinDistribution(allocator: std.mem.Allocator) !void {
    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();

    // Make 9 requests (divisible by 3)
    for (0..9) |_| {
        const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/", null, null);
        defer allocator.free(response);

        const body = try utils.extractJsonBody(response);
        const server_id = try utils.getJsonString(allocator, body, "server_id");
        defer allocator.free(server_id);

        const key = try allocator.dupe(u8, server_id);
        const result = try counts.getOrPut(key);
        if (result.found_existing) {
            allocator.free(key);
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 1;
        }
    }

    // Each backend should get exactly 3 requests
    try std.testing.expectEqual(@as(usize, 3), counts.count());

    var iter = counts.iterator();
    while (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 3), entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
}

fn testAllBackendsReachable(allocator: std.mem.Allocator) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // Make up to 12 requests, should hit all 3 backends
    for (0..12) |_| {
        const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/", null, null);
        defer allocator.free(response);

        const body = try utils.extractJsonBody(response);
        const server_id = try utils.getJsonString(allocator, body, "server_id");

        if (!seen.contains(server_id)) {
            try seen.put(try allocator.dupe(u8, server_id), {});
        }
        allocator.free(server_id);

        if (seen.count() >= 3) break;
    }

    try std.testing.expectEqual(@as(usize, 3), seen.count());

    // Cleanup keys
    var iter = seen.keyIterator();
    while (iter.next()) |key| {
        allocator.free(key.*);
    }
}

pub const suite = harness.Suite{
    .name = "Load Balancing",
    .before_all = beforeAll,
    .after_all = afterAll,
    .tests = &.{
        harness.it("distributes requests with round-robin (3/3/3)", testRoundRobinDistribution),
        harness.it("reaches all configured backends", testAllBackendsReachable),
    },
};
