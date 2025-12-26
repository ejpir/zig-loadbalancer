//! HTTP/2 backend tests.
//!
//! Tests HTTP/2 protocol support with TLS backend.
//! Uses Python hypercorn as HTTP/2 backend.
//!
//! Note: Custom header forwarding is not yet implemented for HTTP/2 backends.
//! The H2Connection.request() API only supports method, path, host, and body.

const std = @import("std");
const harness = @import("../harness.zig");
const utils = @import("../test_utils.zig");
const ProcessManager = @import("../process_manager.zig").ProcessManager;

var pm: ProcessManager = undefined;

fn beforeAll(allocator: std.mem.Allocator) !void {
    pm = ProcessManager.init(allocator);
    try pm.startH2Backend();
    try pm.startLoadBalancerH2();
}

fn afterAll(_: std.mem.Allocator) !void {
    pm.deinit();
}

fn testH2GetRequest(allocator: std.mem.Allocator) !void {
    const response = try utils.httpRequest(allocator, "GET", utils.LB_H2_PORT, "/test/h2", null, null);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const method = try utils.getJsonString(allocator, body, "method");
    defer allocator.free(method);
    const uri = try utils.getJsonString(allocator, body, "uri");
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("GET", method);
    try std.testing.expectEqualStrings("/test/h2", uri);
}

fn testH2PostRequest(allocator: std.mem.Allocator) !void {
    const req_body = "{\"protocol\":\"h2\",\"test\":true}";
    const headers = &[_][2][]const u8{.{ "Content-Type", "application/json" }};

    const response = try utils.httpRequest(allocator, "POST", utils.LB_H2_PORT, "/api/h2", headers, req_body);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const method = try utils.getJsonString(allocator, body, "method");
    defer allocator.free(method);
    const recv_body = try utils.getJsonString(allocator, body, "body");
    defer allocator.free(recv_body);

    try std.testing.expectEqualStrings("POST", method);
    try std.testing.expectEqualStrings(req_body, recv_body);
}

fn testH2ServerIdentity(allocator: std.mem.Allocator) !void {
    const response = try utils.httpRequest(allocator, "GET", utils.LB_H2_PORT, "/", null, null);
    defer allocator.free(response);

    const body = try utils.extractJsonBody(response);
    const server_id = try utils.getJsonString(allocator, body, "server_id");
    defer allocator.free(server_id);

    // Verify we're hitting the HTTP/2 Python backend
    try std.testing.expectEqualStrings("h2_backend", server_id);
}

fn testH2ResponseStatus(allocator: std.mem.Allocator) !void {
    const response = try utils.httpRequest(allocator, "GET", utils.LB_H2_PORT, "/", null, null);
    defer allocator.free(response);

    const status = try utils.getResponseStatusCode(response);
    try std.testing.expectEqual(@as(u16, 200), status);
}

pub const suite = harness.Suite{
    .name = "HTTP/2 Backend Support",
    .before_all = beforeAll,
    .after_all = afterAll,
    .tests = &.{
        harness.it("forwards GET requests over HTTP/2", testH2GetRequest),
        harness.it("forwards POST requests with body over HTTP/2", testH2PostRequest),
        harness.it("reaches HTTP/2 backend correctly", testH2ServerIdentity),
        harness.it("returns correct status code from HTTP/2", testH2ResponseStatus),
    },
};
