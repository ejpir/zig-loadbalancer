const std = @import("std");

const AcceptResult = @import("tardy").AcceptResult;
const Cross = @import("tardy").Cross;
const Dir = @import("tardy").Dir;
const File = @import("tardy").File;
const Pool = @import("tardy").Pool;
const RecvResult = @import("tardy").RecvResult;
const Runtime = @import("tardy").Runtime;
const SendResult = @import("tardy").SendResult;
const Socket = @import("tardy").Socket;
const Task = @import("tardy").Task;
const Timer = @import("tardy").Timer;

const Tardy = @import("tardy").Tardy(.auto);
const EntryParams = struct {
    file_name: [:0]const u8,
    server_socket: *const Socket,
};
const log = std.log.scoped(.@"tardy/example/echo");

fn stream_frame(rt: *Runtime, server: *const Socket, file_name: [:0]const u8) !void {
    defer rt.spawn(.{ rt, server, file_name }, stream_frame, 1024 * 1024 * 4) catch unreachable;

    const socket = try server.accept(rt);
    defer socket.close_blocking();

    const file = try Dir.cwd().open_file(rt, file_name, .{});
    defer file.close_blocking();

    log.debug(
        "{d} - accepted socket [{f}]",
        .{ std.time.milliTimestamp(), socket.addr },
    );

    var buffer: [1024]u8 = undefined;
    var socket_w = socket.writer(rt, &buffer);
    const socket_sw = &socket_w.interface;
    defer socket_sw.flush() catch unreachable;

    file.stream_to(
        socket_sw,
        rt,
    ) catch unreachable;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var tardy: Tardy = try .init(allocator, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 2,
        .size_aio_reap_max = 1,
    });
    defer tardy.deinit();

    const host = "0.0.0.0";
    const port = 9862;

    const server: Socket = try .init(.{ .tcp = .{ .host = host, .port = port } });
    try server.bind();
    try server.listen(1024);

    var i: usize = 0;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const file_name: [:0]const u8 = blk: {
        while (args.next()) |arg| : (i += 1) {
            if (i == 1) break :blk arg;
        }

        try std.fs.File.stdout().writeAll("file name not passed in: ./stream [file name]");
        return;
    };

    var params: EntryParams = .{
        .file_name = file_name,
        .server_socket = &server,
    };

    try tardy.entry(
        &params,
        struct {
            fn start(rt: *Runtime, p: *EntryParams) !void {
                try rt.spawn(.{ rt, p.server_socket, p.file_name }, stream_frame, 1024 * 1024 * 4);
            }
        }.start,
    );
}
