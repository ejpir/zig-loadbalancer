# Token-Based H2 Connection Pool Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace pointer-based H2 connection pool with token-based exclusive ownership to eliminate race conditions.

**Architecture:** Connections live in fixed slots. Callers receive opaque tokens representing exclusive access. All connection access goes through `pool.get(token)`. Generation counters invalidate stale tokens.

**Tech Stack:** Zig, TigerStyle patterns, no external dependencies.

---

### Task 1: Add Token and SlotState Types

**Files:**
- Modify: `src/http/http2/pooled_conn.zig:1-45`

**Step 1: Add the new types after the imports**

Add after line 21 (after config import):

```zig
/// Opaque token representing exclusive access to a connection slot.
/// Small (4 bytes), cheap to copy, safe to pass between functions.
pub const ConnectionToken = struct {
    backend_idx: u8,
    slot_idx: u8,
    generation: u16,
};

/// Explicit state machine for slot lifecycle.
pub const SlotState = enum {
    empty,      // No connection, slot available for new connection
    available,  // Connection ready, can be acquired
    in_use,     // Exclusively owned by a request
    draining,   // Marked for eviction, cleanup when released
};

/// A slot in the connection pool.
pub const ConnectionSlot = struct {
    conn: ?H2PooledConnection = null,
    state: SlotState = .empty,
    generation: u16 = 0,
};
```

**Step 2: Run tests to verify no regressions**

Run: `/usr/local/zig-0.16.0-dev/zig build test --summary all 2>&1 | tail -5`
Expected: All tests pass (new types are just definitions, no behavior change yet)

**Step 3: Commit**

```bash
git add src/http/http2/pooled_conn.zig
git commit -m "feat(h2-pool): add ConnectionToken and SlotState types"
```

---

### Task 2: Simplify H2PooledConnection

**Files:**
- Modify: `src/http/http2/pooled_conn.zig:47-97`

**Step 1: Remove defensive guard fields from H2PooledConnection**

Change the struct fields (lines 47-72) to remove `eviction_pending` and `deinit_started`:

```zig
/// HTTP/2 connection with stream slot tracking
pub const H2PooledConnection = struct {
    /// Underlying socket + TLS state
    sock: UltraSock,

    /// HTTP/2 client state (heap-allocated to keep pool structure small)
    h2_client: ?*Http2Client,

    /// Allocator used for h2_client (needed for cleanup)
    allocator: std.mem.Allocator,

    /// Stream capacity tracking
    stream_slots_used: u32,
    max_concurrent_streams: u32,

    /// Connection health
    last_used_ns: i64,
    goaway_received: bool,
    connected: bool,
    session_established: bool,

    /// Backend identity (for pool routing)
    backend_idx: u32,

    const Self = @This();
```

**Step 2: Update init() to remove the deleted fields**

Update the init function (around line 77-97) - remove the two deleted field initializers:

```zig
    pub fn init(sock: UltraSock, backend_idx: u32, allocator: std.mem.Allocator) !Self {
        std.debug.assert(backend_idx < config.MAX_BACKENDS);

        const h2_client = try allocator.create(Http2Client);
        h2_client.* = Http2Client.init(allocator);

        return Self{
            .sock = sock,
            .h2_client = h2_client,
            .allocator = allocator,
            .stream_slots_used = 0,
            .max_concurrent_streams = MAX_CONCURRENT_STREAMS,
            .last_used_ns = currentTimeNs(),
            .goaway_received = false,
            .connected = true,
            .session_established = false,
            .backend_idx = backend_idx,
        };
    }
```

**Step 3: Simplify deinit() - remove double-deinit guard**

Replace the deinit function (lines 116-137):

```zig
    /// Clean up resources
    pub fn deinit(self: *Self) void {
        if (self.h2_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
            self.h2_client = null;
        }
        self.sock.close_blocking();
    }
```

**Step 4: Simplify shouldEvict() - remove eviction_pending check**

Replace shouldEvict (lines 199-220):

```zig
    /// Check if connection should be evicted from pool
    pub fn shouldEvict(self: *const Self) bool {
        if (self.stream_slots_used > 0) return false;
        if (self.goaway_received) return true;
        if (!self.connected) return true;

        const now = currentTimeNs();
        const idle_ns = now - self.last_used_ns;
        const IDLE_TIMEOUT_NS: i64 = 5_000_000_000;
        return idle_ns > IDLE_TIMEOUT_NS;
    }
```

**Step 5: Simplify hasAvailableSlot() - remove eviction_pending check**

Replace hasAvailableSlot (lines 139-146):

```zig
    pub inline fn hasAvailableSlot(self: *const Self) bool {
        return self.connected and
            !self.goaway_received and
            self.stream_slots_used < self.max_concurrent_streams;
    }
```

**Step 6: Simplify releaseStream() - remove underflow guard**

Replace releaseStream (lines 173-191):

```zig
    /// Release a stream slot after request completes
    pub fn releaseStream(self: *Self, stream_id: u32) void {
        std.debug.assert(self.stream_slots_used > 0);
        self.stream_slots_used -= 1;
        self.last_used_ns = currentTimeNs();

        log.debug("Released stream {d}, slots_used={d}/{d}", .{
            stream_id, self.stream_slots_used, self.max_concurrent_streams,
        });
    }
```

**Step 7: Run tests**

Run: `/usr/local/zig-0.16.0-dev/zig build test --summary all 2>&1 | tail -5`
Expected: All tests pass

**Step 8: Commit**

```bash
git add src/http/http2/pooled_conn.zig
git commit -m "refactor(h2-pool): simplify H2PooledConnection, remove defensive guards"
```

---

### Task 3: Rewrite BackendH2Pool with Token API

**Files:**
- Modify: `src/http/http2/connection_pool.zig:37-163`

**Step 1: Replace H2BackendPool struct entirely**

Replace lines 37-163 with:

```zig
/// Per-backend HTTP/2 connection pool with token-based access
pub const BackendH2Pool = struct {
    slots: [MAX_H2_CONNS_PER_BACKEND]pooled_conn.ConnectionSlot,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .slots = [_]pooled_conn.ConnectionSlot{.{}} ** MAX_H2_CONNS_PER_BACKEND,
        };
    }

    /// Acquire exclusive access to an available connection.
    /// Returns token if available, null otherwise.
    pub fn acquire(self: *Self, backend_idx: u8) ?pooled_conn.ConnectionToken {
        for (&self.slots, 0..) |*slot, i| {
            if (slot.state == .available) {
                if (slot.conn) |*conn| {
                    if (conn.hasAvailableSlot()) {
                        _ = conn.acquireStreamSlot() catch continue;
                        slot.state = .in_use;
                        return pooled_conn.ConnectionToken{
                            .backend_idx = backend_idx,
                            .slot_idx = @intCast(i),
                            .generation = slot.generation,
                        };
                    }
                }
            }
        }
        return null;
    }

    /// Get connection pointer from token. Returns null if token is stale.
    pub fn get(self: *Self, token: pooled_conn.ConnectionToken) ?*H2PooledConnection {
        const slot = &self.slots[token.slot_idx];
        if (slot.generation != token.generation) return null;
        if (slot.state != .in_use) return null;
        return if (slot.conn) |*c| c else null;
    }

    /// Release exclusive access.
    /// keep=true: return to pool, keep=false: close connection
    pub fn release(self: *Self, token: pooled_conn.ConnectionToken, keep: bool) void {
        const slot = &self.slots[token.slot_idx];
        if (slot.generation != token.generation) return;
        if (slot.state != .in_use and slot.state != .draining) return;

        // Release the stream slot on the connection
        if (slot.conn) |*conn| {
            conn.releaseStream(0);
        }

        slot.generation +%= 1;

        if (keep and slot.state == .in_use) {
            slot.state = .available;
        } else {
            if (slot.conn) |*conn| conn.deinit();
            slot.conn = null;
            slot.state = .empty;
        }
    }

    /// Add a new connection and acquire it atomically.
    /// Returns token with exclusive access, or null if pool full.
    pub fn addAndAcquire(self: *Self, conn: H2PooledConnection, backend_idx: u8) ?pooled_conn.ConnectionToken {
        for (&self.slots, 0..) |*slot, i| {
            if (slot.state == .empty) {
                var new_conn = conn;
                _ = new_conn.acquireStreamSlot() catch return null;
                slot.conn = new_conn;
                slot.state = .in_use;
                return pooled_conn.ConnectionToken{
                    .backend_idx = backend_idx,
                    .slot_idx = @intCast(i),
                    .generation = slot.generation,
                };
            }
        }
        return null;
    }

    /// Check if pool has capacity for new connection.
    pub fn hasCapacity(self: *const Self) bool {
        for (self.slots) |slot| {
            if (slot.state == .empty) return true;
        }
        return false;
    }

    /// Close all connections.
    pub fn closeAll(self: *Self) void {
        for (&self.slots) |*slot| {
            if (slot.conn) |*conn| {
                conn.deinit();
            }
            slot.conn = null;
            slot.state = .empty;
        }
    }

    /// Count active connections.
    pub fn count(self: *const Self) usize {
        var n: usize = 0;
        for (self.slots) |slot| {
            if (slot.state != .empty) n += 1;
        }
        return n;
    }

    /// Count idle connections.
    pub fn countIdle(self: *const Self) usize {
        var n: usize = 0;
        for (self.slots) |slot| {
            if (slot.state == .available) n += 1;
        }
        return n;
    }

    /// Get total available stream slots.
    pub fn totalAvailableSlots(self: *const Self) u32 {
        var total: u32 = 0;
        for (self.slots) |slot| {
            if (slot.state == .available) {
                if (slot.conn) |conn| {
                    total += conn.availableSlots();
                }
            }
        }
        return total;
    }
};
```

**Step 2: Compile check**

Run: `/usr/local/zig-0.16.0-dev/zig build 2>&1 | head -20`
Expected: Errors about removed types/functions (AcquiredConnection, findConnectionWithSlot, etc.) - this is expected, we'll fix callers next.

**Step 3: Commit (work in progress)**

```bash
git add src/http/http2/connection_pool.zig
git commit -m "wip(h2-pool): rewrite BackendH2Pool with token API"
```

---

### Task 4: Rewrite H2ConnectionPool Top-Level API

**Files:**
- Modify: `src/http/http2/connection_pool.zig:165-292`

**Step 1: Replace H2ConnectionPool struct**

Replace lines 165-292 with:

```zig
/// HTTP/2 Connection Pool - per-worker, no synchronization needed
pub const H2ConnectionPool = struct {
    pools: [MAX_BACKENDS]BackendH2Pool,
    backend_count: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .pools = [_]BackendH2Pool{BackendH2Pool.init()} ** MAX_BACKENDS,
            .backend_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (0..self.backend_count) |i| {
            self.pools[i].closeAll();
        }
    }

    pub fn setBackendCount(self: *Self, count: usize) void {
        self.backend_count = @min(count, MAX_BACKENDS);
    }

    /// Acquire exclusive access to a connection for backend.
    pub fn acquire(self: *Self, backend_idx: u32) ?pooled_conn.ConnectionToken {
        if (backend_idx >= self.backend_count) return null;
        if (backend_idx >= MAX_BACKENDS) return null;
        return self.pools[backend_idx].acquire(@intCast(backend_idx));
    }

    /// Get connection from token.
    pub fn get(self: *Self, token: pooled_conn.ConnectionToken) ?*H2PooledConnection {
        return self.pools[token.backend_idx].get(token);
    }

    /// Release connection. keep=true returns to pool, keep=false closes.
    pub fn release(self: *Self, token: pooled_conn.ConnectionToken, keep: bool) void {
        self.pools[token.backend_idx].release(token, keep);
    }

    /// Add a new connection and acquire it atomically.
    pub fn addAndAcquire(self: *Self, conn: H2PooledConnection) ?pooled_conn.ConnectionToken {
        const backend_idx = conn.backend_idx;
        std.debug.assert(backend_idx < MAX_BACKENDS);

        if (backend_idx >= self.backend_count) {
            self.backend_count = backend_idx + 1;
        }

        const token = self.pools[backend_idx].addAndAcquire(conn, @intCast(backend_idx));
        if (token) |t| {
            log.debug("Added H2 connection to pool, backend={d}", .{backend_idx});
            return t;
        }
        return null;
    }

    /// Check if backend pool has capacity.
    pub fn hasCapacity(self: *const Self, backend_idx: u32) bool {
        if (backend_idx >= MAX_BACKENDS) return false;
        return self.pools[backend_idx].hasCapacity();
    }

    pub const PoolStats = struct {
        total_connections: usize,
        total_available_slots: u32,
        per_backend_connections: [MAX_BACKENDS]usize,
        per_backend_idle: [MAX_BACKENDS]usize,
    };

    pub fn getStats(self: *const Self) PoolStats {
        var stats = PoolStats{
            .total_connections = 0,
            .total_available_slots = 0,
            .per_backend_connections = [_]usize{0} ** MAX_BACKENDS,
            .per_backend_idle = [_]usize{0} ** MAX_BACKENDS,
        };

        for (0..self.backend_count) |i| {
            const pool = &self.pools[i];
            stats.per_backend_connections[i] = pool.count();
            stats.per_backend_idle[i] = pool.countIdle();
            stats.total_connections += pool.count();
            stats.total_available_slots += pool.totalAvailableSlots();
        }

        return stats;
    }
};
```

**Step 2: Remove old AcquiredConnection type**

Delete lines 31-35 (the old AcquiredConnection struct).

**Step 3: Commit**

```bash
git add src/http/http2/connection_pool.zig
git commit -m "wip(h2-pool): rewrite H2ConnectionPool with token API"
```

---

### Task 5: Update H2StreamContext in handler.zig

**Files:**
- Modify: `src/proxy/handler.zig:62-67`

**Step 1: Import ConnectionToken**

Add after line 36:

```zig
const ConnectionToken = @import("../http/http2/pooled_conn.zig").ConnectionToken;
```

**Step 2: Replace H2StreamContext struct**

Replace lines 62-67 with:

```zig
/// HTTP/2 stream context for multiplexed connections
pub const H2StreamContext = struct {
    token: ConnectionToken,
    stream_id: u32,
    backend_idx: u32,
};
```

**Step 3: Commit**

```bash
git add src/proxy/handler.zig
git commit -m "wip(h2-pool): update H2StreamContext to use token"
```

---

### Task 6: Update connection.zig Acquire Path

**Files:**
- Modify: `src/proxy/connection.zig`

**Step 1: Import ConnectionToken**

Add after line 25:

```zig
const ConnectionToken = @import("../http/http2/pooled_conn.zig").ConnectionToken;
```

**Step 2: Rewrite tryAcquireH2Connection**

Replace the function (around lines 205-253) with:

```zig
/// Try to acquire an HTTP/2 connection from the pool
fn tryAcquireH2Connection(
    pool: *h2_pool.H2ConnectionPool,
    backend_idx: u32,
    req_id: u32,
) ?ProxyState {
    const token = pool.acquire(backend_idx) orelse return null;

    const conn = pool.get(token) orelse {
        pool.release(token, false);
        return null;
    };

    if (conn.shouldEvict()) {
        log.debug("[REQ {d}] H2 connection stale, evicting", .{req_id});
        pool.release(token, false);
        return null;
    }

    metrics.global_metrics.recordPoolHit();
    metrics.global_metrics.recordPoolHitForBackend(backend_idx);
    log.debug("[REQ {d}] H2 POOL HIT backend={d}", .{req_id, backend_idx});

    var proxy_state = ProxyState{
        .sock = conn.sock,
        .from_pool = true,
        .can_return_to_pool = true,
        .is_tls = true,
        .is_http2 = true,
        .tls_conn_ptr = null,
        .status_code = 0,
        .bytes_from_backend = 0,
        .bytes_to_client = 0,
        .body_had_error = false,
        .client_write_error = false,
        .backend_wants_close = false,
        .h2_stream_ctx = H2StreamContext{
            .token = token,
            .stream_id = 0,
            .backend_idx = backend_idx,
        },
    };
    proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
    return proxy_state;
}
```

**Step 3: Update fresh connection path in acquireConnection**

Find the section around lines 113-170 that creates a fresh H2 connection and add it to pool. Replace with:

```zig
        // Add fresh HTTP/2 connection to pool for reuse
        if (state.h2_connection_pool) |h2_pool_ptr| {
            if (h2_pool_ptr.hasCapacity(backend_idx)) {
                var h2_conn = H2PooledConnection.init(sock, backend_idx, state.allocator) catch {
                    sock.close_blocking();
                    return ProxyError.ConnectionFailed;
                };

                // Establish HTTP/2 session
                h2_conn.connect(ctx.io) catch |err| {
                    log.err("[REQ {d}] H2 connection preface failed: {}", .{req_id, err});
                    h2_conn.deinit();
                    return ProxyError.ConnectionFailed;
                };

                const token = h2_pool_ptr.addAndAcquire(h2_conn) orelse {
                    log.debug("[REQ {d}] H2 pool full, using non-pooled", .{req_id});
                    h2_conn.deinit();
                    // Fall through to non-pooled path below
                    break :http2_pool_blk;
                };

                log.debug("[REQ {d}] H2 POOL ADD backend={d}", .{req_id, backend_idx});

                var proxy_state = ProxyState{
                    .sock = sock,
                    .from_pool = false,
                    .can_return_to_pool = true,
                    .is_tls = true,
                    .is_http2 = true,
                    .tls_conn_ptr = null,
                    .status_code = 0,
                    .bytes_from_backend = 0,
                    .bytes_to_client = 0,
                    .body_had_error = false,
                    .client_write_error = false,
                    .backend_wants_close = false,
                    .h2_stream_ctx = H2StreamContext{
                        .token = token,
                        .stream_id = 0,
                        .backend_idx = backend_idx,
                    },
                };
                proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();
                return proxy_state;
            }
        }
```

Note: This requires adding a labeled block `http2_pool_blk:` around this section.

**Step 4: Commit**

```bash
git add src/proxy/connection.zig
git commit -m "wip(h2-pool): update connection.zig to use token API"
```

---

### Task 7: Update handler.zig Usage and Release Paths

**Files:**
- Modify: `src/proxy/handler.zig`

**Step 1: Update streamingProxyHttp2 to use pool.get()**

Find the section around line 556-613 and update to use token-based access:

```zig
    if (proxy_state.h2_stream_ctx) |h2_ctx| {
        const h2_pool_ptr = state.h2_connection_pool orelse return ProxyError.ConnectionFailed;

        const conn = h2_pool_ptr.get(h2_ctx.token) orelse {
            return ProxyError.ConnectionFailed;
        };

        const h2_client = conn.getClient();
        const sock = &conn.sock;

        conn.sock.fixTlsPointersAfterCopy();

        log.debug("[REQ {d}] Using pooled H2 connection", .{req_id});

        // Queue request frames
        const stream_id = h2_client.sendRequest(
            method,
            path,
            host,
            ctx.request.body,
        ) catch |err| {
            log.warn("[REQ {d}] H2 pooled queue failed: {}, closing", .{req_id, err});
            h2_pool_ptr.release(h2_ctx.token, false);
            return ProxyError.SendFailed;
        };

        // Flush write queue
        h2_client.flushWriteQueue(sock, ctx.io) catch |err| {
            log.warn("[REQ {d}] H2 pooled flush failed: {}, closing", .{req_id, err});
            h2_pool_ptr.release(h2_ctx.token, false);
            return ProxyError.SendFailed;
        };

        // Read response
        const h2_response = h2_client.readResponse(sock, ctx.io, stream_id) catch |err| {
            log.warn("[REQ {d}] H2 pooled read failed: {}, closing", .{req_id, err});
            h2_pool_ptr.release(h2_ctx.token, false);
            return ProxyError.ReadFailed;
        };

        // Success - return to pool
        conn.markSuccess();
        h2_pool_ptr.release(h2_ctx.token, true);

        // ... rest of response handling
```

**Step 2: Update cleanup in cleanupProxyState**

Find cleanupProxyState (around line 780) and update:

```zig
    if (proxy_state.h2_stream_ctx) |h2_ctx| {
        if (state.h2_connection_pool) |h2_pool_ptr| {
            // Release with keep=false since we're in cleanup (error path)
            h2_pool_ptr.release(h2_ctx.token, false);
        }
        return;
    }
```

**Step 3: Commit**

```bash
git add src/proxy/handler.zig
git commit -m "wip(h2-pool): update handler.zig to use token API"
```

---

### Task 8: Update Tests in connection_pool.zig

**Files:**
- Modify: `src/http/http2/connection_pool.zig:294-638`

**Step 1: Rewrite tests for new API**

Replace all tests (lines 294-638) with:

```zig
// ============================================================================
// Tests
// ============================================================================

fn createMockSocket() UltraSock {
    return UltraSock{
        .stream = null,
        .io = null,
        .protocol = .https,
        .host = "test.example.com",
        .port = 443,
        .connected = false,
        .tls_options = TlsOptions.insecure(),
    };
}

test "H2ConnectionPool: initial state" {
    var pool = H2ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.backend_count);
    try std.testing.expect(pool.acquire(0) == null);
}

test "H2ConnectionPool: add and acquire" {
    var pool = H2ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.setBackendCount(1);

    const mock_sock = createMockSocket();
    const conn = try H2PooledConnection.init(mock_sock, 0, std.testing.allocator);

    const token = pool.addAndAcquire(conn);
    try std.testing.expect(token != null);

    const conn_ptr = pool.get(token.?);
    try std.testing.expect(conn_ptr != null);
    try std.testing.expectEqual(@as(u32, 0), conn_ptr.?.backend_idx);

    pool.release(token.?, false);
}

test "H2ConnectionPool: token becomes stale after release" {
    var pool = H2ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.setBackendCount(1);

    const mock_sock = createMockSocket();
    const conn = try H2PooledConnection.init(mock_sock, 0, std.testing.allocator);

    const token = pool.addAndAcquire(conn).?;
    pool.release(token, true);  // Return to pool

    // Token is now stale (generation incremented)
    try std.testing.expect(pool.get(token) == null);

    // But we can acquire a new token
    const new_token = pool.acquire(0);
    try std.testing.expect(new_token != null);
    try std.testing.expect(pool.get(new_token.?) != null);

    pool.release(new_token.?, false);
}

test "H2ConnectionPool: release is idempotent" {
    var pool = H2ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.setBackendCount(1);

    const mock_sock = createMockSocket();
    const conn = try H2PooledConnection.init(mock_sock, 0, std.testing.allocator);

    const token = pool.addAndAcquire(conn).?;

    // First release works
    pool.release(token, false);

    // Second release is no-op (stale token)
    pool.release(token, false);
    pool.release(token, true);
}

test "H2ConnectionPool: hasCapacity" {
    var pool = H2ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.setBackendCount(1);

    try std.testing.expect(pool.hasCapacity(0));

    // Fill the pool
    for (0..MAX_H2_CONNS_PER_BACKEND) |_| {
        const sock = createMockSocket();
        const conn = try H2PooledConnection.init(sock, 0, std.testing.allocator);
        const token = pool.addAndAcquire(conn);
        try std.testing.expect(token != null);
        pool.release(token.?, true);  // Return to pool (keep=true)
    }

    try std.testing.expect(!pool.hasCapacity(0));
}

test "H2ConnectionPool: getStats" {
    var pool = H2ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.setBackendCount(2);

    // Add connections
    for (0..2) |_| {
        const sock = createMockSocket();
        const conn = try H2PooledConnection.init(sock, 0, std.testing.allocator);
        const token = pool.addAndAcquire(conn).?;
        pool.release(token, true);
    }

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.total_connections);
    try std.testing.expectEqual(@as(usize, 2), stats.per_backend_connections[0]);
    try std.testing.expectEqual(@as(usize, 2), stats.per_backend_idle[0]);
}
```

**Step 2: Run tests**

Run: `/usr/local/zig-0.16.0-dev/zig build test --summary all 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Commit**

```bash
git add src/http/http2/connection_pool.zig
git commit -m "test(h2-pool): update tests for token-based API"
```

---

### Task 9: Update worker.zig Pool Initialization

**Files:**
- Modify: `src/lb/worker.zig` (if pool init signature changed)

**Step 1: Find and update H2ConnectionPool initialization**

Search for `H2ConnectionPool.init` and update to pass allocator if needed.

**Step 2: Compile and fix any remaining errors**

Run: `/usr/local/zig-0.16.0-dev/zig build 2>&1`

Fix any remaining compile errors by updating call sites.

**Step 3: Run all tests**

Run: `/usr/local/zig-0.16.0-dev/zig build test --summary all`
Expected: All tests pass

**Step 4: Commit**

```bash
git add -A
git commit -m "feat(h2-pool): complete token-based connection pool refactor"
```

---

### Task 10: Integration Test

**Step 1: Build the load balancer**

Run: `/usr/local/zig-0.16.0-dev/zig build`
Expected: Clean build

**Step 2: Start backend server**

In a separate terminal, start a test backend.

**Step 3: Run load balancer**

Run: `./zig-out/bin/load_balancer --backend https://127.0.0.1:9443 -k -l err`

**Step 4: Run stress test**

Run: `wrk -t4 -c10 -d30s http://localhost:8080/`

Expected:
- ~3000+ req/sec
- <10 non-2xx responses
- No crashes or panics

**Step 5: Final commit**

```bash
git add -A
git commit -m "feat(h2-pool): token-based H2 connection pool complete

Replaces pointer-based access with token-based exclusive ownership.
Eliminates race conditions from concurrent async coroutines.

- ConnectionToken provides opaque exclusive access rights
- SlotState enum enforces valid lifecycle transitions
- Generation counters invalidate stale tokens
- Removed defensive guards (deinit_started, eviction_pending, etc.)

Closes the stability issues from race conditions."
```
