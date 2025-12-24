# HTTP/2 Stream Multiplexing Design

## Problem

Currently `MAX_CONCURRENT_STREAMS = 1` because multiple coroutines can't safely read from the same TLS socket. Each request coroutine calls `readResponse()` which loops on `sock.recv()` - concurrent calls corrupt TLS state.

## Goal

Enable true HTTP/2 multiplexing: multiple concurrent streams per connection for maximum throughput through fewer backend connections.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    H2PooledConnection                     │
│                                                          │
│  ┌─────────────┐        ┌─────────────────────────────┐  │
│  │ Write Mutex │        │     Dedicated Reader        │  │
│  │ (serialize  │        │  - reads all frames         │  │
│  │  sends)     │        │  - dispatches by stream_id  │  │
│  └─────────────┘        │  - signals via pipes        │  │
│                         └──────────────┬──────────────┘  │
│                                        │                 │
│  ┌──────────────┬──────────────┬──────────────┐         │
│  │   Stream 1   │   Stream 3   │   Stream 5   │         │
│  │ ┌──────────┐ │ ┌──────────┐ │ ┌──────────┐ │         │
│  │ │  buffer  │ │ │  buffer  │ │ │  buffer  │ │         │
│  │ │  pipe[2] │ │ │  pipe[2] │ │ │  pipe[2] │ │         │
│  │ └──────────┘ │ └──────────┘ │ └──────────┘ │         │
│  └──────────────┴──────────────┴──────────────┘         │
└──────────────────────────────────────────────────────────┘
         ▲                ▲                ▲
         │                │                │
    Request A        Request B        Request C
    (waiting)        (waiting)        (waiting)
```

## Key Components

### 1. Dedicated Reader Coroutine

- Spawned via `Io.Group.concurrent()` when connection added to pool
- Loops reading frames from socket
- Dispatches each frame to correct stream buffer by stream_id
- Signals waiting request via that stream's pipe
- Exits on GOAWAY, socket error, or shutdown signal

### 2. Per-Stream Signaling (Pipes)

- Each active stream gets a `pipe()` pair
- Request coroutine blocks on `io.read(pipe[0])`
- Reader writes to `pipe[1]` when END_STREAM received
- Portable (works on Linux, macOS, BSD)

### 3. Write Mutex

- `std.Io.Mutex` protects frame writes
- Multiple request coroutines can send concurrently
- Mutex serializes actual TLS writes

### 4. Stream-Level Tokens

- Token now represents a stream slot, not entire connection
- Multiple tokens can reference same connection (different streams)
- Connection stays `.available` while it has stream capacity

## Data Structures

### Enhanced Stream (client.zig)

```zig
const Stream = struct {
    id: u31 = 0,
    active: bool = false,

    // Response state (existing)
    status: u16 = 0,
    headers: [32]hpack.Header = undefined,
    header_count: usize = 0,
    body: std.ArrayList(u8) = undefined,

    // Multiplexing additions
    end_stream: bool = false,
    error_code: ?u32 = null,
    signal_pipe: [2]posix.fd_t = .{-1, -1},

    fn initPipe(self: *Stream) !void {
        self.signal_pipe = try posix.pipe();
    }

    fn deinitPipe(self: *Stream) void {
        if (self.signal_pipe[0] != -1) posix.close(self.signal_pipe[0]);
        if (self.signal_pipe[1] != -1) posix.close(self.signal_pipe[1]);
        self.signal_pipe = .{-1, -1};
    }

    fn signal(self: *Stream) void {
        _ = posix.write(self.signal_pipe[1], &[_]u8{1}) catch {};
    }
};
```

### Enhanced H2PooledConnection (pooled_conn.zig)

```zig
pub const H2PooledConnection = struct {
    sock: UltraSock,
    h2_client: *Http2Client,
    allocator: std.mem.Allocator,
    backend_idx: u32,

    // Multiplexing additions
    write_mutex: std.Io.Mutex = .init,
    reader_group: std.Io.Group = .init,
    reader_running: std.atomic.Value(bool) = .{.raw = false},
    shutdown_pipe: [2]posix.fd_t = .{-1, -1},
};
```

### Stream-Level Token (pooled_conn.zig)

```zig
pub const StreamToken = struct {
    backend_idx: u8,
    slot_idx: u8,        // Connection slot
    stream_idx: u8,      // Stream within connection
    generation: u16,
};
```

## Request Flow

### Sending a Request

```zig
pub fn sendRequest(conn: *H2PooledConnection, io: Io, ...) !u31 {
    const slot = try conn.h2_client.acquireStreamSlot();
    try slot.initPipe();
    errdefer slot.deinitPipe();

    conn.write_mutex.lock(io);
    defer conn.write_mutex.unlock(io);

    const stream_id = try conn.h2_client.sendRequest(...);
    try conn.h2_client.flush(&conn.sock, io);

    return stream_id;
}
```

### Awaiting Response

```zig
pub fn awaitResponse(conn: *H2PooledConnection, io: Io, stream_id: u31) !Response {
    const slot = conn.h2_client.findStreamSlot(stream_id);

    // Wait with timeout
    var pipe_read = io.async(readByte, .{slot.signal_pipe[0], io});
    var timeout = io.async(sleep, .{io, 30_000});

    switch (io.select(.{.pipe = &pipe_read, .timeout = &timeout})) {
        .timeout => return error.Timeout,
        .pipe => {
            if (slot.error_code) |_| return error.StreamReset;
            return buildResponse(slot);
        },
    }
}
```

## Reader Coroutine

```zig
fn readerTask(conn: *H2PooledConnection, io: Io) void {
    conn.reader_running.store(true, .release);
    defer conn.reader_running.store(false, .release);
    defer conn.cleanupAllStreams();

    while (true) {
        var sock_read = io.async(readFrameHeader, .{&conn.sock, io});
        var shutdown = io.async(readByte, .{conn.shutdown_pipe[0], io});

        switch (io.select(.{.sock = &sock_read, .shutdown = &shutdown})) {
            .shutdown => break,
            .sock => |header_bytes| {
                const fh = frame.FrameHeader.parse(header_bytes);
                const payload = readPayload(&conn.sock, io, fh.length);
                dispatchFrame(conn.h2_client, fh, payload);
            },
        }
    }
}

fn dispatchFrame(client: *Http2Client, fh: FrameHeader, payload: []u8) void {
    switch (fh.frame_type) {
        .headers, .data => {
            const slot = client.findStreamSlot(fh.stream_id);
            // Store data in slot buffer
            if (fh.isEndStream()) {
                slot.end_stream = true;
                slot.signal();
            }
        },
        .rst_stream => {
            const slot = client.findStreamSlot(fh.stream_id);
            slot.error_code = parseErrorCode(payload);
            slot.signal();
        },
        .goaway => {
            signalAllStreams(client);
            return;
        },
        else => {},
    }
}
```

## Error Handling

| Scenario | Reader Action | Request Action |
|----------|---------------|----------------|
| Socket EOF | Signal all streams, exit | awaitResponse returns error |
| TLS error | Signal all streams, exit | awaitResponse returns error |
| RST_STREAM | Signal that stream with error_code | That request gets error |
| GOAWAY | Signal all streams, mark conn for close | Requests fail, conn evicted |
| Timeout | N/A | Request cancelled, stream reset |

## Connection Lifecycle

1. **Creation**: Spawn reader via `Io.Group.concurrent()`, init shutdown pipe
2. **In Use**: Multiple streams acquired/released, reader dispatches frames
3. **Shutdown**: Write to shutdown pipe, `reader_group.cancel()`, close pipes
4. **Cleanup**: Close socket, deinit client

## Testing Strategy

### Unit Tests
- Pipe signaling works
- Write mutex serializes sends
- Reader dispatches to correct stream
- Timeout fires correctly
- RST_STREAM propagates error
- GOAWAY signals all streams

### Integration Tests
- Two concurrent requests on one connection
- Load test with `wrk -t4 -c100 -d30s`
- Verify throughput increase vs single-stream
- Verify no crashes or hung requests

### Metrics
- Streams per connection (target: > 1 under load)
- Connection count (should decrease)
- Latency p99 (should stay stable)
