/// TCP Passthrough Load Balancer (Layer 4)
///
/// No HTTP parsing - just forward raw bytes between client and backend.
/// Much faster but loses HTTP-aware features (sticky sessions, path routing, etc.)
const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.tcp_lb);

const Io = std.Io;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const Backend = struct {
    host: []const u8,
    port: u16,
};

const backends: []const Backend = &.{
    .{ .host = "127.0.0.1", .port = 9001 },
    .{ .host = "127.0.0.1", .port = 9002 },
};

var rr_counter: usize = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const port: u16 = 8080;
    const host = "0.0.0.0";

    log.warn("=== TCP Passthrough Load Balancer ===", .{});
    log.warn("Listen: {s}:{d}, Backends: {d}", .{ host, port, backends.len });

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try Io.net.IpAddress.parse(host, port);
    var socket = try addr.listen(io, .{ .kernel_backlog = 4096, .reuse_address = true });
    defer socket.deinit(io);

    log.warn("Listening on {s}:{d}", .{ host, port });

    // Concurrent task group for handlers
    var group: Io.Group = .init;
    defer group.cancel(io);

    // Accept loop
    while (true) {
        // Use select with single future (like zzz does)
        var accept_future = io.async(Io.net.Server.accept, .{ &socket, io });
        defer _ = accept_future.cancel(io) catch {};

        const result = io.select(.{ .a = &accept_future }) catch |err| {
            log.err("Select error: {s}", .{@errorName(err)});
            continue;
        };

        const client_stream = result.a catch |err| {
            log.err("Accept error: {s}", .{@errorName(err)});
            continue;
        };

        // Spawn concurrent handler
        group.concurrent(io, handleConnection, .{ io, client_stream }) catch |err| {
            log.err("Spawn error: {s}", .{@errorName(err)});
            client_stream.close(io);
        };
    }
}

fn handleConnection(io: Io, client_stream: Io.net.Stream) void {
    defer client_stream.close(io);

    // Select backend (round-robin)
    const backend_idx = @atomicRmw(usize, &rr_counter, .Add, 1, .monotonic) % backends.len;
    const backend = backends[backend_idx];

    // Connect to backend
    const backend_addr = Io.net.IpAddress.parse(backend.host, backend.port) catch {
        return;
    };
    const backend_stream = backend_addr.connect(io, .{ .mode = .stream }) catch {
        return;
    };
    defer backend_stream.close(io);

    // Buffers
    var client_buf: [8192]u8 = undefined;
    var backend_buf: [8192]u8 = undefined;

    var client_reader = client_stream.reader(io, &client_buf);
    var backend_reader = backend_stream.reader(io, &backend_buf);

    var client_write_buf: [8192]u8 = undefined;
    var backend_write_buf: [8192]u8 = undefined;
    var client_writer = client_stream.writer(io, &client_write_buf);
    var backend_writer = backend_stream.writer(io, &backend_write_buf);

    // Forward client request to backend (read until \r\n\r\n)
    var request_buf: [16384]u8 = undefined;
    var request_len: usize = 0;

    while (request_len < request_buf.len) {
        var bufs: [1][]u8 = .{request_buf[request_len..]};
        const n = client_reader.interface.readVec(&bufs) catch return;
        if (n == 0) return;
        request_len += n;

        // Check for end of HTTP headers
        if (std.mem.indexOf(u8, request_buf[0..request_len], "\r\n\r\n")) |_| {
            break;
        }
    }

    // Send to backend
    backend_writer.interface.writeAll(request_buf[0..request_len]) catch return;
    backend_writer.interface.flush() catch return;

    // Forward backend response to client
    while (true) {
        var bufs: [1][]u8 = .{backend_buf[0..]};
        const n = backend_reader.interface.readVec(&bufs) catch break;
        if (n == 0) break;

        client_writer.interface.writeAll(backend_buf[0..n]) catch break;
        client_writer.interface.flush() catch break;
    }
}
