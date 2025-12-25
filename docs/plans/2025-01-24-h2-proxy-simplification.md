# HTTP/2 Proxy Simplification

## Design Decisions

1. **Single unified API**: `pool.getOrCreate()` + `conn.request()`
2. **Hidden retries**: Pool internally handles stale connection fallback
3. **One code path**: Always async/multiplexed (no sync vs async split)
4. **Binary state**: Connection is `ready` or `dead`

## Target API

### Handler (10 lines)

```zig
fn streamingProxyHttp2(ctx, backend, state, backend_idx) !http.Respond {
    const pool = state.h2_connection_pool orelse return error.NoPool;

    var conn = pool.getOrCreate(backend_idx, ctx.io) catch
        return ProxyError.ConnectionFailed;

    var response = conn.request(
        @tagName(ctx.request.method orelse .GET),
        ctx.request.uri orelse "/",
        backend.getFullHost(),
        ctx.request.body,
        ctx.io,
    ) catch |err| {
        pool.release(conn, false, ctx.io);
        return ProxyError.SendFailed;
    };
    defer response.deinit();

    pool.release(conn, true, ctx.io);
    return forwardH2Response(ctx, &response);
}
```

### Pool API

```zig
pub const H2ConnectionPool = struct {
    /// Get existing pooled connection or create fresh one.
    /// Handles: finding available slot, heap allocation, TLS handshake, H2 session.
    /// Returns ready-to-use connection.
    pub fn getOrCreate(self: *Self, backend_idx: u32, io: Io) !*H2Connection {
        // 1. Try find existing available connection for this backend
        // 2. If none, create fresh: allocate, connect, handshake
        // 3. Mark as in-use, return
    }

    /// Release connection back to pool.
    /// If success=false, connection is destroyed instead of pooled.
    pub fn release(self: *Self, conn: *H2Connection, success: bool, io: Io) void {
        // If success: mark available for reuse
        // If !success or conn.state == .dead: destroy and free slot
    }
};
```

### Connection API

```zig
pub const H2Connection = struct {
    state: enum { ready, dead } = .ready,

    // All internal complexity hidden:
    sock: UltraSock,
    h2_client: *Http2Client,
    tls_input_buffer: [TLS_BUF_SIZE]u8,
    tls_output_buffer: [TLS_BUF_SIZE]u8,
    write_mutex: Io.Mutex,
    stream_mutex: Io.Mutex,
    reader_running: bool,
    // ...

    /// Send request and wait for response. Handles everything:
    /// - Acquires write mutex, sends frames
    /// - Spawns reader if needed (with proper mutex ordering)
    /// - Waits for response via condition variable
    /// - Returns response or error
    pub fn request(
        self: *Self,
        method: []const u8,
        path: []const u8,
        host: []const u8,
        body: ?[]const u8,
        io: Io,
    ) !Response {
        if (self.state == .dead) return error.ConnectionDead;

        // 1. Lock write_mutex, send request frames, unlock
        const stream_id = try self.sendRequest(method, path, host, body, io);

        // 2. Lock stream_mutex FIRST (critical ordering)
        try self.stream_mutex.lock(io);

        // 3. Spawn reader if needed (blocks on our mutex, Io.async yields)
        if (!self.reader_running) {
            self.spawnReader(io);
        }

        // 4. Wait for response (releases mutex, reader dispatches, signals)
        const response = try self.awaitStream(stream_id, io);

        self.stream_mutex.unlock(io);
        return response;
    }
};
```

## Files to Modify

1. **src/http/http2/connection.zig** (NEW) - Simple H2Connection struct
2. **src/http/http2/pool.zig** (NEW) - Simple H2ConnectionPool
3. **src/proxy/handler.zig** - Reduce streamingProxyHttp2 to ~10 lines
4. **DELETE**: pooled_conn.zig complexity absorbed into connection.zig

## Implementation Order

1. Create connection.zig with full H2Connection (merge pooled_conn + client concepts)
2. Create pool.zig with getOrCreate/release API
3. Update handler.zig to use new API
4. Delete old pooled_conn.zig, update imports
5. Test

## TigerBeetle Principles Applied

- **Fixed-size arrays**: No dynamic allocation on hot path
- **Explicit state**: Binary ready/dead, no hidden states
- **No hidden control flow**: request() is the only entry point
- **Pre-allocated buffers**: TLS buffers in connection struct
- **Single code path**: No sync vs async branching
