//! HTTP/2 Connection - Simplified Single-Responsibility Struct
//!
//! Binary state machine: ready or dead. No lifecycle complexity.
//! Single request() method handles everything: send, spawn reader, await.
//! Per-connection TLS buffers for safe concurrent multiplexing.
//!
//! ## Synchronization Strategy
//!
//! We use atomics for simple counters/flags, mutexes for multi-step operations:
//!
//! | Primitive        | Type    | Why                                          |
//! |------------------|---------|----------------------------------------------|
//! | ref_count        | Atomic  | Single counter, fetchAdd/fetchSub            |
//! | active_streams   | Atomic  | Single counter, concurrent inc/dec           |
//! | reader_running   | Atomic  | Single flag, cmpxchg for race-free spawn     |
//! | write_mutex      | Mutex   | Multi-step: encode → buffer → flush          |
//! | stream.mutex     | Mutex   | Must wait for condition signal               |
//! | stream.condition | CondVar | Sleep until reader signals completion        |
//!
//! **Why not all atomics?**
//! - Atomics: ONE instruction, never blocks (fetchAdd, cmpxchg)
//! - Mutex: Protects MULTIPLE operations as atomic unit
//! - Condition: Lets coroutine SLEEP until signaled
//!
//! Atomics cannot protect multi-step sequences or wait for events.
//! write_mutex ensures encode→buffer→flush completes without interleaving.
//! stream.condition lets request() sleep until reader dispatches response.
//!
//! TigerBeetle style:
//! - Fixed-size arrays, no hidden allocations
//! - Explicit state, no implicit transitions
//! - Mutexes at stable addresses (struct is heap-allocated)
//! - Critical ordering: lock FIRST, spawn SECOND (Io.async yields on contention)
//!
//! Usage:
//!   var conn = try H2Connection.init(sock, allocator);
//!   try conn.connect(io);
//!   const resp = try conn.request("GET", "/api", "backend.com", null, io);
//!   conn.deinitAsync(io);

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.h2_conn);
const tls_log = std.log.scoped(.tls_trace);

const Io = std.Io;
const UltraSock = @import("../ultra_sock.zig").UltraSock;
const TlsOptions = @import("../ultra_sock.zig").TlsOptions;
const config_mod = @import("../../core/config.zig");
const client_mod = @import("client.zig");
const Http2Client = client_mod.Http2Client;
const Response = client_mod.Response;
const h2_mod = @import("mod.zig");
const State = h2_mod.ConnectionState;

// TLS buffer sizes from module constants
const TLS_INPUT_BUFFER_LEN = h2_mod.TLS_INPUT_BUFFER_LEN;
const TLS_OUTPUT_BUFFER_LEN = h2_mod.TLS_OUTPUT_BUFFER_LEN;

/// Simplified HTTP/2 connection with single request() method
pub const H2Connection = struct {
    /// Underlying socket + TLS state
    sock: UltraSock,

    /// HTTP/2 client state (inlined - H2Connection is already heap-allocated)
    h2_client: Http2Client,

    /// Allocator for response bodies
    allocator: std.mem.Allocator,

    /// Binary state machine
    state: State = .ready,

    // Multiplexing mutex (must be at stable address - struct is heap-allocated)
    // CANNOT be atomic: protects multi-step TLS write sequence (encode → buffer → flush)
    // All streams share this - contention is the price of safe multiplexing
    write_mutex: Io.Mutex = .init,

    // Reader task tracking
    // CRITICAL: Use atomic for reader_running to prevent race where two requests
    // both see false and spawn duplicate readers (causes double-close panic)
    reader_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown_requested: bool = false,
    reader_future: ?Io.Future(void) = null,

    // Connection health flags (updated by reader task)
    goaway_received: bool = false,

    // Backend tracking and staleness detection
    backend_idx: u32 = 0,
    last_used_ns: i64 = 0,

    // Reference counting for safe multiplexing
    // Incremented by pool.getOrCreate(), decremented by pool.release()
    // Only destroy when ref_count hits 0
    // CRITICAL: Must be atomic - multiple coroutines may release concurrently
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Per-connection TLS buffers - CRITICAL for concurrent connections!
    // Threadlocal buffers are shared between connections on same thread.
    // Concurrent reads/writes corrupt TLS decryption state.
    tls_input_buffer: [TLS_INPUT_BUFFER_LEN]u8 = undefined,
    tls_output_buffer: [TLS_OUTPUT_BUFFER_LEN]u8 = undefined,

    const Self = @This();

    /// Initialize HTTP/2 connection (doesn't establish session yet)
    /// Caller must call connect() before using request()
    pub fn init(sock: UltraSock, backend_idx: u32, allocator: std.mem.Allocator) !Self {
        return Self{
            .sock = sock,
            .h2_client = Http2Client.init(allocator),
            .allocator = allocator,
            .backend_idx = backend_idx,
            .last_used_ns = currentTimeNs(),
        };
    }

    /// Get current time in nanoseconds (monotonic clock)
    fn currentTimeNs() i64 {
        const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
        return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
    }

    /// Establish HTTP/2 session (send preface, exchange SETTINGS)
    /// Safe to call multiple times - no-op if already connected
    /// Uses per-connection TLS buffers (critical for multiplexing)
    pub fn connect(self: *Self, io: Io) !void {
        const trace = config_mod.isTlsTraceEnabled();

        if (self.state == .dead) {
            if (trace) tls_log.warn("!!! H2 connect: connection already dead for {s}:{}", .{ self.sock.host, self.sock.port });
            return error.ConnectionDead;
        }
        if (self.h2_client.preface_sent) {
            if (trace) tls_log.debug("H2 connect: already established for {s}:{}", .{ self.sock.host, self.sock.port });
            return; // Already connected
        }

        if (trace) tls_log.info(">>> H2 session connect starting: {s}:{}", .{ self.sock.host, self.sock.port });

        // Fix pointers to use per-connection buffers instead of threadlocal
        // Critical: concurrent connections need isolated TLS state
        self.sock.fixPointersWithBuffers(io, &self.tls_input_buffer, &self.tls_output_buffer);

        if (trace) tls_log.debug("  Using per-connection TLS buffers (input={}, output={})", .{ TLS_INPUT_BUFFER_LEN, TLS_OUTPUT_BUFFER_LEN });

        try self.h2_client.connect(&self.sock, io);

        if (trace) {
            tls_log.info("<<< H2 session established: {s}:{}", .{ self.sock.host, self.sock.port });
        } else {
            log.debug("H2 session established", .{});
        }
    }

    /// Single method for complete request/response cycle
    /// Handles: send, reader spawn, await, cleanup
    /// CRITICAL ORDERING: lock stream_mutex FIRST, spawn reader SECOND
    /// Io.async yields when reader tries to lock our mutex (we hold it)
    pub fn request(
        self: *Self,
        method: []const u8,
        path: []const u8,
        host: []const u8,
        body: ?[]const u8,
        io: Io,
    ) !Response {
        const trace = config_mod.isTlsTraceEnabled();

        if (self.state == .dead) {
            if (trace) tls_log.warn("!!! H2 request: connection dead for {s}:{}", .{ self.sock.host, self.sock.port });
            return error.ConnectionDead;
        }

        if (trace) {
            tls_log.info(">>> H2 request: {s} {s} to {s}:{}", .{ method, path, self.sock.host, self.sock.port });
        }

        // STEP 1: Send request (write_mutex protects TLS writes)
        if (trace) tls_log.debug("  H2 step 1: acquiring write_mutex", .{});
        log.debug("request: sending {s} {s}", .{ method, path });
        try self.write_mutex.lock(io);

        // Re-check state after acquiring mutex - connection may have died while waiting
        if (self.state == .dead) {
            self.write_mutex.unlock(io);
            log.debug("request: connection died while waiting for mutex", .{});
            return error.ConnectionDead;
        }

        // Send and flush - unlock mutex on ANY exit (success or error)
        const stream_id = self.h2_client.sendRequest(method, path, host, body) catch |err| {
            self.write_mutex.unlock(io);
            return err;
        };
        if (trace) tls_log.debug("  H2 step 1: flushing stream {d}", .{stream_id});
        self.h2_client.flush(&self.sock, io) catch |err| {
            self.write_mutex.unlock(io);
            return err;
        };
        self.write_mutex.unlock(io);
        if (trace) tls_log.debug("  H2 step 1: sent stream {d}, write_mutex released", .{stream_id});
        log.debug("request: sent stream {d}", .{stream_id});

        // STEP 2: Find our stream slot (just allocated, must exist)
        const slot = self.h2_client.findStreamSlot(stream_id) orelse {
            log.err("Stream {d} not found in slots", .{stream_id});
            return error.StreamNotFound;
        };

        // STEP 3: Spawn reader if needed AFTER send but BEFORE locking mutex
        // Critical ordering:
        // - After send: so reader has data to receive (won't timeout waiting)
        // - Before lock: so when Io.async yields, we don't hold the mutex
        // - Reader might dispatch our frame, but we're not in wait yet
        //   That's OK - completed flag will be set, and our wait loop checks it first
        // spawnReader uses atomic cmpxchg internally - safe to call from multiple coroutines
        if (!self.spawnReader(io)) {
            return error.ConnectionDead;
        }

        // STEP 4: Lock per-stream mutex and wait for completion
        // If reader already set completed=true, the while loop exits immediately
        log.debug("request: about to lock stream {d} mutex, slot {d}", .{ stream_id, slot });
        log.debug("request: locking stream {d} mutex, slot {d}", .{ stream_id, slot });
        try self.h2_client.streams[slot].mutex.lock(io);

        log.debug("request: waiting on stream {d}, slot {d}", .{ stream_id, slot });
        while (!self.h2_client.streams[slot].completed) {
            try self.h2_client.streams[slot].condition.wait(io, &self.h2_client.streams[slot].mutex);
        }

        // STEP 5: Check for stream errors and retry conditions
        if (self.h2_client.streams[slot].retry_needed) {
            log.debug("Stream {d} needs retry (GOAWAY)", .{stream_id});
            self.h2_client.streams[slot].mutex.unlock(io);
            self.h2_client.streams[slot].reset();
            return error.RetryNeeded;
        }

        if (self.h2_client.streams[slot].error_code) |code| {
            log.debug("Stream {d} reset with error {d}", .{ stream_id, code });
            self.h2_client.streams[slot].mutex.unlock(io);
            self.h2_client.streams[slot].reset();
            return error.StreamReset;
        }

        // STEP 6: Build response, transfer ownership
        const response = Response{
            .status = self.h2_client.streams[slot].status,
            .headers = self.h2_client.streams[slot].headers,
            .header_count = self.h2_client.streams[slot].header_count,
            .body = self.h2_client.streams[slot].body,
            .allocator = self.allocator,
        };

        // Transfer body ownership to response, reset slot
        self.h2_client.streams[slot].body = .{};
        self.h2_client.streams[slot].active = false;

        // Atomically decrement active_streams (returns previous value)
        const prev = self.h2_client.active_streams.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0); // Must have had at least 1 active stream

        self.h2_client.streams[slot].mutex.unlock(io);
        self.last_used_ns = currentTimeNs();
        log.debug("request: completed stream {d}, status {d}", .{ stream_id, response.status });
        return response;
    }

    /// Spawn async reader task for frame dispatch
    /// Returns true if reader started, false if connection is dead
    /// Safe to call multiple times - no-op if already running
    /// Uses atomic cmpxchg to prevent race condition where two requests
    /// both spawn readers (causes double-close panic)
    fn spawnReader(self: *Self, io: Io) bool {
        // Atomic compare-and-swap: only proceed if we're the one who set it to true
        // This prevents the race where two requests both see false and spawn readers
        if (self.reader_running.cmpxchgStrong(false, true, .acq_rel, .acquire)) |_| {
            // cmpxchg returned non-null = failed = someone else already set it
            log.debug("spawnReader: already running", .{});
            return true;
        }

        // We won the race - we set reader_running from false to true
        if (self.state == .dead) {
            log.warn("spawnReader: connection dead", .{});
            self.reader_running.store(false, .release);
            return false;
        }
        if (self.goaway_received) {
            log.warn("spawnReader: GOAWAY received", .{});
            self.reader_running.store(false, .release);
            return false;
        }

        log.debug("spawnReader: starting reader task", .{});
        self.shutdown_requested = false;

        // Spawn reader and store future for proper cleanup in deinitAsync
        self.reader_future = Io.async(
            io,
            Http2Client.readerTask,
            .{
                &self.h2_client,
                &self.sock,
                &self.shutdown_requested,
                &self.reader_running,
                &self.state,
                &self.goaway_received,
                io,
            },
        );
        log.debug("spawnReader: Io.async returned, future={?}", .{if (self.reader_future != null) @as(?*anyopaque, @ptrCast(&self.reader_future.?)) else null});

        return true;
    }

    /// Mark connection as dead (no new requests allowed)
    /// Existing requests will fail with error.ConnectionDead
    pub fn markDead(self: *Self) void {
        self.state = .dead;
        log.debug("Connection marked dead", .{});
    }

    /// Check if connection is alive and ready for requests
    pub inline fn isReady(self: *const Self) bool {
        return self.state == .ready and !self.goaway_received;
    }

    /// Clean up resources (async version - waits for reader to exit)
    /// Use when you have Io context (from request handler)
    pub fn deinitAsync(self: *Self, io: Io) void {
        const trace = config_mod.isTlsTraceEnabled();

        if (trace) tls_log.info(">>> H2 deinitAsync starting for {s}:{}", .{ self.sock.host, self.sock.port });

        // Signal reader to stop
        self.shutdown_requested = true;
        if (trace) tls_log.debug("  H2 deinitAsync: shutdown_requested=true", .{});

        // Await reader future if it exists - ensures reader's defer block completes
        if (self.reader_future) |*future| {
            if (trace) tls_log.debug("  H2 deinitAsync: awaiting reader future", .{});

            // Send close_notify to unblock reader from recv()
            // Only if state is not dead (reader hasn't already closed socket)
            if (self.reader_running.load(.acquire) and self.state != .dead) {
                self.sock.sendCloseNotify(io);
            }

            // Properly await the reader task
            _ = future.await(io);
            self.reader_future = null;
            if (trace) tls_log.debug("  H2 deinitAsync: reader future completed", .{});
        }

        // Close socket if reader didn't already
        // When state == .dead, reader already sent close_notify AND closed socket
        if (self.state != .dead) {
            if (trace) tls_log.debug("  H2 deinitAsync: closing socket", .{});
            self.sock.sendCloseNotify(io);
            self.sock.closeSocketOnly();
        } else if (trace) {
            tls_log.debug("  H2 deinitAsync: reader already closed socket, skipping", .{});
        }

        self.h2_client.deinit();

        if (trace) tls_log.info("<<< H2 deinitAsync complete for {s}:{}", .{ self.sock.host, self.sock.port });
    }

    /// Clean up resources (blocking version - for tests/non-async contexts)
    /// WARNING: May leak async closure memory if reader was spawned
    /// Prefer deinitAsync when Io is available
    pub fn deinit(self: *Self) void {
        // Signal reader to stop (it will exit naturally)
        self.shutdown_requested = true;

        // Note: reader_future cleanup skipped - no Io available
        // Acceptable for tests with mock sockets (no real async)

        self.h2_client.deinit();
        self.sock.close_blocking();
    }
};

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
        .connected = true,
        .tls_options = TlsOptions.insecure(),
    };
}

test "H2Connection: initial state" {
    const mock_sock = createMockSocket();
    var conn = try H2Connection.init(mock_sock, 0, std.testing.allocator);
    defer conn.deinit();

    try std.testing.expectEqual(State.ready, conn.state);
    try std.testing.expect(!conn.goaway_received);
    try std.testing.expect(!conn.reader_running.load(.acquire));
    try std.testing.expect(conn.isReady());
}

test "H2Connection: markDead transitions state" {
    const mock_sock = createMockSocket();
    var conn = try H2Connection.init(mock_sock, 0, std.testing.allocator);
    defer conn.deinit();

    try std.testing.expect(conn.isReady());

    conn.markDead();

    try std.testing.expectEqual(State.dead, conn.state);
    try std.testing.expect(!conn.isReady());
}

test "H2Connection: h2_client initialized" {
    const mock_sock = createMockSocket();
    var conn = try H2Connection.init(mock_sock, 0, std.testing.allocator);
    defer conn.deinit();

    try std.testing.expectEqual(@as(u31, 1), conn.h2_client.next_stream_id);
    try std.testing.expect(!conn.h2_client.preface_sent);
}
