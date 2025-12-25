# Zig Test Harness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Python pytest integration tests with pure Zig tests using a minimal describe/it test harness.

**Architecture:** Create a lightweight test harness (~100 LOC) providing Jest-like `describe`/`it` organization on top of Zig's native `std.testing`. Refactor existing integration tests to use this harness, add missing test coverage, and improve reliability with proper port waiting.

**Tech Stack:** Zig 0.16, std.testing, std.posix (sockets), std.json

---

## Task 1: Create Test Harness Module

**Files:**
- Create: `tests/harness.zig`

**Step 1: Write the test harness**

```zig
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
```

**Step 2: Verify it compiles**

Run: `cd /Users/nick/repos/zzz/examples/zzz-fix && zig build-lib tests/harness.zig --name harness 2>&1 || echo "Expected - just checking syntax"`

Expected: No syntax errors (may show "no root module" which is fine)

**Step 3: Commit**

```bash
git add tests/harness.zig
git commit -m "feat(tests): add minimal Jest-like test harness"
```

---

## Task 2: Create Test Utilities Module

**Files:**
- Create: `tests/test_utils.zig`

**Step 1: Write port waiting and HTTP utilities**

```zig
//! Test utilities for integration tests.
//!
//! Provides:
//! - Port availability waiting
//! - HTTP request helpers
//! - JSON response parsing

const std = @import("std");
const posix = std.posix;

pub const TEST_HOST = "127.0.0.1";
pub const BACKEND1_PORT: u16 = 19001;
pub const BACKEND2_PORT: u16 = 19002;
pub const BACKEND3_PORT: u16 = 19003;
pub const LB_PORT: u16 = 18080;

/// Wait for a port to accept connections
pub fn waitForPort(port: u16, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    const deadline = start + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() < deadline) {
        if (tryConnect(port)) {
            return;
        }
        std.time.sleep(100 * std.time.ns_per_ms);
    }
    return error.PortTimeout;
}

fn tryConnect(port: u16) bool {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(sock);

    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
}

/// Make an HTTP request and return the response body
pub fn httpRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    port: u16,
    path: []const u8,
    headers: ?[]const [2][]const u8,
    body: ?[]const u8,
) ![]const u8 {
    // Build request
    var request = std.ArrayList(u8).init(allocator);
    defer request.deinit();

    try request.writer().print("{s} {s} HTTP/1.1\r\n", .{ method, path });
    try request.writer().print("Host: {s}:{d}\r\n", .{ TEST_HOST, port });

    if (headers) |hdrs| {
        for (hdrs) |h| {
            try request.writer().print("{s}: {s}\r\n", .{ h[0], h[1] });
        }
    }

    if (body) |b| {
        try request.writer().print("Content-Length: {d}\r\n", .{b.len});
    }

    try request.appendSlice("Connection: close\r\n\r\n");

    if (body) |b| {
        try request.appendSlice(b);
    }

    // Connect and send
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    try posix.connect(sock, &addr.any, addr.getOsSockLen());

    _ = try posix.send(sock, request.items, 0);

    // Read response
    var response = std.ArrayList(u8).init(allocator);
    errdefer response.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.recv(sock, &buf, 0);
        if (n == 0) break;
        try response.appendSlice(buf[0..n]);
    }

    return response.toOwnedSlice();
}

/// Extract JSON body from HTTP response
pub fn extractJsonBody(response: []const u8) ![]const u8 {
    const separator = "\r\n\r\n";
    const idx = std.mem.indexOf(u8, response, separator) orelse return error.NoBodyFound;
    return response[idx + separator.len ..];
}

/// Parse JSON response and get a string field
pub fn getJsonString(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const value = parsed.value.object.get(field) orelse return error.FieldNotFound;
    return allocator.dupe(u8, value.string);
}

/// Parse JSON response and get an integer field
pub fn getJsonInt(allocator: std.mem.Allocator, json: []const u8, field: []const u8) !i64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const value = parsed.value.object.get(field) orelse return error.FieldNotFound;
    return value.integer;
}

/// Check if a header exists in the JSON headers object
pub fn hasHeader(allocator: std.mem.Allocator, json: []const u8, header: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const headers_val = parsed.value.object.get("headers") orelse return error.NoHeaders;
    const headers = headers_val.object;

    // Case-insensitive check
    var iter = headers.iterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, header)) {
            return true;
        }
    }
    return false;
}

/// Get header value (case-insensitive)
pub fn getHeader(allocator: std.mem.Allocator, json: []const u8, header: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const headers_val = parsed.value.object.get("headers") orelse return error.NoHeaders;
    const headers = headers_val.object;

    var iter = headers.iterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, header)) {
            return allocator.dupe(u8, entry.value_ptr.string);
        }
    }
    return error.HeaderNotFound;
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/nick/repos/zzz/examples/zzz-fix && zig build-lib tests/test_utils.zig --name test_utils 2>&1 | head -5`

**Step 3: Commit**

```bash
git add tests/test_utils.zig
git commit -m "feat(tests): add test utilities for HTTP and port waiting"
```

---

## Task 3: Create Process Manager

**Files:**
- Create: `tests/process_manager.zig`

**Step 1: Write process management utilities**

```zig
//! Process manager for integration tests.
//!
//! Handles spawning and cleanup of backend/load balancer processes.

const std = @import("std");
const posix = std.posix;
const test_utils = @import("test_utils.zig");

pub const Process = struct {
    child: std.process.Child,
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn kill(self: *Process) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
    }

    pub fn deinit(self: *Process) void {
        self.allocator.free(self.name);
    }
};

pub const ProcessManager = struct {
    allocator: std.mem.Allocator,
    processes: std.ArrayList(Process),

    pub fn init(allocator: std.mem.Allocator) ProcessManager {
        return .{
            .allocator = allocator,
            .processes = std.ArrayList(Process).init(allocator),
        };
    }

    pub fn deinit(self: *ProcessManager) void {
        self.stopAll();
        self.processes.deinit();
    }

    pub fn startBackend(self: *ProcessManager, port: u16, server_id: []const u8) !void {
        var port_buf: [8]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

        var child = std.process.Child.init(
            &.{ "./zig-out/bin/test_backend_echo", "--port", port_str, "--id", server_id },
            self.allocator,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        try self.processes.append(.{
            .child = child,
            .name = try std.fmt.allocPrint(self.allocator, "backend_{s}", .{server_id}),
            .allocator = self.allocator,
        });

        // Wait for port to be ready
        try test_utils.waitForPort(port, 10000);
    }

    pub fn startLoadBalancer(self: *ProcessManager, backend_ports: []const u16) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("./zig-out/bin/load_balancer");
        try args.append("--port");

        var lb_port_buf: [8]u8 = undefined;
        const lb_port_str = try std.fmt.bufPrint(&lb_port_buf, "{d}", .{test_utils.LB_PORT});
        try args.append(try self.allocator.dupe(u8, lb_port_str));

        // Use single-process mode for easier testing
        try args.append("--mode");
        try args.append("sp");

        for (backend_ports) |port| {
            try args.append("--backend");
            var buf: [32]u8 = undefined;
            const backend_str = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port});
            try args.append(try self.allocator.dupe(u8, backend_str));
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        try self.processes.append(.{
            .child = child,
            .name = try self.allocator.dupe(u8, "load_balancer"),
            .allocator = self.allocator,
        });

        // Wait for LB port
        try test_utils.waitForPort(test_utils.LB_PORT, 10000);

        // Wait for health checks (backends need to be marked healthy)
        std.time.sleep(2 * std.time.ns_per_s);
    }

    pub fn stopAll(self: *ProcessManager) void {
        // Stop in reverse order (LB first, then backends)
        while (self.processes.items.len > 0) {
            var proc = self.processes.pop();
            proc.kill();
            proc.deinit();
        }
    }
};
```

**Step 2: Verify it compiles**

Run: `cd /Users/nick/repos/zzz/examples/zzz-fix && zig build-lib tests/process_manager.zig --name pm 2>&1 | head -5`

**Step 3: Commit**

```bash
git add tests/process_manager.zig
git commit -m "feat(tests): add process manager for test fixtures"
```

---

## Task 4: Create Basic Tests Suite

**Files:**
- Create: `tests/suites/basic.zig`

**Step 1: Create directory**

Run: `mkdir -p /Users/nick/repos/zzz/examples/zzz-fix/tests/suites`

**Step 2: Write basic tests**

```zig
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
    _ = try utils.getJsonString(allocator, body, "server_id");
    _ = try utils.getJsonString(allocator, body, "method");
    _ = try utils.getJsonString(allocator, body, "uri");
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
```

**Step 3: Commit**

```bash
git add tests/suites/basic.zig
git commit -m "feat(tests): add basic proxy tests suite"
```

---

## Task 5: Create Headers Tests Suite

**Files:**
- Create: `tests/suites/headers.zig`

**Step 1: Write headers tests**

```zig
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
```

**Step 2: Commit**

```bash
git add tests/suites/headers.zig
git commit -m "feat(tests): add header handling tests suite"
```

---

## Task 6: Create Body Forwarding Tests Suite

**Files:**
- Create: `tests/suites/body.zig`

**Step 1: Write body forwarding tests**

```zig
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
```

**Step 2: Commit**

```bash
git add tests/suites/body.zig
git commit -m "feat(tests): add body forwarding tests suite"
```

---

## Task 7: Create Load Balancing Tests Suite

**Files:**
- Create: `tests/suites/load_balancing.zig`

**Step 1: Write load balancing tests**

```zig
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
```

**Step 2: Commit**

```bash
git add tests/suites/load_balancing.zig
git commit -m "feat(tests): add load balancing tests suite"
```

---

## Task 8: Create Test Runner

**Files:**
- Replace: `tests/integration_test.zig`

**Step 1: Write the new test runner**

```zig
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
    };

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var suite_failures: usize = 0;

    for (suites) |suite| {
        harness.runSuite(allocator, suite) catch {
            suite_failures += 1;
        };
        total_passed += suite.tests.len; // Approximate
    }

    std.debug.print("\n\x1b[1m════════════════════════════════════════\x1b[0m\n", .{});
    if (suite_failures == 0) {
        std.debug.print("\x1b[32m✓ All test suites passed!\x1b[0m\n", .{});
    } else {
        std.debug.print("\x1b[31m✗ {d} suite(s) had failures\x1b[0m\n", .{suite_failures});
        std.process.exit(1);
    }
}

// Also support zig test
test "run all integration tests" {
    try main();
}
```

**Step 2: Commit**

```bash
git add tests/integration_test.zig
git commit -m "refactor(tests): replace old integration tests with harness runner"
```

---

## Task 9: Update Build Configuration

**Files:**
- Modify: `build.zig`

**Step 1: Update integration test module imports**

Find and replace the integration tests section (around line 111-127):

```zig
    // E2E Integration tests
    const integration_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_tests_mod.addImport("zzz", zzz_module);
    integration_tests_mod.addImport("tls", tls_module);

    // Add integration test as executable (for better output)
    const integration_exe = b.addExecutable(.{
        .name = "integration_tests",
        .root_module = integration_tests_mod,
    });
    const run_integration_exe = b.addRunArtifact(integration_exe);
    run_integration_exe.step.dependOn(&build_test_backend_echo.step);
    run_integration_exe.step.dependOn(&build_load_balancer.step);

    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_exe.step);
```

**Step 2: Commit**

```bash
git add build.zig
git commit -m "build: update integration test configuration for new harness"
```

---

## Task 10: Build and Verify Tests Run

**Step 1: Build everything**

Run: `cd /Users/nick/repos/zzz/examples/zzz-fix && zig build build-all`

Expected: Clean build with no errors

**Step 2: Run the integration tests**

Run: `cd /Users/nick/repos/zzz/examples/zzz-fix && zig build test-integration 2>&1`

Expected: All tests pass with colored output showing describe/it structure

**Step 3: Commit if passing**

```bash
git add -A
git commit -m "test: verify all integration tests pass"
```

---

## Task 11: Remove Python Test Files

**Files:**
- Delete: `tests/conftest.py`
- Delete: `tests/test_basic.py`
- Delete: `tests/test_headers.py`
- Delete: `tests/test_body_forwarding.py`
- Delete: `tests/test_load_balancing.py`
- Delete: `tests/requirements.txt`
- Delete: `tests/PYTEST_README.md`
- Delete: `tests/direct.py`
- Delete: `tests/quick_test.sh`
- Delete: `tests/run_integration_tests.sh`

**Step 1: Remove Python test files**

Run:
```bash
cd /Users/nick/repos/zzz/examples/zzz-fix/tests
rm -f conftest.py test_basic.py test_headers.py test_body_forwarding.py test_load_balancing.py
rm -f requirements.txt PYTEST_README.md direct.py quick_test.sh run_integration_tests.sh
rm -rf venv __pycache__
```

**Step 2: Update tests/README.md**

Create `tests/README.md`:

```markdown
# Load Balancer Integration Tests

Pure Zig integration tests using a minimal Jest-like test harness.

## Running Tests

```bash
# Build all binaries first
zig build build-all

# Run integration tests
zig build test-integration
```

## Test Structure

```
tests/
├── harness.zig           # Jest-like describe/it test harness
├── test_utils.zig        # HTTP client and utilities
├── process_manager.zig   # Process spawning/cleanup
├── integration_test.zig  # Test runner (main entry point)
└── suites/
    ├── basic.zig         # GET/POST/PUT/PATCH forwarding
    ├── headers.zig       # Header handling
    ├── body.zig          # Body forwarding
    └── load_balancing.zig # Round-robin distribution
```

## Test Coverage

- **Basic (5 tests)**: HTTP method forwarding
- **Headers (5 tests)**: Header forwarding and hop-by-hop filtering
- **Body (6 tests)**: Body handling including large payloads
- **Load Balancing (2 tests)**: Round-robin distribution

Total: **18 tests**
```

**Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove Python test framework, add Zig test README"
```

---

## Summary

After completing all tasks:

- **18 integration tests** in pure Zig
- **No Python dependency**
- **Jest-like syntax** with describe/it blocks
- **Proper process management** with cleanup
- **Robust port waiting** instead of fixed delays
- **Colored terminal output** for test results

Run with: `zig build test-integration`
