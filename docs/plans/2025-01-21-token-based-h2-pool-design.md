# Token-Based H2 Connection Pool Design

## Problem

The current H2 connection pool hands out raw pointers (`*H2PooledConnection`) to callers. Multiple async coroutines can hold the same pointer, leading to race conditions:
- Double-deinit when multiple paths try to cleanup
- Use-after-free when eviction races with usage
- Count underflow when operations interleave

We added numerous defensive guards (`deinit_started`, vtable checks, underflow guards) but these are band-aids, not fixes.

## Solution

Replace pointer-based access with token-based exclusive ownership. The pool never hands out pointers to memory it owns. Instead, callers receive opaque tokens that represent exclusive access rights.

## Design Decisions

1. **Clean break** - Replace old API entirely, no backward compatibility
2. **H2 pool only** - HTTP/1.1 pool is working fine, leave it alone
3. **Token replaces pointer** - `H2StreamContext` holds `ConnectionToken` instead of `*H2PooledConnection`

## Core Data Structures

```zig
/// Opaque token representing exclusive access to a connection slot
/// Small (4 bytes), cheap to copy, safe to pass between functions
pub const ConnectionToken = struct {
    backend_idx: u8,
    slot_idx: u8,
    generation: u16,  // Wrapping counter, catches use-after-release
};

/// Explicit state machine for slot lifecycle
pub const SlotState = enum {
    empty,      // No connection, slot available for new connection
    available,  // Connection ready, can be acquired
    in_use,     // Exclusively owned by a request
    draining,   // Marked for eviction, cleanup when released
};

/// A slot in the connection pool
pub const ConnectionSlot = struct {
    conn: ?H2PooledConnection,
    state: SlotState,
    generation: u16,
};
```

## Pool API

```zig
pub const BackendH2Pool = struct {
    slots: [MAX_CONNECTIONS_PER_BACKEND]ConnectionSlot,

    /// Acquire exclusive access to an available connection
    pub fn acquire(self: *Self) ?ConnectionToken;

    /// Get connection pointer - only valid while token is held
    pub fn get(self: *Self, token: ConnectionToken) ?*H2PooledConnection;

    /// Release exclusive access (keep=true returns to pool, keep=false closes)
    pub fn release(self: *Self, token: ConnectionToken, keep: bool) void;

    /// Add a new connection to an empty slot
    pub fn add(self: *Self, conn: H2PooledConnection) ?ConnectionToken;
};

pub const H2ConnectionPool = struct {
    pools: [MAX_BACKENDS]BackendH2Pool,

    pub fn acquire(self: *Self, backend_idx: u32) ?ConnectionToken;
    pub fn get(self: *Self, token: ConnectionToken) ?*H2PooledConnection;
    pub fn release(self: *Self, token: ConnectionToken, keep: bool) void;
    pub fn addAndAcquire(self: *Self, conn: H2PooledConnection, backend_idx: u32) ?ConnectionToken;
};
```

## Updated H2StreamContext

```zig
pub const H2StreamContext = struct {
    token: ConnectionToken,      // Exclusive access token (was: *H2PooledConnection)
    stream_id: u32,              // HTTP/2 stream ID
    backend_idx: u32,            // For metrics/logging
};
```

## Usage Pattern

```zig
// Acquire
const token = pool.acquire(backend_idx) orelse return null;
errdefer pool.release(token, false);

// Access through token
const conn = pool.get(token) orelse return error.StaleToken;

// Use connection...
try conn.sendRequest(...);

// Release (success = keep, error = close)
pool.release(token, true);
```

## What We Remove

With proper ownership, these guards become unnecessary:

- `H2PooledConnection.deinit_started` - Can't double-deinit with tokens
- `H2PooledConnection.eviction_pending` - Replaced by `SlotState.draining`
- Allocator vtable validation in deinit
- `releaseStream` underflow guard
- `BackendH2Pool.count` field and underflow guards
- `evictSpecific()` function - Use `release(token, false)`

## Files to Modify

1. `src/http/http2/pooled_conn.zig` - Add token types, simplify H2PooledConnection
2. `src/http/http2/connection_pool.zig` - New slot-based pool with token API
3. `src/proxy/connection.zig` - Use new acquire API
4. `src/proxy/handler.zig` - Use token-based access and release

## Benefits

| Before | After |
|--------|-------|
| Pointer can outlive connection | Token validated on every access |
| Multiple holders of same pointer | Exclusive ownership enforced |
| Guards check for corruption after the fact | State machine prevents invalid transitions |
| `deinit_started` flag needed | Impossible to deinit while in_use |
| Count underflow guards | Count derived from slot states |
| Eviction races with usage | `draining` state defers cleanup |
