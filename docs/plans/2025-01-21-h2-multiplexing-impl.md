# HTTP/2 Stream Multiplexing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable true HTTP/2 multiplexing with multiple concurrent streams per connection via a dedicated reader coroutine.

**Architecture:** Each H2PooledConnection spawns a reader coroutine that reads all frames and dispatches to per-stream buffers. Request coroutines wait on pipes for their stream's completion. A write mutex serializes frame sends.

**Tech Stack:** Zig 0.16, std.Io (io_uring), POSIX pipes

---

## Task 1: Add Pipe Helpers to Stream Struct

**Files:**
- Modify: `src/http/http2/client.zig:36-54`

**Step 1: Add pipe fields and methods to Stream**

```zig
const posix = std.posix;

/// Per-stream state for multiplexing
const Stream = struct {
    id: u31 = 0,
    active: bool = false,
    status: u16 = 0,
    headers: [32]hpack.Header = undefined,
    header_count: usize = 0,
    body: std.ArrayList(u8) = undefined,
    end_stream: bool = false,

    // Multiplexing: signaling pipe
    signal_pipe: [2]posix.fd_t = .{ -1, -1 },
    error_code: ?u32 = null,

    fn initPipe(self: *Stream) !void {
        self.signal_pipe = try posix.pipe();
    }

    fn deinitPipe(self: *Stream) void {
        if (self.signal_pipe[0] != -1) {
            posix.close(self.signal_pipe[0]);
            posix.close(self.signal_pipe[1]);
            self.signal_pipe = .{ -1, -1 };
        }
    }

    fn signal(self: *Stream) void {
        if (self.signal_pipe[1] != -1) {
            _ = posix.write(self.signal_pipe[1], &[_]u8{1}) catch {};
        }
    }

    fn reset(self: *Stream) void {
        self.id = 0;
        self.active = false;
        self.status = 0;
        self.header_count = 0;
        self.end_stream = false;
        self.error_code = null;
        self.deinitPipe();
        // Don't deinit body - reuse capacity
        self.body.items.len = 0;
    }
};
```

**Step 2: Build and verify no errors**

Run: `/usr/local/zig-0.16.0-dev/zig build 2>&1`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add src/http/http2/client.zig
git commit -m "feat(h2): add pipe signaling to Stream struct"
```

---

## Task 2: Add Multiplexing Fields to H2PooledConnection

**Files:**
- Modify: `src/http/http2/pooled_conn.zig:70-115`

**Step 1: Add write mutex, reader group, and shutdown pipe**

```zig
const Io = std.Io;

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

    // Multiplexing support
    write_mutex: Io.Mutex = .{},
    shutdown_pipe: [2]posix.fd_t = .{ -1, -1 },
    reader_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ... rest of struct
```

**Step 2: Add initMultiplexing and deinitMultiplexing methods**

```zig
    /// Initialize multiplexing infrastructure (call after init, before first use)
    pub fn initMultiplexing(self: *Self) !void {
        self.shutdown_pipe = try posix.pipe();
    }

    /// Clean up multiplexing infrastructure
    pub fn deinitMultiplexing(self: *Self) void {
        // Signal reader to stop
        if (self.shutdown_pipe[1] != -1) {
            _ = posix.write(self.shutdown_pipe[1], &[_]u8{1}) catch {};
        }
        if (self.shutdown_pipe[0] != -1) {
            posix.close(self.shutdown_pipe[0]);
            posix.close(self.shutdown_pipe[1]);
            self.shutdown_pipe = .{ -1, -1 };
        }
    }
```

**Step 3: Update deinit to call deinitMultiplexing**

```zig
    pub fn deinit(self: *Self) void {
        self.deinitMultiplexing();
        if (self.h2_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
            self.h2_client = null;
        }
        self.sock.close_blocking();
    }
```

**Step 4: Build and verify**

Run: `/usr/local/zig-0.16.0-dev/zig build 2>&1`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add src/http/http2/pooled_conn.zig
git commit -m "feat(h2): add multiplexing fields to H2PooledConnection"
```

---

## Task 3: Implement Reader Coroutine

**Files:**
- Modify: `src/http/http2/client.zig` (add readerLoop function)

**Step 1: Add reader loop function to Http2Client**

Add after the existing `readAndRouteFrame` function:

```zig
    /// Dedicated reader loop for multiplexing.
    /// Reads frames and dispatches to correct stream, signals completion.
    /// Runs until shutdown signaled or connection error.
    pub fn readerLoop(
        self: *Self,
        sock: *UltraSock,
        shutdown_fd: posix.fd_t,
        reader_active: *std.atomic.Value(bool),
    ) void {
        reader_active.store(true, .release);
        defer reader_active.store(false, .release);
        defer self.signalAllStreams(); // Wake any waiters on exit

        var recv_buf: [mod.MAX_FRAME_SIZE_DEFAULT + 9]u8 = undefined;

        while (true) {
            // Read frame header (9 bytes)
            var header_buf: [9]u8 = undefined;
            var header_read: usize = 0;

            while (header_read < 9) {
                // Check shutdown before blocking read
                var poll_fds = [_]posix.pollfd{
                    .{ .fd = sock.getRawFd(), .events = posix.POLL.IN, .revents = 0 },
                    .{ .fd = shutdown_fd, .events = posix.POLL.IN, .revents = 0 },
                };

                _ = posix.poll(&poll_fds, 100) catch break; // 100ms timeout

                if (poll_fds[1].revents & posix.POLL.IN != 0) {
                    return; // Shutdown signaled
                }

                if (poll_fds[0].revents & posix.POLL.IN != 0) {
                    const n = sock.recvBlocking(header_buf[header_read..]) catch break;
                    if (n == 0) return; // Connection closed
                    header_read += n;
                }
            }

            const fh = frame.FrameHeader.parse(&header_buf) catch break;

            if (fh.length > mod.MAX_FRAME_SIZE_DEFAULT) {
                log.err("Frame too large: {d}", .{fh.length});
                break;
            }

            // Read payload
            if (fh.length > 0) {
                var payload_read: usize = 0;
                while (payload_read < fh.length) {
                    const n = sock.recvBlocking(recv_buf[payload_read..fh.length]) catch break;
                    if (n == 0) break;
                    payload_read += n;
                }
                if (payload_read < fh.length) break;
            }

            const payload = recv_buf[0..fh.length];

            // Dispatch frame
            self.dispatchFrame(fh, payload) catch |err| {
                log.err("Frame dispatch error: {}", .{err});
                if (err == error.ConnectionGoaway) return;
            };
        }
    }

    /// Dispatch a frame to the correct stream
    fn dispatchFrame(self: *Self, fh: frame.FrameHeader, payload: []const u8) !void {
        const ft = frame.FrameType.fromU8(fh.frame_type) orelse return;

        switch (ft) {
            .headers => {
                if (self.findStreamSlot(fh.stream_id)) |slot| {
                    self.streams[slot].header_count = try hpack.Hpack.decodeHeaders(
                        payload,
                        &self.streams[slot].headers,
                    );
                    self.streams[slot].status = hpack.Hpack.getStatus(
                        self.streams[slot].headers[0..self.streams[slot].header_count],
                    ) orelse 0;

                    if (fh.isEndStream()) {
                        self.streams[slot].end_stream = true;
                        self.streams[slot].signal();
                    }
                }
            },
            .data => {
                if (self.findStreamSlot(fh.stream_id)) |slot| {
                    self.streams[slot].body.appendSlice(self.allocator, payload) catch {};

                    if (fh.isEndStream()) {
                        self.streams[slot].end_stream = true;
                        self.streams[slot].signal();
                    }
                }
            },
            .rst_stream => {
                if (self.findStreamSlot(fh.stream_id)) |slot| {
                    if (payload.len >= 4) {
                        self.streams[slot].error_code = std.mem.readInt(u32, payload[0..4], .big);
                    }
                    self.streams[slot].signal();
                }
            },
            .goaway => {
                self.signalAllStreams();
                return error.ConnectionGoaway;
            },
            .window_update => {
                // Handle at connection level
                if (fh.stream_id == 0 and payload.len >= 4) {
                    const increment = std.mem.readInt(u32, payload[0..4], .big);
                    self.connection_window += @intCast(increment & 0x7FFFFFFF);
                }
            },
            .ping => {
                // Ping responses handled elsewhere or ignored
            },
            .settings => {
                if (!fh.isAck()) {
                    self.settings_acked = true;
                }
            },
            else => {},
        }
    }

    /// Signal all active streams (used on connection close)
    fn signalAllStreams(self: *Self) void {
        for (&self.streams) |*s| {
            if (s.active) {
                s.signal();
            }
        }
    }
```

**Step 2: Add helper methods to UltraSock for blocking reads**

In `src/http/ultra_sock.zig`, add:

```zig
    /// Get raw file descriptor for poll()
    pub fn getRawFd(self: *Self) posix.fd_t {
        if (self.stream) |s| {
            return s.handle;
        }
        return -1;
    }

    /// Blocking receive (for reader thread)
    pub fn recvBlocking(self: *Self, buf: []u8) !usize {
        if (self.tls_state) |tls| {
            return tls.read(buf) catch |err| {
                return err;
            };
        } else if (self.stream) |s| {
            return posix.read(s.handle, buf);
        }
        return error.NotConnected;
    }
```

**Step 3: Build and verify**

Run: `/usr/local/zig-0.16.0-dev/zig build 2>&1`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add src/http/http2/client.zig src/http/ultra_sock.zig
git commit -m "feat(h2): implement reader coroutine for multiplexing"
```

---

## Task 4: Add Multiplexed Send/Await API

**Files:**
- Modify: `src/http/http2/pooled_conn.zig`

**Step 1: Add sendRequestMultiplexed method**

```zig
    /// Send a request with multiplexing support.
    /// Acquires write mutex, sends frames, returns stream ID.
    pub fn sendRequestMultiplexed(
        self: *Self,
        io: anytype,
        method: []const u8,
        path: []const u8,
        host: []const u8,
        body: ?[]const u8,
    ) !u31 {
        const client = self.h2_client orelse return error.NotConnected;

        // Initialize pipe for this stream
        const slot_idx = client.findFreeSlot() orelse return error.NoStreamSlot;
        try client.streams[slot_idx].initPipe();
        errdefer client.streams[slot_idx].deinitPipe();

        // Serialize writes
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);

        // Queue and flush request
        const stream_id = try client.sendRequest(method, path, host, body);
        try client.flush(&self.sock, io);

        return stream_id;
    }

    /// Wait for response on a specific stream.
    /// Blocks until reader signals completion or timeout.
    pub fn awaitResponse(
        self: *Self,
        io: anytype,
        stream_id: u31,
        timeout_ms: u32,
    ) !Http2Client.Response {
        const client = self.h2_client orelse return error.NotConnected;
        const slot = client.findStreamSlot(stream_id) orelse return error.StreamNotFound;

        const pipe_fd = client.streams[slot].signal_pipe[0];
        if (pipe_fd == -1) return error.NoPipe;

        // Wait for signal with timeout
        var poll_fds = [_]posix.pollfd{
            .{ .fd = pipe_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        const result = posix.poll(&poll_fds, @intCast(timeout_ms)) catch |err| {
            client.streams[slot].reset();
            return err;
        };

        if (result == 0) {
            client.streams[slot].reset();
            return error.Timeout;
        }

        // Drain the signal byte
        var buf: [1]u8 = undefined;
        _ = posix.read(pipe_fd, &buf) catch {};

        // Check for stream error
        if (client.streams[slot].error_code) |code| {
            log.debug("Stream {d} reset with error {d}", .{ stream_id, code });
            client.streams[slot].reset();
            return error.StreamReset;
        }

        // Build response
        const response = Http2Client.Response{
            .status = client.streams[slot].status,
            .headers = client.streams[slot].headers,
            .header_count = client.streams[slot].header_count,
            .body = client.streams[slot].body,
            .allocator = self.allocator,
        };

        // Transfer ownership, reset slot
        client.streams[slot].body = .{};
        client.streams[slot].deinitPipe();
        client.streams[slot].active = false;
        client.active_streams -= 1;

        return response;
    }
```

**Step 2: Add findFreeSlot to Http2Client**

In `src/http/http2/client.zig`:

```zig
    /// Find a free stream slot
    pub fn findFreeSlot(self: *Self) ?usize {
        for (&self.streams, 0..) |*s, i| {
            if (!s.active) return i;
        }
        return null;
    }
```

**Step 3: Build and verify**

Run: `/usr/local/zig-0.16.0-dev/zig build 2>&1`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add src/http/http2/pooled_conn.zig src/http/http2/client.zig
git commit -m "feat(h2): add multiplexed send/await API"
```

---

## Task 5: Spawn Reader on Connection Creation

**Files:**
- Modify: `src/http/http2/connection_pool.zig`

**Step 1: Update addAndAcquire to init multiplexing**

```zig
    /// Add a new connection and acquire it atomically.
    /// Returns token with exclusive access, or null if pool full.
    pub fn addAndAcquire(self: *Self, conn: H2PooledConnection, backend_idx: u8) ?pooled_conn.ConnectionToken {
        for (&self.slots, 0..) |*slot, i| {
            if (slot.state == .empty) {
                var new_conn = conn;
                _ = new_conn.acquireStreamSlot() catch return null;

                // Initialize multiplexing (creates shutdown pipe)
                new_conn.initMultiplexing() catch return null;

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
```

**Step 2: Build and verify**

Run: `/usr/local/zig-0.16.0-dev/zig build 2>&1`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add src/http/http2/connection_pool.zig
git commit -m "feat(h2): init multiplexing on connection creation"
```

---

## Task 6: Start Reader Thread for Each Connection

**Files:**
- Modify: `src/http/http2/pooled_conn.zig`

**Step 1: Add startReader method that spawns a thread**

```zig
    /// Start the reader thread for multiplexing.
    /// Call after connection is established and added to pool.
    pub fn startReader(self: *Self) !std.Thread {
        return std.Thread.spawn(.{}, readerThreadFn, .{self});
    }

    fn readerThreadFn(self: *Self) void {
        if (self.h2_client) |client| {
            client.readerLoop(
                &self.sock,
                self.shutdown_pipe[0],
                &self.reader_active,
            );
        }
    }

    /// Stop the reader thread.
    pub fn stopReader(self: *Self) void {
        // Signal shutdown
        if (self.shutdown_pipe[1] != -1) {
            _ = posix.write(self.shutdown_pipe[1], &[_]u8{1}) catch {};
        }
        // Reader will exit on next poll
    }
```

**Step 2: Build and verify**

Run: `/usr/local/zig-0.16.0-dev/zig build 2>&1`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add src/http/http2/pooled_conn.zig
git commit -m "feat(h2): add reader thread spawn/stop methods"
```

---

## Task 7: Update Handler to Use Multiplexed API

**Files:**
- Modify: `src/proxy/handler.zig`

**Step 1: Update streamingProxyHttp2 to use multiplexed send/await**

Find the HTTP/2 streaming path and update to use the new API. The key changes:

1. Start reader thread when connection is first used
2. Use `sendRequestMultiplexed` instead of direct client access
3. Use `awaitResponse` instead of `readResponse`

```zig
// In streamingProxyHttp2, replace the send/receive section:

// Start reader if not already running
if (!h2_conn.reader_active.load(.acquire)) {
    const reader_thread = h2_conn.startReader() catch |err| {
        log.err("[REQ {d}] Failed to start H2 reader: {}", .{ req_id, err });
        return proxyError(ctx, 502);
    };
    reader_thread.detach();
}

// Send request (mutex-protected)
const stream_id = h2_conn.sendRequestMultiplexed(
    ctx.io,
    method_str,
    path,
    host,
    request_body,
) catch |err| {
    log.err("[REQ {d}] H2 send failed: {}", .{ req_id, err });
    return proxyError(ctx, 502);
};

// Wait for response
const response = h2_conn.awaitResponse(ctx.io, stream_id, 30000) catch |err| {
    log.err("[REQ {d}] H2 await failed: {}", .{ req_id, err });
    return proxyError(ctx, 504);
};
```

**Step 2: Build and verify**

Run: `/usr/local/zig-0.16.0-dev/zig build 2>&1`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add src/proxy/handler.zig
git commit -m "feat(h2): update handler to use multiplexed API"
```

---

## Task 8: Increase MAX_CONCURRENT_STREAMS

**Files:**
- Modify: `src/http/http2/pooled_conn.zig:61`

**Step 1: Change limit from 1 to 8**

```zig
/// Maximum concurrent streams per HTTP/2 connection
/// Now enabled with dedicated reader thread for multiplexing.
pub const MAX_CONCURRENT_STREAMS: u32 = 8;
```

**Step 2: Build and run tests**

Run: `/usr/local/zig-0.16.0-dev/zig build test 2>&1`
Expected: All tests pass

**Step 3: Commit**

```bash
git add src/http/http2/pooled_conn.zig
git commit -m "feat(h2): enable multiplexing with MAX_CONCURRENT_STREAMS=8"
```

---

## Task 9: Integration Test

**Step 1: Start backends and load balancer**

```bash
# Terminal 1: Backend
./zig-out/bin/test_backend_echo &

# Terminal 2: Load balancer
./zig-out/bin/load_balancer
```

**Step 2: Run stress test**

```bash
wrk -t4 -c50 -d30s https://127.0.0.1:9443
```

**Step 3: Verify results**

Expected:
- Higher throughput than single-stream mode
- No crashes or hung requests
- 99%+ success rate

**Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix(h2): integration test fixes for multiplexing"
```

---

## Task 10: Add Unit Tests for Multiplexing

**Files:**
- Modify: `src/http/http2/connection_pool.zig` (add tests at end)

**Step 1: Add pipe signaling test**

```zig
test "Stream: pipe signaling works" {
    var stream = Stream{};
    try stream.initPipe();
    defer stream.deinitPipe();

    // Signal the stream
    stream.signal();

    // Should be readable
    var buf: [1]u8 = undefined;
    const n = try posix.read(stream.signal_pipe[0], &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
}
```

**Step 2: Run tests**

Run: `/usr/local/zig-0.16.0-dev/zig build test 2>&1`
Expected: All tests pass

**Step 3: Commit**

```bash
git add src/http/http2/connection_pool.zig
git commit -m "test(h2): add multiplexing unit tests"
```
