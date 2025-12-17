/// Backend that proxies to backend2 - measures raw zzz proxy overhead
const std = @import("std");
const log = std.log.scoped(.backend_proxy);

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;
const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

fn proxyHandler(ctx: *const Context, _: void) !Respond {
    const io = ctx.io;

    // Connect to backend2
    const addr = Io.net.IpAddress.parse("127.0.0.1", 9002) catch {
        return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.HTML });
    };
    const backend = addr.connect(io, .{ .mode = .stream }) catch {
        return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.HTML });
    };
    defer backend.close(io);

    // Forward request
    var write_buf: [4096]u8 = undefined;
    var writer = backend.writer(io, &write_buf);

    const method = @tagName(ctx.request.method orelse .GET);
    const uri = ctx.request.uri orelse "/";

    writer.interface.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:9002\r\nConnection: close\r\n\r\n", .{ method, uri }) catch {
        return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.HTML });
    };
    writer.interface.flush() catch {
        return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.HTML });
    };

    // Read response
    var read_buf: [4096]u8 = undefined;
    var reader = backend.reader(io, &read_buf);

    var response_buf: [8192]u8 = undefined;
    var response_len: usize = 0;

    while (response_len < response_buf.len) {
        var bufs: [1][]u8 = .{response_buf[response_len..]};
        const n = reader.interface.readVec(&bufs) catch break;
        if (n == 0) break;
        response_len += n;
    }

    // Find body (after \r\n\r\n)
    if (std.mem.indexOf(u8, response_buf[0..response_len], "\r\n\r\n")) |header_end| {
        const body = response_buf[header_end + 4 .. response_len];
        return ctx.response.apply(.{
            .status = .OK,
            .mime = http.Mime.HTML,
            .body = body,
        });
    }

    return ctx.response.apply(.{ .status = .@"Bad Gateway", .mime = http.Mime.HTML });
}

var server: Server = undefined;

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 8080;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var router = try Router.init(allocator, &.{
        Route.init("/").all({}, proxyHandler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var socket = try addr.listen(io, .{ .kernel_backlog = 4096, .reuse_address = true });
    defer socket.deinit(io);

    log.warn("Proxy backend listening on {s}:{d} -> 127.0.0.1:9002", .{ host, port });

    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 32,
        .keepalive_count_max = 1000,
        .connection_count_max = 10000,
    });
    defer server.deinit();

    try server.serve(io, &router, &socket);
}
