/// Universal Socket Abstraction for HTTP/HTTPS
///
/// Simplified socket wrapper using Zig 0.16's std.Io for async operations.
/// Supports TLS via std.crypto.tls.Client with configurable certificate verification.
const std = @import("std");
const log = std.log.scoped(.ultra_sock);

const Io = std.Io;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

/// Protocol type
pub const Protocol = enum {
    http,
    https,
};

/// TLS configuration options
pub const TlsOptions = struct {
    /// Certificate authority verification mode
    pub const CaVerification = union(enum) {
        /// No CA verification - INSECURE, for local dev only
        none,
        /// Use system trust store (default)
        system,
        /// Use custom certificate bundle
        custom: Certificate.Bundle,
    };

    /// Host verification mode
    pub const HostVerification = union(enum) {
        /// No hostname verification - INSECURE
        none,
        /// Verify against connection host (default)
        from_connection,
        /// Verify against explicit hostname
        explicit: []const u8,
    };

    ca: CaVerification = .system,
    host: HostVerification = .from_connection,

    /// Production preset: full verification with system trust store
    pub fn production() TlsOptions {
        return .{
            .ca = .system,
            .host = .from_connection,
        };
    }

    /// Insecure preset: skip all verification (local dev only)
    pub fn insecure() TlsOptions {
        return .{
            .ca = .none,
            .host = .none,
        };
    }

    /// Check if this config skips verification (for logging warnings)
    pub fn isInsecure(self: TlsOptions) bool {
        return self.ca == .none or self.host == .none;
    }
};

/// UltraSock - A socket abstraction for HTTP/HTTPS connections
pub const UltraSock = struct {
    stream: ?Io.net.Stream = null,
    tls_client: ?tls.Client = null,
    ca_bundle: ?Certificate.Bundle = null,
    io: ?Io = null,
    protocol: Protocol,
    host: []const u8,
    port: u16,
    connected: bool = false,
    allocator: std.mem.Allocator,
    tls_options: TlsOptions,

    // TLS I/O state (kept alive for duration of connection)
    tls_read_buf: ?[]u8 = null,
    tls_write_buf: ?[]u8 = null,
    // Stream reader/writer must persist for TLS client lifetime
    tls_stream_reader: ?Io.net.Stream.Reader = null,
    tls_stream_writer: ?Io.net.Stream.Writer = null,

    /// Initialize a new UltraSock with default TLS options (production)
    pub fn init(allocator: std.mem.Allocator, protocol: Protocol, host: []const u8, port: u16) !UltraSock {
        return initWithTls(allocator, protocol, host, port, TlsOptions.production());
    }

    /// Initialize with explicit TLS options
    pub fn initWithTls(
        allocator: std.mem.Allocator,
        protocol: Protocol,
        host: []const u8,
        port: u16,
        tls_options: TlsOptions,
    ) !UltraSock {
        if (protocol == .https and tls_options.isInsecure()) {
            log.warn("HTTPS connection with insecure TLS options - use only for local development", .{});
        }
        return UltraSock{
            .protocol = protocol,
            .host = host,
            .port = port,
            .allocator = allocator,
            .tls_options = tls_options,
        };
    }

    /// Connect to the backend server using std.Io (async, properly handles errors)
    pub fn connect(self: *UltraSock, io: Io) !void {
        if (self.connected) return;

        // Resolve address - first try as IP, then DNS resolution
        const addr = Io.net.IpAddress.parse(self.host, self.port) catch blk: {
            // Not a raw IP, try DNS resolution using getaddrinfo
            const resolved = resolveDns(self.host, self.port) catch {
                log.err("Failed to resolve hostname: {s}", .{self.host});
                return error.InvalidAddress;
            };
            break :blk resolved;
        };

        // Connect using std.Io
        self.stream = addr.connect(io, .{ .mode = .stream }) catch {
            return error.ConnectionFailed;
        };
        errdefer self.closeStream();

        self.io = io;

        // TLS handshake for HTTPS
        if (self.protocol == .https) {
            try self.performTlsHandshake(io);
        }

        self.connected = true;
    }

    /// Resolve hostname using getaddrinfo (blocking)
    fn resolveDns(host: []const u8, port: u16) !Io.net.IpAddress {
        // Create null-terminated strings for getaddrinfo
        var host_buf: [256]u8 = undefined;
        if (host.len >= host_buf.len) return error.HostNameTooLong;
        @memcpy(host_buf[0..host.len], host);
        host_buf[host.len] = 0;
        const host_z: [*:0]const u8 = host_buf[0..host.len :0];

        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return error.InvalidPort;
        var port_z_buf: [8]u8 = undefined;
        @memcpy(port_z_buf[0..port_str.len], port_str);
        port_z_buf[port_str.len] = 0;
        const port_z: [*:0]const u8 = port_z_buf[0..port_str.len :0];

        const hints: std.posix.addrinfo = .{
            .flags = .{},
            .family = std.posix.AF.UNSPEC,
            .socktype = std.posix.SOCK.STREAM,
            .protocol = std.posix.IPPROTO.TCP,
            .addrlen = 0,
            .addr = null,
            .canonname = null,
            .next = null,
        };

        var res: ?*std.posix.addrinfo = null;
        const rc = std.posix.system.getaddrinfo(host_z, port_z, &hints, &res);
        if (rc != @as(std.posix.system.EAI, @enumFromInt(0))) {
            log.err("getaddrinfo failed for {s}", .{host});
            return error.DnsResolutionFailed;
        }
        defer if (res) |r| std.posix.system.freeaddrinfo(r);

        // Get first result
        const info = res orelse return error.NoAddressFound;
        const sockaddr = info.addr orelse return error.NoAddressFound;

        // Convert to Io.net.IpAddress
        if (sockaddr.family == std.posix.AF.INET) {
            const addr4: *const std.posix.sockaddr.in = @ptrCast(@alignCast(sockaddr));
            return Io.net.IpAddress{
                .ip4 = .{
                    .bytes = @bitCast(addr4.addr),
                    .port = port,
                },
            };
        } else if (sockaddr.family == std.posix.AF.INET6) {
            const addr6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(sockaddr));
            return Io.net.IpAddress{
                .ip6 = .{
                    .bytes = addr6.addr,
                    .port = port,
                    .flow = addr6.flowinfo,
                },
            };
        }

        return error.UnsupportedAddressFamily;
    }

    /// Perform TLS handshake
    fn performTlsHandshake(self: *UltraSock, io: Io) !void {
        const stream = self.stream orelse return error.SocketNotInitialized;

        // Allocate TLS buffers
        self.tls_read_buf = try self.allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer {
            if (self.tls_read_buf) |b| self.allocator.free(b);
            self.tls_read_buf = null;
        }

        self.tls_write_buf = try self.allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer {
            if (self.tls_write_buf) |b| self.allocator.free(b);
            self.tls_write_buf = null;
        }

        // Load system CA bundle if needed
        if (self.tls_options.ca == .system) {
            self.ca_bundle = .{};
            // Get current wall clock time using POSIX clock_gettime
            const ts = std.posix.clock_gettime(.REALTIME) catch {
                log.err("Failed to get current time for CA bundle", .{});
                return error.CaBundleLoadFailed;
            };
            const now: Io.Timestamp = .{
                .nanoseconds = @as(i96, ts.sec) * std.time.ns_per_s + ts.nsec,
            };
            self.ca_bundle.?.rescan(self.allocator, io, now) catch |err| {
                log.err("Failed to load system CA bundle: {}", .{err});
                return error.CaBundleLoadFailed;
            };
            log.debug("Loaded {} certificates from system trust store", .{self.ca_bundle.?.map.count()});
        }

        // Set up TCP stream readers/writers for TLS - must persist for TLS client lifetime
        self.tls_stream_reader = stream.reader(io, self.tls_read_buf.?);
        self.tls_stream_writer = stream.writer(io, self.tls_write_buf.?);

        // Generate entropy for handshake
        var entropy: [176]u8 = undefined;
        std.crypto.random.bytes(&entropy);

        // Get current time in seconds for certificate validation
        const time_ts = std.posix.clock_gettime(.REALTIME) catch {
            log.err("Failed to get current time for TLS handshake", .{});
            return error.TlsHandshakeFailed;
        };
        const now_sec: i64 = time_ts.sec;

        log.debug("Starting TLS handshake with {s}:{}", .{ self.host, self.port });

        // Build TLS options inline (the types are anonymous unions)
        const options: tls.Client.Options = .{
            .host = switch (self.tls_options.host) {
                .none => .no_verification,
                .from_connection => .{ .explicit = self.host },
                .explicit => |h| .{ .explicit = h },
            },
            .ca = switch (self.tls_options.ca) {
                .none => .no_verification,
                .system => .{ .bundle = self.ca_bundle.? },
                .custom => |bundle| .{ .bundle = bundle },
            },
            .read_buffer = self.tls_read_buf.?,
            .write_buffer = self.tls_write_buf.?,
            .entropy = &entropy,
            .realtime_now_seconds = now_sec,
        };

        self.tls_client = tls.Client.init(
            &self.tls_stream_reader.?.interface,
            &self.tls_stream_writer.?.interface,
            options,
        ) catch |err| {
            log.err("TLS handshake failed: {}", .{err});
            return error.TlsHandshakeFailed;
        };

        log.info("TLS connection established with {s}:{}", .{ self.host, self.port });
    }

    /// Send all data over the socket - uses passed io context
    pub fn send_all(self: *UltraSock, io: Io, data: []const u8) !usize {
        if (!self.connected) return error.NotConnected;

        if (self.tls_client) |*tls_c| {
            // TLS: write through encrypted channel
            tls_c.writer.writeAll(data) catch |err| {
                self.connected = false;
                log.debug("TLS write error: {}", .{err});
                return error.BrokenPipe;
            };
            tls_c.writer.flush() catch |err| {
                self.connected = false;
                log.debug("TLS flush error: {}", .{err});
                return error.BrokenPipe;
            };
            return data.len;
        } else {
            // Plain HTTP
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
    }

    /// Send data (single call)
    pub fn send(self: *UltraSock, io: Io, data: []const u8) !usize {
        return self.send_all(io, data);
    }

    /// Receive data from the socket - uses passed io context
    pub fn recv(self: *UltraSock, io: Io, buffer: []u8) !usize {
        if (!self.connected) return error.NotConnected;

        if (self.tls_client) |*tls_c| {
            // TLS: read from decrypted channel
            var bufs: [1][]u8 = .{buffer};
            const n = tls_c.reader.readVec(&bufs) catch |err| {
                self.connected = false;
                if (err == error.EndOfStream) return 0;
                log.debug("TLS read error: {}", .{err});
                return error.ReadFailed;
            };
            if (n == 0) {
                self.connected = false;
            }
            return n;
        } else {
            // Plain HTTP
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
    }

    /// Close the underlying TCP stream
    fn closeStream(self: *UltraSock) void {
        if (self.stream) |stream| {
            std.posix.close(stream.socket.handle);
            self.stream = null;
        }
    }

    /// Free TLS resources
    fn freeTlsResources(self: *UltraSock) void {
        self.tls_client = null;
        self.tls_stream_reader = null;
        self.tls_stream_writer = null;

        if (self.ca_bundle) |*bundle| {
            bundle.deinit(self.allocator);
            self.ca_bundle = null;
        }

        if (self.tls_read_buf) |buf| {
            self.allocator.free(buf);
            self.tls_read_buf = null;
        }

        if (self.tls_write_buf) |buf| {
            self.allocator.free(buf);
            self.tls_write_buf = null;
        }
    }

    /// Close the socket directly via posix (safe for pooled connections)
    pub fn close_blocking(self: *UltraSock) void {
        self.freeTlsResources();
        self.closeStream();
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
    /// Note: For TLS connections, use send_all instead
    pub fn posixWriteAll(self: *UltraSock, data: []const u8) !void {
        if (self.tls_client != null) {
            // For TLS, we need io context - this is a legacy API
            return error.UseSendAllForTls;
        }

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
    /// Note: For TLS connections, use recv instead
    pub fn posixRead(self: *UltraSock, buffer: []u8) !usize {
        if (self.tls_client != null) {
            // For TLS, we need io context - this is a legacy API
            return error.UseRecvForTls;
        }

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

    /// Check if this is a TLS connection
    pub fn isTls(self: *const UltraSock) bool {
        return self.tls_client != null;
    }

    /// Get mutable pointer to TLS client (for direct reader/writer access)
    /// Returns null for plain HTTP connections
    pub fn getTlsClient(self: *UltraSock) ?*tls.Client {
        if (self.tls_client != null) {
            return &self.tls_client.?;
        }
        return null;
    }

    /// Get the underlying stream reader error (for debugging TLS read failures)
    pub fn getStreamReaderError(self: *UltraSock) ?Io.net.Stream.Reader.Error {
        if (self.tls_stream_reader) |*reader| {
            return reader.err;
        }
        return null;
    }

    /// Get the underlying stream writer error (for debugging TLS write failures)
    pub fn getStreamWriterError(self: *UltraSock) ?Io.net.Stream.Writer.Error {
        if (self.tls_stream_writer) |*writer| {
            return writer.err;
        }
        return null;
    }

    /// Create from backend config
    pub fn fromBackendConfig(allocator: std.mem.Allocator, backend: anytype) !UltraSock {
        return fromBackendConfigWithTls(allocator, backend, TlsOptions.production());
    }

    /// Create from backend config with explicit TLS options
    pub fn fromBackendConfigWithTls(allocator: std.mem.Allocator, backend: anytype, tls_options: TlsOptions) !UltraSock {
        const use_https = backend.port == 443 or std.mem.startsWith(u8, backend.host, "https://");
        const protocol: Protocol = if (use_https) .https else .http;

        var host = backend.host;
        if (std.mem.startsWith(u8, host, "https://")) {
            host = host[8..];
        } else if (std.mem.startsWith(u8, host, "http://")) {
            host = host[7..];
        }

        return try initWithTls(allocator, protocol, host, backend.port, tls_options);
    }

    /// Create from BackendServer struct
    pub fn fromBackendServer(allocator: std.mem.Allocator, backend: anytype) !UltraSock {
        return fromBackendServerWithTls(allocator, backend, TlsOptions.production());
    }

    /// Create from BackendServer struct with explicit TLS options
    pub fn fromBackendServerWithTls(allocator: std.mem.Allocator, backend: anytype, tls_options: TlsOptions) !UltraSock {
        const protocol: Protocol = if (backend.isHttps()) .https else .http;
        return try initWithTls(allocator, protocol, backend.getHost(), backend.port, tls_options);
    }
};
