//! Body forwarding tests.
//!
//! Tests request body handling: empty, large, JSON, binary, Content-Length

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

fn testEmptyBodyPost(allocator: std.mem.Allocator) !void {
    const response = try utils.httpRequest(allocator, "POST", utils.LB_PORT, "/", null, "");
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const body_len = try utils.getJsonInt(allocator, body, "body_length");

    try std.testing.expectEqual(@as(i64, 0), body_len);
}

fn testLargeBody(allocator: std.mem.Allocator) !void {
    // 1KB payload
    const large_body = try allocator.alloc(u8, 1024);
    defer allocator.free(large_body);
    @memset(large_body, 'X');

    const headers = &[_][2][]const u8{.{ "Content-Type", "text/plain" }};
    const response = try utils.httpRequest(allocator, "POST", utils.LB_PORT, "/", headers, large_body);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const body_len = try utils.getJsonInt(allocator, body, "body_length");

    try std.testing.expectEqual(@as(i64, 1024), body_len);
}

fn testJsonBodyPreserved(allocator: std.mem.Allocator) !void {
    const json_body =
        \\{"user":"john_doe","email":"john@example.com","age":30,"active":true}
    ;
    const headers = &[_][2][]const u8{.{ "Content-Type", "application/json" }};

    const response = try utils.httpRequest(allocator, "POST", utils.LB_PORT, "/api/users", headers, json_body);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const recv_body = try utils.getJsonString(allocator, body, "body");
    defer allocator.free(recv_body);

    try std.testing.expectEqualStrings(json_body, recv_body);
}

fn testBinaryData(allocator: std.mem.Allocator) !void {
    // UTF-8 safe binary data
    const binary_data = "Binary test data with special chars: \xc2\xa9\xc2\xae";
    const headers = &[_][2][]const u8{.{ "Content-Type", "application/octet-stream" }};

    const response = try utils.httpRequest(allocator, "POST", utils.LB_PORT, "/upload", headers, binary_data);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const body_len = try utils.getJsonInt(allocator, body, "body_length");

    try std.testing.expectEqual(@as(i64, binary_data.len), body_len);
}

fn testContentLengthCorrect(allocator: std.mem.Allocator) !void {
    const req_body = "{\"key\":\"value\",\"number\":42}";
    const headers = &[_][2][]const u8{.{ "Content-Type", "application/json" }};

    const response = try utils.httpRequest(allocator, "POST", utils.LB_PORT, "/", headers, req_body);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);

    // Check Content-Length header matches body length
    const cl = try utils.getHeader(allocator, body, "Content-Length");
    defer allocator.free(cl);
    const cl_int = try std.fmt.parseInt(i64, cl, 10);

    const body_len = try utils.getJsonInt(allocator, body, "body_length");

    try std.testing.expectEqual(cl_int, body_len);
    try std.testing.expectEqual(@as(i64, req_body.len), body_len);
}

fn testSequentialPosts(allocator: std.mem.Allocator) !void {
    const bodies = [_][]const u8{
        "{\"id\":1,\"name\":\"first\"}",
        "{\"id\":2,\"name\":\"second\"}",
        "{\"id\":3,\"name\":\"third\"}",
    };

    for (bodies) |req_body| {
        const headers = &[_][2][]const u8{.{ "Content-Type", "application/json" }};
        const response = try utils.httpRequest(allocator, "POST", utils.LB_PORT, "/", headers, req_body);
        defer allocator.free(response);

        const body = try utils.extractJsonBody(response);
        const recv_body = try utils.getJsonString(allocator, body, "body");
        defer allocator.free(recv_body);

        try std.testing.expectEqualStrings(req_body, recv_body);
    }
}

pub const suite = harness.Suite{
    .name = "Body Forwarding",
    .before_all = beforeAll,
    .after_all = afterAll,
    .tests = &.{
        harness.it("handles empty POST body", testEmptyBodyPost),
        harness.it("handles large body (1KB)", testLargeBody),
        harness.it("preserves JSON body exactly", testJsonBodyPreserved),
        harness.it("handles binary data", testBinaryData),
        harness.it("sets Content-Length correctly", testContentLengthCorrect),
        harness.it("handles multiple sequential POSTs", testSequentialPosts),
    },
};
