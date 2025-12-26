/// Mock OTLP Collector - Receives and stores traces for integration tests
///
/// Provides:
/// - POST /v1/traces - Receive OTLP traces (protobuf)
/// - GET /traces - Retrieve stored traces as JSON
/// - DELETE /traces - Clear stored traces
///
/// This allows integration tests to verify that telemetry is correctly exported.
const std = @import("std");
const log = std.log.scoped(.mock_otlp);

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;
const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

/// Stored trace data for test verification
const StoredTrace = struct {
    sequence: usize,
    body_size: usize,
    /// Raw protobuf body (first 1KB for debugging)
    body_preview: []const u8,
};

var stored_traces: std.ArrayListUnmanaged(StoredTrace) = .empty;
var traces_mutex: std.Thread.Mutex = .{};
var trace_allocator: std.mem.Allocator = undefined;
var trace_sequence: usize = 0;

/// Handle incoming OTLP traces
fn handleOtlpTraces(ctx: *const Context, _: void) !Respond {
    const body = ctx.request.body orelse "";

    log.info("Received OTLP trace: {d} bytes", .{body.len});

    // Store trace info
    traces_mutex.lock();
    defer traces_mutex.unlock();

    // Store preview of body (up to 1KB)
    const preview_len = @min(body.len, 1024);
    const preview = trace_allocator.dupe(u8, body[0..preview_len]) catch {
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.JSON,
            .body = "{\"error\":\"allocation_failed\"}",
        });
    };

    trace_sequence += 1;
    stored_traces.append(trace_allocator, .{
        .sequence = trace_sequence,
        .body_size = body.len,
        .body_preview = preview,
    }) catch {
        trace_allocator.free(preview);
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.JSON,
            .body = "{\"error\":\"storage_failed\"}",
        });
    };

    log.info("Stored trace #{d}", .{stored_traces.items.len});

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        .body = "{}",
    });
}

/// Retrieve stored traces for test verification
fn handleGetTraces(ctx: *const Context, _: void) !Respond {
    const allocator = ctx.allocator;

    traces_mutex.lock();
    defer traces_mutex.unlock();

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"trace_count\":");

    var count_buf: [16]u8 = undefined;
    const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{stored_traces.items.len});
    try json.appendSlice(allocator, count_str);

    try json.appendSlice(allocator, ",\"traces\":[");

    for (stored_traces.items, 0..) |trace, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        try json.appendSlice(allocator, "{\"sequence\":");
        var seq_buf: [32]u8 = undefined;
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{trace.sequence});
        try json.appendSlice(allocator, seq_str);

        try json.appendSlice(allocator, ",\"body_size\":");
        var size_buf: [16]u8 = undefined;
        const size_str = try std.fmt.bufPrint(&size_buf, "{d}", .{trace.body_size});
        try json.appendSlice(allocator, size_str);

        // Add hex preview of first few bytes for debugging
        try json.appendSlice(allocator, ",\"body_preview_hex\":\"");
        const hex_len = @min(trace.body_preview.len, 64);
        for (trace.body_preview[0..hex_len]) |byte| {
            var hex_buf: [2]u8 = undefined;
            _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{byte}) catch continue;
            try json.appendSlice(allocator, &hex_buf);
        }
        try json.appendSlice(allocator, "\"}");
    }

    try json.appendSlice(allocator, "]}");

    const response_body = try json.toOwnedSlice(allocator);

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        .body = response_body,
    });
}

/// Clear stored traces
fn handleClearTraces(ctx: *const Context, _: void) !Respond {
    traces_mutex.lock();
    defer traces_mutex.unlock();

    for (stored_traces.items) |trace| {
        trace_allocator.free(trace.body_preview);
    }
    stored_traces.clearRetainingCapacity();
    trace_sequence = 0;

    log.info("Cleared all stored traces", .{});

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        .body = "{\"cleared\":true}",
    });
}

var server: Server = undefined;

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var port: u16 = 14318; // Default OTLP test port

    // Parse command line arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 < args.len) {
                port = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 1;
            }
        }
    }

    const host: []const u8 = "127.0.0.1";

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Set up trace storage allocator
    trace_allocator = allocator;

    // Clean up stored traces on exit
    defer {
        for (stored_traces.items) |trace| {
            trace_allocator.free(trace.body_preview);
        }
        stored_traces.deinit(trace_allocator);
    }

    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var router = try Router.init(allocator, &.{
        // OTLP trace endpoint
        Route.init("/v1/traces").post({}, handleOtlpTraces).layer(),
        // Test verification endpoints
        Route.init("/traces").get({}, handleGetTraces).delete({}, handleClearTraces).layer(),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var socket = try addr.listen(io, .{
        .kernel_backlog = 1024,
        .reuse_address = true,
    });
    defer socket.deinit(io);

    log.info("Mock OTLP Collector listening on {s}:{d}", .{ host, port });

    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 64, // Larger buffer for protobuf data
        .keepalive_count_max = null,
        .connection_count_max = 128,
    });
    defer server.deinit();

    try server.serve(io, &router, &socket);
}
