/// Universal Socket Abstraction for HTTP
///
/// Simplified socket wrapper using Zig 0.16's std.Io for async operations.
/// TODO: Add HTTPS/TLS support when needed.
const std = @import("std");
const log = std.log.scoped(.ultra_sock);

const Io = std.Io;

/// Protocol type
pub const Protocol = enum {
    http,
    https,
};

/// UltraSock - A socket abstraction for HTTP connections
pub const UltraSock = struct {
    stream: ?Io.net.Stream = null,
    io: ?Io = null,
    protocol: Protocol,
    host: []const u8,
    port: u16,
    connected: bool = false,
    allocator: std.mem.Allocator,

    /// Initialize a new UltraSock
    pub fn init(allocator: std.mem.Allocator, protocol: Protocol, host: []const u8, port: u16) !UltraSock {
        if (protocol == .https) {
            log.warn("HTTPS not yet supported in zzz.io migration, falling back to HTTP", .{});
        }
        return UltraSock{
            .protocol = protocol,
            .host = host,
            .port = port,
            .allocator = allocator,
        };
    }

    /// Connect to the backend server
    pub fn connect(self: *UltraSock, io: Io) !void {
        if (self.connected) return;

        const addr = try Io.net.IpAddress.parse(self.host, self.port);
        self.stream = try addr.connect(io, .{ .mode = .stream });
        self.io = io;
        self.connected = true;
    }

    /// Send all data over the socket using Writer
    pub fn send_all(self: *UltraSock, _: anytype, data: []const u8) !usize {
        if (!self.connected) return error.NotConnected;

        if (self.stream) |stream| {
            if (self.io) |io| {
                var write_buf: [4096]u8 = undefined;
                var writer = stream.writer(io, &write_buf);
                writer.interface.writeAll(data) catch {
                    self.connected = false;
                    return error.BrokenPipe;
                };
                writer.interface.flush() catch {
                    self.connected = false;
                    return error.BrokenPipe;
                };
                return data.len;
            }
        }
        return error.SocketNotInitialized;
    }

    /// Send data (single call)
    pub fn send(self: *UltraSock, io: anytype, data: []const u8) !usize {
        return self.send_all(io, data);
    }

    /// Receive data from the socket using Reader
    /// Returns immediately with available data (non-blocking read)
    pub fn recv(self: *UltraSock, _: anytype, buffer: []u8) !usize {
        if (!self.connected) return error.NotConnected;

        if (self.stream) |stream| {
            if (self.io) |io| {
                var read_buf: [4096]u8 = undefined;
                var reader = stream.reader(io, &read_buf);
                // Use readVec for single non-blocking read (returns immediately with available data)
                var bufs: [1][]u8 = .{buffer};
                const n = reader.interface.readVec(&bufs) catch |err| {
                    self.connected = false;
                    if (err == error.EndOfStream) return 0;
                    return error.ReadFailed;
                };
                if (n == 0) {
                    self.connected = false;
                }
                return n;
            }
        }
        return error.SocketNotInitialized;
    }

    /// Close the socket
    pub fn close_blocking(self: *UltraSock) void {
        if (self.stream) |stream| {
            if (self.io) |io| {
                stream.close(io);
            }
            self.stream = null;
        }
        self.io = null;
        self.connected = false;
    }

    /// Deinit (alias for close_blocking)
    pub fn deinit(self: *UltraSock) void {
        self.close_blocking();
    }

    /// Create from backend config
    pub fn fromBackendConfig(allocator: std.mem.Allocator, backend: anytype) !UltraSock {
        const use_https = backend.port == 443 or std.mem.startsWith(u8, backend.host, "https://");
        const protocol: Protocol = if (use_https) .https else .http;

        var host = backend.host;
        if (std.mem.startsWith(u8, host, "https://")) {
            host = host[8..];
        } else if (std.mem.startsWith(u8, host, "http://")) {
            host = host[7..];
        }

        return try init(allocator, protocol, host, backend.port);
    }

    /// Create from BackendServer struct
    pub fn fromBackendServer(allocator: std.mem.Allocator, backend: anytype) !UltraSock {
        const protocol: Protocol = if (backend.isHttps()) .https else .http;
        return try init(allocator, protocol, backend.getHost(), backend.port);
    }
};
