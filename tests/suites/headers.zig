//! Header handling tests.
//!
//! Tests header forwarding: Content-Type, custom headers, hop-by-hop filtering

const std = @import("std");
const harness = @import("../harness.zig");
const utils = @import("../test_utils.zig");
const ProcessManager = @import("../process_manager.zig").ProcessManager;

var pm: ProcessManager = undefined;

fn beforeAll(allocator: std.mem.Allocator) !void {
    pm = ProcessManager.init(allocator);
    try pm.startBackend(utils.BACKEND1_PORT, "backend1");
    try pm.startLoadBalancer(&.{utils.BACKEND1_PORT});
}

fn afterAll(_: std.mem.Allocator) !void {
    pm.deinit();
}

fn testContentTypeForwarded(allocator: std.mem.Allocator) !void {
    const headers = &[_][2][]const u8{.{ "Content-Type", "application/json" }};
    const response = try utils.httpRequest(allocator, "POST", utils.LB_PORT, "/", headers, "{}");
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const ct = try utils.getHeader(allocator, body, "Content-Type");
    defer allocator.free(ct);

    try std.testing.expect(std.mem.indexOf(u8, ct, "application/json") != null);
}

fn testCustomHeadersForwarded(allocator: std.mem.Allocator) !void {
    const headers = &[_][2][]const u8{
        .{ "X-Custom-Header", "CustomValue" },
        .{ "X-Request-ID", "test-123" },
        .{ "X-API-Key", "secret-key" },
    };

    const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/", headers, null);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);

    const custom = try utils.getHeader(allocator, body, "X-Custom-Header");
    defer allocator.free(custom);
    try std.testing.expectEqualStrings("CustomValue", custom);

    const req_id = try utils.getHeader(allocator, body, "X-Request-ID");
    defer allocator.free(req_id);
    try std.testing.expectEqualStrings("test-123", req_id);
}

fn testAuthorizationHeaderForwarded(allocator: std.mem.Allocator) !void {
    const headers = &[_][2][]const u8{.{ "Authorization", "Bearer token123" }};
    const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/", headers, null);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const auth = try utils.getHeader(allocator, body, "Authorization");
    defer allocator.free(auth);

    try std.testing.expectEqualStrings("Bearer token123", auth);
}

fn testHopByHopHeadersFiltered(allocator: std.mem.Allocator) !void {
    const headers = &[_][2][]const u8{
        .{ "Connection", "keep-alive" },
        .{ "Keep-Alive", "timeout=5" },
        .{ "X-Safe-Header", "should-be-forwarded" },
    };

    const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/", headers, null);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);

    // Hop-by-hop headers should NOT be forwarded
    const has_connection = utils.hasHeader(allocator, body, "Connection") catch false;
    try std.testing.expect(!has_connection);

    // Safe headers should be forwarded
    const safe = try utils.getHeader(allocator, body, "X-Safe-Header");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("should-be-forwarded", safe);
}

fn testHostHeaderPresent(allocator: std.mem.Allocator) !void {
    const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/", null, null);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const host = try utils.getHeader(allocator, body, "Host");
    defer allocator.free(host);

    try std.testing.expect(std.mem.indexOf(u8, host, "127.0.0.1") != null);
}

pub const suite = harness.Suite{
    .name = "Header Handling",
    .before_all = beforeAll,
    .after_all = afterAll,
    .tests = &.{
        harness.it("forwards Content-Type header", testContentTypeForwarded),
        harness.it("forwards custom X-* headers", testCustomHeadersForwarded),
        harness.it("forwards Authorization header", testAuthorizationHeaderForwarded),
        harness.it("filters hop-by-hop headers", testHopByHopHeadersFiltered),
        harness.it("includes Host header to backend", testHostHeaderPresent),
    },
};
