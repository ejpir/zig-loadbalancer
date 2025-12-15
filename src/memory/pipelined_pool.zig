/// HTTP/1.1 Pipelined Connection Pool
///
/// Allows multiple requests to be sent on the same backend connection
/// without waiting for responses. Responses are read in order and
/// routed back to waiting callers.
const std = @import("std");
const log = std.log.scoped(.pipelined_pool);
const UltraSock = @import("../http/ultra_sock.zig").UltraSock;
const BackendServer = @import("../core/types.zig").BackendServer;
const simd_parse = @import("../internal/simd_parse.zig");

/// A single pipelined connection to a backend
pub const PipelinedConnection = struct {
    socket: UltraSock,
    backend_index: usize,
    /// Number of requests sent but not yet received
    pending_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Lock for send operations (multiple senders, responses in order)
    send_mutex: std.Thread.Mutex = .{},
    /// Lock for recv operations (single reader at a time)
    recv_mutex: std.Thread.Mutex = .{},
    /// Is this connection valid?
    connected: bool = false,

    const MAX_PIPELINE_DEPTH: u32 = 8;

    pub fn init(socket: UltraSock, backend_index: usize) PipelinedConnection {
        return .{
            .socket = socket,
            .backend_index = backend_index,
            .connected = true,
        };
    }

    /// Check if we can send another request on this connection
    pub fn canPipeline(self: *const PipelinedConnection) bool {
        return self.connected and self.pending_count.load(.acquire) < MAX_PIPELINE_DEPTH;
    }

    /// Send a request (increments pending count)
    pub fn sendRequest(self: *PipelinedConnection, rt: anytype, request_data: []const u8) !void {
        self.send_mutex.lock();
        defer self.send_mutex.unlock();

        if (!self.connected) return error.ConnectionClosed;

        _ = self.socket.send_all(rt, request_data) catch |err| {
            self.connected = false;
            return err;
        };

        _ = self.pending_count.fetchAdd(1, .release);
    }

    /// Receive a response (decrements pending count)
    /// Returns the raw response data
    pub fn recvResponse(self: *PipelinedConnection, rt: anytype, allocator: std.mem.Allocator) ![]u8 {
        self.recv_mutex.lock();
        defer self.recv_mutex.unlock();

        if (!self.connected) return error.ConnectionClosed;

        // Read response headers first
        var buffer: [8192]u8 = undefined;
        var response = std.ArrayList(u8).init(allocator);
        errdefer response.deinit();

        var header_end: ?usize = null;
        while (header_end == null) {
            const n = self.socket.recv(rt, &buffer) catch |err| {
                self.connected = false;
                return err;
            };
            if (n == 0) {
                self.connected = false;
                return error.ConnectionClosed;
            }
            try response.appendSlice(buffer[0..n]);

            header_end = simd_parse.findHeaderEnd(response.items);
        }

        // Parse Content-Length to read body
        const headers = response.items[0 .. header_end.? + 4];
        var content_length: usize = 0;

        if (std.mem.indexOf(u8, headers, "Content-Length:")) |cl_start| {
            const cl_line_start = cl_start + 16;
            if (std.mem.indexOfPos(u8, headers, cl_line_start, "\r\n")) |cl_end| {
                const cl_str = std.mem.trim(u8, headers[cl_line_start..cl_end], " ");
                content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
            }
        }

        // Read remaining body if needed
        const body_received = response.items.len - (header_end.? + 4);
        var body_remaining = if (content_length > body_received) content_length - body_received else 0;

        while (body_remaining > 0) {
            const n = self.socket.recv(rt, &buffer) catch |err| {
                self.connected = false;
                return err;
            };
            if (n == 0) break;
            try response.appendSlice(buffer[0..n]);
            body_remaining -|= n;
        }

        _ = self.pending_count.fetchSub(1, .release);
        return response.toOwnedSlice();
    }

    pub fn close(self: *PipelinedConnection) void {
        self.connected = false;
        self.socket.close_blocking();
    }
};

/// Pool of pipelined connections per backend
pub const PipelinedPool = struct {
    connections: std.ArrayList(PipelinedConnection),
    backend: *const BackendServer,
    backend_index: usize,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    const MAX_CONNECTIONS: usize = 16;

    pub fn init(allocator: std.mem.Allocator, backend: *const BackendServer, backend_index: usize) PipelinedPool {
        return .{
            .connections = std.ArrayList(PipelinedConnection).init(allocator),
            .backend = backend,
            .backend_index = backend_index,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PipelinedPool) void {
        for (self.connections.items) |*conn| {
            conn.close();
        }
        self.connections.deinit();
    }

    /// Get a connection that can accept more pipelined requests
    /// Creates a new connection if needed
    pub fn getConnection(self: *PipelinedPool, rt: anytype) !*PipelinedConnection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find existing connection with pipeline capacity
        for (self.connections.items) |*conn| {
            if (conn.canPipeline()) {
                return conn;
            }
        }

        // Create new connection if under limit
        if (self.connections.items.len < MAX_CONNECTIONS) {
            var sock = try UltraSock.fromBackendServer(self.allocator, self.backend);
            sock.connect(rt) catch |err| {
                sock.close_blocking();
                return err;
            };

            try self.connections.append(PipelinedConnection.init(sock, self.backend_index));
            return &self.connections.items[self.connections.items.len - 1];
        }

        // All connections at max pipeline depth - wait for one
        // For now, just return the first one (will block on recv)
        if (self.connections.items.len > 0) {
            return &self.connections.items[0];
        }

        return error.NoConnectionAvailable;
    }
};
