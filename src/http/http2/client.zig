//! HTTP/2 Client for Load Balancer Backend Connections
//!
//! Provides HTTP/2 protocol support with stream multiplexing.
//! Uses a write queue pattern for safe concurrent access:
//! - sendRequest() queues frames to a buffer (no IO)
//! - flush() writes all queued frames in single TLS write
//!
//! Usage (single request):
//!   var client = Http2Client.init(allocator);
//!   try client.connect(&sock, io);
//!   const stream_id = try client.sendRequest("GET", "/api", "backend.com", null);
//!   try client.flush(&sock, io);
//!   const response = try client.readResponse(&sock, io, stream_id);
//!
//! Usage (multiplexed - queue multiple then flush once):
//!   const s1 = try client.sendRequest("GET", "/a", host, null);
//!   const s2 = try client.sendRequest("GET", "/b", host, null);
//!   try client.flush(&sock, io);  // Single TLS write for both
//!   const r1 = try client.readResponse(&sock, io, s1);
//!   const r2 = try client.readResponse(&sock, io, s2);

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.http2_client);

const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const mod = @import("mod.zig");
const UltraSock = @import("../ultra_sock.zig").UltraSock;

const Io = std.Io;

// Import shared connection state enum
pub const State = mod.ConnectionState;

/// Maximum concurrent streams per connection
const MAX_STREAMS: usize = 8;

/// Per-stream state for multiplexing
pub const Stream = struct {
    id: u31 = 0, // HTTP/2 stream ID
    active: bool = false,
    status: u16 = 0,
    headers: [32]hpack.Header = undefined,
    header_count: usize = 0,
    body: std.ArrayList(u8) = .{},
    end_stream: bool = false,

    // Per-stream mutex+condition for async multiplexing
    // CANNOT be atomic: request() must SLEEP until reader signals completion
    // Flow: request() waits on condition → reader dispatches frame → signals condition
    mutex: Io.Mutex = .init,
    condition: Io.Condition = Io.Condition.init,
    completed: bool = false, // Set by reader, checked by request()
    error_code: ?u32 = null,
    retry_needed: bool = false, // Set when GOAWAY indicates stream wasn't processed

    pub fn reset(self: *Stream) void {
        self.id = 0;
        self.active = false;
        self.status = 0;
        self.header_count = 0;
        self.end_stream = false;
        self.completed = false;
        self.error_code = null;
        self.retry_needed = false;
        // Don't reset mutex/condition - they're managed by lock/unlock
        // Don't deinit body - reuse capacity
        self.body.items.len = 0;
    }
};

/// Write buffer size - enough for multiple frames
/// Max frame is 16KB + 9 byte header, we allow batching several
const WRITE_BUFFER_SIZE: usize = 32768;

/// HTTP/2 Client State with multiplexing support
pub const Http2Client = struct {
    allocator: std.mem.Allocator,
    next_stream_id: u31 = 1, // Client uses odd stream IDs
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = mod.INITIAL_WINDOW_SIZE,
    max_frame_size: u32 = mod.MAX_FRAME_SIZE_DEFAULT,
    connection_window: i64 = mod.INITIAL_WINDOW_SIZE,
    settings_acked: bool = false,
    preface_sent: bool = false,
    goaway_received: bool = false, // GOAWAY received - no new streams allowed

    /// Pending streams for multiplexing (fixed-size, no allocation)
    streams: [MAX_STREAMS]Stream = [_]Stream{.{}} ** MAX_STREAMS,
    /// Count of in-flight streams - MUST be atomic
    /// Incremented under write_mutex, decremented under stream.mutex (different mutexes!)
    /// Without atomic: concurrent decrements cause lost updates → count goes negative
    active_streams: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Write buffer for frame batching (enables safe multiplexing)
    /// Frames are queued here, then flushed in one TLS write
    write_buffer: [WRITE_BUFFER_SIZE]u8 = undefined,
    write_len: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (&self.streams) |*s| {
            // Only deinit if body was actually allocated
            if (s.body.capacity > 0) {
                s.body.deinit(self.allocator);
            }
        }
    }

    // =========================================================================
    // Write Queue - enables safe multiplexing by batching frame writes
    // =========================================================================

    /// Queue data to write buffer (no IO, just memcpy)
    fn queueWrite(self: *Self, data: []const u8) !void {
        if (self.write_len + data.len > WRITE_BUFFER_SIZE) {
            return error.WriteBufferFull;
        }
        @memcpy(self.write_buffer[self.write_len..][0..data.len], data);
        self.write_len += data.len;
    }

    /// Flush all queued frames to socket in single TLS write
    /// This is the ONLY place that writes to the socket, ensuring serialization
    pub fn flush(self: *Self, sock: *UltraSock, io: Io) !void {
        if (self.write_len == 0) return;

        _ = try sock.send_all(io, self.write_buffer[0..self.write_len]);
        self.write_len = 0;
    }

    /// Check if there's queued data to flush
    pub fn hasPendingWrites(self: *const Self) bool {
        return self.write_len > 0;
    }

    // =========================================================================
    // Connection Setup
    // =========================================================================

    /// Establish HTTP/2 connection over UltraSock
    /// Queues and flushes connection preface, then reads server settings
    pub fn connect(self: *Self, sock: *UltraSock, io: Io) !void {
        // Build connection preface + SETTINGS frame
        var preface_buf: [64]u8 = undefined;
        @memcpy(preface_buf[0..mod.CONNECTION_PREFACE.len], mod.CONNECTION_PREFACE);

        const settings = [_]frame.SettingsEntry{
            .{ .id = mod.Settings.MAX_CONCURRENT_STREAMS, .value = MAX_STREAMS },
            .{ .id = mod.Settings.INITIAL_WINDOW_SIZE, .value = mod.INITIAL_WINDOW_SIZE },
            .{ .id = mod.Settings.MAX_FRAME_SIZE, .value = mod.MAX_FRAME_SIZE_DEFAULT },
        };

        var settings_buf: [64]u8 = undefined;
        const settings_len = try frame.FrameBuilder.settings(&settings_buf, &settings);

        const total_len = mod.CONNECTION_PREFACE.len + settings_len;
        @memcpy(preface_buf[mod.CONNECTION_PREFACE.len..][0..settings_len], settings_buf[0..settings_len]);

        // Queue and flush immediately (must send before reading server settings)
        try self.queueWrite(preface_buf[0..total_len]);
        try self.flush(sock, io);
        self.preface_sent = true;

        log.debug("HTTP/2 connection preface sent", .{});
        try self.readServerSettings(sock, io);
    }

    /// Queue HTTP/2 request frames, returns stream ID
    /// Frames are queued to write buffer - caller must call flush() to send
    /// Can be called multiple times before flushing (multiplexing)
    pub fn sendRequest(
        self: *Self,
        method: []const u8,
        path: []const u8,
        authority: []const u8,
        body: ?[]const u8,
    ) !u31 {
        // Don't accept new streams after GOAWAY
        if (self.goaway_received) {
            return error.ConnectionGoaway;
        }

        // Find free stream slot
        const slot = self.findFreeSlot() orelse return error.TooManyStreams;

        const stream_id = self.nextStreamId();
        self.streams[slot].id = stream_id;
        self.streams[slot].active = true;
        self.streams[slot].end_stream = false;
        self.streams[slot].status = 0;
        self.streams[slot].header_count = 0;
        self.streams[slot].body.items.len = 0;
        self.streams[slot].completed = false;
        self.streams[slot].error_code = null;
        _ = self.active_streams.fetchAdd(1, .acq_rel);

        log.debug("Queueing HTTP/2 request: method={s}, path={s}, stream={d}, slot={d}", .{
            method, path, stream_id, slot,
        });

        const end_stream = (body == null);

        var hpack_buf: [4096]u8 = undefined;
        const hpack_len = try hpack.Hpack.encodeRequest(
            &hpack_buf,
            method,
            path,
            authority,
            &[_]hpack.Header{},
        );

        var frame_buf: [4096]u8 = undefined;
        const headers_len = try frame.FrameBuilder.headers(
            &frame_buf,
            stream_id,
            hpack_buf[0..hpack_len],
            end_stream,
        );

        // Queue HEADERS frame (no IO here)
        try self.queueWrite(frame_buf[0..headers_len]);

        // Queue DATA frames if body present
        if (body) |data| {
            try self.queueData(stream_id, data, true);
        }

        return stream_id;
    }

    /// Queue DATA frames to write buffer (no IO)
    fn queueData(
        self: *Self,
        stream_id: u31,
        data: []const u8,
        end_stream: bool,
    ) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_size = @min(data.len - offset, mod.MAX_FRAME_SIZE_DEFAULT);
            const is_last = (offset + chunk_size >= data.len) and end_stream;

            var frame_buf: [mod.MAX_FRAME_SIZE_DEFAULT + 9]u8 = undefined;
            const frame_len = try frame.FrameBuilder.data(
                &frame_buf,
                stream_id,
                data[offset..][0..chunk_size],
                is_last,
            );

            try self.queueWrite(frame_buf[0..frame_len]);
            offset += chunk_size;
        }
    }

    /// Read response for a specific stream (blocks until stream completes)
    /// Handles frame demuxing - frames for other streams are routed correctly
    ///
    /// WARNING: This is for SINGLE-STREAM connections only (fresh, non-pooled).
    /// For multiplexed connections, use H2PooledConnection.awaitResponse() instead,
    /// which uses the dedicated readerTask to properly dispatch frames to streams.
    /// Using this function on a pooled connection WILL cause frame corruption.
    ///
    /// Internal function - prefer H2PooledConnection.awaitResponse() for pool usage.
    pub fn readResponse(
        self: *Self,
        sock: *UltraSock,
        io: Io,
        stream_id: u31,
    ) !Response {
        const slot = self.findStreamSlot(stream_id) orelse return error.StreamNotFound;

        var recv_buf: [mod.MAX_FRAME_SIZE_DEFAULT + 9]u8 = undefined;

        // Read frames until our stream is complete
        while (!self.streams[slot].end_stream) {
            try self.readAndRouteFrame(sock, io, &recv_buf);
        }

        // Build response from stream state
        const response = Response{
            .status = self.streams[slot].status,
            .headers = self.streams[slot].headers,
            .header_count = self.streams[slot].header_count,
            .body = self.streams[slot].body,
            .allocator = self.allocator,
        };

        // Clear stream slot (but don't deinit body - it's moved to response)
        self.streams[slot].active = false;
        self.streams[slot].body = .{}; // Reset to empty (ownership transferred)
        _ = self.active_streams.fetchSub(1, .acq_rel);

        return response;
    }

    /// Read and route a single frame to the appropriate stream
    fn readAndRouteFrame(self: *Self, sock: *UltraSock, io: Io, recv_buf: *[mod.MAX_FRAME_SIZE_DEFAULT + 9]u8) !void {
        // Read frame header
        var header_buf: [9]u8 = undefined;
        var header_read: usize = 0;
        while (header_read < 9) {
            const n = try sock.recv(io, header_buf[header_read..]);
            if (n == 0) return error.ConnectionClosed;
            header_read += n;
        }

        const fh = try frame.FrameHeader.parse(&header_buf);
        const frame_type = frame.FrameType.fromU8(fh.frame_type);

        // TigerStyle: Validate frame length before reading
        // HTTP/2 default max frame size is 16384, reject corrupt frames
        if (fh.length > mod.MAX_FRAME_SIZE_DEFAULT) {
            log.err("Invalid frame length: {d} > {d} (max)", .{ fh.length, mod.MAX_FRAME_SIZE_DEFAULT });
            return error.FrameTooLarge;
        }

        // Read payload
        var payload: []const u8 = &.{};
        if (fh.length > 0) {
            var payload_read: usize = 0;
            while (payload_read < fh.length) {
                const n = try sock.recv(io, recv_buf[payload_read..fh.length]);
                if (n == 0) return error.ConnectionClosed;
                payload_read += n;
            }
            payload = recv_buf[0..fh.length];
        }

        // Route frame to correct stream or handle connection-level frames
        const ft = frame_type orelse return;

        switch (ft) {
            .headers => try self.handleHeaders(fh, payload),
            .data => try self.handleData(sock, io, fh, payload),
            .settings => try self.handleSettings(sock, io, fh),
            .window_update => self.handleWindowUpdate(fh, payload),
            .ping => try self.handlePing(sock, io, fh, payload),
            .goaway => return error.ConnectionGoaway,
            .rst_stream => try self.handleRstStream(fh),
            else => {},
        }
    }

    fn handleHeaders(self: *Self, fh: frame.FrameHeader, payload: []const u8) !void {
        const slot = self.findStreamSlot(fh.stream_id) orelse return;

        self.streams[slot].header_count = try hpack.Hpack.decodeHeaders(
            payload,
            &self.streams[slot].headers,
        );
        self.streams[slot].status = hpack.Hpack.getStatus(
            self.streams[slot].headers[0..self.streams[slot].header_count],
        ) orelse 0;

        if (fh.isEndStream()) {
            self.streams[slot].end_stream = true;
        }

        log.debug("HEADERS stream={d} status={d} end={}", .{
            fh.stream_id, self.streams[slot].status, self.streams[slot].end_stream
        });
    }

    fn handleData(self: *Self, sock: *UltraSock, io: Io, fh: frame.FrameHeader, payload: []const u8) !void {
        const slot = self.findStreamSlot(fh.stream_id) orelse return;

        try self.streams[slot].body.appendSlice(self.allocator, payload);

        if (fh.isEndStream()) {
            self.streams[slot].end_stream = true;
        }

        // Flow control: send WINDOW_UPDATE
        if (fh.length > 0) {
            var conn_wu_buf: [13]u8 = undefined;
            const conn_wu_len = try frame.FrameBuilder.windowUpdate(&conn_wu_buf, 0, fh.length);
            _ = try sock.send_all(io, conn_wu_buf[0..conn_wu_len]);

            var stream_wu_buf: [13]u8 = undefined;
            const stream_wu_len = try frame.FrameBuilder.windowUpdate(&stream_wu_buf, fh.stream_id, fh.length);
            _ = try sock.send_all(io, stream_wu_buf[0..stream_wu_len]);
        }

        log.debug("DATA stream={d} len={d} end={}", .{ fh.stream_id, fh.length, self.streams[slot].end_stream });
    }

    fn handleSettings(self: *Self, sock: *UltraSock, io: Io, fh: frame.FrameHeader) !void {
        if (!fh.isAck()) {
            var ack_buf: [9]u8 = undefined;
            const ack_len = try frame.FrameBuilder.settingsAck(&ack_buf);
            _ = try sock.send_all(io, ack_buf[0..ack_len]);
        }
        _ = self;
    }

    fn handleWindowUpdate(self: *Self, fh: frame.FrameHeader, payload: []const u8) void {
        if (fh.stream_id == 0 and payload.len >= 4) {
            const increment = std.mem.readInt(u32, payload[0..4], .big);
            self.connection_window += increment;
        }
    }

    fn handlePing(self: *Self, sock: *UltraSock, io: Io, fh: frame.FrameHeader, payload: []const u8) !void {
        _ = self;
        if (!fh.isAck() and payload.len >= 8) {
            var ping_buf: [17]u8 = undefined;
            const ping_len = try frame.FrameBuilder.ping(&ping_buf, payload[0..8].*, true);
            _ = try sock.send_all(io, ping_buf[0..ping_len]);
        }
    }

    fn handleRstStream(self: *Self, fh: frame.FrameHeader) !void {
        const slot = self.findStreamSlot(fh.stream_id) orelse return;
        log.warn("Stream {d} reset by server", .{fh.stream_id});
        self.streams[slot].end_stream = true;
        self.streams[slot].status = 0; // Mark as failed
    }

    /// Close HTTP/2 connection gracefully
    pub fn close(self: *Self, sock: *UltraSock, io: Io) !void {
        var buf: [17]u8 = undefined;
        const len = try frame.FrameBuilder.goaway(&buf, self.next_stream_id -| 2, frame.ErrorCode.NO_ERROR);
        _ = try sock.send_all(io, buf[0..len]);
    }

    /// Get count of active streams
    pub inline fn activeStreamCount(self: *Self) usize {
        return self.active_streams.load(.acquire);
    }

    // --- Stream ID management ---

    /// Get next stream ID and increment counter (client uses odd IDs)
    pub inline fn nextStreamId(self: *Self) u31 {
        const id = self.next_stream_id;
        self.next_stream_id += 2;
        return id;
    }

    /// Find a free stream slot (public for multiplexing)
    pub fn findFreeSlot(self: *Self) ?usize {
        for (self.streams, 0..) |s, i| {
            if (!s.active) return i;
        }
        return null;
    }

    pub fn findStreamSlot(self: *Self, stream_id: u31) ?usize {
        for (self.streams, 0..) |s, i| {
            if (s.active and s.id == stream_id) return i;
        }
        return null;
    }

    fn readServerSettings(self: *Self, sock: *UltraSock, io: Io) !void {
        var recv_buf: [256]u8 = undefined;

        var header_read: usize = 0;
        while (header_read < 9) {
            const n = try sock.recv(io, recv_buf[header_read..9]);
            if (n == 0) return error.ConnectionClosed;
            header_read += n;
        }

        const fh = try frame.FrameHeader.parse(recv_buf[0..9]);

        if (frame.FrameType.fromU8(fh.frame_type) != .settings) {
            log.warn("Expected SETTINGS, got frame type {d}", .{fh.frame_type});
            return error.ProtocolError;
        }

        if (fh.length > 0) {
            var payload_read: usize = 0;
            while (payload_read < fh.length) {
                const n = try sock.recv(io, recv_buf[9 + payload_read .. 9 + fh.length]);
                if (n == 0) return error.ConnectionClosed;
                payload_read += n;
            }

            var offset: usize = 0;
            while (offset + 6 <= fh.length) {
                const id = std.mem.readInt(u16, recv_buf[9 + offset ..][0..2], .big);
                const value = std.mem.readInt(u32, recv_buf[9 + offset + 2 ..][0..4], .big);
                offset += 6;

                switch (id) {
                    mod.Settings.MAX_CONCURRENT_STREAMS => self.max_concurrent_streams = value,
                    mod.Settings.INITIAL_WINDOW_SIZE => self.initial_window_size = value,
                    mod.Settings.MAX_FRAME_SIZE => self.max_frame_size = value,
                    else => {},
                }
            }
        }

        var ack_buf: [9]u8 = undefined;
        const ack_len = try frame.FrameBuilder.settingsAck(&ack_buf);
        _ = try sock.send_all(io, ack_buf[0..ack_len]);

        self.settings_acked = true;
        log.debug("HTTP/2 SETTINGS exchanged, max_streams={d}", .{self.max_concurrent_streams});
    }

    // =========================================================================
    // Multiplexing: Dedicated reader for concurrent streams
    // =========================================================================
    /// Async reader task for multiplexing.
    /// Reads frames and dispatches to correct stream, signals completion.
    /// Runs until shutdown requested or connection error.
    /// Spawned via Io.async() - yields during I/O waits.
    pub fn readerTask(
        self: *Self,
        sock: *UltraSock,
        shutdown_requested: *bool,
        reader_running: *std.atomic.Value(bool),
        state: *State,
        goaway_received: *bool,
        io: Io,
    ) void {
        log.debug("readerTask: started, active_streams={d}", .{self.active_streams.load(.acquire)});
        defer {
            // CRITICAL: Capture shutdown state BEFORE any other operations
            // After signalAllStreams: request() wakes -> release() -> deinitAsync() sets shutdown_requested=true
            const was_clean_shutdown = shutdown_requested.*;
            log.debug("readerTask: exiting, shutdown_requested={}", .{was_clean_shutdown});

            // On unclean shutdown (GOAWAY, error): close socket, mark dead
            // Only send close_notify if socket is still connected (TLS state valid)
            // If backend already closed, TLS cipher state may be corrupt - skip close_notify
            if (!was_clean_shutdown) {
                state.* = .dead;
                if (sock.connected) {
                    sock.sendCloseNotify(io);
                }
                sock.closeSocketOnly();
                log.debug("readerTask: closed socket, marked dead", .{});
            }

            // Now signal waiting streams and update state
            goaway_received.* = self.goaway_received;
            self.signalAllStreams(io);
            reader_running.store(false, .release);
        }

        var recv_buf: [mod.MAX_FRAME_SIZE_DEFAULT + 9]u8 = undefined;

        while (!shutdown_requested.*) {
            // Read frame header (9 bytes) - loop to handle partial reads
            // Use 5 second timeout to detect dead connections
            const RECV_TIMEOUT_MS: u32 = 5000;
            var header_buf: [9]u8 = undefined;
            var header_read: usize = 0;
            log.debug("Reader: waiting for frame header...", .{});
            while (header_read < 9) {
                const n = sock.recvWithTimeout(io, header_buf[header_read..], RECV_TIMEOUT_MS) catch |err| {
                    // Check shutdown first
                    if (shutdown_requested.*) {
                        log.debug("Reader: shutdown requested during recv", .{});
                        return;
                    }

                    // Timeout with no active streams - exit cleanly (connection idle)
                    if (err == error.Timeout) {
                        if (self.active_streams.load(.acquire) == 0) {
                            log.debug("Reader: timeout with no active streams, exiting", .{});
                            return;
                        }
                        // Active streams waiting - keep trying
                        log.debug("Reader: timeout but {d} streams active, continuing", .{self.active_streams.load(.acquire)});
                        continue;
                    }

                    // Active streams or socket truly dead - exit reader
                    log.debug("Reader: recv failed: {}, active_streams={}, connected={}", .{ err, self.active_streams.load(.acquire), sock.connected });
                    return;
                };
                if (n == 0) {
                    log.debug("Reader: connection closed during header read", .{});
                    return;
                }
                header_read += n;
            }
            log.debug("Reader: got frame header, parsing...", .{});

            const fh = frame.FrameHeader.parse(&header_buf) catch |err| {
                log.debug("Reader: frame header parse failed: {}", .{err});
                return;
            };
            log.debug("Reader: frame type={d}, len={d}, stream={d}", .{ fh.frame_type, fh.length, fh.stream_id });

            if (fh.length > mod.MAX_FRAME_SIZE_DEFAULT) {
                log.err("Frame too large: {d}", .{fh.length});
                return;
            }

            // Read payload - loop to handle partial reads
            if (fh.length > 0) {
                var payload_read: usize = 0;
                while (payload_read < fh.length) {
                    const n = sock.recvWithTimeout(io, recv_buf[payload_read..fh.length], RECV_TIMEOUT_MS) catch |err| {
                        if (err == error.Timeout) {
                            log.debug("Reader: payload timeout, continuing", .{});
                            continue;
                        }
                        log.debug("Reader payload recv error: {}", .{err});
                        return;
                    };
                    if (n == 0) {
                        log.debug("Reader: connection closed during payload read", .{});
                        return;
                    }
                    payload_read += n;
                }
            }

            const payload = recv_buf[0..fh.length];

            // Dispatch frame to correct stream (per-stream mutex in dispatchFrame)
            const dispatch_result = self.dispatchFrame(fh, payload, io);

            dispatch_result catch |err| {
                if (err == error.ConnectionGoaway) {
                    log.debug("Reader: received GOAWAY, exiting", .{});
                    return;
                }
                log.debug("Frame dispatch error: {}", .{err});
            };
        }
    }

    /// Dispatch a frame to the correct stream
    fn dispatchFrame(self: *Self, fh: frame.FrameHeader, payload: []const u8, io: Io) !void {
        const ft = frame.FrameType.fromU8(fh.frame_type) orelse return;

        switch (ft) {
            .headers => {
                if (self.findStreamSlot(fh.stream_id)) |slot| {
                    // Lock per-stream mutex for atomic update+signal
                    self.streams[slot].mutex.lock(io) catch return;
                    defer self.streams[slot].mutex.unlock(io);

                    self.streams[slot].header_count = hpack.Hpack.decodeHeaders(
                        payload,
                        &self.streams[slot].headers,
                    ) catch 0;
                    self.streams[slot].status = hpack.Hpack.getStatus(
                        self.streams[slot].headers[0..self.streams[slot].header_count],
                    ) orelse 0;

                    if (fh.isEndStream()) {
                        self.streams[slot].end_stream = true;
                        self.streams[slot].completed = true;
                        self.streams[slot].condition.signal(io);
                    }
                }
            },
            .data => {
                if (self.findStreamSlot(fh.stream_id)) |slot| {
                    // Lock per-stream mutex for atomic update+signal
                    self.streams[slot].mutex.lock(io) catch return;
                    defer self.streams[slot].mutex.unlock(io);

                    self.streams[slot].body.appendSlice(self.allocator, payload) catch {};

                    if (fh.isEndStream()) {
                        self.streams[slot].end_stream = true;
                        self.streams[slot].completed = true;
                        self.streams[slot].condition.signal(io);
                    }
                }
            },
            .rst_stream => {
                if (self.findStreamSlot(fh.stream_id)) |slot| {
                    // Lock per-stream mutex for atomic update+signal
                    self.streams[slot].mutex.lock(io) catch return;
                    defer self.streams[slot].mutex.unlock(io);

                    if (payload.len >= 4) {
                        self.streams[slot].error_code = std.mem.readInt(u32, payload[0..4], .big);
                    }
                    self.streams[slot].completed = true;
                    self.streams[slot].condition.signal(io);
                }
            },
            .goaway => {
                // GOAWAY contains: last_stream_id (4 bytes) + error_code (4 bytes)
                // Per RFC 7540: streams > last_stream_id were NOT processed, retry immediately
                // Streams <= last_stream_id might complete, let them wait for response or timeout
                if (payload.len >= 4) {
                    const last_stream_id = std.mem.readInt(u32, payload[0..4], .big);
                    log.debug("GOAWAY received: last_stream_id={d}", .{last_stream_id});

                    // Signal streams that won't be processed (ID > last_stream_id) for retry
                    // Also count remaining active streams that might still complete
                    var remaining_active: u32 = 0;
                    for (&self.streams) |*stream| {
                        if (stream.active and !stream.completed) {
                            if (stream.id > last_stream_id) {
                                // Lock per-stream mutex for atomic update+signal
                                stream.mutex.lock(io) catch continue;
                                log.debug("GOAWAY: signaling stream {d} for retry", .{stream.id});
                                stream.retry_needed = true;
                                stream.completed = true;
                                stream.condition.signal(io);
                                stream.mutex.unlock(io);
                            } else {
                                remaining_active += 1;
                            }
                        }
                    }

                    // Mark that we received GOAWAY - no new streams allowed
                    self.goaway_received = true;
                    log.debug("GOAWAY: set goaway_received=true, active_streams={d}, remaining={d}", .{ self.active_streams.load(.acquire), remaining_active });

                    // FAST EXIT: If no streams are waiting for completion, exit immediately
                    // instead of waiting for read timeout. This prevents 1-2s delay on retry.
                    if (remaining_active == 0) {
                        log.debug("GOAWAY: no remaining streams, exiting immediately", .{});
                        return error.ConnectionGoaway;
                    }
                    // Continue reading - remaining streams <= last_stream_id may still complete
                } else {
                    // Malformed GOAWAY - signal all and exit
                    self.signalAllStreamsUnlocked(io);
                    return error.ConnectionGoaway;
                }
            },
            .window_update => {
                if (fh.stream_id == 0 and payload.len >= 4) {
                    const increment = std.mem.readInt(u32, payload[0..4], .big);
                    self.connection_window += @intCast(increment & 0x7FFFFFFF);
                }
            },
            .settings => {
                if (!fh.isAck()) {
                    self.settings_acked = true;
                }
            },
            else => {},
        }
    }

    /// Signal all active streams with per-stream mutexes
    pub fn signalAllStreams(self: *Self, io: Io) void {
        for (&self.streams) |*stream| {
            if (stream.active and !stream.completed) {
                stream.mutex.lock(io) catch continue;
                stream.retry_needed = true;
                stream.completed = true;
                stream.condition.signal(io);
                stream.mutex.unlock(io);
            }
        }
    }

    /// Signal all active streams (unlocked version for use when mutexes already held)
    fn signalAllStreamsUnlocked(self: *Self, io: Io) void {
        for (&self.streams) |*stream| {
            if (stream.active and !stream.completed) {
                stream.mutex.lock(io) catch continue;
                stream.retry_needed = true;
                stream.completed = true;
                stream.condition.signal(io);
                stream.mutex.unlock(io);
            }
        }
    }
};

/// HTTP/2 Response
pub const Response = struct {
    status: u16,
    headers: [32]hpack.Header,
    header_count: usize,
    body: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.body.deinit(self.allocator);
    }

    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers[0..self.header_count]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }

    pub inline fn getBody(self: *const Response) []const u8 {
        return self.body.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "http2 client init" {
    var client = Http2Client.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectEqual(@as(u31, 1), client.next_stream_id);
    try std.testing.expectEqual(false, client.preface_sent);
    try std.testing.expectEqual(@as(usize, 0), client.active_streams.load(.acquire));
}

test "http2 client stream slot management" {
    var client = Http2Client.init(std.testing.allocator);
    defer client.deinit();

    // Initially all slots free
    try std.testing.expectEqual(@as(?usize, 0), client.findFreeSlot());

    // Allocate a stream
    client.streams[0].active = true;
    client.streams[0].id = 1;

    try std.testing.expectEqual(@as(?usize, 1), client.findFreeSlot());
    try std.testing.expectEqual(@as(?usize, 0), client.findStreamSlot(1));
    try std.testing.expectEqual(@as(?usize, null), client.findStreamSlot(3));
}

test "http2 client max streams" {
    var client = Http2Client.init(std.testing.allocator);
    defer client.deinit();

    // Fill all slots
    for (&client.streams) |*s| {
        s.active = true;
    }

    try std.testing.expectEqual(@as(?usize, null), client.findFreeSlot());
}
