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

    /// Per-backend mutex to prevent concurrent connection creation race
    /// CANNOT be atomic: protects multi-step sequence (check empty → create → store)
    /// Without this, multiple coroutines see "empty" before any assigns,
    /// leading to duplicate connections and memory leaks
    backend_mutex: [MAX_BACKENDS]Io.Mutex,

    const Self = @This();

    /// Initialize pool with backend servers
    pub fn init(backends: []const BackendServer, allocator: std.mem.Allocator) Self {
        std.debug.assert(backends.len <= MAX_BACKENDS);

        var pool = Self{
            .slots = undefined,
            .slot_state = undefined,
            .backends = backends,
            .allocator = allocator,
            .backend_mutex = [_]Io.Mutex{.init} ** MAX_BACKENDS,
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
    /// Strategy for HTTP/2 MULTIPLEXING:
    /// 1. Lock per-backend mutex (prevents concurrent creation race)
    /// 2. Scan for available connection with room for more streams
    /// 3. If found and healthy, return it (stays available for more requests)
    /// 4. If not found, find empty slot and create fresh
    /// 5. Unlock mutex on return
    pub fn getOrCreate(self: *Self, backend_idx: u32, io: Io) !*H2Connection {
        std.debug.assert(backend_idx < self.backends.len);

        // Lock per-backend mutex to prevent concurrent creation race
        // Critical: without this, multiple coroutines see "empty" before any assigns
        try self.backend_mutex[backend_idx].lock(io);
        defer self.backend_mutex[backend_idx].unlock(io);

        // Phase 1: Find existing connection with room for more streams
        for (&self.slot_state[backend_idx], &self.slots[backend_idx], 0..) |*state, *slot, i| {
            if (state.* == .available) {
                if (slot.*) |conn| {
                    // Destroy stale connections so slots don't remain permanently unavailable.
                    // Available slots must have ref_count == 0.
                    if (self.isConnectionStale(conn)) {
                        log.debug("Connection stale, destroying: backend={d} slot={d}", .{ backend_idx, i });
                        // backend_mutex serializes getOrCreate calls; release() only
                        // marks a slot available when ref_count drops to 0.
                        std.debug.assert(conn.ref_count.load(.acquire) == 0);
                        slot.* = null;
                        state.* = .empty;
                        self.destroyConnection(conn, io);
                        continue;
                    }

                    // Check actual slot availability (8 stream slots per connection)
                    if (conn.h2_client.findFreeSlot() != null) {
                        const new_refs = conn.ref_count.fetchAdd(1, .acq_rel) + 1;
                        log.debug("Reusing connection: backend={d} slot={d} streams={d} refs={d}", .{ backend_idx, i, conn.h2_client.active_streams.load(.acquire), new_refs });
                        return conn;
                    }
                }
            }
        }

        // Phase 2: Create new connection in empty slot
        for (&self.slot_state[backend_idx], &self.slots[backend_idx], 0..) |*state, *slot, i| {
            if (state.* == .empty) {
                const conn = try self.createFreshConnection(backend_idx, io);
                conn.ref_count.store(1, .release); // First user
                slot.* = conn;
                state.* = .available;
                log.debug("Created fresh connection: backend={d} slot={d} refs=1", .{ backend_idx, i });
                return conn;
            }
        }

        // All slots full - handler will retry on TooManyStreams
        log.warn("Connection pool exhausted: backend={d}", .{backend_idx});
        return error.PoolExhausted;
    }

    /// Release connection back to pool
    ///
    /// Decrements ref_count. Only destroys when ref_count hits 0.
    /// If success=true and connection healthy: mark available for reuse
    /// If success=false or connection dead: destroy and mark empty
    pub fn release(self: *Self, conn: *H2Connection, success: bool, io: Io) void {
        const backend_idx = conn.backend_idx;
        std.debug.assert(backend_idx < self.backends.len);

        // Atomically decrement reference count and get previous value
        // This is safe for concurrent releases - only the one that gets prev_refs=1 proceeds to destroy
        const prev_refs = conn.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(prev_refs > 0); // Must have had at least 1 ref

        // If other users still have references (prev was > 1, now > 0), just return
        if (prev_refs > 1) {
            log.debug("Connection released, refs remaining: backend={d} refs={d}", .{ backend_idx, prev_refs - 1 });
            return;
        }

        // We were the last user (prev_refs == 1, now 0) - find slot and decide fate
        for (&self.slot_state[backend_idx], &self.slots[backend_idx]) |*state, *slot| {
            if (slot.* == conn) {

                // Last user - decide whether to keep or destroy
                if (success and conn.isReady() and !self.isConnectionStale(conn)) {
                    // Connection healthy - return to pool for reuse
                    log.debug("Returning connection to pool: backend={d}", .{backend_idx});
                    conn.last_used_ns = currentTimeNs();
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

        // Enable TCP keepalive to detect dead connections (replaces SO_RCVTIMEO)
        // OS will send probes and close dead connections automatically
        conn.sock.enableKeepalive() catch {};

        // Perform HTTP/2 handshake (send preface + SETTINGS)
        try conn.connect(io);

        log.debug("Fresh H2 connection established: backend={d}", .{backend_idx});
        return conn;
    }

    /// Check if connection is stale or dead
    /// Returns true if connection should NOT be used for NEW requests
    fn isConnectionStale(self: *Self, conn: *H2Connection) bool {
        _ = self;

        // Safety check - connection may have been destroyed by another coroutine
        if (conn.state == .dead) {
            return true;
        }

        // GOAWAY = no new streams allowed (existing streams can complete)
        // Must check BEFORE active_streams - we can't send NEW requests even if conn is busy
        if (conn.goaway_received) {
            return true;
        }

        // Check basic connectivity
        if (!conn.sock.connected) {
            return true;
        }

        // Skip idle timeout check if connection has active streams
        // Active connections are obviously not "idle"
        if (conn.h2_client.active_streams.load(.acquire) > 0) {
            return false;
        }

        // Check idle timeout (only for connections with no active streams)
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
