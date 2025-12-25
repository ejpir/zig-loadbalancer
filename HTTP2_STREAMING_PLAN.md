# HTTP/2 Stream Multiplexing Implementation Plan

## Overview
Enable true HTTP/2 stream multiplexing to allow multiple concurrent requests over a single HTTP/2 connection, following TigerBeetle style and idiomatic Zig patterns.

## Current State
- HTTP/2 ALPN negotiation ✅
- HTTP/2 frame parsing/building ✅
- Connection pooling (HTTP/1.1 style) ✅
- **Limitation**: One request per HTTP/2 connection (no multiplexing)

## Goals
- Multiple concurrent streams per HTTP/2 connection
- Per-worker design (no cross-worker synchronization)
- Fixed-size arrays (TigerBeetle style)
- Backward compatible with HTTP/1.1
- Small, testable incremental steps

---

## Implementation Phases

### Phase 1: Basic HTTP/2 Connection Pool Infrastructure
**Goal**: Create pool structure without stream multiplexing (limit 1 stream/conn initially)

#### Step 1.1: Create H2PooledConnection Structure
**File**: `src/http/http2/pooled_conn.zig` (NEW)

**Implementation**:
```zig
const std = @import("std");
const UltraSock = @import("../ultra_sock.zig").UltraSock;
const Http2Client = @import("client.zig").Http2Client;
const mod = @import("mod.zig");

/// HTTP/2 connection with stream slot tracking
/// Lives in connection pool, shared across multiple requests
pub const H2PooledConnection = struct {
    // Underlying socket + TLS state
    sock: UltraSock,

    // HTTP/2 client state
    h2_client: Http2Client,

    // Stream capacity (Phase 1: limit to 1, Phase 3: enable 100)
    stream_slots_used: u32,
    max_concurrent_streams: u32,

    // Connection health
    last_used_ns: i64,
    goaway_received: bool,
    connected: bool,

    // Backend identity
    backend_idx: u32,

    pub fn init(sock: UltraSock, backend_idx: u32, allocator: std.mem.Allocator) H2PooledConnection {
        return .{
            .sock = sock,
            .h2_client = Http2Client.init(allocator),
            .stream_slots_used = 0,
            .max_concurrent_streams = 1,  // Phase 1: limit to 1
            .last_used_ns = std.time.nanoTimestamp(),
            .goaway_received = false,
            .connected = true,
            .backend_idx = backend_idx,
        };
    }

    pub inline fn hasAvailableSlot(self: *const H2PooledConnection) bool {
        return self.connected
            and !self.goaway_received
            and self.stream_slots_used < self.max_concurrent_streams;
    }

    pub fn acquireStream(self: *H2PooledConnection) !u31 {
        std.debug.assert(self.hasAvailableSlot());
        self.stream_slots_used += 1;
        self.last_used_ns = std.time.nanoTimestamp();
        return self.h2_client.nextStreamId();
    }

    pub fn releaseStream(self: *H2PooledConnection, stream_id: u31) void {
        _ = stream_id;
        std.debug.assert(self.stream_slots_used > 0);
        self.stream_slots_used -= 1;
        self.last_used_ns = std.time.nanoTimestamp();
    }

    pub inline fn isIdle(self: *const H2PooledConnection) bool {
        return self.stream_slots_used == 0;
    }

    pub fn shouldEvict(self: *const H2PooledConnection) bool {
        if (self.goaway_received) return true;
        if (!self.connected) return true;
        if (self.stream_slots_used > 0) return false;

        const now = std.time.nanoTimestamp();
        const idle_ns = now - self.last_used_ns;
        const IDLE_TIMEOUT_NS = 5_000_000_000;  // 5 seconds
        return idle_ns > IDLE_TIMEOUT_NS;
    }
};
```

**Tests**:
```zig
test "H2PooledConnection: initial state" {
    const testing = std.testing;
    var mock_sock = createMockSocket();
    var conn = H2PooledConnection.init(mock_sock, 0, testing.allocator);

    try testing.expect(conn.hasAvailableSlot());
    try testing.expectEqual(@as(u32, 0), conn.stream_slots_used);
}

test "H2PooledConnection: acquire and release stream" {
    const testing = std.testing;
    var mock_sock = createMockSocket();
    var conn = H2PooledConnection.init(mock_sock, 0, testing.allocator);

    const stream_id = try conn.acquireStream();
    try testing.expectEqual(@as(u32, 1), conn.stream_slots_used);
    try testing.expect(!conn.hasAvailableSlot());  // Phase 1: max 1 stream

    conn.releaseStream(stream_id);
    try testing.expectEqual(@as(u32, 0), conn.stream_slots_used);
    try testing.expect(conn.hasAvailableSlot());
}
```

**Verification**: `zig build test` passes for new file

---

#### Step 1.2: Create H2ConnectionPool Structure
**File**: `src/http/http2/connection_pool.zig` (NEW)

**Implementation**:
```zig
const std = @import("std");
const H2PooledConnection = @import("pooled_conn.zig").H2PooledConnection;

pub const MAX_BACKENDS: usize = 64;
pub const MAX_H2_CONNS_PER_BACKEND: usize = 16;

pub const H2ConnectionPool = struct {
    pools: [MAX_BACKENDS]H2BackendPool,
    backend_count: usize,

    const H2BackendPool = struct {
        connections: [MAX_H2_CONNS_PER_BACKEND]?H2PooledConnection,
        count: usize,

        pub fn init() H2BackendPool {
            return .{
                .connections = [_]?H2PooledConnection{null} ** MAX_H2_CONNS_PER_BACKEND,
                .count = 0,
            };
        }
    };

    pub fn init() H2ConnectionPool {
        return .{
            .pools = [_]H2BackendPool{H2BackendPool.init()} ** MAX_BACKENDS,
            .backend_count = 0,
        };
    }

    /// Get connection with available stream slot
    pub fn getConnectionWithSlot(
        self: *H2ConnectionPool,
        backend_idx: usize
    ) ?*H2PooledConnection {
        if (backend_idx >= self.backend_count) return null;

        const pool = &self.pools[backend_idx];

        for (pool.connections[0..pool.count]) |*maybe_conn| {
            if (maybe_conn.*) |*conn| {
                if (conn.hasAvailableSlot()) {
                    return conn;
                }
            }
        }

        return null;
    }

    /// Add new connection to pool
    pub fn addConnection(
        self: *H2ConnectionPool,
        conn: H2PooledConnection
    ) !void {
        const backend_idx = conn.backend_idx;
        std.debug.assert(backend_idx < MAX_BACKENDS);

        if (backend_idx >= self.backend_count) {
            self.backend_count = backend_idx + 1;
        }

        const pool = &self.pools[backend_idx];
        if (pool.count >= MAX_H2_CONNS_PER_BACKEND) {
            return error.PoolFull;
        }

        pool.connections[pool.count] = conn;
        pool.count += 1;
    }

    /// Return connection to pool or close if should evict
    pub fn returnConnection(
        self: *H2ConnectionPool,
        conn: *H2PooledConnection
    ) void {
        if (conn.shouldEvict()) {
            conn.sock.close_blocking();
            return;
        }

        // Connection stays in pool (already there)
        // Just update state via release
    }
};
```

**Tests**:
```zig
test "H2ConnectionPool: get connection with slot" {
    const testing = std.testing;
    var pool = H2ConnectionPool.init();

    var mock_sock = createMockSocket();
    var conn = H2PooledConnection.init(mock_sock, 0, testing.allocator);
    try pool.addConnection(conn);

    const retrieved = pool.getConnectionWithSlot(0);
    try testing.expect(retrieved != null);
}
```

**Verification**: `zig build test` passes

---

### Phase 2: Integration with Proxy Handler
**Goal**: Use H2ConnectionPool in request flow (still 1 stream/conn)

#### Step 2.1: Add H2StreamContext to ProxyState
**File**: `src/proxy/handler.zig`

**Changes**:
```zig
// Add after existing imports
const H2PooledConnection = @import("../http/http2/pooled_conn.zig").H2PooledConnection;

pub const ProxyState = struct {
    // EXISTING FIELDS
    sock: UltraSock,
    from_pool: bool,
    can_return_to_pool: bool,
    is_tls: bool,
    is_http2: bool,
    // ... other fields ...

    // NEW FIELD
    h2_stream_ctx: ?H2StreamContext,
};

pub const H2StreamContext = struct {
    stream_id: u31,
    connection_ref: *H2PooledConnection,
    owns_slot: bool,
    backend_idx: u32,
};
```

**Verification**: `zig build` compiles

---

#### Step 2.2: Add H2ConnectionPool to WorkerState
**File**: `src/proxy/handler.zig` (or wherever WorkerState is defined)

**Changes**:
```zig
const H2ConnectionPool = @import("../http/http2/connection_pool.zig").H2ConnectionPool;

pub const WorkerState = struct {
    // EXISTING
    connection_pool: SimpleConnectionPool,
    // ... other fields ...

    // NEW
    h2_connection_pool: H2ConnectionPool,

    pub fn init() WorkerState {
        return .{
            .connection_pool = SimpleConnectionPool.init(),
            .h2_connection_pool = H2ConnectionPool.init(),
            // ... other inits ...
        };
    }
};
```

**Verification**: `zig build` compiles

---

#### Step 2.3: Update acquireConnection Logic
**File**: `src/proxy/connection.zig`

**Changes**:
```zig
pub fn acquireConnection(
    comptime BackendT: type,
    ctx: *const http.Context,
    backend: *const BackendT,
    backend_idx: u32,
    state: *WorkerState,
    req_id: u32,
) ProxyError!ProxyState {
    std.debug.assert(backend_idx < MAX_BACKENDS);

    // NEW: Try HTTP/2 connection pool for HTTPS backends
    if (backend.isHttps()) {
        if (tryAcquireH2Connection(backend_idx, state, req_id)) |h2_state| {
            return h2_state;
        }
    }

    // EXISTING: Fall back to HTTP/1.1 pool or fresh connection
    // ... existing code ...
}

fn tryAcquireH2Connection(
    backend_idx: u32,
    state: *WorkerState,
    req_id: u32,
) ?ProxyState {
    const conn = state.h2_connection_pool.getConnectionWithSlot(backend_idx) orelse return null;

    const stream_id = conn.acquireStream() catch return null;

    log.debug("[REQ {d}] H2 POOL HIT backend={d} stream={d}", .{
        req_id, backend_idx, stream_id
    });

    return ProxyState{
        .sock = conn.sock,
        .from_pool = true,
        .can_return_to_pool = true,
        .is_tls = true,
        .is_http2 = true,
        .h2_stream_ctx = H2StreamContext{
            .stream_id = stream_id,
            .connection_ref = conn,
            .owns_slot = true,
            .backend_idx = backend_idx,
        },
        // ... other fields ...
    };
}
```

**Verification**: `zig build` compiles

---

#### Step 2.4: Update Connection Release Logic
**File**: `src/proxy/handler.zig` (in finalization function)

**Changes**:
```zig
// In streamingProxy_finalize or similar
if (proxy_state.is_http2) {
    if (proxy_state.h2_stream_ctx) |h2_ctx| {
        if (h2_ctx.owns_slot) {
            // Release stream slot
            h2_ctx.connection_ref.releaseStream(h2_ctx.stream_id);

            // Return connection to pool (or close if evict)
            state.h2_connection_pool.returnConnection(h2_ctx.connection_ref);

            log.debug("[REQ {d}] Released H2 stream {d}", .{
                req_id, h2_ctx.stream_id
            });
        }
    }
} else {
    // EXISTING HTTP/1.1 path
    state.connection_pool.returnConnection(backend_idx, proxy_state.sock);
}
```

**Verification**: `zig build` compiles

---

### Phase 3: Enable Stream Multiplexing
**Goal**: Allow max_concurrent_streams > 1 (up to 100)

#### Step 3.1: Update max_concurrent_streams
**File**: `src/http/http2/pooled_conn.zig`

**Change**:
```zig
pub fn init(sock: UltraSock, backend_idx: u32, allocator: std.mem.Allocator) H2PooledConnection {
    return .{
        // ...
        .max_concurrent_streams = 100,  // CHANGED from 1
        // ...
    };
}
```

**Test**: Create integration test that sends 10 concurrent requests and verifies they use same connection

---

#### Step 3.2: Implement Frame Demultiplexing
**File**: `src/http/http2/client.zig`

**Add**:
```zig
const StreamState = struct {
    stream_id: u31,
    response: PartialResponse,
    end_stream_received: bool,
};

const PartialResponse = struct {
    status: u16,
    headers: [32]hpack.Header,
    header_count: usize,
    body: std.ArrayList(u8),
};

pub const Http2Client = struct {
    // EXISTING
    next_stream_id: u31,
    max_concurrent_streams: u32,
    // ...

    // NEW
    active_streams: [100]?StreamState,
    active_stream_count: u32,

    pub fn readResponseForStream(
        self: *Self,
        sock: *UltraSock,
        io: Io,
        target_stream_id: u31,
    ) !Response {
        // Demultiplex frames by stream ID
        // Buffer data for other streams
        // Return response when target stream complete
    }
};
```

**Test**: Mock multiple interleaved frames and verify correct demultiplexing

---

### Phase 4: Testing & Validation
**Goal**: Comprehensive testing at each level

#### Tests to Add:

1. **Unit Tests** (in each file's test block)
   - H2PooledConnection lifecycle
   - H2ConnectionPool operations
   - Frame demultiplexing

2. **Integration Tests**
   - Single stream per connection
   - Multiple streams per connection
   - Connection reuse across requests
   - Pool eviction (idle timeout)

3. **Benchmarks**
   - Compare latency with/without pooling
   - Verify connection count reduction
   - Measure throughput improvement

---

## Testing Strategy

### Manual Testing
```bash
# Phase 1: Build with basic pool
zig build

# Phase 2: Run load balancer
./zig-out/bin/load_balancer

# Phase 3: Send requests, verify pooling
wrk -t4 -c100 -d10s http://localhost:8080/

# Check logs for "H2 POOL HIT" messages
```

### Automated Testing
```bash
# Run all tests
zig build test

# Run specific test file
zig test src/http/http2/pooled_conn.zig
```

---

## Success Metrics

### Phase 1 Complete:
- [ ] H2PooledConnection compiles and passes tests
- [ ] H2ConnectionPool compiles and passes tests
- [ ] `zig build test` passes

### Phase 2 Complete:
- [ ] Integration compiles without errors
- [ ] Load balancer starts successfully
- [ ] Single HTTP/2 request works
- [ ] Connection returned to pool (logs confirm)

### Phase 3 Complete:
- [ ] Multiple concurrent requests use same connection
- [ ] Frame demultiplexing works correctly
- [ ] Connection count significantly reduced
- [ ] Latency improved (no TLS handshake overhead)

---

## Rollback Plan
If issues arise:
1. Each phase is in separate commit
2. Can revert to previous phase
3. Can disable H2 pool via config flag
4. Falls back to HTTP/1.1 automatically

---

## Key TigerBeetle/Zig Patterns Used

1. **Fixed-size arrays**: `[MAX_H2_CONNS_PER_BACKEND]?H2PooledConnection`
2. **No allocations on hot path**: Stack buffers, preallocated pools
3. **Inline functions**: `hasAvailableSlot()`, `isIdle()`
4. **Assertions**: Pre/post conditions in every function
5. **Explicit state tracking**: `stream_slots_used`, `connected`, `goaway_received`
6. **Single-threaded per worker**: No atomics, no locks
7. **Zero-cost abstractions**: Comptime strategy selection
8. **Descriptive test names**: "operation: expected behavior"

---

## Next Steps
1. ✅ Install Zig 0.16
2. Create Step 1.1: H2PooledConnection
3. Test Step 1.1
4. Create Step 1.2: H2ConnectionPool
5. Test Step 1.2
6. Continue through phases...
