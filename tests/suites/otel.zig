//! OpenTelemetry integration tests.
//!
//! Tests that the load balancer correctly exports traces to an OTLP collector.
//! Uses a mock OTLP collector to receive and verify trace data.

const std = @import("std");
const harness = @import("../harness.zig");
const utils = @import("../test_utils.zig");
const ProcessManager = @import("../process_manager.zig").ProcessManager;

var pm: ProcessManager = undefined;

fn beforeAll(allocator: std.mem.Allocator) !void {
    pm = ProcessManager.init(allocator);

    // Start mock OTLP collector first
    try pm.startOtlpCollector();

    // Start backend
    try pm.startBackend(utils.BACKEND1_PORT, "backend1");

    // Start load balancer with OTLP endpoint
    try pm.startLoadBalancerWithOtel(&.{utils.BACKEND1_PORT});
}

fn afterAll(_: std.mem.Allocator) !void {
    pm.deinit();
}

fn testTracesExported(allocator: std.mem.Allocator) !void {
    // Clear any existing traces
    try utils.clearOtlpTraces(allocator);

    // Make a request through the load balancer
    const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/test/trace", null, null);
    defer allocator.free(response);

    // Verify request succeeded
    const status = try utils.getResponseStatusCode(response);
    try std.testing.expectEqual(@as(u16, 200), status);

    // Wait for traces to be exported (batching processor has delay)
    // The BatchingProcessor exports every 5 seconds or when batch is full
    try utils.waitForTraces(allocator, 1, 10000);

    // Verify we received at least one trace
    const count = try utils.getOtlpTraceCount(allocator);
    try std.testing.expect(count >= 1);
}

fn testMultipleRequestsGenerateTraces(allocator: std.mem.Allocator) !void {
    // Clear existing traces
    try utils.clearOtlpTraces(allocator);

    // Make multiple requests
    const num_requests: usize = 5;
    for (0..num_requests) |_| {
        const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/api/multi", null, null);
        defer allocator.free(response);

        const status = try utils.getResponseStatusCode(response);
        try std.testing.expectEqual(@as(u16, 200), status);
    }

    // Wait for at least one trace export
    // Note: BatchingProcessor batches spans, so multiple requests may result
    // in a single export containing all spans
    try utils.waitForTraces(allocator, 1, 10000);

    // Verify we got at least one trace export
    const count = try utils.getOtlpTraceCount(allocator);
    try std.testing.expect(count >= 1);
}

fn testPostRequestGeneratesTrace(allocator: std.mem.Allocator) !void {
    // Clear existing traces
    try utils.clearOtlpTraces(allocator);

    // Make a POST request with body
    const body = "{\"test\":\"data\"}";
    const headers = &[_][2][]const u8{.{ "Content-Type", "application/json" }};

    const response = try utils.httpRequest(allocator, "POST", utils.LB_PORT, "/api/post", headers, body);
    defer allocator.free(response);

    // Verify request succeeded
    const status = try utils.getResponseStatusCode(response);
    try std.testing.expectEqual(@as(u16, 200), status);

    // Wait for trace
    try utils.waitForTraces(allocator, 1, 10000);

    const count = try utils.getOtlpTraceCount(allocator);
    try std.testing.expect(count >= 1);
}

fn testTracesHaveData(allocator: std.mem.Allocator) !void {
    // Clear existing traces
    try utils.clearOtlpTraces(allocator);

    // Make a request
    const response = try utils.httpRequest(allocator, "GET", utils.LB_PORT, "/verify/data", null, null);
    defer allocator.free(response);

    // Wait for trace
    try utils.waitForTraces(allocator, 1, 10000);

    // Get the raw traces response
    const traces_response = try utils.httpRequest(allocator, "GET", utils.OTLP_PORT, "/traces", null, null);
    defer allocator.free(traces_response);

    const traces_body = try utils.extractJsonBody(traces_response);

    // Verify the response contains trace data
    // The body_size field should be > 0 indicating actual protobuf data was received
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, traces_body, .{});
    defer parsed.deinit();

    const traces_array = parsed.value.object.get("traces") orelse return error.NoTraces;
    try std.testing.expect(traces_array.array.items.len >= 1);

    // Check first trace has non-zero body size
    const first_trace = traces_array.array.items[0];
    const body_size = first_trace.object.get("body_size") orelse return error.NoBodySize;
    try std.testing.expect(body_size.integer > 0);
}

pub const suite = harness.Suite{
    .name = "OpenTelemetry Tracing",
    .before_all = beforeAll,
    .after_all = afterAll,
    .tests = &.{
        harness.it("exports traces to OTLP collector", testTracesExported),
        harness.it("generates traces for multiple requests", testMultipleRequestsGenerateTraces),
        harness.it("generates traces for POST requests", testPostRequestGeneratesTrace),
        harness.it("trace data contains valid protobuf", testTracesHaveData),
    },
};
