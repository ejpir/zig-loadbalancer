/// Test Backend Server - Echoes request details for integration tests
///
/// This backend server responds with JSON containing:
/// - Request method
/// - Request URI
/// - Request headers
/// - Request body (if present)
/// - Server ID
///
/// This allows integration tests to verify that the load balancer
/// correctly forwards requests, headers, and bodies.
const std = @import("std");
const log = std.log.scoped(.test_backend_echo);

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;
const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

const ServerConfig = struct {
    port: u16,
    server_id: []const u8,
    should_fail: bool = false, // For testing failover
};

var config: ServerConfig = undefined;

fn escapeJson(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |ch| {
        if (ch == '"') {
            try result.appendSlice(allocator, "\\\"");
        } else if (ch == '\\') {
            try result.appendSlice(allocator, "\\\\");
        } else if (ch == '\n') {
            try result.appendSlice(allocator, "\\n");
        } else if (ch == '\r') {
            try result.appendSlice(allocator, "\\r");
        } else if (ch == '\t') {
            try result.appendSlice(allocator, "\\t");
        } else {
            try result.append(allocator, ch);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn echoHandler(ctx: *const Context, _: void) !Respond {
    if (config.should_fail) {
        log.warn("Server {s} configured to fail - returning 500", .{config.server_id});
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.JSON,
            .body = "{\"error\":\"server_configured_to_fail\"}",
        });
    }

    const method = @tagName(ctx.request.method orelse .GET);
    const uri = ctx.request.uri orelse "/";
    const body = ctx.request.body orelse "";

    log.info("Server {s}: {s} {s} (body_len={d})", .{
        config.server_id,
        method,
        uri,
        body.len,
    });

    // Use ctx.allocator which persists beyond this function
    const allocator = ctx.allocator;

    var response_json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response_json.deinit(allocator);

    // Start JSON object
    try response_json.appendSlice(allocator, "{");

    // Server ID
    const server_id_part = try std.fmt.allocPrint(allocator, "\"server_id\":\"{s}\",", .{config.server_id});
    try response_json.appendSlice(allocator, server_id_part);

    // Method
    const method_part = try std.fmt.allocPrint(allocator, "\"method\":\"{s}\",", .{method});
    try response_json.appendSlice(allocator, method_part);

    // URI
    const uri_part = try std.fmt.allocPrint(allocator, "\"uri\":\"{s}\",", .{uri});
    try response_json.appendSlice(allocator, uri_part);

    // Headers
    try response_json.appendSlice(allocator, "\"headers\":{");
    var header_iter = ctx.request.headers.iterator();
    var first = true;
    while (header_iter.next()) |entry| {
        if (!first) try response_json.appendSlice(allocator, ",");
        first = false;
        const header_part = try std.fmt.allocPrint(allocator, "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        try response_json.appendSlice(allocator, header_part);
    }
    try response_json.appendSlice(allocator, "},");

    // Body (escape quotes)
    const escaped_body = try escapeJson(allocator, body);
    const body_part = try std.fmt.allocPrint(allocator, "\"body\":\"{s}\",", .{escaped_body});
    try response_json.appendSlice(allocator, body_part);

    // Body length
    const body_len_part = try std.fmt.allocPrint(allocator, "\"body_length\":{d}", .{body.len});
    try response_json.appendSlice(allocator, body_len_part);

    // End JSON object
    try response_json.appendSlice(allocator, "}");

    const response_body = try response_json.toOwnedSlice(allocator);

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        .body = response_body,
    });
}

var server: Server = undefined;

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var port: u16 = 19001;
    var server_id: []const u8 = "test_backend_1";

    // Parse command line arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 < args.len) {
                port = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--id")) {
            if (i + 1 < args.len) {
                server_id = args[i + 1];
                i += 1;
            }
        }
    }

    config = .{
        .port = port,
        .server_id = server_id,
        .should_fail = false,
    };

    const host: []const u8 = "127.0.0.1";

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var router = try Router.init(allocator, &.{
        Route.init("/").all({}, echoHandler).layer(),
        Route.init("/%r").all({}, echoHandler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var socket = try addr.listen(io, .{
        .kernel_backlog = 1024,
        .reuse_address = true,
    });
    defer socket.deinit(io);

    log.info("Test Echo Backend '{s}' listening on {s}:{d}", .{ server_id, host, port });

    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 4,
        .keepalive_count_max = null,
        .connection_count_max = 1024,
    });
    defer server.deinit();

    try server.serve(io, &router, &socket);
}
