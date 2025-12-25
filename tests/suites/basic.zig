//! Basic proxy functionality tests.
//!
//! Tests HTTP method forwarding: GET, POST, PUT, PATCH

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

fn testGetRequest(allocator: std.mem.Allocator) !void {
    const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/test/path", null, null);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const method = try utils.getJsonString(allocator, body, "method");
    defer allocator.free(method);
    const uri = try utils.getJsonString(allocator, body, "uri");
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("GET", method);
    try std.testing.expectEqualStrings("/test/path", uri);
}

fn testPostRequest(allocator: std.mem.Allocator) !void {
    const req_body = "{\"test\":\"data\",\"number\":42}";
    const headers = &[_][2][]const u8{.{ "Content-Type", "application/json" }};

    const response = try utils.httpRequest(allocator, "POST", utils.LB_PORT, "/api/endpoint", headers, req_body);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const method = try utils.getJsonString(allocator, body, "method");
    defer allocator.free(method);
    const recv_body = try utils.getJsonString(allocator, body, "body");
    defer allocator.free(recv_body);

    try std.testing.expectEqualStrings("POST", method);
    try std.testing.expectEqualStrings(req_body, recv_body);
}

fn testPutRequest(allocator: std.mem.Allocator) !void {
    const req_body = "Updated content";

    const response = try utils.httpRequest(allocator, "PUT", utils.LB_PORT, "/resource/123", null, req_body);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const method = try utils.getJsonString(allocator, body, "method");
    defer allocator.free(method);
    const uri = try utils.getJsonString(allocator, body, "uri");
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("PUT", method);
    try std.testing.expectEqualStrings("/resource/123", uri);
}

fn testPatchRequest(allocator: std.mem.Allocator) !void {
    const req_body = "{\"field\":\"name\",\"value\":\"new\"}";
    const headers = &[_][2][]const u8{.{ "Content-Type", "application/json" }};

    const response = try utils.httpRequest(allocator, "PATCH", utils.LB_PORT, "/api/resource/456", headers, req_body);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const method = try utils.getJsonString(allocator, body, "method");
    defer allocator.free(method);
    const uri = try utils.getJsonString(allocator, body, "uri");
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("PATCH", method);
    try std.testing.expectEqualStrings("/api/resource/456", uri);
}

fn testResponseStructure(allocator: std.mem.Allocator) !void {
    const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/", null, null);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);

    // Verify all expected fields exist
    const server_id = try utils.getJsonString(allocator, body, "server_id");
    defer allocator.free(server_id);
    const method = try utils.getJsonString(allocator, body, "method");
    defer allocator.free(method);
    const uri = try utils.getJsonString(allocator, body, "uri");
    defer allocator.free(uri);
    _ = try utils.getJsonInt(allocator, body, "body_length");
    _ = try utils.hasHeader(allocator, body, "Host");
}

pub const suite = harness.Suite{
    .name = "Basic Proxy Functionality",
    .before_all = beforeAll,
    .after_all = afterAll,
    .tests = &.{
        harness.it("forwards GET requests correctly", testGetRequest),
        harness.it("forwards POST requests with JSON body", testPostRequest),
        harness.it("forwards PUT requests with body", testPutRequest),
        harness.it("forwards PATCH requests with body", testPatchRequest),
        harness.it("returns complete response structure", testResponseStructure),
    },
};
