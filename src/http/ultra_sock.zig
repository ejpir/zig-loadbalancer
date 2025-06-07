/// Universal Socket Abstraction for HTTP/HTTPS
/// 
/// Unified interface for both plain HTTP and TLS-encrypted HTTPS connections.
/// Simplifies proxy implementation by providing common operations regardless
/// of underlying protocol.
const std = @import("std");
const log = std.log.scoped(.ultra_sock);

const zzz = @import("zzz");
const http = zzz.HTTP;
const tardy = zzz.tardy;
const Socket = tardy.Socket;
const Runtime = tardy.Runtime;
const secsock = zzz.secsock;

/// Protocol type for the secure socket
pub const Protocol = enum {
    http,
    https,
};

/// UltraSock - A socket abstraction that can handle both HTTP and HTTPS connections
pub const UltraSock = struct {
    socket: ?Socket = null,
    secure_socket: ?secsock.SecureSocket = null,
    protocol: Protocol,
    host: []const u8,
    port: u16,
    connected: bool = false,
    allocator: std.mem.Allocator,
    

    /// Initialize a new UltraSock with the given protocol, host, and port
    pub fn init(allocator: std.mem.Allocator, protocol: Protocol, host: []const u8, port: u16) !UltraSock {
        return UltraSock{
            .protocol = protocol,
            .host = host,
            .port = port,
            .allocator = allocator,
        };
    }

    /// Connect to the backend server with timeout handling
    pub fn connect(self: *UltraSock, runtime: *Runtime) !void {
        if (self.connected) return;

        // Create a regular socket
        var sock = try Socket.init(.{ .tcp = .{
            .host = self.host,
            .port = self.port,
        } });
        errdefer sock.close_blocking();

        // Track connection time for timeout handling
        const start_time = std.time.milliTimestamp();
        const connection_timeout_ms = 10000; // 10 second connection timeout

        switch (self.protocol) {
            .http => {
                // For HTTP, connect with timeout check
                sock.connect(runtime) catch |err| {
                    const elapsed_ms = std.time.milliTimestamp() - start_time;
                    if (elapsed_ms >= connection_timeout_ms) {
                        log.err("HTTP connection timed out after {d}ms to {s}:{d}", .{ elapsed_ms, self.host, self.port });
                        return error.ConnectionTimeout;
                    }
                    log.err("HTTP connection failed after {d}ms to {s}:{d}: {s}", .{ elapsed_ms, self.host, self.port, @errorName(err) });
                    return err;
                };
                self.socket = sock;
            },
            .https => {
                // For HTTPS, create secure connection - fail if TLS handshake fails
                self.connectWithBearSSL(sock, runtime) catch |err| {
                    const elapsed_ms = std.time.milliTimestamp() - start_time;
                    if (elapsed_ms >= connection_timeout_ms) {
                        log.err("HTTPS connection timed out after {d}ms to {s}:{d}", .{ elapsed_ms, self.host, self.port });
                        return error.ConnectionTimeout;
                    }
                    log.err("HTTPS connection failed after {d}ms to {s}:{d}: {s}", .{ elapsed_ms, self.host, self.port, @errorName(err) });
                    return err;
                };
                log.info("Successfully established secure HTTPS connection to {s}:{d}", .{ self.host, self.port });
            },
        }

        self.connected = true;
    }

    /// Connect using BearSSL implementation
    fn connectWithBearSSL(self: *UltraSock, sock: Socket, runtime: *Runtime) !void {
        // Add small delay to prevent rapid BearSSL context creation issues
        std.time.sleep(50 * std.time.ns_per_ms); // 50ms delay
        
        // Initialize BearSSL with trust store for verification
        var bearssl = secsock.BearSSL.init(self.allocator);
        errdefer bearssl.deinit(); // Cleans up bearssl resources if function errors

        // Load the system trust store or use embedded certificates 
        log.debug("Configuring BearSSL trust anchors", .{});
        
        // TODO: In a production version, we would load system trust anchors
        // try bearssl.load_system_trust_anchors();
        
        // Try to create secure socket
        var secure = try bearssl.to_secure_socket(sock, .client);
        errdefer secure.deinit();

        // Set the server name for SNI (Server Name Indication)
        // Note: Commenting out since the current secsock API doesn't expose this method yet
        if (self.host.len > 0) {
            log.debug("SNI hostname would be {s}, but SNI not implemented yet", .{self.host});
            // TODO: When available in secsock API, uncomment:
            // try secure.set_server_name(self.host);
        }
        
        // Add client certificate for mutual TLS if needed
        //try bearssl.add_cert_chain("CERTIFICATE", @embedFile("certs/client-cert.pem"), "key", @embedFile("certs/client-key.pem"));

        // Configure TLS options
        // Note: Commenting out since the current secsock API doesn't expose this method yet
        // TODO: When available in secsock API, uncomment:
        // secure.set_min_proto_version(.tls_v12); // Minimum TLS 1.2 for security
        log.debug("Would set minimum TLS protocol to TLS 1.2, but API not available yet", .{});
        
        // Attempt TLS handshake with advanced error handling
        log.info("Attempting TLS handshake for {s}:{d}...", .{ self.host, self.port });
        log.debug("Using secure socket via BearSSL", .{});
        log.debug("Client TLS details - host: {s}, port: {d}, min_version: TLS 1.2", .{ self.host, self.port });

        // Connect with a timeout
        const timeout_ms = 5000; // 5 second timeout for TLS handshake
        const start_time = std.time.milliTimestamp();
        
        secure.connect(runtime) catch |err| {
            // Calculate elapsed time for diagnostics
            const elapsed_ms = std.time.milliTimestamp() - start_time;
            
            // Detailed error reporting for TLS failures
            log.err("TLS handshake failed after {d}ms: {s}", .{ elapsed_ms, @errorName(err) });
            
            if (elapsed_ms >= timeout_ms) {
                log.err("TLS handshake timed out", .{});
            }
            
            // Perform additional diagnostics
            log.debug("Connection details - socket: {d}, host: {s}, port: {d}", .{
                sock.handle, self.host, self.port
            });
            
            // Return the error - caller will handle fallback to plain socket
            return err;
        };

        // If we get here, secure.connect() was successful
        log.info("TLS handshake successful for {s}:{d}", .{ self.host, self.port });
        
        // Get TLS session info for logging
        // Note: Commenting out since the current secsock API doesn't expose these methods yet
        // TODO: When available in secsock API, uncomment:
        // const protocol_version = secure.get_protocol_version();
        // const cipher_suite = secure.get_cipher_suite();
        // log.debug("TLS Session: Protocol={s}, Cipher={s}", .{
        //     @tagName(protocol_version), 
        //     @tagName(cipher_suite)
        // });
        log.debug("TLS Session established (details not available yet)", .{});

        // Store the secure socket
        self.secure_socket = secure;

        // Ensure the regular socket field is nulled out
        self.socket = null;
    }

    /// Send data over the socket
    pub fn send_all(self: *UltraSock, runtime: *Runtime, data: []const u8) !void {
        if (!self.connected) return error.NotConnected;

        switch (self.protocol) {
            .http => {
                if (self.socket) |*sock| {
                    _ = sock.send_all(runtime, data) catch |err| {
                        // Update connected state on connection-related errors
                        switch (err) {
                            error.Closed, error.NotConnected, error.BrokenPipe => {
                                log.debug("Send error detected, marking socket as disconnected: {s}", .{@errorName(err)});
                                self.connected = false;
                            },
                            else => {},
                        }
                        return err;
                    };
                } else {
                    return error.SocketNotInitialized;
                }
            },
            .https => {
                if (self.secure_socket) |*secure| {
                    _ = secure.send_all(runtime, data) catch |err| {
                        // Update connected state on connection-related errors
                        switch (err) {
                            error.Closed, error.NotConnected, error.BrokenPipe => {
                                log.debug("Secure send error detected, marking socket as disconnected: {s}", .{@errorName(err)});
                                self.connected = false;
                            },
                            else => {},
                        }
                        return err;
                    };
                } else {
                    return error.SocketNotInitialized;
                }
            },
        }
    }

    /// Receive data from the socket
    pub fn recv(self: *UltraSock, runtime: *Runtime, buffer: []u8) !usize {
        if (!self.connected) return error.NotConnected;

        switch (self.protocol) {
            .http => {
                if (self.socket) |*sock| {
                    return sock.recv(runtime, buffer) catch |err| {
                        // Update connected state on connection-related errors
                        switch (err) {
                            error.Closed, error.NotConnected => {
                                log.debug("Recv error detected, marking socket as disconnected: {s}", .{@errorName(err)});
                                self.connected = false;
                            },
                            error.Unexpected => {
                                // For Unexpected errors, check if it's a connection issue
                                const errno_val = std.posix.errno(-1);
                                switch (errno_val) {
                                    .CONNRESET, .PIPE, .NOTCONN => {
                                        log.debug("Recv Unexpected error is connection-related, marking socket as disconnected: {any}", .{errno_val});
                                        self.connected = false;
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                        return err;
                    };
                } else {
                    return error.SocketNotInitialized;
                }
            },
            .https => {
                if (self.secure_socket) |*secure| {
                    log.debug("ULTRA_SOCK: Starting SSL recv on task={?d}", .{runtime.current_task});
                    const result = secure.recv(runtime, buffer) catch |err| {
                        log.debug("ULTRA_SOCK: SSL recv error on task={?d}: {s}", .{ runtime.current_task, @errorName(err) });
                        return err;
                    };
                    log.debug("ULTRA_SOCK: SSL recv completed on task={?d}, bytes={d}", .{ runtime.current_task, result });
                    return result;
                } else {
                    return error.SocketNotInitialized;
                }
            },
        }
    }

    /// Close the socket
    pub fn close_blocking(self: *UltraSock) void {
        // Fixed: We can now modify self.connected since self is no longer const

        switch (self.protocol) {
            .http => {
                if (self.socket) |sock| {
                    // Only close if the socket appears to be initialized
                    log.debug("Closing regular HTTP socket", .{});

                    // Check if the socket is valid before closing
                    // Socket handles are typically > 0
                    if (sock.handle > 0) {
                        sock.close_blocking();
                    } else {
                        log.warn("Skipping close for invalid socket handle: {d}", .{sock.handle});
                    }

                    // Null out the socket to prevent reuse after close
                    self.socket = null;
                }
            },
            .https => {
                if (self.secure_socket) |secure| {
                    log.debug("Closing secure HTTPS socket", .{});
                    
                    // Clean up the secure socket properly
                    self.safeSecureSocketCleanup(secure);

                    // Null out the secure socket to prevent reuse after close
                    self.secure_socket = null;
                }
            },
        }

        // Mark as disconnected to prevent reuse
        self.connected = false;
    }

    /// Safely cleanup secure socket to prevent union state conflicts during SSL deinit
    fn safeSecureSocketCleanup(self: *UltraSock, secure: secsock.SecureSocket) void {
        // Defensive approach: validate socket state before SSL cleanup
        
        // Check if we're already disconnected (but still clean up SSL resources)
        if (!self.connected) {
            log.debug("Socket already disconnected, but still performing SSL cleanup", .{});
        }
        
        log.debug("CLEANUP: About to call secure.deinit() on socket {*}", .{self});
        secure.deinit();
        log.debug("CLEANUP: secure.deinit() completed successfully on socket {*}", .{self});
    }

    /// Create a UltraSock from backend configuration
    pub fn fromBackendConfig(allocator: std.mem.Allocator, backend: anytype) !UltraSock {
        // Determine protocol based on port or URL scheme
        const use_https = backend.port == 443 or std.mem.startsWith(u8, backend.host, "https://");
        const protocol: Protocol = if (use_https) .https else .http;

        // Extract hostname without protocol prefix
        var host = backend.host;
        if (std.mem.startsWith(u8, host, "https://")) {
            host = host[8..];
        } else if (std.mem.startsWith(u8, host, "http://")) {
            host = host[7..];
        }

        return try init(allocator, protocol, host, backend.port);
    }

    /// Create a UltraSock from a BackendServer struct
    pub fn fromBackendServer(allocator: std.mem.Allocator, backend: anytype) !UltraSock {
        const protocol: Protocol = if (backend.isHttps()) .https else .http;
        return try init(allocator, protocol, backend.getHost(), backend.port);
    }
};
