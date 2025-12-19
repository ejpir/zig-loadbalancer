/// Universal Socket Abstraction for HTTP/HTTPS
///
/// Simplified socket wrapper using Zig 0.16's std.Io for async operations.
/// Supports TLS via ianic/tls.zig for reliable HTTPS connections.
const std = @import("std");
const log = std.log.scoped(.ultra_sock);

const Io = std.Io;
const tls = @import("tls");

const config_mod = @import("../core/config.zig");

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
        /// Use system trust store (default when DEFAULT_TLS_VERIFY_CA = true)
        system,
        /// Use custom certificate bundle
        custom: tls.config.cert.Bundle,
    };

    /// Host verification mode
    pub const HostVerification = union(enum) {
        /// No hostname verification - INSECURE
        none,
        /// Verify against connection host (default when DEFAULT_TLS_VERIFY_HOST = true)
        from_connection,
        /// Verify against explicit hostname
        explicit: []const u8,
    };

    ca: CaVerification = .system,
    host: HostVerification = .from_connection,

    /// Create TlsOptions from config.zig defaults
    /// Uses DEFAULT_TLS_VERIFY_CA and DEFAULT_TLS_VERIFY_HOST
    pub fn fromDefaults() TlsOptions {
        return .{
            .ca = if (config_mod.DEFAULT_TLS_VERIFY_CA) .system else .none,
            .host = if (config_mod.DEFAULT_TLS_VERIFY_HOST) .from_connection else .none,
        };
    }

    /// Get TLS options based on runtime config
    /// Returns insecure() if --insecure flag was used, otherwise production()
    pub fn fromRuntime() TlsOptions {
        return if (config_mod.isInsecureTls()) insecure() else production();
    }

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
/// Threadlocal TLS buffers avoid allocation during handshake
threadlocal var tls_input_buffer: [tls.input_buffer_len]u8 = undefined;
threadlocal var tls_output_buffer: [tls.output_buffer_len]u8 = undefined;

/// Global CA bundle (loaded once at startup)
var global_ca_bundle: ?tls.config.cert.Bundle = null;
var ca_bundle_loaded: bool = false;

pub const UltraSock = struct {
    stream: ?Io.net.Stream = null,
    tls_conn: ?tls.Connection = null,
    io: ?Io = null,
    protocol: Protocol,
    host: []const u8,
    port: u16,
    connected: bool = false,
    tls_options: TlsOptions,

    // Embedded stream reader/writer (stable addresses, zero allocation)
    stream_reader: Io.net.Stream.Reader = undefined,
    stream_writer: Io.net.Stream.Writer = undefined,
    has_reader_writer: bool = false,

    /// Initialize a new UltraSock with default TLS options (production)
    pub fn init(protocol: Protocol, host: []const u8, port: u16) UltraSock {
        return initWithTls(protocol, host, port, TlsOptions.fromRuntime());
    }

    /// Initialize with explicit TLS options (zero allocation)
    pub fn initWithTls(
        protocol: Protocol,
        host: []const u8,
        port: u16,
        tls_options: TlsOptions,
    ) UltraSock {
        if (protocol == .https and tls_options.isInsecure()) {
            log.warn("HTTPS with insecure TLS - dev only", .{});
        }
        return UltraSock{
            .protocol = protocol,
            .host = host,
            .port = port,
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
        const host_z = try makeNullTerminated(host);
        const port_z = try makePortString(port);

        const hints: std.c.addrinfo = .{
            .flags = .{},
            .family = std.posix.AF.UNSPEC,
            .socktype = std.posix.SOCK.STREAM,
            .protocol = std.posix.IPPROTO.TCP,
            .addrlen = 0,
            .addr = null,
            .canonname = null,
            .next = null,
        };

        var res: ?*std.c.addrinfo = null;
        const rc = std.c.getaddrinfo(host_z, port_z, &hints, &res);
        if (@intFromEnum(rc) != 0) {
            log.err("getaddrinfo failed for {s}", .{host});
            return error.DnsResolutionFailed;
        }
        defer if (res) |r| std.c.freeaddrinfo(r);

        const info = res orelse return error.NoAddressFound;
        const sockaddr = info.addr orelse return error.NoAddressFound;

        return convertSockaddrToIpAddress(sockaddr, port);
    }

    // Threadlocal buffers for DNS resolution - avoids stack use-after-free.
    threadlocal var dns_host_buf: [256]u8 = undefined;
    threadlocal var dns_port_buf: [8]u8 = undefined;

    /// Convert hostname to null-terminated string for getaddrinfo
    fn makeNullTerminated(host: []const u8) ![*:0]const u8 {
        if (host.len >= dns_host_buf.len) return error.HostNameTooLong;
        @memcpy(dns_host_buf[0..host.len], host);
        dns_host_buf[host.len] = 0;
        return dns_host_buf[0..host.len :0];
    }

    /// Convert port to null-terminated string for getaddrinfo
    fn makePortString(port: u16) ![*:0]const u8 {
        const port_str = std.fmt.bufPrint(&dns_port_buf, "{d}", .{port}) catch
            return error.InvalidPort;
        dns_port_buf[port_str.len] = 0;
        return dns_port_buf[0..port_str.len :0];
    }

    /// Convert sockaddr to Io.net.IpAddress
    fn convertSockaddrToIpAddress(
        sockaddr: *const std.c.sockaddr,
        port: u16,
    ) !Io.net.IpAddress {
        if (sockaddr.family == std.posix.AF.INET) {
            const addr4: *const std.c.sockaddr.in =
                @ptrCast(@alignCast(sockaddr));
            return Io.net.IpAddress{
                .ip4 = .{
                    .bytes = @bitCast(addr4.addr),
                    .port = port,
                },
            };
        } else if (sockaddr.family == std.posix.AF.INET6) {
            const addr6: *const std.c.sockaddr.in6 =
                @ptrCast(@alignCast(sockaddr));
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

    /// Perform TLS handshake using ianic/tls.zig (zero allocation)
    fn performTlsHandshake(self: *UltraSock, io: Io) !void {
        const stream = self.stream orelse return error.SocketNotInitialized;

        try ensureCaBundleLoaded(io, self.tls_options.ca);

        const input_buf = &tls_input_buffer;
        const output_buf = &tls_output_buffer;

        self.stream_reader = stream.reader(io, input_buf);
        self.stream_writer = stream.writer(io, output_buf);
        self.has_reader_writer = true;

        const now = try Io.Clock.real.now(io);
        log.debug("Starting TLS handshake with {s}:{}", .{ self.host, self.port });

        const client_opts = try buildTlsClientOptions(
            self.tls_options,
            self.host,
            now,
        );

        self.tls_conn = tls.client(
            &self.stream_reader.interface,
            &self.stream_writer.interface,
            client_opts,
        ) catch |err| {
            log.err("TLS handshake failed: {}", .{err});
            return error.TlsHandshakeFailed;
        };

        // Log TLS connection details
        const cipher_name = @tagName(self.tls_conn.?.cipher);

        if (config_mod.isTlsTraceEnabled()) {
            // Detailed TLS trace logging
            const tls_log = std.log.scoped(.tls_trace);

            // Determine TLS version from cipher suite
            // TLS 1.3 ciphers: AES_128_GCM_SHA256, AES_256_GCM_SHA384, CHACHA20_POLY1305_SHA256
            // TLS 1.2 ciphers: ECDHE_* or RSA_*
            const tls_version: []const u8 = if (std.mem.startsWith(u8, cipher_name, "AES_") or
                std.mem.startsWith(u8, cipher_name, "CHACHA20_"))
                "TLS 1.3"
            else
                "TLS 1.2";

            // CA verification mode
            const ca_mode: []const u8 = switch (self.tls_options.ca) {
                .none => "none (INSECURE)",
                .system => "system trust store",
                .custom => "custom bundle",
            };

            // Host verification mode
            const host_mode: []const u8 = switch (self.tls_options.host) {
                .none => "disabled (INSECURE)",
                .from_connection => "enabled",
                .explicit => "explicit",
            };

            tls_log.info("=== TLS Handshake Complete ===", .{});
            tls_log.info("  Host: {s}:{}", .{ self.host, self.port });
            tls_log.info("  Version: {s}", .{tls_version});
            tls_log.info("  Cipher Suite: {s}", .{cipher_name});
            tls_log.info("  CA Verification: {s}", .{ca_mode});
            tls_log.info("  Host Verification: {s}", .{host_mode});
            if (ca_bundle_loaded) {
                if (global_ca_bundle) |bundle| {
                    tls_log.info("  CA Certificates: {} loaded", .{bundle.map.count()});
                }
            }
        } else {
            log.info("TLS established {s}:{} ({s})", .{ self.host, self.port, cipher_name });
        }
    }

    /// Ensure CA bundle is loaded (only once per process)
    fn ensureCaBundleLoaded(io: Io, ca_mode: TlsOptions.CaVerification) !void {
        if (ca_mode == .system and !ca_bundle_loaded) {
            global_ca_bundle =
                tls.config.cert.fromSystem(std.heap.page_allocator, io) catch |err| {
                    log.err("Failed to load system CA bundle: {}", .{err});
                    return error.CaBundleLoadFailed;
                };
            ca_bundle_loaded = true;
            const cert_count = global_ca_bundle.?.map.count();
            log.info("Loaded {} certificates from system trust store", .{cert_count});
        }
    }

    /// Build TLS client options from verification settings
    fn buildTlsClientOptions(
        tls_options: TlsOptions,
        host: []const u8,
        now: Io.Timestamp,
    ) !tls.config.Client {
        return tls.config.Client{
            .host = switch (tls_options.host) {
                .none => "",
                .from_connection => host,
                .explicit => |h| h,
            },
            .root_ca = switch (tls_options.ca) {
                .none => .{},
                .system => global_ca_bundle.?,
                .custom => |bundle| bundle,
            },
            .insecure_skip_verify = tls_options.ca == .none,
            .now = now,
        };
    }

    /// Send all data over the socket
    pub fn send_all(self: *UltraSock, io: Io, data: []const u8) !usize {
        if (!self.connected) return error.NotConnected;

        if (self.tls_conn) |*conn| {
            // TLS: write through encrypted channel (uses io context from handshake)
            conn.writeAll(data) catch |err| {
                self.connected = false;
                log.debug("TLS write error: {}", .{err});
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

    /// Receive data from the socket
    pub fn recv(self: *UltraSock, io: Io, buffer: []u8) !usize {
        if (!self.connected) return error.NotConnected;

        if (self.tls_conn) |*conn| {
            // TLS: read from decrypted channel (uses io context from handshake)
            const n = conn.read(buffer) catch |err| {
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

    /// Get the TLS connection (for direct access to writeAll/read/next)
    pub fn getTlsConnection(self: *UltraSock) ?*tls.Connection {
        if (self.tls_conn != null) {
            return &self.tls_conn.?;
        }
        return null;
    }

    /// Fix TLS connection pointers after struct copy.
    /// Must be called after copying UltraSock to update internal TLS pointers.
    pub fn fixTlsPointersAfterCopy(self: *UltraSock) void {
        if (self.tls_conn != null and self.has_reader_writer) {
            // Update TLS connection to point to THIS struct's reader/writer.
            self.tls_conn.?.input = &self.stream_reader.interface;
            self.tls_conn.?.output = &self.stream_writer.interface;
        }
    }

    /// Close the underlying TCP stream
    fn closeStream(self: *UltraSock) void {
        if (self.stream) |stream| {
            std.posix.close(stream.socket.handle);
            self.stream = null;
        }
    }

    /// Free TLS resources (zero deallocation - resources are threadlocal/global)
    fn freeTlsResources(self: *UltraSock) void {
        // Close TLS connection gracefully
        if (self.tls_conn) |*conn| {
            conn.close() catch {};
            self.tls_conn = null;
        }

        // Reset embedded reader/writer flag
        self.has_reader_writer = false;

        // Note: CA bundle is global (never freed during runtime)
        // Note: I/O buffers are threadlocal (never freed during runtime)
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
        std.posix.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {
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
        std.posix.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {
            return error.SetTimeoutFailed;
        };
    }

    /// Enable TCP keepalive to detect dead connections
    pub fn enableKeepalive(self: *UltraSock) !void {
        const fd = self.getFd() orelse return error.NotConnected;

        // Enable keepalive
        const enable: u32 = 1;
        std.posix.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.KEEPALIVE,
            std.mem.asBytes(&enable),
        ) catch {
            return error.SetOptionFailed;
        };

        // Probes start after idle period (platform-specific)
        const idle_secs: u32 = 5;
        if (@hasDecl(std.posix.TCP, "KEEPALIVE")) {
            // macOS
            std.posix.setsockopt(
                fd,
                std.posix.IPPROTO.TCP,
                std.posix.TCP.KEEPALIVE,
                std.mem.asBytes(&idle_secs),
            ) catch {};
        } else if (@hasDecl(std.posix.TCP, "KEEPIDLE")) {
            // Linux
            std.posix.setsockopt(
                fd,
                std.posix.IPPROTO.TCP,
                std.posix.TCP.KEEPIDLE,
                std.mem.asBytes(&idle_secs),
            ) catch {};
        }
    }

    /// Write all data using POSIX (returns error instead of panicking)
    /// Note: For TLS connections, use send_all instead
    pub fn posixWriteAll(self: *UltraSock, data: []const u8) !void {
        if (self.tls_conn != null) {
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
        if (self.tls_conn != null) {
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
        return self.tls_conn != null;
    }

    /// Create from backend config (zero allocation)
    pub fn fromBackendConfig(backend: anytype) UltraSock {
        return fromBackendConfigWithTls(backend, TlsOptions.fromRuntime());
    }

    /// Create from backend config with explicit TLS options (zero allocation)
    pub fn fromBackendConfigWithTls(backend: anytype, tls_options: TlsOptions) UltraSock {
        const use_https = backend.port == 443 or std.mem.startsWith(u8, backend.host, "https://");
        const protocol: Protocol = if (use_https) .https else .http;

        var host = backend.host;
        if (std.mem.startsWith(u8, host, "https://")) {
            host = host[8..];
        } else if (std.mem.startsWith(u8, host, "http://")) {
            host = host[7..];
        }

        return initWithTls(protocol, host, backend.port, tls_options);
    }

    /// Create from BackendServer struct (zero allocation)
    pub fn fromBackendServer(backend: anytype) UltraSock {
        return fromBackendServerWithTls(backend, TlsOptions.fromRuntime());
    }

    /// Create from BackendServer struct with explicit TLS options (zero allocation)
    pub fn fromBackendServerWithTls(backend: anytype, tls_options: TlsOptions) UltraSock {
        const protocol: Protocol = if (backend.isHttps()) .https else .http;
        return initWithTls(protocol, backend.getHost(), backend.port, tls_options);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "UltraSock: init creates correct protocol" {
    const http_sock = UltraSock.init(.http, "example.com", 80);
    try std.testing.expectEqual(Protocol.http, http_sock.protocol);
    try std.testing.expectEqualStrings("example.com", http_sock.host);
    try std.testing.expectEqual(@as(u16, 80), http_sock.port);

    const https_sock = UltraSock.init(.https, "secure.com", 443);
    try std.testing.expectEqual(Protocol.https, https_sock.protocol);
}

test "UltraSock: isTls returns false for non-TLS connection" {
    var sock = UltraSock.init(.http, "example.com", 80);
    try std.testing.expect(!sock.isTls());
}

test "UltraSock: fixTlsPointersAfterCopy is safe on non-TLS socket" {
    var sock = UltraSock.init(.http, "example.com", 80);
    // Should not crash when called on non-TLS socket.
    sock.fixTlsPointersAfterCopy();
    try std.testing.expect(!sock.isTls());
}

test "UltraSock: getTlsConnection returns null for non-TLS" {
    var sock = UltraSock.init(.http, "example.com", 80);
    try std.testing.expect(sock.getTlsConnection() == null);
}

test "DNS helpers: makeNullTerminated handles valid host" {
    const host_z = try UltraSock.makeNullTerminated("example.com");
    try std.testing.expectEqualStrings("example.com", std.mem.span(host_z));
}

test "DNS helpers: makeNullTerminated rejects too-long host" {
    var long_host: [300]u8 = undefined;
    @memset(&long_host, 'a');
    const result = UltraSock.makeNullTerminated(&long_host);
    try std.testing.expectError(error.HostNameTooLong, result);
}

test "DNS helpers: makePortString formats port correctly" {
    const port_z = try UltraSock.makePortString(8080);
    try std.testing.expectEqualStrings("8080", std.mem.span(port_z));

    const port_443 = try UltraSock.makePortString(443);
    try std.testing.expectEqualStrings("443", std.mem.span(port_443));
}
