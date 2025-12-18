/// End-to-End Integration Tests for Load Balancer
///
/// These tests verify complete request/response flows through the load balancer
/// including header forwarding, body forwarding, load balancing, and failover.
///
/// Test Architecture:
/// 1. Start test backend servers (echo servers that return request details)
/// 2. Start load balancer pointing to test backends
/// 3. Make HTTP requests to load balancer
/// 4. Verify responses contain expected data
/// 5. Clean up processes
///
/// Run with: zig build test-integration
const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.integration_test);

const Io = std.Io;
const posix = std.posix;

// Test configuration
const BACKEND1_PORT: u16 = 19001;
const BACKEND2_PORT: u16 = 19002;
const BACKEND3_PORT: u16 = 19003;
const LB_PORT: u16 = 18080;
const TEST_HOST = "127.0.0.1";

// Timeouts
const STARTUP_DELAY_MS = 500; // Wait for servers to start
const SHUTDOWN_DELAY_MS = 100; // Wait for graceful shutdown
const REQUEST_TIMEOUT_MS = 5000; // Maximum time for a request

/// Process handle for cleanup
const ProcessHandle = struct {
    child: std.process.Child,
    name: []const u8,

    fn kill(self: *ProcessHandle) void {
        _ = self.child.kill() catch |err| {
            log.warn("Failed to kill {s}: {}", .{ self.name, err });
        };
    }

    fn wait(self: *ProcessHandle) void {
        _ = self.child.wait() catch |err| {
            log.warn("Failed to wait for {s}: {}", .{ self.name, err });
        };
    }
};

/// Test fixture - manages backend and load balancer processes
const TestFixture = struct {
    allocator: std.mem.Allocator,
    backends: std.ArrayListUnmanaged(ProcessHandle),
    load_balancer: ?ProcessHandle,

    fn init(allocator: std.mem.Allocator) TestFixture {
        return .{
            .allocator = allocator,
            .backends = .empty,
            .load_balancer = null,
        };
    }

    fn deinit(self: *TestFixture) void {
        self.stopAll();
        self.backends.deinit(self.allocator);
    }

    fn startBackend(self: *TestFixture, port: u16, server_id: []const u8) !void {
        const exe_path = "./zig-out/bin/test_backend_echo";

        var port_buf: [16]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

        var child = std.process.Child.init(&.{
            exe_path,
            "--port",
            port_str,
            "--id",
            server_id,
        }, self.allocator);

        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        try self.backends.append(self.allocator, .{
            .child = child,
            .name = try std.fmt.allocPrint(self.allocator, "backend_{s}", .{server_id}),
        });

        log.info("Started backend {s} on port {d} (PID: {d})", .{ server_id, port, child.id });
    }

    fn startLoadBalancer(self: *TestFixture, backend_ports: []const u16) !void {
        const exe_path = "./zig-out/bin/load_balancer_sp"; // Use single-process for easier testing

        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, exe_path);
        try args.append(self.allocator, "--port");

        var lb_port_buf: [16]u8 = undefined;
        const lb_port_str = try std.fmt.bufPrint(&lb_port_buf, "{d}", .{LB_PORT});
        try args.append(self.allocator, try self.allocator.dupe(u8, lb_port_str));

        // Add backends
        for (backend_ports) |port| {
            try args.append(self.allocator, "--backend");
            var backend_buf: [32]u8 = undefined;
            const backend_str = try std.fmt.bufPrint(&backend_buf, "127.0.0.1:{d}", .{port});
            try args.append(self.allocator, try self.allocator.dupe(u8, backend_str));
        }

        var child = std.process.Child.init(args.items, self.allocator);

        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        self.load_balancer = .{
            .child = child,
            .name = try self.allocator.dupe(u8, "load_balancer"),
        };

        log.info("Started load balancer on port {d} (PID: {d})", .{ LB_PORT, child.id });
    }

    fn stopAll(self: *TestFixture) void {
        // Stop load balancer first
        if (self.load_balancer) |*lb| {
            log.info("Stopping load balancer...", .{});
            lb.kill();
            lb.wait();
            self.allocator.free(lb.name);
        }

        // Stop backends
        for (self.backends.items) |*backend| {
            log.info("Stopping {s}...", .{backend.name});
            backend.kill();
            backend.wait();
            self.allocator.free(backend.name);
        }

        self.backends.clearRetainingCapacity();
        self.load_balancer = null;
    }

    fn waitForStartup(self: *TestFixture) !void {
        _ = self;
        posix.nanosleep(0, STARTUP_DELAY_MS * std.time.ns_per_ms);
    }
};

/// HTTP client for making test requests
fn makeHttpRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    headers: ?std.StringHashMap([]const u8),
    body: ?[]const u8,
) ![]const u8 {
    // Build request
    var request: std.ArrayListUnmanaged(u8) = .empty;
    defer request.deinit(allocator);

    // Request line
    const request_line = try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ method, path, TEST_HOST, LB_PORT });
    try request.appendSlice(allocator, request_line);

    // Custom headers
    if (headers) |hdrs| {
        var iter = hdrs.iterator();
        while (iter.next()) |entry| {
            const header_line = try std.fmt.allocPrint(allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            try request.appendSlice(allocator, header_line);
        }
    }

    // Body
    if (body) |b| {
        const content_len = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n", .{b.len});
        try request.appendSlice(allocator, content_len);
    }

    try request.appendSlice(allocator, "Connection: close\r\n");
    try request.appendSlice(allocator, "\r\n");

    if (body) |b| {
        try request.appendSlice(allocator, b);
    }

    // Connect and send
    const addr = try Io.net.IpAddress.parse(TEST_HOST, LB_PORT);
    const tcp_socket = try posix.socket(addr.family(), posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(tcp_socket);

    try posix.connect(tcp_socket, &addr.addr, addr.addrLen());
    const stream = std.fs.File{ .handle = tcp_socket };
    defer stream.close();

    try stream.writeAll(request.items);

    // Read response
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;
        try response.appendSlice(allocator, buf[0..n]);
    }

    return response.toOwnedSlice(allocator);
}

fn extractBody(response: []const u8) ![]const u8 {
    // Find \r\n\r\n separating headers from body
    const separator = "\r\n\r\n";
    if (std.mem.indexOf(u8, response, separator)) |idx| {
        return response[idx + separator.len ..];
    }
    return error.NoBodyFound;
}

fn parseJson(allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
}

// ============================================================================
// Basic Functionality Tests
// ============================================================================

test "integration: GET request forwarded correctly" {
    const allocator = testing.allocator;

    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();

    // Start backend and load balancer
    try fixture.startBackend(BACKEND1_PORT, "backend1");
    try fixture.startLoadBalancer(&.{BACKEND1_PORT});
    try fixture.waitForStartup();

    // Make GET request
    const response = try makeHttpRequest(allocator, "GET", "/test/path", null, null);
    defer allocator.free(response);

    const body = try extractBody(response);
    const parsed = try parseJson(allocator, body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // Verify response
    try testing.expectEqualStrings("GET", root.get("method").?.string);
    try testing.expectEqualStrings("/test/path", root.get("uri").?.string);
    try testing.expectEqual(@as(i64, 0), root.get("body_length").?.integer);
}

test "integration: POST request with JSON body forwarded correctly" {
    const allocator = testing.allocator;

    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.startBackend(BACKEND1_PORT, "backend1");
    try fixture.startLoadBalancer(&.{BACKEND1_PORT});
    try fixture.waitForStartup();

    // Create headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("Content-Type", "application/json");

    const request_body = "{\"test\":\"data\",\"number\":42}";

    // Make POST request
    const response = try makeHttpRequest(allocator, "POST", "/api/endpoint", headers, request_body);
    defer allocator.free(response);

    const body = try extractBody(response);
    const parsed = try parseJson(allocator, body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // Verify response
    try testing.expectEqualStrings("POST", root.get("method").?.string);
    try testing.expectEqualStrings("/api/endpoint", root.get("uri").?.string);
    try testing.expectEqualStrings(request_body, root.get("body").?.string);
    try testing.expectEqual(@as(i64, request_body.len), root.get("body_length").?.integer);

    // Verify Content-Type header was forwarded
    const resp_headers = root.get("headers").?.object;
    try testing.expect(resp_headers.get("Content-Type") != null);
}

test "integration: PUT request with body forwarded correctly" {
    const allocator = testing.allocator;

    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.startBackend(BACKEND1_PORT, "backend1");
    try fixture.startLoadBalancer(&.{BACKEND1_PORT});
    try fixture.waitForStartup();

    const request_body = "Updated content for PUT request";

    // Make PUT request
    const response = try makeHttpRequest(allocator, "PUT", "/resource/123", null, request_body);
    defer allocator.free(response);

    const body = try extractBody(response);
    const parsed = try parseJson(allocator, body);
    defer parsed.deinit();

    const root = parsed.value.object;

    try testing.expectEqualStrings("PUT", root.get("method").?.string);
    try testing.expectEqualStrings("/resource/123", root.get("uri").?.string);
    try testing.expectEqualStrings(request_body, root.get("body").?.string);
}

test "integration: Custom headers forwarded to backend" {
    const allocator = testing.allocator;

    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.startBackend(BACKEND1_PORT, "backend1");
    try fixture.startLoadBalancer(&.{BACKEND1_PORT});
    try fixture.waitForStartup();

    // Create custom headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("X-Custom-Header", "CustomValue");
    try headers.put("X-Request-ID", "test-123");
    try headers.put("Authorization", "Bearer token123");

    const response = try makeHttpRequest(allocator, "GET", "/", headers, null);
    defer allocator.free(response);

    const body = try extractBody(response);
    const parsed = try parseJson(allocator, body);
    defer parsed.deinit();

    const root = parsed.value.object;
    const resp_headers = root.get("headers").?.object;

    // Verify custom headers were forwarded
    try testing.expectEqualStrings("CustomValue", resp_headers.get("X-Custom-Header").?.string);
    try testing.expectEqualStrings("test-123", resp_headers.get("X-Request-ID").?.string);
    try testing.expectEqualStrings("Bearer token123", resp_headers.get("Authorization").?.string);
}

test "integration: Hop-by-hop headers NOT forwarded" {
    const allocator = testing.allocator;

    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.startBackend(BACKEND1_PORT, "backend1");
    try fixture.startLoadBalancer(&.{BACKEND1_PORT});
    try fixture.waitForStartup();

    // Create headers including hop-by-hop headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("Connection", "keep-alive");
    try headers.put("Keep-Alive", "timeout=5");
    try headers.put("Transfer-Encoding", "chunked");
    try headers.put("X-Safe-Header", "this-should-be-forwarded");

    const response = try makeHttpRequest(allocator, "GET", "/", headers, null);
    defer allocator.free(response);

    const body = try extractBody(response);
    const parsed = try parseJson(allocator, body);
    defer parsed.deinit();

    const root = parsed.value.object;
    const resp_headers = root.get("headers").?.object;

    // Verify hop-by-hop headers were NOT forwarded
    try testing.expect(resp_headers.get("Connection") == null);
    try testing.expect(resp_headers.get("Keep-Alive") == null);
    try testing.expect(resp_headers.get("Transfer-Encoding") == null);

    // But safe headers should be forwarded
    try testing.expectEqualStrings("this-should-be-forwarded", resp_headers.get("X-Safe-Header").?.string);
}

// ============================================================================
// Load Balancing Tests
// ============================================================================

test "integration: Round-robin distributes requests across backends" {
    const allocator = testing.allocator;

    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();

    // Start multiple backends
    try fixture.startBackend(BACKEND1_PORT, "backend1");
    try fixture.startBackend(BACKEND2_PORT, "backend2");
    try fixture.startBackend(BACKEND3_PORT, "backend3");
    try fixture.startLoadBalancer(&.{ BACKEND1_PORT, BACKEND2_PORT, BACKEND3_PORT });
    try fixture.waitForStartup();

    // Track which backends handle requests
    var backend_counts = std.StringHashMap(usize).init(allocator);
    defer backend_counts.deinit();

    // Make multiple requests
    const num_requests = 9; // Divisible by 3 for perfect distribution
    for (0..num_requests) |i| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/request/{d}", .{i});

        const response = try makeHttpRequest(allocator, "GET", path, null, null);
        defer allocator.free(response);

        const body = try extractBody(response);
        const parsed = try parseJson(allocator, body);
        defer parsed.deinit();

        const root = parsed.value.object;
        const server_id = root.get("server_id").?.string;

        // Count requests per backend
        const result = try backend_counts.getOrPut(server_id);
        if (!result.found_existing) {
            result.value_ptr.* = 0;
        }
        result.value_ptr.* += 1;
    }

    // Verify round-robin distribution
    // Each backend should handle num_requests/3 requests
    const expected_per_backend = num_requests / 3;

    try testing.expectEqual(expected_per_backend, backend_counts.get("backend1").?);
    try testing.expectEqual(expected_per_backend, backend_counts.get("backend2").?);
    try testing.expectEqual(expected_per_backend, backend_counts.get("backend3").?);
}

// ============================================================================
// Connection Pooling Tests
// ============================================================================

test "integration: Multiple sequential requests work" {
    const allocator = testing.allocator;

    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.startBackend(BACKEND1_PORT, "backend1");
    try fixture.startLoadBalancer(&.{BACKEND1_PORT});
    try fixture.waitForStartup();

    // Make multiple sequential requests to verify pooling works
    for (0..5) |i| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/seq/{d}", .{i});

        const response = try makeHttpRequest(allocator, "GET", path, null, null);
        defer allocator.free(response);

        const body = try extractBody(response);
        const parsed = try parseJson(allocator, body);
        defer parsed.deinit();

        const root = parsed.value.object;

        // Verify each request succeeds
        try testing.expectEqualStrings("backend1", root.get("server_id").?.string);
        try testing.expectEqualStrings(path, root.get("uri").?.string);
    }
}

// ============================================================================
// Body Forwarding Edge Cases
// ============================================================================

test "integration: Large POST body forwarded correctly" {
    const allocator = testing.allocator;

    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.startBackend(BACKEND1_PORT, "backend1");
    try fixture.startLoadBalancer(&.{BACKEND1_PORT});
    try fixture.waitForStartup();

    // Create a larger body (4KB)
    var large_body = try allocator.alloc(u8, 4096);
    defer allocator.free(large_body);
    @memset(large_body, 'X');

    const response = try makeHttpRequest(allocator, "POST", "/large", null, large_body);
    defer allocator.free(response);

    const body = try extractBody(response);
    const parsed = try parseJson(allocator, body);
    defer parsed.deinit();

    const root = parsed.value.object;

    // Verify body length
    try testing.expectEqual(@as(i64, large_body.len), root.get("body_length").?.integer);
}

test "integration: Empty body on POST works" {
    const allocator = testing.allocator;

    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.startBackend(BACKEND1_PORT, "backend1");
    try fixture.startLoadBalancer(&.{BACKEND1_PORT});
    try fixture.waitForStartup();

    const response = try makeHttpRequest(allocator, "POST", "/empty", null, "");
    defer allocator.free(response);

    const body = try extractBody(response);
    const parsed = try parseJson(allocator, body);
    defer parsed.deinit();

    const root = parsed.value.object;

    try testing.expectEqualStrings("POST", root.get("method").?.string);
    try testing.expectEqual(@as(i64, 0), root.get("body_length").?.integer);
}

// ============================================================================
// Test Main
// ============================================================================

test {
    std.testing.refAllDecls(@This());
}
