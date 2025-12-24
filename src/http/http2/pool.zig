/// Simplified HTTP/2 Connection Pool
///
/// TigerBeetle-style pool with fixed-size arrays and explicit state.
/// Handles connection creation, TLS handshake, HTTP/2 session establishment,
/// and automatic retry on stale connections.
///
/// Design:
/// - getOrCreate: Find available or create fresh connection
/// - release: Return to pool if healthy, destroy if failed
/// - Automatic stale detection and retry
/// - Fixed-size arrays, no dynamic allocation for pool structure
const std = @import("std");
const log = std.log.scoped(.h2_pool);

const Io = std.Io;
const H2Connection = @import("connection.zig").H2Connection;
const ultra_sock_mod = @import("../ultra_sock.zig");
const UltraSock = ultra_sock_mod.UltraSock;
const Protocol = ultra_sock_mod.Protocol;
const TlsOptions = ultra_sock_mod.TlsOptions;
const BackendServer = @import("../../core/types.zig").BackendServer;

const MAX_CONNECTIONS_PER_BACKEND: usize = 16;
const MAX_BACKENDS: usize = 64;

/// Idle timeout for connections (30 seconds in nanoseconds)
const IDLE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;

/// Slot state machine
const SlotState = enum {
    empty,      // No connection allocated
    available,  // Connection ready for use
    in_use,     // Temporarily unavailable (being used)
};

/// Simplified HTTP/2 Connection Pool
pub const H2ConnectionPool = struct {
    slots: [MAX_BACKENDS][MAX_CONNECTIONS_PER_BACKEND]?*H2Connection,
    slot_state: [MAX_BACKENDS][MAX_CONNECTIONS_PER_BACKEND]SlotState,
    backends: []const BackendServer,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize pool with backend servers
    pub fn init(backends: []const BackendServer, allocator: std.mem.Allocator) Self {
        var pool = Self{
            .slots = undefined,
            .slot_state = undefined,
            .backends = backends,
            .allocator = allocator,
        };

        // Initialize all slots to empty
        for (0..MAX_BACKENDS) |b| {
            for (0..MAX_CONNECTIONS_PER_BACKEND) |s| {
                pool.slots[b][s] = null;
                pool.slot_state[b][s] = .empty;
            }
        }

        return pool;
    }

    /// Get or create connection for backend
    ///
    /// Strategy:
    /// 1. Scan for available connection in this backend's slots
    /// 2. If found and healthy, mark in_use and return
    /// 3. If found but stale, destroy and create fresh
    /// 4. If not found, find empty slot and create fresh
    /// 5. Connect (TLS + HTTP/2 handshake)
    pub fn getOrCreate(self: *Self, backend_idx: u32, io: Io) !*H2Connection {
        std.debug.assert(backend_idx < self.backends.len);

        // Phase 1: Scan for existing available connection
        for (&self.slot_state[backend_idx], &self.slots[backend_idx], 0..) |*state, *slot, i| {
            if (state.* == .available) {
                if (slot.*) |conn| {
                    // Check if connection is stale/dead
                    if (self.isConnectionStale(conn)) {
                        log.debug("Connection stale, destroying: backend={d} slot={d}", .{ backend_idx, i });
                        // CRITICAL: Clear slot FIRST to prevent other coroutines from seeing stale pointer
                        slot.* = null;
                        state.* = .empty;
                        self.destroyConnection(conn, io);
                        continue; // Will create fresh in Phase 2
                    }

                    // Connection healthy, mark in_use and return
                    state.* = .in_use;
                    // Reset to aggressive timeout for active request handling
                    conn.sock.setReadTimeout(500) catch {};
                    log.debug("Reusing connection: backend={d} slot={d}", .{ backend_idx, i });
                    return conn;
                }
            }
        }

        // Phase 2: No available connection, find empty slot and create fresh
        for (&self.slot_state[backend_idx], &self.slots[backend_idx], 0..) |*state, *slot, i| {
            if (state.* == .empty) {
                std.debug.assert(slot.* == null);

                // Create fresh connection
                const conn = try self.createFreshConnection(backend_idx, io);
                errdefer self.destroyConnection(conn, io);

                // Store in slot, mark in_use
                slot.* = conn;
                state.* = .in_use;
                log.debug("Created fresh connection: backend={d} slot={d}", .{ backend_idx, i });
                return conn;
            }
        }

        // Pool exhausted
        log.warn("Connection pool exhausted: backend={d}", .{backend_idx});
        return error.PoolExhausted;
    }

    /// Release connection back to pool
    ///
    /// If success=true and connection healthy: mark available for reuse
    /// If success=false or connection dead: destroy and mark empty
    pub fn release(self: *Self, conn: *H2Connection, success: bool, io: Io) void {
        const backend_idx = conn.backend_idx;
        std.debug.assert(backend_idx < self.backends.len);

        // Find slot containing this connection
        for (&self.slot_state[backend_idx], &self.slots[backend_idx]) |*state, *slot| {
            if (slot.* == conn) {
                if (success and conn.isReady() and !self.isConnectionStale(conn)) {
                    // Connection healthy - return to pool for reuse
                    // HTTP/2 multiplexing makes connection reuse highly valuable
                    log.debug("Returning connection to pool: backend={d}", .{backend_idx});
                    conn.last_used_ns = currentTimeNs();
                    // Set longer timeout for idle pooled connection (30 seconds)
                    // This allows the reader to wait for GOAWAY without triggering false errors
                    conn.sock.setReadTimeout(30_000) catch {};
                    state.* = .available;
                } else {
                    // Failed, dead, or stale - destroy
                    if (!success) {
                        log.debug("Destroying failed connection: backend={d}", .{backend_idx});
                    } else if (!conn.isReady()) {
                        log.debug("Destroying dead connection: backend={d}", .{backend_idx});
                    } else {
                        log.debug("Destroying stale connection: backend={d}", .{backend_idx});
                    }
                    // CRITICAL: Clear slot FIRST to prevent other coroutines from seeing stale pointer
                    slot.* = null;
                    state.* = .empty;
                    self.destroyConnection(conn, io);
                }
                return;
            }
        }

        log.warn("release() called with unknown connection: backend={d}", .{backend_idx});
    }

    /// Create fresh connection with TLS and HTTP/2 handshake
    fn createFreshConnection(self: *Self, backend_idx: u32, io: Io) !*H2Connection {
        std.debug.assert(backend_idx < self.backends.len);
        const backend = &self.backends[backend_idx];

        // Allocate connection on heap (stable address for mutexes)
        const conn = try self.allocator.create(H2Connection);
        errdefer self.allocator.destroy(conn);

        // Create socket from backend server
        const protocol: Protocol = if (backend.isHttps()) .https else .http;
        const tls_options = TlsOptions.fromRuntimeWithHttp2();
        const sock = UltraSock.initWithTls(protocol, backend.getHost(), backend.port, tls_options);

        // Initialize H2Connection with per-connection buffers
        conn.* = try H2Connection.init(sock, backend_idx, self.allocator);
        errdefer conn.deinit();

        // Connect socket with per-connection TLS buffers
        // (prevents threadlocal buffer corruption in concurrent scenarios)
        try conn.sock.connectWithBuffers(
            io,
            &conn.tls_input_buffer,
            &conn.tls_output_buffer,
        );

        // Set aggressive timeout for fresh connection
        conn.sock.setReadTimeout(500) catch {};

        // Perform HTTP/2 handshake (send preface + SETTINGS)
        try conn.connect(io);

        log.debug("Fresh H2 connection established: backend={d}", .{backend_idx});
        return conn;
    }

    /// Check if connection is stale or dead
    fn isConnectionStale(self: *Self, conn: *H2Connection) bool {
        _ = self;

        // Safety check - connection may have been destroyed by another coroutine
        if (conn.state == .dead) {
            return true;
        }

        // Never destroy connections with active streams
        if (conn.h2_client.active_streams > 0) {
            return false;
        }

        // Check basic connectivity
        if (!conn.sock.connected) {
            return true;
        }

        // Check GOAWAY received
        if (conn.goaway_received) {
            return true;
        }

        // Check idle timeout
        const now_ns = currentTimeNs();
        const idle_ns = now_ns - conn.last_used_ns;
        if (idle_ns > IDLE_TIMEOUT_NS) {
            return true;
        }

        return false;
    }

    /// Destroy connection and free resources
    /// CRITICAL: Mark dead FIRST to prevent other coroutines from using it
    fn destroyConnection(self: *Self, conn: *H2Connection, io: Io) void {
        conn.markDead(); // Prevents other coroutines from using
        conn.deinitAsync(io);
        self.allocator.destroy(conn);
    }

    /// Cleanup all connections (call on shutdown)
    pub fn deinit(self: *Self, io: Io) void {
        for (0..self.backends.len) |b| {
            for (0..MAX_CONNECTIONS_PER_BACKEND) |s| {
                if (self.slots[b][s]) |conn| {
                    self.destroyConnection(conn, io);
                    self.slots[b][s] = null;
                    self.slot_state[b][s] = .empty;
                }
            }
        }
    }
};

/// Get current time in nanoseconds (monotonic clock)
fn currentTimeNs() i64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}
