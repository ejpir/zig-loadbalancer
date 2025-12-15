const std = @import("std");

const Tardy = @import("tardy").Tardy(.auto);
const Timer = @import("tardy").Timer;
const Socket = @import("tardy").Socket;
const Runtime = @import("tardy").Runtime;

const secsock = @import("secsock");
const SecureSocket = secsock.SecureSocket;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var tardy = try Tardy.init(allocator, .{ .threading = .single });
    defer tardy.deinit();

    var bearssl = secsock.BearSSL.init(allocator);
    defer bearssl.deinit();

    //try bearssl.add_cert_chain(
    //    "CERTIFICATE",
    //    @embedFile("certs/cert.pem"),
    //    "EC PRIVATE KEY",
    //    @embedFile("certs/key.pem"),
    //);

    try bearssl.add_cert_chain(
        "CERTIFICATE",
        @embedFile("certs/rsa_cert.pem"),
        "PRIVATE KEY",
        @embedFile("certs/rsa_key.pem"),
    );

    const socket = try Socket.init(.{ .tcp = .{ .host = "127.0.0.1", .port = 9862 } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(128);

    const secure = try bearssl.to_secure_socket(socket, .server);
    defer secure.deinit();

    try tardy.entry(&secure, struct {
        fn entry(rt: *Runtime, s: *const SecureSocket) !void {
            try rt.spawn(.{ rt, s }, echo_frame, 1024 * 1024 * 16);
        }
    }.entry);
}

fn echo_frame(rt: *Runtime, secure: *const SecureSocket) !void {
    const connected = try secure.accept(rt);
    defer connected.deinit();
    defer connected.socket.close_blocking();

    while (true) {
        var buf: [1024]u8 = undefined;
        const count = connected.recv(rt, &buf) catch |e| if (e == error.Closed) break else return e;
        std.log.info("recv count: {d}", .{count});
        _ = connected.send(rt, buf[0..count]) catch |e| if (e == error.Closed) break else return e;
    }
}
