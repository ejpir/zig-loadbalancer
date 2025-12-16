const std = @import("std");
const log = std.log.scoped(.@"examples/backend1");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

fn handler(ctx: *const Context, _: void) !Respond {
    // Log some request info
    log.info("Received request: {s} {s}", .{
        @tagName(ctx.request.method orelse .GET),
        ctx.request.uri orelse "/",
    });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "<html><body><h1>Hello from Backend 1!</h1><p>This request was handled by backend server 1.</p></body></html>",
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9001;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .auto });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/").all({}, handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    log.info("Backend 1 listening on {s}:{d}", .{ host, port });

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 4,
                    .keepalive_count_max = null,
                    .connection_count_max = 1024,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
