const std = @import("std");

const AcceptResult = @import("tardy").AcceptResult;
const Cross = @import("tardy").Cross;
const Pool = @import("tardy").Pool;
const RecvResult = @import("tardy").RecvResult;
const Runtime = @import("tardy").Runtime;
const SendResult = @import("tardy").SendResult;
const Socket = @import("tardy").Socket;
const Task = @import("tardy").Task;
const Timer = @import("tardy").Timer;

const Tardy = @import("tardy").Tardy(.auto);
const log = std.log.scoped(.@"tardy/example/echo");

const STACK_SIZE: usize = 1024 * 16;
const HTTP_RESPONSE = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 27\r\nContent-Type: text/plain\r\n\r\nThis is an HTTP benchmark\r\n";

fn main_frame(rt: *Runtime, server: *const Socket) !void {
    const socket = try server.accept(rt);
    defer socket.close_blocking();

    log.debug(
        "{d} - accepted socket [{f}]",
        .{ std.time.milliTimestamp(), socket.addr },
    );

    // spawn off a new frame.
    try rt.spawn(.{ rt, server }, main_frame, STACK_SIZE);

    var buffer: [1024]u8 = undefined;
    var recv_length: usize = 0;
    while (true) {
        recv_length += socket.recv(rt, &buffer) catch |e| {
            log.err("Failed to recv on socket | {}", .{e});
            return;
        };

        if (std.mem.indexOf(u8, buffer[0..recv_length], "\r\n\r\n")) |_| {
            _ = socket.send_all(rt, HTTP_RESPONSE[0..]) catch |e| {
                log.err("Failed to send on socket | {}", .{e});
                return;
            };
            recv_length = 0;
        }
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var tardy: Tardy = try .init(allocator, .{
        .threading = .auto,
        .pooling = .grow,
        .size_tasks_initial = 256,
        .size_aio_reap_max = 1024,
    });
    defer tardy.deinit();

    const host = "0.0.0.0";
    const port = 9862;

    const server: Socket = try .init(.{ .tcp = .{ .host = host, .port = port } });
    try server.bind();
    try server.listen(1024);

    try tardy.entry(
        &server,
        struct {
            fn start(rt: *Runtime, tcp_server: *const Socket) !void {
                try rt.spawn(.{ rt, tcp_server }, main_frame, STACK_SIZE);
            }
        }.start,
    );
}
