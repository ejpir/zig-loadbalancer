# HTTP/2 with TLS Implementation Code Review

## Executive Summary

This review examines the HTTP/2 with TLS implementation focusing on:
1. Redundant guards from iterative debugging
2. Code quality and documentation
3. Idiomatic Zig patterns
4. TigerBeetle-style compliance
5. Performance optimizations

**Overall Assessment**: The implementation is solid and functional. The TLS shutdown sequence is correct. However, there are opportunities to remove redundant guards added during debugging iterations and improve consistency.

---

## 1. REDUNDANT GUARDS & DEAD CODE

### 1.1 Dual Connected Flags - REDUNDANT

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/connection.zig`

**Lines 63-64**:
```zig
connected: bool = true,
goaway_received: bool = false,
```

**Issue**: Connection has BOTH:
- `state: State` (binary: `.ready` or `.dead`) - line 52
- `connected: bool` - line 64

**Analysis**: These are redundant. The `state` enum is the canonical source of truth for connection health.

**Locations where `connected` is checked**:
- Line 64: Initial value
- Line 207-209: `spawnReader()` checks `if (!self.connected)`
- Line 242: `markDead()` sets both `self.state = .dead` and `self.connected = false`
- Line 248: `isReady()` checks both `self.state == .ready and self.connected`

**Recommendation**: **REMOVE `connected` field entirely**. Use only `state`:
- Replace `self.connected = false` with `self.state = .dead`
- Replace `self.connected` checks with `self.state == .ready`
- The `isReady()` method already encapsulates the logic correctly

**Affected Functions**:
```zig
// connection.zig:207-209
fn spawnReader(self: *Self, io: Io) bool {
    if (self.reader_running) return true;
    // REDUNDANT: state check would suffice
    if (!self.connected) {
        log.warn("spawnReader: connection dead", .{});
        return false;
    }
    // ...
}
```

**Fix**:
```zig
fn spawnReader(self: *Self, io: Io) bool {
    if (self.reader_running) return true;
    if (self.state == .dead) {  // Single source of truth
        log.warn("spawnReader: connection dead", .{});
        return false;
    }
    // ...
}
```

---

### 1.2 Reader Socket Connected Check - REDUNDANT

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/client.zig`

**Lines 539-543**:
```zig
while (!shutdown_requested.*) {
    // Check if socket looks dead before blocking on recv
    if (!sock.connected) {
        log.debug("Reader: socket not connected, exiting", .{});
        return;
    }
```

**Issue**: This check is redundant because:
1. The `sock.recv()` call immediately after (line 550) will fail if socket is disconnected
2. The error handler already exits the reader (line 552)
3. This adds an extra field access in the hot path

**Recommendation**: **REMOVE** the pre-check at line 540-543. The natural error from `recv()` provides the same outcome with one less check.

---

### 1.3 Double GOAWAY Propagation - REDUNDANT

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/client.zig`

**Lines 522 and 595-597**:
```zig
// Line 522 - in defer block
goaway_received.* = self.goaway_received;

// Lines 595-597 - in main loop
if (self.goaway_received) {
    goaway_received.* = true;
}
```

**Issue**: GOAWAY flag is propagated in TWO places:
1. Always in the defer block when exiting (line 522)
2. Immediately when detected (line 595-597)

**Analysis**: The defer block **already** propagates the flag on exit. The immediate propagation (595-597) is only marginally useful - it lets the pool know slightly earlier, but the defer runs on every exit anyway.

**Recommendation**: **Keep the defer propagation (522), REMOVE immediate propagation (595-597)**. Simpler code with same functional outcome.

---

### 1.4 Redundant Error Markers in Stream Reset

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/client.zig`

**Lines 644-650** (RST_STREAM handler in `dispatchFrame`):
```zig
.rst_stream => {
    if (self.findStreamSlot(fh.stream_id)) |slot| {
        if (payload.len >= 4) {
            self.streams[slot].error_code = std.mem.readInt(u32, payload[0..4], .big);
        }
        self.streams[slot].completed = true;
        self.streams[slot].condition.signal(io);
    }
},
```

**Lines 666-669** (GOAWAY handler):
```zig
if (stream.id > last_stream_id) {
    log.debug("GOAWAY: signaling stream {d} for retry", .{stream.id});
    stream.error_code = 0xFFFFFFFF; // Internal retry marker
    stream.completed = true;
```

**Issue**: Uses magic value `0xFFFFFFFF` as "internal retry marker". This is fragile - what if a server actually sends this error code?

**Recommendation**: Add an explicit flag or use an enum:
```zig
// In Stream struct:
retry_needed: bool = false,

// In GOAWAY handler:
stream.retry_needed = true;
```

This is clearer than magic numbers.

---

### 1.5 Active Streams Underflow Guard - DEFENSIVE BUT VALID

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/connection.zig`

**Lines 186-191**:
```zig
// Safety: prevent underflow if stream count is corrupt
if (self.h2_client.active_streams > 0) {
    self.h2_client.active_streams -= 1;
} else {
    log.warn("active_streams underflow prevented, stream_id={d}", .{stream_id});
}
```

**Issue**: This is a defensive guard against corrupted state.

**Analysis**: TigerBeetle style would assert here instead. If stream count is wrong, it's a bug that should crash in debug, not be silently fixed.

**Recommendation**: Replace with debug assertion:
```zig
std.debug.assert(self.h2_client.active_streams > 0);
self.h2_client.active_streams -= 1;
```

If underflow happens, it indicates a logic bug in stream lifecycle management that should be fixed, not masked.

---

## 2. CODE QUALITY ISSUES

### 2.1 Inconsistent State Management Pattern

**Files**: Multiple

**Issue**: The codebase mixes different patterns for managing connection state:
- Binary enum (`State.ready` / `.dead`) in `connection.zig`
- Boolean flags (`connected`, `reader_running`, `shutdown_requested`)
- Ternary enum in pool (`SlotState.empty` / `.available` / `.in_use`)

**Recommendation**: Standardize on enums for multi-state, bools only for binary true/false questions.

**Example** - Connection state should use enum consistently:
```zig
const ConnectionState = enum {
    initializing,  // Created but not connected
    ready,         // Active and healthy
    draining,      // Shutdown requested, finishing work
    dead,          // Closed
};
```

This makes state transitions explicit and debuggable.

---

### 2.2 TODO Comments Should Be Addressed or Removed

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/pool.zig`

**Lines 134-135**:
```zig
// For now, always destroy HTTP/2 connections after use
// TODO: Implement proper connection reuse with persistent reader
```

**Issue**: This TODO contradicts the current implementation. The code DOES have persistent readers (via `readerTask`), but the pool intentionally destroys connections.

**Recommendation**: Either:
1. Implement persistent pooling (if needed for performance)
2. Remove the TODO and document WHY connections are destroyed (simpler lifecycle, avoids stale connections)

**Suggested fix**:
```zig
// HTTP/2 connections are always destroyed after use for simplicity.
// Each request creates a fresh connection with known-good state.
// This avoids complex lifecycle management and stale connection issues.
```

---

### 2.3 Magic Numbers Should Be Named Constants

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/pool.zig`

**Line 218**:
```zig
if (idle_ms > 30_000) {
    return true;
}
```

**Issue**: Hard-coded 30 second timeout with no named constant.

**Recommendation**:
```zig
const IDLE_TIMEOUT_MS: i64 = 30_000; // 30 seconds

// Usage:
if (idle_ms > IDLE_TIMEOUT_MS) {
    return true;
}
```

---

### 2.4 Inconsistent Logging Style

**File**: Multiple

**Issue**: Mix of logging styles:
- Some logs include metadata: `"[REQ {d}] ..."` in connection.zig
- Some are bare: `"Reader: socket not connected"` in client.zig
- Inconsistent capitalization

**Recommendation**: Establish consistent pattern:
```zig
// Good: structured with context
log.debug("reader_task: exiting, shutdown={}", .{shutdown_requested.*});

// Good: action + result
log.debug("request: sent stream {d}", .{stream_id});

// Bad: inconsistent
log.debug("Reader: socket not connected, exiting", .{});
```

---

## 3. IDIOMATIC ZIG ISSUES

### 3.1 Unnecessary Mutable Pointer in readerTask

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/client.zig`

**Lines 509-518**:
```zig
pub fn readerTask(
    self: *Self,
    sock: *UltraSock,  // Mutable pointer
    shutdown_requested: *bool,
    reader_running: *bool,
    connected: *bool,
    goaway_received: *bool,
    stream_mutex: *Io.Mutex,
    io: Io,
) void {
```

**Issue**: Takes mutable pointer to `UltraSock`, but only reads from it (except in defer).

**Analysis**: The socket is modified in the defer block (line 532: `sock.closeAsync(io)`). However, this modifies fields inside the socket, not the pointer itself.

**Recommendation**: This is actually fine - the pointer is needed to call methods. No change needed.

---

### 3.2 Prefer Comptime for Constants

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/connection.zig`

**Lines 30-32**:
```zig
const TLS_INPUT_BUFFER_LEN = 16645;
const TLS_OUTPUT_BUFFER_LEN = 16469;
```

**Issue**: These are duplicated from `pool.zig` lines 27-28 AND from vendor/tls (according to comment).

**Recommendation**: Define once in a shared location:
```zig
// In http2/mod.zig or similar
pub const TLS_INPUT_BUFFER_LEN = tls.input_buffer_len;
pub const TLS_OUTPUT_BUFFER_LEN = tls.output_buffer_len;
```

Then import from there. Avoids drift between files.

---

### 3.3 Error Return vs Early Return Inconsistency

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/client.zig`

**Lines 550-557**:
```zig
const n = sock.recv(io, header_buf[header_read..]) catch |err| {
    log.debug("Reader: header recv failed: {}, sock.connected={}", .{ err, sock.connected });
    return; // Exit reader task
};
if (n == 0) {
    log.debug("Reader: connection closed during header read", .{});
    return;
}
```

**Issue**: Both error and EOF use `return` (exit normally). This is fine for this use case but inconsistent with error propagation elsewhere.

**Recommendation**: This is actually correct - `readerTask` returns `void` and exits via defer block cleanup. No change needed. The pattern is idiomatic for async tasks.

---

## 4. TIGERBEETLE STYLE COMPLIANCE

### 4.1 GOOD: Fixed-Size Arrays

The code correctly uses fixed-size arrays throughout:
- `streams: [MAX_STREAMS]Stream` (client.zig:82)
- `write_buffer: [WRITE_BUFFER_SIZE]u8` (client.zig:87)
- `tls_input_buffer: [TLS_INPUT_BUFFER_LEN]u8` (connection.zig:74)

**Assessment**: ✓ Compliant

---

### 4.2 GOOD: Explicit State Machines

Binary state enum is clear:
```zig
pub const State = enum {
    ready,
    dead,
};
```

**Assessment**: ✓ Compliant (but see issue 2.1 about redundant `connected` flag)

---

### 4.3 GOOD: Stable Addresses for Mutexes

```zig
// connection.zig:54-56
// Multiplexing mutexes (must be at stable address - struct is heap-allocated)
write_mutex: Io.Mutex = .init,
stream_mutex: Io.Mutex = .init,
```

With comment at line 159-160:
```zig
// Allocate connection on heap (stable address for mutexes)
const conn = try self.allocator.create(H2Connection);
```

**Assessment**: ✓ Compliant and well-documented

---

### 4.4 ISSUE: Assertions Could Be More Aggressive

**File**: Multiple

**Issue**: Some defensive guards should be assertions:

**Example 1** - pool.zig:194-197:
```zig
// Safety check - connection may have been destroyed by another coroutine
if (conn.state == .dead) {
    return true;
}
```

**TigerBeetle approach**: If another coroutine destroyed the connection, that's a race condition bug. Should assert instead:
```zig
std.debug.assert(conn.state != .dead);
```

**Example 2** - connection.zig:186-191 (discussed in 1.5):
The underflow guard should be an assertion.

**Recommendation**: Use assertions for invariants that indicate bugs, not runtime guards that hide them.

---

### 4.5 GOOD: Critical Ordering Documentation

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/connection.zig`

**Lines 137-141**:
```zig
// STEP 2: Lock stream_mutex FIRST (critical ordering)
// When reader tries to lock for dispatch, it BLOCKS -> Io.async yields
log.debug("request: locking stream_mutex", .{});
try self.stream_mutex.lock(io);
```

**Assessment**: ✓ Excellent documentation of lock ordering and async behavior

---

## 5. PERFORMANCE ISSUES

### 5.1 Unnecessary Allocation: h2_client Heap vs Inline

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/connection.zig`

**Lines 45-46**:
```zig
/// HTTP/2 client state (heap-allocated for small struct size)
h2_client: *Http2Client,
```

**Issue**: Comment says "heap-allocated for small struct size", but `Http2Client` is actually LARGE:
- Fixed array: `streams: [MAX_STREAMS]Stream` (8 streams)
- Each `Stream` has ~200+ bytes (headers array, ArrayList, condition variable)
- Write buffer: `[WRITE_BUFFER_SIZE]u8` = 32KB
- Total: ~35KB+

**Analysis**: The pointer indirection adds cache misses for frequent field access. The comment suggests this was done to keep H2Connection small, but:
1. H2Connection is already heap-allocated (line 160)
2. The indirection adds a pointer chase on every access
3. TigerBeetle style prefers inline structs for cache locality

**Recommendation**: **Inline h2_client**:
```zig
h2_client: Http2Client,
```

Change initialization:
```zig
pub fn init(sock: UltraSock, backend_idx: u32, allocator: std.mem.Allocator) !Self {
    return Self{
        .sock = sock,
        .h2_client = Http2Client.init(allocator),
        .allocator = allocator,
        .backend_idx = backend_idx,
        .last_used_ns = currentTimeNs(),
    };
}
```

And cleanup:
```zig
pub fn deinitAsync(self: *Self, io: Io) void {
    // ...
    self.h2_client.deinit();
    // No destroy call needed
}
```

**Performance impact**: Saves one heap allocation per connection + improves cache locality.

---

### 5.2 Redundant Time Conversion

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/pool.zig`

**Lines 215-218**:
```zig
const now_ns = currentTimeNs();
const idle_ns = now_ns - conn.last_used_ns;
const idle_ms = @divFloor(idle_ns, 1_000_000);
if (idle_ms > 30_000) {
```

**Issue**: Converts nanoseconds to milliseconds just for comparison. Simpler to compare nanoseconds directly:

**Recommendation**:
```zig
const IDLE_TIMEOUT_NS: i64 = 30_000 * 1_000_000; // 30 seconds in nanoseconds

const now_ns = currentTimeNs();
const idle_ns = now_ns - conn.last_used_ns;
if (idle_ns > IDLE_TIMEOUT_NS) {
    return true;
}
```

Saves division operation per stale check.

---

### 5.3 Double Mutex Lock in Frame Dispatch

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/client.zig`

**Lines 591-598**:
```zig
// Dispatch frame to correct stream (mutex-protected)
stream_mutex.lock(io) catch return; // Cancelled
const dispatch_result = self.dispatchFrame(fh, payload, io);
// Propagate GOAWAY flag immediately so pool knows connection is closing
if (self.goaway_received) {
    goaway_received.* = true;
}
stream_mutex.unlock(io);
```

**Issue**: The mutex is locked for EVERY frame, even though most frames only touch a single stream's isolated state.

**Analysis**: The mutex is needed only when:
1. Signaling stream completion (calls `condition.signal()`)
2. Accessing shared state like `active_streams`

**Recommendation**: Fine-grained locking - only lock when needed:
```zig
// Dispatch frame WITHOUT mutex
const dispatch_result = self.dispatchFrame(fh, payload, io, stream_mutex);
```

Then inside `dispatchFrame`, only lock around `condition.signal()`.

**Performance impact**: Reduces contention in high-throughput scenarios.

---

## 6. TLS SHUTDOWN SEQUENCE - CORRECT

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/connection.zig`

**Lines 253-276** (deinitAsync):

The current 3-phase shutdown is **CORRECT**:

1. **Signal shutdown**: `self.shutdown_requested = true` (line 255)
2. **Send close_notify**: `self.sock.sendCloseNotify(io)` (line 259)
3. **Await reader exit**: `future.await(io)` (line 266)
4. **Close socket**: `self.sock.closeSocketOnly()` (line 272)

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/ultra_sock.zig`

**Lines 619-635** (sendCloseNotify):
```zig
pub fn sendCloseNotify(self: *UltraSock, io: Io) void {
    if (self.connected and self.has_reader_writer) {
        if (self.tls_conn) |*conn| {
            self.stream_writer.io = io;
            conn.output = &self.stream_writer.interface;
            log.debug("Sending TLS close_notify", .{});
            conn.close() catch |err| {
                log.debug("TLS close_notify failed: {}", .{err});
            };
        }
    }
}
```

**Lines 647-653** (closeSocketOnly):
```zig
pub fn closeSocketOnly(self: *UltraSock) void {
    self.freeTlsResources();
    self.closeStream();
    self.io = null;
    self.connected = false;
}
```

**Assessment**: ✓ The TLS shutdown sequence is correct and matches the fix description:
1. Send close_notify to peer
2. Reader receives peer's close_notify/EOF naturally
3. Then close socket

No redundant code here. This is the result of the debugging iterations and should be kept.

---

## 7. NITPICKS & STYLE

### 7.1 Comment Style Inconsistency

Mix of:
- `//!` (module-level docs)
- `///` (item-level docs)
- `//` (regular comments)
- `// ---` (section separators)

**Recommendation**: Standardize section separators:
```zig
// ========================================================================
// Section Name
// ========================================================================
```

Current code already uses this in some places (client.zig:107), but not consistently.

---

### 7.2 Verbose Debug Logging Can Be Removed

**File**: `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/client.zig`

Lines 548, 560, 566 have very verbose reader logging:
```zig
log.debug("Reader: waiting for frame header...", .{});
log.debug("Reader: got frame header, parsing...", .{});
log.debug("Reader: frame type={d}, len={d}, stream={d}", .{...});
```

**Recommendation**: These were useful during debugging but can be removed or moved to trace level for production:
```zig
if (config.isTraceEnabled()) {
    log.debug("Reader: frame type={d}, len={d}, stream={d}", .{...});
}
```

---

## 8. SUMMARY OF RECOMMENDATIONS

### Critical (Must Fix)

1. **Remove redundant `connected` field** (connection.zig:64) - use only `state` enum
2. **Inline `h2_client` instead of heap pointer** (connection.zig:46) - better cache locality
3. **Replace underflow guard with assertion** (connection.zig:186-191) - TigerBeetle style

### Important (Should Fix)

4. **Remove pre-check in reader loop** (client.zig:540-543) - redundant with recv error
5. **Remove immediate GOAWAY propagation** (client.zig:595-597) - defer handles it
6. **Use named constant for idle timeout** (pool.zig:218)
7. **Remove/update TODO comments** (pool.zig:134-135)
8. **Use explicit retry flag instead of magic number** (client.zig:667)

### Nice to Have (Optional)

9. Standardize logging format
10. Reduce debug verbosity in reader loop
11. Deduplicate TLS buffer size constants
12. Fine-grained locking in dispatchFrame (performance optimization)
13. Use nanosecond comparison instead of division (micro-optimization)

---

## 9. FILES REVIEWED

- `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/connection.zig`
- `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/pool.zig`
- `/Users/nick/repos/zzz/examples/load_balancer/src/http/http2/client.zig`
- `/Users/nick/repos/zzz/examples/load_balancer/src/http/ultra_sock.zig`
- `/Users/nick/repos/zzz/examples/load_balancer/src/proxy/connection.zig`

**Lines of code reviewed**: ~2000+

**Issues found**: 13 actionable items across 5 categories

---

## 10. CONCLUSION

The HTTP/2 with TLS implementation is fundamentally sound. The TLS shutdown sequence is correct and well-documented. The main opportunities for improvement are:

1. **Removing redundant state tracking** left over from debugging iterations
2. **Improving performance** through better cache locality (inline h2_client)
3. **Tightening invariants** with assertions instead of defensive guards
4. **Code consistency** in logging, error handling, and naming

The code demonstrates good engineering practices with clear comments explaining critical ordering and TLS buffer management. The issues identified are polish items rather than fundamental flaws.
