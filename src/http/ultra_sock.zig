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

    /// Connect to the backend server using std.Io (async, properly handles errors)
    pub fn connect(self: *UltraSock, io: Io) !void {
        if (self.connected) return;

        // Parse IP address and connect using std.Io
        const addr = Io.net.IpAddress.parse(self.host, self.port) catch {
            return error.InvalidAddress;
        };

        // Connect using std.Io (patched to return errors instead of panicking)
        self.stream = addr.connect(io, .{ .mode = .stream }) catch {
            return error.ConnectionFailed;
        };

        self.io = io;
        self.connected = true;
    }

    /// Send all data over the socket - uses passed io context
    pub fn send_all(self: *UltraSock, io: Io, data: []const u8) !usize {
        if (!self.connected) return error.NotConnected;
        const stream = self.stream orelse return error.SocketNotInitialized;

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

    /// Send data (single call)
    pub fn send(self: *UltraSock, io: Io, data: []const u8) !usize {
        return self.send_all(io, data);
    }

    /// Receive data from the socket - uses passed io context
    pub fn recv(self: *UltraSock, io: Io, buffer: []u8) !usize {
        if (!self.connected) return error.NotConnected;
        const stream = self.stream orelse return error.SocketNotInitialized;

        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
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

    /// Close the socket directly via posix (safe for pooled connections)
    pub fn close_blocking(self: *UltraSock) void {
        if (self.stream) |stream| {
            // Use direct posix.close() instead of stream.close(io)
            // This avoids issues with stale io context from pooled connections
            std.posix.close(stream.socket.handle);
            self.stream = null;
        }
        self.io = null;
        self.connected = false;
    }

    /// Deinit (alias for close_blocking)
    pub fn deinit(self: *UltraSock) void {
        self.close_blocking();
    }

    /// Get the raw file descriptor (for POSIX operations)
    pub fn getFd(self: *const UltraSock) ?std.posix.fd_t {
        const stream = self.stream orelse return null;
        return stream.socket.handle;
    }

    /// Set read timeout on socket (in milliseconds)
    pub fn setReadTimeout(self: *UltraSock, timeout_ms: u32) !void {
        const fd = self.getFd() orelse return error.NotConnected;
        const seconds = timeout_ms / 1000;
        const microseconds = (timeout_ms % 1000) * 1000;
        const timeout = std.posix.timeval{
            .sec = @intCast(seconds),
            .usec = @intCast(microseconds),
        };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {
            return error.SetTimeoutFailed;
        };
    }

    /// Set write timeout on socket (in milliseconds)
    pub fn setWriteTimeout(self: *UltraSock, timeout_ms: u32) !void {
        const fd = self.getFd() orelse return error.NotConnected;
        const seconds = timeout_ms / 1000;
        const microseconds = (timeout_ms % 1000) * 1000;
        const timeout = std.posix.timeval{
            .sec = @intCast(seconds),
            .usec = @intCast(microseconds),
        };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {
            return error.SetTimeoutFailed;
        };
    }

    /// Enable TCP keepalive to detect dead connections
    pub fn enableKeepalive(self: *UltraSock) !void {
        const fd = self.getFd() orelse return error.NotConnected;

        // Enable keepalive
        const enable: u32 = 1;
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {
            return error.SetOptionFailed;
        };

        // Set keepalive parameters (macOS uses TCP_KEEPALIVE for idle time)
        const idle_secs: u32 = 5; // Start probes after 5 seconds idle
        if (@hasDecl(std.posix.TCP, "KEEPALIVE")) {
            // macOS
            std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPALIVE, std.mem.asBytes(&idle_secs)) catch {};
        } else if (@hasDecl(std.posix.TCP, "KEEPIDLE")) {
            // Linux
            std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPIDLE, std.mem.asBytes(&idle_secs)) catch {};
        }
    }

    /// Write all data using POSIX (returns error instead of panicking)
    pub fn posixWriteAll(self: *UltraSock, data: []const u8) !void {
        const fd = self.getFd() orelse return error.NotConnected;
        var total_written: usize = 0;

        while (total_written < data.len) {
            const written = std.posix.write(fd, data[total_written..]) catch |err| {
                self.connected = false;
                return switch (err) {
                    error.BrokenPipe => error.BrokenPipe,
                    error.ConnectionResetByPeer => error.ConnectionResetByPeer,
                    error.NotOpenForWriting => error.NotConnected,
                    else => error.WriteFailed,
                };
            };
            if (written == 0) {
                self.connected = false;
                return error.ConnectionClosed;
            }
            total_written += written;
        }
    }

    /// Read data using POSIX (returns error instead of panicking)
    pub fn posixRead(self: *UltraSock, buffer: []u8) !usize {
        const fd = self.getFd() orelse return error.NotConnected;

        const n = std.posix.read(fd, buffer) catch |err| {
            self.connected = false;
            return switch (err) {
                error.ConnectionResetByPeer => error.ConnectionResetByPeer,
                error.NotOpenForReading => error.NotConnected,
                else => error.ReadFailed,
            };
        };

        if (n == 0) {
            self.connected = false;
        }
        return n;
    }

    /// Check if socket has pending data or is in bad state
    /// Returns true if connection should NOT be reused
    /// Uses poll() with zero timeout for non-blocking check
    pub fn hasStaleData(self: *UltraSock) bool {
        const stream = self.stream orelse return true; // No stream = stale
        const fd = stream.socket.handle;

        // Check for invalid fd
        if (fd < 0) return true;

        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        // Poll with 0 timeout = non-blocking check
        const result = std.posix.poll(&poll_fds, 0) catch {
            return true; // On error, assume stale
        };

        const revents = poll_fds[0].revents;

        // Check for any problematic conditions:
        // - POLLIN: Data waiting (stale response data)
        // - POLLHUP: Connection closed by peer
        // - POLLERR: Socket error
        // - POLLNVAL: Invalid fd
        if (result > 0) {
            if ((revents & std.posix.POLL.IN) != 0) return true;
            if ((revents & std.posix.POLL.HUP) != 0) return true;
            if ((revents & std.posix.POLL.ERR) != 0) return true;
            if ((revents & std.posix.POLL.NVAL) != 0) return true;
        }

        return false;
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
