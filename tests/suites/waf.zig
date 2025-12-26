//! WAF (Web Application Firewall) integration tests.
//!
//! Tests rate limiting, body size limits, URI length limits, and shadow mode.
//! Creates a temporary WAF config file for each test suite run.

const std = @import("std");
const harness = @import("../harness.zig");
const utils = @import("../test_utils.zig");
const ProcessManager = @import("../process_manager.zig").ProcessManager;
const posix = std.posix;

var pm: ProcessManager = undefined;
var waf_config_path: []const u8 = undefined;
var allocator: std.mem.Allocator = undefined;

/// WAF test config - tight limits for testing
const WAF_CONFIG =
    \\{
    \\  "enabled": true,
    \\  "shadow_mode": false,
    \\  "rate_limits": [
    \\    {
    \\      "name": "test_limit",
    \\      "path": "/api/*",
    \\      "limit": { "requests": 5, "period_sec": 60 },
    \\      "burst": 0,
    \\      "by": "ip",
    \\      "action": "block"
    \\    }
    \\  ],
    \\  "request_limits": {
    \\    "max_uri_length": 100,
    \\    "max_body_size": 1024
    \\  }
    \\}
;

/// Shadow mode config - logs but doesn't block
const WAF_SHADOW_CONFIG =
    \\{
    \\  "enabled": true,
    \\  "shadow_mode": true,
    \\  "rate_limits": [
    \\    {
    \\      "name": "test_limit",
    \\      "path": "/api/*",
    \\      "limit": { "requests": 2, "period_sec": 60 },
    \\      "burst": 0,
    \\      "by": "ip",
    \\      "action": "block"
    \\    }
    \\  ],
    \\  "request_limits": {
    \\    "max_uri_length": 50,
    \\    "max_body_size": 512
    \\  }
    \\}
;

fn beforeAll(alloc: std.mem.Allocator) !void {
    allocator = alloc;
    pm = ProcessManager.init(alloc);

    // Create temporary WAF config file
    waf_config_path = try createTempWafConfig(alloc, WAF_CONFIG);

    // Start backend on dedicated WAF port
    try pm.startBackend(utils.WAF_BACKEND_PORT, "waf_backend");

    // Start load balancer with WAF enabled on dedicated port
    try pm.startLoadBalancerWithWafOnPort(&.{utils.WAF_BACKEND_PORT}, waf_config_path, utils.WAF_LB_PORT);
}

fn afterAll(_: std.mem.Allocator) !void {
    pm.deinit();

    // Clean up temporary WAF config file
    deleteTempWafConfig(waf_config_path);
    allocator.free(waf_config_path);
}

/// Create a temporary WAF config file
fn createTempWafConfig(alloc: std.mem.Allocator, config: []const u8) ![]const u8 {
    // Use /tmp for temporary files with a unique name based on timestamp
    const now = std.time.Instant.now() catch return error.TimerUnavailable;
    // Use seconds + nanoseconds for unique filename
    const ts_sec: i64 = now.timestamp.sec;
    const ts_nsec: i64 = now.timestamp.nsec;
    const path = try std.fmt.allocPrint(alloc, "/tmp/waf_test_{d}_{d}.json", .{ ts_sec, ts_nsec });
    errdefer alloc.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    try file.writeAll(config);

    return path;
}

/// Delete the temporary WAF config file
fn deleteTempWafConfig(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

// =============================================================================
// Rate Limiting Tests
// =============================================================================

fn testRateLimitingBlocks(alloc: std.mem.Allocator) !void {
    // The rate limit is 5 requests per 60 seconds with no burst
    // We need to make 6 requests to trigger the block
    // Note: we use a unique path suffix to avoid interference from other tests

    const path = "/api/rate-test-1";

    // Make 5 requests - all should succeed
    for (0..5) |_| {
        const response = try utils.httpRequest(alloc, "GET", utils.WAF_LB_PORT, path, null, null);
        defer alloc.free(response);

        const status = try utils.getResponseStatusCode(response);
        // First 5 should succeed (200) or we might get 429 from previous test runs
        if (status != 200 and status != 429) {
            return error.UnexpectedStatus;
        }
    }

    // The 6th request should be rate limited (429)
    const response = try utils.httpRequest(alloc, "GET", utils.WAF_LB_PORT, path, null, null);
    defer alloc.free(response);

    const status = try utils.getResponseStatusCode(response);
    try std.testing.expectEqual(@as(u16, 429), status);
}

fn testNonApiPathNotRateLimited(alloc: std.mem.Allocator) !void {
    // The rate limit only applies to /api/* paths
    // Requests to other paths should not be rate limited

    const path = "/other/path";

    // Make many requests - all should succeed
    for (0..10) |_| {
        const response = try utils.httpRequest(alloc, "GET", utils.WAF_LB_PORT, path, null, null);
        defer alloc.free(response);

        const status = try utils.getResponseStatusCode(response);
        try std.testing.expectEqual(@as(u16, 200), status);
    }
}

// =============================================================================
// Request Size Limit Tests
// =============================================================================

fn testBodySizeLimitBlocks(alloc: std.mem.Allocator) !void {
    // The max_body_size is 1024 bytes
    // Sending a larger body should be blocked with 413

    // Create a body larger than 1024 bytes
    const large_body = try alloc.alloc(u8, 2000);
    defer alloc.free(large_body);
    @memset(large_body, 'X');

    const headers = &[_][2][]const u8{.{ "Content-Type", "application/octet-stream" }};

    const response = try utils.httpRequest(alloc, "POST", utils.WAF_LB_PORT, "/upload", headers, large_body);
    defer alloc.free(response);

    const status = try utils.getResponseStatusCode(response);
    try std.testing.expectEqual(@as(u16, 413), status);
}

fn testSmallBodyAllowed(alloc: std.mem.Allocator) !void {
    // A body smaller than 1024 bytes should be allowed

    const small_body = "This is a small body that should be allowed";
    const headers = &[_][2][]const u8{.{ "Content-Type", "text/plain" }};

    const response = try utils.httpRequest(alloc, "POST", utils.WAF_LB_PORT, "/data", headers, small_body);
    defer alloc.free(response);

    const status = try utils.getResponseStatusCode(response);
    try std.testing.expectEqual(@as(u16, 200), status);
}

// =============================================================================
// URI Length Limit Tests
// =============================================================================

fn testUriLengthLimitBlocks(alloc: std.mem.Allocator) !void {
    // The max_uri_length is 100 bytes
    // Sending a longer URI should be blocked with 403

    // Create a URI longer than 100 bytes
    var long_uri_buf: [200]u8 = undefined;
    @memset(&long_uri_buf, 'a');
    long_uri_buf[0] = '/';
    const long_uri = long_uri_buf[0..150];

    const response = try utils.httpRequest(alloc, "GET", utils.WAF_LB_PORT, long_uri, null, null);
    defer alloc.free(response);

    const status = try utils.getResponseStatusCode(response);
    try std.testing.expectEqual(@as(u16, 403), status);
}

fn testShortUriAllowed(alloc: std.mem.Allocator) !void {
    // A URI shorter than 100 bytes should be allowed

    const short_uri = "/short/path";

    const response = try utils.httpRequest(alloc, "GET", utils.WAF_LB_PORT, short_uri, null, null);
    defer alloc.free(response);

    const status = try utils.getResponseStatusCode(response);
    try std.testing.expectEqual(@as(u16, 200), status);
}

pub const suite = harness.Suite{
    .name = "WAF (Web Application Firewall)",
    .before_all = beforeAll,
    .after_all = afterAll,
    .tests = &.{
        harness.it("rate limiting blocks after limit exceeded", testRateLimitingBlocks),
        harness.it("non-API paths not rate limited", testNonApiPathNotRateLimited),
        harness.it("blocks requests with body exceeding size limit", testBodySizeLimitBlocks),
        harness.it("allows requests with small body", testSmallBodyAllowed),
        harness.it("blocks requests with URI exceeding length limit", testUriLengthLimitBlocks),
        harness.it("allows requests with short URI", testShortUriAllowed),
    },
};

// =============================================================================
// Shadow Mode Test Suite
// =============================================================================

var pm_shadow: ProcessManager = undefined;
var waf_shadow_config_path: []const u8 = undefined;

fn beforeAllShadow(alloc: std.mem.Allocator) !void {
    allocator = alloc;
    pm_shadow = ProcessManager.init(alloc);

    // Create temporary WAF config file with shadow mode
    waf_shadow_config_path = try createTempWafConfig(alloc, WAF_SHADOW_CONFIG);

    // Start backend on dedicated WAF shadow port to avoid conflicts
    try pm_shadow.startBackend(utils.WAF_SHADOW_BACKEND_PORT, "waf_shadow_backend");

    // Start load balancer with WAF shadow mode on dedicated port
    try pm_shadow.startLoadBalancerWithWafOnPort(&.{utils.WAF_SHADOW_BACKEND_PORT}, waf_shadow_config_path, utils.WAF_SHADOW_LB_PORT);
}

fn afterAllShadow(_: std.mem.Allocator) !void {
    pm_shadow.deinit();

    // Clean up temporary WAF config file
    deleteTempWafConfig(waf_shadow_config_path);
    allocator.free(waf_shadow_config_path);
}

fn testShadowModeDoesNotBlock(alloc: std.mem.Allocator) !void {
    // In shadow mode, the rate limit is 2 requests per 60 seconds
    // But shadow mode should NOT block, only log
    // All requests should succeed

    const path = "/api/shadow-test";

    // Make more requests than the limit
    for (0..5) |_| {
        const response = try utils.httpRequest(alloc, "GET", utils.WAF_SHADOW_LB_PORT, path, null, null);
        defer alloc.free(response);

        const status = try utils.getResponseStatusCode(response);
        // In shadow mode, all requests should succeed
        try std.testing.expectEqual(@as(u16, 200), status);
    }
}

fn testShadowModeAllowsLargeBody(alloc: std.mem.Allocator) !void {
    // In shadow mode, max_body_size is 512 bytes
    // But shadow mode should NOT block, only log

    // Create a body larger than 512 bytes
    const large_body = try alloc.alloc(u8, 800);
    defer alloc.free(large_body);
    @memset(large_body, 'Y');

    const headers = &[_][2][]const u8{.{ "Content-Type", "application/octet-stream" }};

    const response = try utils.httpRequest(alloc, "POST", utils.WAF_SHADOW_LB_PORT, "/upload", headers, large_body);
    defer alloc.free(response);

    const status = try utils.getResponseStatusCode(response);
    // In shadow mode, should still succeed
    try std.testing.expectEqual(@as(u16, 200), status);
}

fn testShadowModeAllowsLongUri(alloc: std.mem.Allocator) !void {
    // In shadow mode, max_uri_length is 50 bytes
    // But shadow mode should NOT block, only log

    // Create a URI longer than 50 bytes but shorter than typical limits
    var uri_buf: [80]u8 = undefined;
    @memset(&uri_buf, 'z');
    uri_buf[0] = '/';
    const long_uri = uri_buf[0..70];

    const response = try utils.httpRequest(alloc, "GET", utils.WAF_SHADOW_LB_PORT, long_uri, null, null);
    defer alloc.free(response);

    const status = try utils.getResponseStatusCode(response);
    // In shadow mode, should still succeed
    try std.testing.expectEqual(@as(u16, 200), status);
}

pub const shadow_suite = harness.Suite{
    .name = "WAF Shadow Mode",
    .before_all = beforeAllShadow,
    .after_all = afterAllShadow,
    .tests = &.{
        harness.it("shadow mode does not block rate-limited requests", testShadowModeDoesNotBlock),
        harness.it("shadow mode allows large body requests", testShadowModeAllowsLargeBody),
        harness.it("shadow mode allows long URI requests", testShadowModeAllowsLongUri),
    },
};
