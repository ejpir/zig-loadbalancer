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
const config = @import("../core/config.zig");
const ultra_sock = @import("../http/ultra_sock.zig");
const UltraSock = ultra_sock.UltraSock;
const TlsOptions = ultra_sock.TlsOptions;

pub const MAX_IDLE_CONNS = config.MAX_IDLE_CONNS;
pub const MAX_BACKENDS = config.MAX_BACKENDS;

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
            // Caller must close socket when pool is full
            return false;
        }
        self.sockets[self.top] = socket;
        self.top += 1;
        return true;
    }

    /// Pop a connection from the stack
    /// Returns null if stack is empty
    pub inline fn pop(self: *SimpleConnectionStack) ?UltraSock {
        if (self.top == 0) {
            // No cached connection available; caller must create new one
            return null;
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

/// Per-worker connection pool - NO SYNCHRONIZATION NEEDED
///
/// Each worker process has its own pool instance. Within a worker:
/// - I/O event loop is single-threaded (io_uring/kqueue completions are sequential)
/// - Health probe thread does NOT access connection pool (uses shared_region instead)
/// - No concurrent access = no locks needed
///
/// This eliminates mutex overhead on every connection acquire/release.
/// TigerStyle: explicit single-threaded design, no hidden synchronization costs.
pub const SimpleConnectionPool = struct {
    /// Per-backend connection stacks (zero-initialized for safety)
    pools: [MAX_BACKENDS]SimpleConnectionStack = [_]SimpleConnectionStack{.{}} ** MAX_BACKENDS,
    /// Number of active backends
    backend_count: usize = 0,

    /// Deinitialize and close all connections
    pub fn deinit(self: *SimpleConnectionPool) void {
        for (0..self.backend_count) |i| {
            self.pools[i].closeAll();
        }
    }

    /// Add backends to the pool
    pub fn addBackends(self: *SimpleConnectionPool, count: usize) void {
        self.backend_count = @min(count, MAX_BACKENDS);
    }

    /// Get a connection for a backend (returns null if pool empty)
    /// No synchronization - single-threaded I/O loop per worker
    pub inline fn getConnection(self: *SimpleConnectionPool, backend_idx: usize) ?UltraSock {
        if (backend_idx >= MAX_BACKENDS or backend_idx >= self.backend_count) return null;
        return self.pools[backend_idx].pop();
    }

    /// Return a connection to the pool
    /// No synchronization - single-threaded I/O loop per worker
    pub inline fn returnConnection(
        self: *SimpleConnectionPool,
        backend_idx: usize,
        socket: UltraSock,
    ) void {
        if (backend_idx >= MAX_BACKENDS or backend_idx >= self.backend_count) {
            var sock = socket;
            sock.close_blocking();
            return;
        }

        if (!self.pools[backend_idx].push(socket)) {
            // Pool full - close excess connection
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
fn createMockSocket() UltraSock {
    return UltraSock{
        .stream = null,
        .io = null,
        .protocol = .http,
        .host = "test",
        .port = 8080,
        .connected = false,
        .tls_options = TlsOptions.insecure(),
    };
}

test "SimpleConnectionStack: initial state is empty" {
    var stack = SimpleConnectionStack{};

    try std.testing.expectEqual(@as(usize, 0), stack.size());
    try std.testing.expect(stack.pop() == null);
}

test "SimpleConnectionStack: push and pop single item" {
    var stack = SimpleConnectionStack{};
    const sock = createMockSocket();

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
    var sock1 = createMockSocket();
    sock1.port = 1001;
    var sock2 = createMockSocket();
    sock2.port = 1002;
    var sock3 = createMockSocket();
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
    const sock = createMockSocket();

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
    const sock = createMockSocket();

    _ = stack.push(sock);
    _ = stack.push(sock);
    try std.testing.expectEqual(@as(usize, 2), stack.size());

    _ = stack.pop();
    try std.testing.expectEqual(@as(usize, 1), stack.size());

    _ = stack.push(sock);
    try std.testing.expectEqual(@as(usize, 2), stack.size());
}

test "SimpleConnectionPool: default initialization" {
    var pool = SimpleConnectionPool{};
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.backend_count);
    try std.testing.expectEqual(@as(usize, 0), pool.pools[0].size());
}

test "SimpleConnectionPool: addBackends sets count" {
    var pool = SimpleConnectionPool{};
    defer pool.deinit();

    pool.addBackends(5);
    try std.testing.expectEqual(@as(usize, 5), pool.backend_count);
}

test "SimpleConnectionPool: addBackends caps at MAX_BACKENDS" {
    var pool = SimpleConnectionPool{};
    defer pool.deinit();

    pool.addBackends(100);
    try std.testing.expectEqual(MAX_BACKENDS, pool.backend_count);
}

test "SimpleConnectionPool: getConnection returns null for empty pool" {
    var pool = SimpleConnectionPool{};
    defer pool.deinit();
    pool.addBackends(2);

    try std.testing.expect(pool.getConnection(0) == null);
    try std.testing.expect(pool.getConnection(1) == null);
}

test "SimpleConnectionPool: getConnection returns null for invalid backend" {
    var pool = SimpleConnectionPool{};
    defer pool.deinit();
    pool.addBackends(2);

    try std.testing.expect(pool.getConnection(2) == null);
    try std.testing.expect(pool.getConnection(100) == null);
}

test "SimpleConnectionPool: returnConnection and getConnection round-trip" {
    var pool = SimpleConnectionPool{};
    defer pool.deinit();
    pool.addBackends(2);

    var sock = createMockSocket();
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
    defer pool.deinit();
    pool.addBackends(3);

    var sock0 = createMockSocket();
    sock0.port = 1000;
    var sock1 = createMockSocket();
    sock1.port = 1001;
    var sock2 = createMockSocket();
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
    defer pool.deinit();
    pool.addBackends(1);

    const sock = createMockSocket();

    // Should not crash, socket is discarded
    pool.returnConnection(5, sock);
    pool.returnConnection(100, sock);
}

test "SimpleConnectionPool: getStats tracks pool sizes" {
    var pool = SimpleConnectionPool{};
    defer pool.deinit();
    pool.addBackends(3);

    const sock = createMockSocket();

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
    defer pool.deinit();
    pool.addBackends(2);

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.per_backend[0]);
    try std.testing.expectEqual(@as(usize, 0), stats.per_backend[1]);
}

test "SimpleConnectionPool: multiple connections per backend" {
    var pool = SimpleConnectionPool{};
    defer pool.deinit();
    pool.addBackends(1);

    // Add 5 connections to backend 0
    for (0..5) |i| {
        var sock = createMockSocket();
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

test "SimpleConnectionPool: deinit on empty pool is safe" {
    var pool = SimpleConnectionPool{};
    // Should not crash
    pool.deinit();
}

test "SimpleConnectionPool: TLS sockets can be pooled" {
    var pool = SimpleConnectionPool{};
    defer pool.deinit();
    pool.addBackends(1);

    // Create a mock TLS socket using UltraSock.init
    const tls_sock = UltraSock.init(.https, "secure.example.com", 443);

    // Pool the TLS socket
    pool.returnConnection(0, tls_sock);

    // Retrieve it
    const retrieved = pool.getConnection(0);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("secure.example.com", retrieved.?.host);
    try std.testing.expectEqual(@as(u16, 443), retrieved.?.port);
}

test "SimpleConnectionStack: multiple TLS connections" {
    var stack = SimpleConnectionStack{};

    // Create multiple TLS sockets using UltraSock.init
    const sock1 = UltraSock.init(.https, "api1.example.com", 443);
    const sock2 = UltraSock.init(.https, "api2.example.com", 443);

    // Push both TLS sockets
    _ = stack.push(sock1);
    _ = stack.push(sock2);

    try std.testing.expectEqual(@as(usize, 2), stack.size());

    // Pop in LIFO order
    const popped2 = stack.pop();
    try std.testing.expect(popped2 != null);
    try std.testing.expectEqualStrings("api2.example.com", popped2.?.host);

    const popped1 = stack.pop();
    try std.testing.expect(popped1 != null);
    try std.testing.expectEqualStrings("api1.example.com", popped1.?.host);

    try std.testing.expectEqual(@as(usize, 0), stack.size());
}
