const std = @import("std");
const log = std.log.scoped(.@"examples/backend1");

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

fn handler(ctx: *const Context, _: void) !Respond {
    log.info("Received request: {s} {s}", .{
        @tagName(ctx.request.method orelse .GET),
        ctx.request.uri orelse "/",
    });

    const body =
        "<html><body>" ++
        "<h1>Hello from Backend 1!</h1>" ++
        "<p>This request was handled by backend server 1.</p>" ++
        "</body></html>";
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body,
    });
}

var server: Server = undefined;

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9001;

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
        Route.init("/").all({}, handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var socket = try addr.listen(io, .{
        .kernel_backlog = 4096,
        .reuse_address = true,
    });
    defer socket.deinit(io);

    log.info("Backend 1 listening on {s}:{d}", .{ host, port });

    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 4,
        .keepalive_count_max = null,
        .connection_count_max = 1024,
    });
    defer server.deinit();

    try server.serve(io, &router, &socket);
}
