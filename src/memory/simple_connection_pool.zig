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

/// Maximum number of backends.
/// Must match health_state.MAX_BACKENDS (limited by u64 bitmap).
pub const MAX_BACKENDS: usize = 64;

/// Simple stack for connection pooling (no atomics)
pub const SimpleConnectionStack = struct {
    /// Fixed-size array of socket slots
    sockets: [MAX_IDLE_CONNS]?UltraSock = [_]?UltraSock{null} ** MAX_IDLE_CONNS,
    /// Current stack top (next free slot)
    top: usize = 0,

    /// Push a connection onto the stack
    /// Returns false if stack is full
    pub inline fn push(self: *SimpleConnectionStack, socket: UltraSock) bool {
        if (self.top >= MAX_IDLE_CONNS) {
            return false; // Stack full
        }
        self.sockets[self.top] = socket;
        self.top += 1;
        return true;
    }

    /// Pop a connection from the stack
    /// Returns null if stack is empty
    pub inline fn pop(self: *SimpleConnectionStack) ?UltraSock {
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

/// Simple connection pool - thread-safe with mutex
pub const SimpleConnectionPool = struct {
    /// Per-backend connection stacks
    pools: [MAX_BACKENDS]SimpleConnectionStack = undefined,
    /// Number of active backends
    backend_count: usize = 0,
    /// Initialized flag
    initialized: bool = false,
    /// Single mutex (simpler, better cache locality)
    mutex: std.Thread.Mutex = .{},

    /// Initialize the pool
    pub fn init(self: *SimpleConnectionPool) void {
        for (&self.pools) |*pool| {
            pool.* = SimpleConnectionStack{};
        }
        self.backend_count = 0;
        self.initialized = true;
        self.mutex = .{};
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
    /// Thread-safe with mutex
    pub inline fn getConnection(self: *SimpleConnectionPool, backend_idx: usize) ?UltraSock {
        if (backend_idx >= self.backend_count) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pools[backend_idx].pop();
    }

    /// Return a connection to the pool
    /// Thread-safe with mutex
    pub inline fn returnConnection(self: *SimpleConnectionPool, backend_idx: usize, socket: UltraSock) void {
        if (backend_idx >= self.backend_count) {
            // Invalid backend, just close
            var sock = socket;
            sock.close_blocking();
            return;
        }

        self.mutex.lock();
        const pushed = self.pools[backend_idx].push(socket);
        self.mutex.unlock();

        if (!pushed) {
            // Pool full, close the connection
            var sock = socket;
            sock.close_blocking();
        }
    }

    /// Pool statistics
    pub const PoolStats = struct {
        total: usize,
        per_backend: [MAX_BACKENDS]usize,
    };

    /// Get pool statistics
    pub fn getStats(self: *const SimpleConnectionPool) PoolStats {
        var stats: PoolStats = .{
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

// Helper to create a mock UltraSock for testing (no actual network)
fn createMockSocket(allocator: std.mem.Allocator) UltraSock {
    return UltraSock{
        .stream = null,
        .io = null,
        .protocol = .http,
        .host = "test",
        .port = 8080,
        .connected = false,
        .allocator = allocator,
    };
}

test "SimpleConnectionStack: initial state is empty" {
    var stack = SimpleConnectionStack{};

    try std.testing.expectEqual(@as(usize, 0), stack.size());
    try std.testing.expect(stack.pop() == null);
}

test "SimpleConnectionStack: push and pop single item" {
    var stack = SimpleConnectionStack{};
    const sock = createMockSocket(std.testing.allocator);

    const pushed = stack.push(sock);
    try std.testing.expect(pushed);
    try std.testing.expectEqual(@as(usize, 1), stack.size());

    const popped = stack.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(usize, 0), stack.size());
}

test "SimpleConnectionStack: LIFO order" {
    var stack = SimpleConnectionStack{};

    // Push sockets with different ports to identify them
    var sock1 = createMockSocket(std.testing.allocator);
    sock1.port = 1001;
    var sock2 = createMockSocket(std.testing.allocator);
    sock2.port = 1002;
    var sock3 = createMockSocket(std.testing.allocator);
    sock3.port = 1003;

    _ = stack.push(sock1);
    _ = stack.push(sock2);
    _ = stack.push(sock3);

    // Should pop in reverse order (LIFO)
    try std.testing.expectEqual(@as(u16, 1003), stack.pop().?.port);
    try std.testing.expectEqual(@as(u16, 1002), stack.pop().?.port);
    try std.testing.expectEqual(@as(u16, 1001), stack.pop().?.port);
    try std.testing.expect(stack.pop() == null);
}

test "SimpleConnectionStack: push fails when full" {
    var stack = SimpleConnectionStack{};
    const sock = createMockSocket(std.testing.allocator);

    // Fill the stack
    for (0..MAX_IDLE_CONNS) |_| {
        const pushed = stack.push(sock);
        try std.testing.expect(pushed);
    }
    try std.testing.expectEqual(MAX_IDLE_CONNS, stack.size());

    // Next push should fail
    const overflow = stack.push(sock);
    try std.testing.expect(!overflow);
    try std.testing.expectEqual(MAX_IDLE_CONNS, stack.size());
}

test "SimpleConnectionStack: push after pop" {
    var stack = SimpleConnectionStack{};
    const sock = createMockSocket(std.testing.allocator);

    _ = stack.push(sock);
    _ = stack.push(sock);
    try std.testing.expectEqual(@as(usize, 2), stack.size());

    _ = stack.pop();
    try std.testing.expectEqual(@as(usize, 1), stack.size());

    _ = stack.push(sock);
    try std.testing.expectEqual(@as(usize, 2), stack.size());
}

test "SimpleConnectionPool: init sets up correctly" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();

    try std.testing.expect(pool.initialized);
    try std.testing.expectEqual(@as(usize, 0), pool.backend_count);
}

test "SimpleConnectionPool: addBackends sets count" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();

    pool.addBackends(5);
    try std.testing.expectEqual(@as(usize, 5), pool.backend_count);
}

test "SimpleConnectionPool: addBackends caps at MAX_BACKENDS" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();

    pool.addBackends(100);
    try std.testing.expectEqual(MAX_BACKENDS, pool.backend_count);
}

test "SimpleConnectionPool: getConnection returns null for empty pool" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();
    pool.addBackends(2);

    try std.testing.expect(pool.getConnection(0) == null);
    try std.testing.expect(pool.getConnection(1) == null);
}

test "SimpleConnectionPool: getConnection returns null for invalid backend" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();
    pool.addBackends(2);

    try std.testing.expect(pool.getConnection(2) == null);
    try std.testing.expect(pool.getConnection(100) == null);
}

test "SimpleConnectionPool: returnConnection and getConnection round-trip" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();
    pool.addBackends(2);

    var sock = createMockSocket(std.testing.allocator);
    sock.port = 9999;

    pool.returnConnection(0, sock);

    const retrieved = pool.getConnection(0);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u16, 9999), retrieved.?.port);

    // Pool should be empty again
    try std.testing.expect(pool.getConnection(0) == null);
}

test "SimpleConnectionPool: connections are per-backend" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();
    pool.addBackends(3);

    var sock0 = createMockSocket(std.testing.allocator);
    sock0.port = 1000;
    var sock1 = createMockSocket(std.testing.allocator);
    sock1.port = 1001;
    var sock2 = createMockSocket(std.testing.allocator);
    sock2.port = 1002;

    pool.returnConnection(0, sock0);
    pool.returnConnection(1, sock1);
    pool.returnConnection(2, sock2);

    // Each backend should have its own connection
    try std.testing.expectEqual(@as(u16, 1000), pool.getConnection(0).?.port);
    try std.testing.expectEqual(@as(u16, 1001), pool.getConnection(1).?.port);
    try std.testing.expectEqual(@as(u16, 1002), pool.getConnection(2).?.port);
}

test "SimpleConnectionPool: returnConnection to invalid backend is handled" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();
    pool.addBackends(1);

    const sock = createMockSocket(std.testing.allocator);

    // Should not crash, socket is discarded
    pool.returnConnection(5, sock);
    pool.returnConnection(100, sock);
}

test "SimpleConnectionPool: getStats tracks pool sizes" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();
    pool.addBackends(3);

    const sock = createMockSocket(std.testing.allocator);

    // Add connections to different backends
    pool.returnConnection(0, sock);
    pool.returnConnection(0, sock);
    pool.returnConnection(1, sock);

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 3), stats.total);
    try std.testing.expectEqual(@as(usize, 2), stats.per_backend[0]);
    try std.testing.expectEqual(@as(usize, 1), stats.per_backend[1]);
    try std.testing.expectEqual(@as(usize, 0), stats.per_backend[2]);
}

test "SimpleConnectionPool: getStats on empty pool" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();
    pool.addBackends(2);

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.per_backend[0]);
    try std.testing.expectEqual(@as(usize, 0), stats.per_backend[1]);
}

test "SimpleConnectionPool: multiple connections per backend" {
    var pool = SimpleConnectionPool{};
    pool.init();
    defer pool.deinit();
    pool.addBackends(1);

    // Add 5 connections to backend 0
    for (0..5) |i| {
        var sock = createMockSocket(std.testing.allocator);
        sock.port = @intCast(3000 + i);
        pool.returnConnection(0, sock);
    }

    // Should retrieve in LIFO order
    try std.testing.expectEqual(@as(u16, 3004), pool.getConnection(0).?.port);
    try std.testing.expectEqual(@as(u16, 3003), pool.getConnection(0).?.port);
    try std.testing.expectEqual(@as(u16, 3002), pool.getConnection(0).?.port);
    try std.testing.expectEqual(@as(u16, 3001), pool.getConnection(0).?.port);
    try std.testing.expectEqual(@as(u16, 3000), pool.getConnection(0).?.port);
    try std.testing.expect(pool.getConnection(0) == null);
}

test "SimpleConnectionPool: deinit without init is safe" {
    var pool = SimpleConnectionPool{};
    // Should not crash
    pool.deinit();
}

test "SimpleConnectionPool: double init is safe" {
    var pool = SimpleConnectionPool{};
    pool.init();
    pool.init(); // Should reinitialize
    defer pool.deinit();

    try std.testing.expect(pool.initialized);
}
