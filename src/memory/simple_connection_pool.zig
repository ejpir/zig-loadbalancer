/// Simple Connection Pool (No Atomics)
///
/// Optimized for single-threaded workers where no synchronization is needed.
/// Uses direct array access instead of atomic CAS operations.
///
/// Performance advantage over LockFreeConnectionPool:
/// - No atomic load/store overhead
/// - No memory barriers
/// - Better branch prediction (no CAS retry loops)
/// - Cache-friendly linear access
const std = @import("std");
const log = std.log.scoped(.simple_pool);
const UltraSock = @import("../http/ultra_sock.zig").UltraSock;

/// Maximum idle connections per backend
pub const MAX_IDLE_CONNS: usize = 128;

/// Maximum number of backends
pub const MAX_BACKENDS: usize = 64;

/// Simple stack for connection pooling (no atomics)
pub const SimpleConnectionStack = struct {
    /// Fixed-size array of socket slots
    sockets: [MAX_IDLE_CONNS]?UltraSock = [_]?UltraSock{null} ** MAX_IDLE_CONNS,
    /// Current stack top (next free slot)
    top: usize = 0,

    /// Push a connection onto the stack
    /// Returns false if stack is full
    pub fn push(self: *SimpleConnectionStack, socket: UltraSock) bool {
        if (self.top >= MAX_IDLE_CONNS) {
            return false; // Stack full
        }
        self.sockets[self.top] = socket;
        self.top += 1;
        return true;
    }

    /// Pop a connection from the stack
    /// Returns null if stack is empty
    pub fn pop(self: *SimpleConnectionStack) ?UltraSock {
        if (self.top == 0) {
            return null; // Stack empty
        }
        self.top -= 1;
        const socket = self.sockets[self.top];
        self.sockets[self.top] = null;
        return socket;
    }

    /// Get current size
    pub fn size(self: *const SimpleConnectionStack) usize {
        return self.top;
    }

    /// Close all connections in the stack
    pub fn closeAll(self: *SimpleConnectionStack) void {
        while (self.top > 0) {
            self.top -= 1;
            if (self.sockets[self.top]) |*sock| {
                sock.close_blocking();
                self.sockets[self.top] = null;
            }
        }
    }
};

/// Simple connection pool for single-threaded workers
pub const SimpleConnectionPool = struct {
    /// Per-backend connection stacks
    pools: [MAX_BACKENDS]SimpleConnectionStack = undefined,
    /// Number of active backends
    backend_count: usize = 0,
    /// Initialized flag
    initialized: bool = false,

    /// Initialize the pool
    pub fn init(self: *SimpleConnectionPool) void {
        for (&self.pools) |*pool| {
            pool.* = SimpleConnectionStack{};
        }
        self.backend_count = 0;
        self.initialized = true;
    }

    /// Deinitialize and close all connections
    pub fn deinit(self: *SimpleConnectionPool) void {
        if (!self.initialized) return;

        for (0..self.backend_count) |i| {
            self.pools[i].closeAll();
        }
        self.initialized = false;
    }

    /// Add backends to the pool
    pub fn addBackends(self: *SimpleConnectionPool, count: usize) void {
        self.backend_count = @min(count, MAX_BACKENDS);
    }

    /// Get a connection for a backend (returns null if pool empty)
    pub fn getConnection(self: *SimpleConnectionPool, backend_idx: usize) ?UltraSock {
        if (backend_idx >= self.backend_count) return null;
        return self.pools[backend_idx].pop();
    }

    /// Return a connection to the pool
    pub fn returnConnection(self: *SimpleConnectionPool, backend_idx: usize, socket: UltraSock) void {
        if (backend_idx >= self.backend_count) {
            // Invalid backend, just close
            var sock = socket;
            sock.close_blocking();
            return;
        }

        if (!self.pools[backend_idx].push(socket)) {
            // Pool full, close the connection
            var sock = socket;
            sock.close_blocking();
        }
    }

    /// Get pool statistics
    pub fn getStats(self: *const SimpleConnectionPool) struct { total: usize, per_backend: [MAX_BACKENDS]usize } {
        var stats: struct { total: usize, per_backend: [MAX_BACKENDS]usize } = .{
            .total = 0,
            .per_backend = [_]usize{0} ** MAX_BACKENDS,
        };

        for (0..self.backend_count) |i| {
            const count = self.pools[i].size();
            stats.per_backend[i] = count;
            stats.total += count;
        }

        return stats;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SimpleConnectionStack push/pop" {
    var stack = SimpleConnectionStack{};

    // Stack should be empty initially
    try std.testing.expectEqual(@as(usize, 0), stack.size());
    try std.testing.expectEqual(@as(?UltraSock, null), stack.pop());
}

test "SimpleConnectionPool init/deinit" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();

    pool.addBackends(2);
    try std.testing.expectEqual(@as(usize, 2), pool.backend_count);
}
