# Async HTTP/2 Multiplexing Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable HTTP/2 stream multiplexing without blocking worker threads.

**Problem:** Current implementation uses `std.Thread` + `posix.pipe()` + `posix.poll()`. The `poll()` call blocks the entire async worker thread, freezing all request handling.

**Solution:** Replace thread-based reader with async task using `Io.async()`, and pipes with `Io.Condition` for signaling.

---

## Architecture

```
Request coroutine          Async Reader Task
       |                          |
  send request                    |
       |                    recv frame (async, yields)
  condition.wait() -----.         |
       |                 |   dispatch to stream
     (yielded)           |   stream.completed = true
       |                 '-- condition.signal()
  (woken up)                      |
  read response                   |
```

**Key insight:** Both reader and request coroutines run in the same worker's async scheduler. `sock.recv(io, buffer)` and `condition.wait(io, mutex)` yield to the scheduler, allowing other coroutines to run.

---

## Data Structures

### Stream (client.zig)

```zig
const Stream = struct {
    id: u31 = 0,
    active: bool = false,
    status: u16 = 0,
    headers: [32]hpack.Header = undefined,
    header_count: usize = 0,
    body: std.ArrayList(u8) = .{},
    end_stream: bool = false,

    // Async signaling (replaces pipes):
    condition: Io.Condition = .{},
    completed: bool = false,
    error_code: ?u32 = null,

    pub fn reset(self: *Stream) void {
        self.id = 0;
        self.active = false;
        self.completed = false;
        self.error_code = null;
        self.condition = .{};
        self.body.items.len = 0;
    }
};
```

### H2PooledConnection (pooled_conn.zig)

```zig
pub const H2PooledConnection = struct {
    // ... existing fields ...

    write_mutex: Io.Mutex = .init,      // protects socket writes
    stream_mutex: Io.Mutex = .init,     // protects stream state
    reader_running: bool = false,
    shutdown_requested: bool = false,

    // Removed: shutdown_pipe, reader_active atomic
};
```

---

## Async Reader Task

```zig
pub fn readerTask(self: *Http2Client, conn: *H2PooledConnection, io: Io) void {
    var recv_buf: [MAX_FRAME_SIZE + 9]u8 = undefined;

    while (!conn.shutdown_requested) {
        // Async recv - yields to scheduler during I/O wait
        var header_buf: [9]u8 = undefined;
        const header_n = conn.sock.recv(io, &header_buf) catch break;
        if (header_n == 0) break;

        const fh = frame.FrameHeader.parse(&header_buf) catch break;

        if (fh.length > 0) {
            _ = conn.sock.recv(io, recv_buf[0..fh.length]) catch break;
        }

        // Dispatch with mutex protection
        conn.stream_mutex.lockUncancelable(io);
        defer conn.stream_mutex.unlock(io);
        self.dispatchFrame(fh, recv_buf[0..fh.length], io) catch break;
    }

    self.signalAllStreams(io);
    conn.reader_running = false;
}
```

---

## Request Flow

### Send Request

```zig
pub fn sendRequestMultiplexed(self: *Self, io: Io, ...) !u31 {
    const client = self.h2_client orelse return error.NotConnected;

    self.stream_mutex.lockUncancelable(io);
    const slot_idx = client.findFreeSlot() orelse {
        self.stream_mutex.unlock(io);
        return error.NoStreamSlot;
    };
    client.streams[slot_idx].completed = false;
    self.stream_mutex.unlock(io);

    self.write_mutex.lockUncancelable(io);
    defer self.write_mutex.unlock(io);

    const stream_id = try client.sendRequest(method, path, host, body);
    try client.flush(&self.sock, io);
    return stream_id;
}
```

### Await Response

```zig
pub fn awaitResponse(self: *Self, io: Io, stream_id: u31) !Response {
    const client = self.h2_client orelse return error.NotConnected;
    const slot = client.findStreamSlot(stream_id) orelse return error.StreamNotFound;

    self.stream_mutex.lockUncancelable(io);
    while (!client.streams[slot].completed) {
        // YIELDS to scheduler - non-blocking!
        client.streams[slot].condition.waitUncancelable(io, &self.stream_mutex);
    }

    if (client.streams[slot].error_code) |_| {
        client.streams[slot].reset();
        self.stream_mutex.unlock(io);
        return error.StreamReset;
    }

    const response = Response{ ... };
    client.streams[slot].reset();
    self.stream_mutex.unlock(io);
    return response;
}
```

---

## Spawning Reader

```zig
// In handler.zig:
if (!conn.reader_running) {
    conn.reader_running = true;
    _ = Io.async(io, Http2Client.readerTask, .{ conn.h2_client.?, conn, io });
}
```

---

## Error Handling

- Reader exits on any recv error or connection close
- `signalAllStreams()` wakes all waiters with error marker
- GOAWAY triggers immediate shutdown
- No timeout needed - health checks handle stuck connections

---

## Files to Modify

1. **client.zig** - Stream struct, readerTask, dispatchFrame
2. **pooled_conn.zig** - Remove pipes/thread, add stream_mutex, async await
3. **ultra_sock.zig** - Remove recvBlocking, getRawFd
4. **handler.zig** - Spawn via Io.async instead of Thread.spawn
5. **connection_pool.zig** - Keep thread mutex for cross-worker safety (already done)

---

## Benefits

- No blocking calls in async context
- Simpler code (-50 lines approx)
- No pipe file descriptors to manage
- No thread spawn/join complexity
- Natural integration with Zig's async I/O
