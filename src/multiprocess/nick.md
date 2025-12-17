⏺ I see the debug logging is already there (line 383). The key diagnostic is w.end - if this is non-zero, there's unflushed data.

  Summary of Key Files

  | File                                  | Purpose                                            |
  |---------------------------------------|----------------------------------------------------|
  | src/multiprocess/proxy.zig            | Connection pooling to backends, response streaming |
  | src/multiprocess/connection_reuse.zig | Rules for when backend connections can be pooled   |
  | src/memory/simple_connection_pool.zig | Per-worker connection pool                         |
  | vendor/zzz.io/src/http/server.zig     | HTTP server (modified to share writer)             |
  | vendor/zzz.io/src/http/response.zig   | Response writing with Server: zzz header           |

  Recommended Fix

  Add an assertion to catch the issue. In server.zig, after line 383:

  .responded => {
      log.debug("[ZZZ] .responded w.end={d} keepalive={d}", .{ w.end, keepalive_count });
      // ADD THIS: Assert buffer is empty
      if (w.end != 0) {
          log.err("[ZZZ] BUG: w.end={d} after .responded - unflushed data!", .{w.end});
          // Force flush to clear buffer
          w.flush() catch |e| break :http_loop e;
      }
      // ... rest of code

  Also enable debug logging in main_multiprocess.zig:

  pub const std_options: std.Options = .{
      .log_level = .debug,  // Change from .warn
  };

  This will show if w.end is non-zero when handlers return .responded, which would prove there's unflushed data causing duplicate responses.

  Would you like me to apply this debugging change so we can identify the exact cause?


---

⏺ Excellent question. Let me analyze the design.

  The Current Approach

  // server.zig - stack-allocated buffer, lives for entire connection
  var bufw: [8192]u8 = undefined;
  var writer = stream.writer(io, &bufw);
  const w = &writer.interface;

  // Passed to handler via context
  const context: Context = .{
      // ...
      .writer = w,  // Pointer to same writer
  };

  Memory Safety: ✓ OK

  The buffer bufw lives on the stack of doWork(), and the handler runs synchronously within doWork(). So the lifetime is correct - the buffer exists while the handler uses it.

  Shared State: ⚠️ Potential Issues

  The problem is ownership semantics. You have two potential writers to the same buffer:

  1. Server (in .respond state): provision.response.headers_into_writer(w, ...)
  2. Handler (proxy): response.headers_into_writer_opts(ctx.writer, ...)

  The contract is:
  - Return .standard → Server writes
  - Return .responded → Handler already wrote

  But there's no enforcement. Nothing prevents:
  - Handler writes, returns .standard → Double write!
  - Handler partially writes, returns .responded → Corrupt state!

  A Safer Design

  Consider tracking writer usage explicitly:

  // In Context, track if writer was used
  pub const Context = struct {
      // ...
      writer: *std.Io.Writer,
      writer_used: *bool,  // Track if handler touched it
  };

  // In server.zig
  var writer_used: bool = false;
  const context: Context = .{
      // ...
      .writer = w,
      .writer_used = &writer_used,
  };

  // After handler returns
  switch (next_respond) {
      .standard => {
          if (writer_used) {
              log.err("BUG: Handler used writer but returned .standard!");
              break :http_loop;
          }
          state = .respond;
      },
      .responded => {
          if (w.end != 0) {
              log.err("BUG: Handler returned .responded with unflushed data!");
              // Force flush or close connection
          }
          // ...
      },
  }

  Alternative: Writer Wrapper

  A cleaner approach - wrap the writer to enforce the contract:

  pub const ResponseWriter = struct {
      inner: *std.Io.Writer,
      committed: bool = false,

      pub fn write(self: *ResponseWriter, data: []const u8) !void {
          self.committed = true;
          try self.inner.writeAll(data);
      }

      pub fn finish(self: *ResponseWriter) !Respond {
          try self.inner.flush();
          std.debug.assert(self.inner.end == 0);
          return .responded;
      }
  };

  This makes the contract explicit - once you use the writer, you MUST return .responded.

  The Real Question

  Is the current approach causing your bug? Likely yes. The shared writer without validation means:

  1. If flush doesn't fully complete for some reason
  2. Or if there's leftover data from a previous request (shouldn't happen but...)
  3. Or if there's a code path that writes without proper flush

  ...you get "unsolicited responses."

  Want me to add validation/assertions to catch the exact issue?


----


- Considered it acceptable to require users to handle this at a higher level

⏺ Great question! Here's how you'd handle it at a higher level without patching std.Io:

  1. Pre-validation with poll() (what we did)
  // Check before using pooled connection
  if (sock.hasStaleData()) {
      // Discard and get fresh connection
      sock.close_blocking();
      sock = createNewConnection();
  }
  Problem: Race condition - connection can die between check and use.

  2. Bypass std.Io entirely (POSIX calls)
  // Use raw POSIX for the error-prone paths
  std.posix.write(fd, data) catch |err| {
      // Handle error gracefully
      return error.ConnectionFailed;
  };
  This is what we were implementing - works but loses async benefits.

  3. Connection TTL (time-to-live)
  // Don't pool connections longer than X seconds
  if (pooled_connection.age > 5_seconds) {
      discard_connection();
  }
  Reduces race window but doesn't eliminate it.

  4. Catch-and-retry pattern
  // Can't catch panics in Zig, but you could...
  // - Use a subprocess per request (expensive)
  // - Use signal handlers (platform-specific, fragile)

  5. Don't pool connections
  const ENABLE_POOLING = false; // Just disable it
  Simple but loses the 99% pool hit rate performance benefit.

  The fundamental issue is that Zig's panic philosophy doesn't align well with connection pooling semantics. Panics are meant for "this should never happen" situations, but connection pooling creates legitimate scenarios where sockets become invalid.

  That's why patching std.Io is the cleanest solution - it fixes the root cause rather than working around it.

  Let me now test if our patches work. First, let me rebuild and run the load balancer.

---

⏺ Good question. Here's my honest assessment:

  Arguments against acceptance:

  1. Zig's philosophy - These errors are intentionally treated as "programmer bugs" because in Zig's ownership model, if you have an fd, it should be valid
  2. Masks real bugs - Silently handling BADF could hide actual programming errors in other codebases
  3. Connection pooling is "your problem" - They might argue pooling should be implemented differently (e.g., with explicit health checks, not error recovery)

  Arguments for acceptance:

  1. Real-world use case - Connection pooling is standard practice (nginx, HAProxy, every database driver)
  2. Race conditions are unavoidable - Remote peer can close connection at any time; no amount of pre-checking eliminates this
  3. Panic is too harsh - Returning an error lets the caller decide how to handle it; panic forces crash
  4. Consistency - Some errors already return (CONNRESET, TIMEDOUT) while similar ones panic

  How I'd frame the PR:

  Title: Return errors instead of panicking for socket errors that can occur in connection pooling

  Connection pooling is a common pattern where sockets are reused across requests.
  The remote peer can close the connection at any time, causing BADF/NOTCONN/CONNABORTED
  on the next operation. These are not programmer bugs - they're legitimate race conditions.

  Current behavior: panic in debug mode
  Proposed behavior: return error (ConnectionResetByPeer, SocketUnconnected, etc.)

  Likely outcome: 50/50. They might suggest an alternative like a separate "pooled socket" abstraction or ask you to use raw syscalls for pooling scenarios.

  Want me to help prepare a proper PR with tests?


---

⏺ The race condition is inherent to TCP and network programming:

  Timeline of a "stale connection" race:

  Time 0:  Request completes, connection returned to pool ✓
  Time 1:  Backend server decides to close (idle timeout, restart, etc.)
  Time 2:  Backend sends FIN packet → travels over network
  Time 3:  FIN arrives at load balancer's kernel
  Time 4:  Kernel marks socket as half-closed
  Time 5:  Our code: hasStaleData() check → returns false (no data yet!)
  Time 6:  Kernel processes FIN, socket now invalid
  Time 7:  Our code: write() → BADF/NOTCONN/EPIPE

  The problem is between Time 5 and Time 7 - we checked, it looked fine, but then the kernel state changed.

  Why poll()/hasStaleData() can't prevent this:

  - poll() tells you the current state
  - The state can change immediately after poll returns
  - Network packets arrive asynchronously
  - Kernel processes them asynchronously

  Even with perfect checking:

  if (!sock.hasStaleData()) {      // ← Looks good!
      // ← FIN processed HERE by kernel
      sock.write(data);            // ← BOOM: socket now invalid
  }

  This is why:
  - Every production HTTP client has retry logic
  - Every database driver has reconnection logic
  - nginx/HAProxy handle these errors gracefully

  The only way to truly avoid this would be to lock the kernel from processing network events while you use the socket - which is obviously impossible.

  The fix is error handling, not prevention.



---



⏺ Yes, there's something they could point to:

  Our pool has no TTL/lifecycle management:

  // Our pool just stores sockets indefinitely
  sockets: [MAX_IDLE_CONNS]?UltraSock
  // No timestamp tracking
  // No max age
  // No idle timeout

  What production pools do:

  const PooledConnection = struct {
      socket: UltraSock,
      created_at: i64,      // When connection was established
      last_used_at: i64,    // When last request completed
      request_count: u32,   // How many requests on this connection
  };

  // On getConnection():
  if (now - conn.last_used_at > MAX_IDLE_SECONDS) {
      // Close stale connection, don't use it
  }
  if (now - conn.created_at > MAX_CONNECTION_AGE) {
      // Connection too old, close it
  }

  So the Zig team could say:

  "You're keeping connections indefinitely with no lifecycle management. The backend's keep-alive timeout is probably 60 seconds. After that, the backend closes the connection. You're then trying to use a dead connection. That's your bug, not ours."

  They'd be partially right. Adding TTL would reduce the frequency of stale connections. But even with perfect TTL management, the race still exists - just happens less often.

  The real answer: Both are needed:
  1. TTL management - reduces frequency of staleness (our improvement)
  2. Error handling - handles the unavoidable race (their fix)

  Want me to add TTL tracking to the connection pool?
