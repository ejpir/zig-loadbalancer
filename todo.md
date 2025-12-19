  ---
  Ultrathink Code Review: Load Balancer

  The Soul of This Code

  This is genuinely excellent work. The TigerStyle discipline, cache-line optimization, bitmap health tracking, and
  comptime specialization show deep craft. The ~127 tests demonstrate commitment to correctness.

  But let's think different about what could make this inevitable.

  ---
  🔴 Critical: Missing Functionality

  1. Request Body Forwarding Is Missing

  src/multiprocess/proxy.zig:401-410

  const fmt_str = "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\n" ++
      "Connection: keep-alive\r\n\r\n";

  The proxy only forwards the request line and Host header. POST/PUT bodies are silently dropped. This makes the load
  balancer unusable for any real API that mutates state.

  Suggestion: Stream the client request body through to the backend, respecting Content-Length and Transfer-Encoding.

  ---
  2. Weighted Round-Robin Is a Lie

  src/multiprocess/backend_selector.zig:33

  .round_robin, .weighted_round_robin => self.selectRoundRobin(),

  The weight field exists in BackendServer but is completely ignored. Users who configure weights will get uniform
  distribution and wonder why.

  Suggestion: Either implement it properly (track cumulative weights, select based on weighted probability) or remove the
  enum variant to avoid false promises.

  ---
  3. Sticky Sessions Return Constant Zero

  src/multiprocess/backend_selector.zig:35

  .sticky => 0, // Sticky handled externally via cookies

  This returns backend 0 always, creating a perfect thundering herd. The comment says "handled externally" but there's no
  external handling.

  Suggestion: Either implement proper cookie-based affinity or remove this strategy entirely. A placeholder that directs
  all traffic to one backend is worse than no feature.

  ---
  🟡 Architectural Opportunities

  4. TLS Connections Can't Be Pooled

  src/multiprocess/proxy.zig:990-991

  if (proxy_state.is_tls) {
      proxy_state.can_return_to_pool = false;

  HTTPS backends create a new TLS handshake for every request (~300ms latency). For the 99% of production backends running
   HTTPS, this destroys the connection pooling benefit.

  Why this matters: TLS session resumption exists. The TLS library likely supports it. This is low-hanging fruit that
  could 10x performance for HTTPS backends.

  ---
  5. Health Probes and Circuit Breaker Disagree

  The health probe thread (health.zig) marks backends healthy/unhealthy based on active probes. The circuit breaker
  (circuit_breaker.zig) marks them based on request failures. These two systems don't talk to each other.

  Scenario:
  1. Circuit breaker marks backend 0 unhealthy after 3 failures
  2. Health probe sends GET / and gets 200
  3. Health probe marks backend 0 healthy
  4. Circuit breaker still has consecutive_failures[0] = 3
  5. Next failure immediately re-trips the circuit

  Suggestion: Unify health state ownership. Either:
  - Health probes feed into circuit breaker (call recordSuccess/recordFailure)
  - Or circuit breaker is the health source, probes just accelerate recovery

  ---
  6. Per-Backend Metrics Don't Exist

  src/utils/metrics.zig has global counters only. You can't see:
  - Which backend is slow
  - Which backend is failing
  - Pool hit rate per backend

  Suggestion: Add backend_id label dimension. Even a simple [MAX_BACKENDS]AtomicCounter array would transform
  observability.

  ---
  🟢 Elegance Opportunities

  7. The fixTlsPointersAfterCopy Pattern Is Fragile

  src/multiprocess/proxy.zig:250-251

  proxy_state.sock.fixTlsPointersAfterCopy();
  proxy_state.tls_conn_ptr = proxy_state.sock.getTlsConnection();

  This appears in multiple places and is easy to forget. Forgetting it causes subtle memory corruption.

  Suggestion: Make UltraSock non-copyable by adding:
  pub const UltraSock = struct {
      // ...
      const Self = @This();
      pub usingnamespace struct {
          pub fn clone(_: Self) Self { @compileError("UltraSock must not be copied"); }
      };
  };

  Then pass by pointer everywhere. The type system enforces correctness.

  ---
  8. PRNG Seeding in Hot Path

  src/multiprocess/backend_selector.zig:65-75

  The xorshift PRNG seeds itself from the monotonic clock inside the selectRandomFast function, which runs on every
  request.

  Suggestion: Seed once at BackendSelector creation. The random_state field already exists—initialize it properly in
  WorkerState.init().

  ---
  9. Redundant Conditional After Assertion

  src/multiprocess/backend_selector.zig:58-59

  std.debug.assert(healthy_count > 0);
  if (healthy_count == 0) return 0;

  The conditional can never be true after the assertion. In release builds, the assertion is stripped and the conditional
  becomes meaningful—but then the return value of 0 is wrong (should be null/error).

  Suggestion: Remove the conditional or change the assertion to an early return that's meaningful in both modes.

  ---
  10. Header Name Truncation

  src/multiprocess/proxy.zig:738

  var lb: [64]u8 = undefined;
  const name_len: u32 = @min(@as(u32, @intCast(line[0..c].len)), 64);

  Header names over 64 bytes are truncated before comparison. This could cause the skip-list to fail on long custom
  headers.

  Suggestion: Hash the lowercased name instead of truncating, or increase buffer size (HTTP/2 allows much longer header
  names).

  ---
  🔵 Simplification Opportunities

  11. Remove Unused Initialization Ceremony

  src/memory/simple_connection_pool.zig:85-91

  pub fn init(self: *SimpleConnectionPool) void {
      for (&self.pools) |*pool| {
          pool.* = SimpleConnectionStack{};
      }
      // ...
  }

  Zig already zero-initializes the struct. The pools field has a default value. The init method does redundant work.

  Suggestion: Use a simple const pool = SimpleConnectionPool{}; pattern. Remove initialized flag (check backend_count > 0
  instead).

  ---
  12. The WorkerConfig vs Config Duality

  There's WorkerConfig in main_multiprocess.zig, Config in config.zig, and CliConfig also in main. This creates confusion
  about which config goes where.

  Suggestion: One config struct, used everywhere. Parse CLI into it directly.

  ---
  🎯 The Big Idea: What Would Make This Inevitable?

  The current architecture is nginx-style (multi-process, SO_REUSEPORT). But Zig's strengths—comptime, zero-cost
  abstractions, no GC—enable something nginx can't do:

  Dynamic backend configuration with zero-copy updates.

  Imagine:
  1. Backends defined in a memory-mapped file
  2. Health state in shared memory between workers
  3. Add/remove backends by atomic pointer swap
  4. Zero restarts, zero coordination

  This would make it not just a load balancer, but a live infrastructure primitive.

  ---
  Summary: What to Do First

  | Priority | Item                                 | Impact                       |
  |----------|--------------------------------------|------------------------------|
  | 🔴       | Forward request bodies               | Unblocks all non-GET traffic |
  | 🔴       | Implement or remove weighted/sticky  | Removes broken features      |
  | 🟡       | TLS session resumption/pooling       | 10x HTTPS performance        |
  | 🟡       | Unify health probe + circuit breaker | Eliminates state conflicts   |
  | 🟢       | Per-backend metrics                  | Enables debugging            |
  | 🟢       | Non-copyable UltraSock               | Prevents memory corruption   |

  The foundation is beautiful. These changes would make it production-ready.



----

⏺ No, they were partial solutions. Let me design a complete architecture that covers all four:

  Complete Architecture

  ┌─────────────────────────────────────────────────────────────────────┐
  │                         Shared Memory Region                         │
  │                     (mmap'd, inherited across fork)                  │
  ├─────────────────────────────────────────────────────────────────────┤
  │                                                                      │
  │  ┌──────────────────────────────────────────────────────────────┐   │
  │  │ ControlBlock (64 bytes, cache-aligned)                       │   │
  │  │   backends_ptr: *BackendArray    ← atomic pointer (RCU)      │   │
  │  │   generation: u64                ← ABA prevention            │   │
  │  │   backend_count: u32                                         │   │
  │  │   _padding: [44]u8                                           │   │
  │  └──────────────────────────────────────────────────────────────┘   │
  │                                                                      │
  │  ┌──────────────────────────────────────────────────────────────┐   │
  │  │ HealthState (64 bytes, separate cache line)                  │   │
  │  │   bitmap: u64                    ← shared health bitmap      │   │
  │  │   failure_counts: [64]u8         ← per-backend counters      │   │
  │  └──────────────────────────────────────────────────────────────┘   │
  │                                                                      │
  │  ┌──────────────────────────────────────────────────────────────┐   │
  │  │ BackendArray[0] (mmap'd file region)                         │   │
  │  │   host, port, weight, tls...                                 │   │
  │  ├──────────────────────────────────────────────────────────────┤   │
  │  │ BackendArray[1] (double-buffer for atomic swap)              │   │
  │  │   host, port, weight, tls...                                 │   │
  │  └──────────────────────────────────────────────────────────────┘   │
  │                                                                      │
  └─────────────────────────────────────────────────────────────────────┘
            ▲              ▲              ▲              ▲
            │              │              │              │
       ┌────┴────┐    ┌────┴────┐    ┌────┴────┐    ┌────┴────┐
       │Worker 0 │    │Worker 1 │    │Worker 2 │    │Worker 3 │
       └─────────┘    └─────────┘    └─────────┘    └─────────┘

            ▲
            │ File watch (inotify/kqueue)
            │
       ┌────┴────────────────────────────────────────┐
       │  /etc/lb/backends.json                      │
       │  [{"host":"10.0.0.1","port":8080,"weight":5}]│
       └─────────────────────────────────────────────┘

  Feature Mapping

  | Requirement                | Implementation                                                            |
  |----------------------------|---------------------------------------------------------------------------|
  | 1. Backends in mmap'd file | Config file watched via kqueue/inotify, parsed into shared BackendArray   |
  | 2. Health in shared memory | Single HealthState struct in shared region, all workers read/write        |
  | 3. Atomic pointer swap     | Double-buffered BackendArray, RCU-style @atomicStore of pointer           |
  | 4. Zero restarts           | File watcher triggers hot reload, workers pick up changes on next request |

  Data Structures

  const std = @import("std");

  pub const MAX_BACKENDS = 64;
  pub const MAX_HOST_LEN = 253;

  /// Stored in mmap'd shared memory
  pub const SharedRegion = extern struct {
      control: ControlBlock align(64),
      health: HealthState align(64),
      backend_arrays: [2]BackendArray, // Double buffer

      pub fn init() *SharedRegion {
          const fd = std.posix.mmap(
              null,
              @sizeOf(SharedRegion),
              std.posix.PROT.READ | std.posix.PROT.WRITE,
              .{ .TYPE = .SHARED, .ANONYMOUS = true },
              -1,
              0,
          ) catch unreachable;

          const region: *SharedRegion = @ptrCast(@alignCast(fd));
          region.* = .{
              .control = .{},
              .health = .{},
              .backend_arrays = undefined,
          };
          return region;
      }
  };

  pub const ControlBlock = extern struct {
      /// Points to either backend_arrays[0] or backend_arrays[1]
      backends_ptr: std.atomic.Value(u64) = .{ .raw = 0 },
      /// Incremented on each config change (ABA prevention)
      generation: std.atomic.Value(u64) = .{ .raw = 0 },
      /// Number of active backends
      backend_count: std.atomic.Value(u32) = .{ .raw = 0 },
      /// Padding to fill cache line
      _padding: [44]u8 = undefined,

      pub fn getBackends(self: *const ControlBlock, region: *SharedRegion) []const Backend {
          const ptr_val = self.backends_ptr.load(.acquire);
          const array_idx = ptr_val & 1; // 0 or 1
          const count = self.backend_count.load(.acquire);
          return region.backend_arrays[array_idx].backends[0..count];
      }
  };

  pub const HealthState = extern struct {
      /// Bitmap: bit N = 1 means backend N is healthy
      bitmap: std.atomic.Value(u64) = .{ .raw = std.math.maxInt(u64) },
      /// Consecutive failure count per backend
      failure_counts: [MAX_BACKENDS]std.atomic.Value(u8) =
          [_]std.atomic.Value(u8){.{ .raw = 0 }} ** MAX_BACKENDS,

      pub fn isHealthy(self: *const HealthState, idx: usize) bool {
          const mask = @as(u64, 1) << @intCast(idx);
          return (self.bitmap.load(.acquire) & mask) != 0;
      }

      pub fn markUnhealthy(self: *HealthState, idx: usize) void {
          const mask = ~(@as(u64, 1) << @intCast(idx));
          _ = self.bitmap.fetchAnd(mask, .release);
      }

      pub fn markHealthy(self: *HealthState, idx: usize) void {
          const mask = @as(u64, 1) << @intCast(idx);
          _ = self.bitmap.fetchOr(mask, .release);
          self.failure_counts[idx].store(0, .release);
      }

      pub fn recordFailure(self: *HealthState, idx: usize, threshold: u8) void {
          const prev = self.failure_counts[idx].fetchAdd(1, .acq_rel);
          if (prev + 1 >= threshold) {
              self.markUnhealthy(idx);
          }
      }
  };

  pub const Backend = extern struct {
      host: [MAX_HOST_LEN + 1]u8 = [_]u8{0} ** (MAX_HOST_LEN + 1),
      port: u16 = 0,
      weight: u16 = 1,
      use_tls: bool = false,
      _padding: [2]u8 = undefined,
  };

  pub const BackendArray = extern struct {
      backends: [MAX_BACKENDS]Backend,
  };

  Hot Reload Flow

  /// Called by file watcher when config changes
  pub fn hotReload(region: *SharedRegion, new_config: []const BackendDef) void {
      const control = &region.control;

      // 1. Determine which buffer is NOT active
      const current_idx = control.backends_ptr.load(.acquire) & 1;
      const new_idx = 1 - current_idx;

      // 2. Write new config to inactive buffer (no readers here)
      const new_array = &region.backend_arrays[new_idx];
      for (new_config, 0..) |def, i| {
          @memcpy(new_array.backends[i].host[0..def.host.len], def.host);
          new_array.backends[i].host[def.host.len] = 0;
          new_array.backends[i].port = def.port;
          new_array.backends[i].weight = def.weight;
          new_array.backends[i].use_tls = def.use_tls;
      }

      // 3. Update count first (release ensures writes above are visible)
      control.backend_count.store(@intCast(new_config.len), .release);

      // 4. Atomic pointer swap - readers instantly see new config
      const new_gen = control.generation.fetchAdd(1, .acq_rel);
      control.backends_ptr.store(new_idx | ((new_gen + 1) << 1), .release);

      // 5. Reset health for new backends
      region.health.bitmap.store(std.math.maxInt(u64), .release);

      log.info("Hot reload complete: {d} backends, generation {d}", .{
          new_config.len,
          new_gen + 1,
      });
  }

  Worker Read Path (Zero Coordination)

  pub fn handleRequest(region: *SharedRegion, ctx: *http.Context) !void {
      // Lock-free read of current backend list
      const backends = region.control.getBackends(region);

      // Lock-free health check
      const idx = selectBackend(backends, &region.health);

      // Proxy request...
      if (proxyToBackend(&backends[idx], ctx)) |_| {
          // Success - lock-free health update
          region.health.markHealthy(idx);
      } else |_| {
          // Failure - lock-free failure recording
          region.health.recordFailure(idx, 3);
      }
  }

  Contention Analysis for Complete Design

  | Operation              | Frequency        | Contention           | Latency |
  |------------------------|------------------|----------------------|---------|
  | Read backend ptr       | Every request    | None (read-only)     | 1-4ns   |
  | Read health bitmap     | Every request    | Low (mostly reads)   | 1-10ns  |
  | Write health (failure) | On backend error | Medium               | 10-50ns |
  | Hot reload             | Config change    | None (double buffer) | <1ms    |

  Worst case: All workers simultaneously hit a failing backend:
  - 8 workers × 1 atomic fetchAnd = 8 cache line bounces
  - Total impact: ~400ns spread across workers
  - Acceptable for error path

  File Watcher Integration

  const FileWatcher = struct {
      kq: std.posix.fd_t,
      config_fd: std.posix.fd_t,
      region: *SharedRegion,

      pub fn watch(self: *FileWatcher) void {
          var events: [1]std.posix.Kevent = undefined;

          while (true) {
              const n = std.posix.kevent(self.kq, &.{}, &events, null);
              if (n > 0 and events[0].filter == std.posix.system.EVFILT_VNODE) {
                  // Config file changed
                  const new_config = parseConfigFile(self.config_fd);
                  hotReload(self.region, new_config);
              }
          }
      }
  };

  Summary

  | Feature                    | Status | How                                        |
  |----------------------------|--------|--------------------------------------------|
  | 1. Backends in mmap'd file | ✅     | BackendArray in SharedRegion, file watcher |
  | 2. Health in shared memory | ✅     | HealthState with atomic bitmap + counters  |
  | 3. Atomic pointer swap     | ✅     | Double-buffered arrays, RCU-style swap     |
  | 4. Zero restarts           | ✅     | Workers read atomically, no coordination   |

  Want me to implement this?
  ⎿  Stop says:



---

Yes! This is called "zero-downtime upgrade" or "hot binary reload". Several approaches:

  Comparison

  | Approach                     | Complexity | Connection Drop   | Platform        |
  |------------------------------|------------|-------------------|-----------------|
  | SO_REUSEPORT + drain         | Low        | None (with drain) | Linux 3.9+      |
  | Socket passing (nginx-style) | Medium     | None              | POSIX           |
  | systemd socket activation    | Low        | None              | Linux + systemd |
  | execve-in-place              | High       | Risk of drops     | POSIX           |

  Option A: SO_REUSEPORT + Graceful Drain (Simplest)

  Timeline:

  T=0     ┌─────────────────────────┐
          │ LB v1.0 (accepting)     │  ← Running, serving requests
          │ listen :8080 REUSEPORT  │
          └─────────────────────────┘

  T=1     ┌─────────────────────────┐  ┌─────────────────────────┐
          │ LB v1.0 (draining)      │  │ LB v2.0 (accepting)     │
          │ stop accept, finish req │  │ listen :8080 REUSEPORT  │
          └─────────────────────────┘  └─────────────────────────┘
                      ↓
  T=N     (exits when drained)          ┌─────────────────────────┐
                                        │ LB v2.0 (sole owner)    │
                                        └─────────────────────────┘

  // In main.zig - signal handler for graceful shutdown
  var shutting_down: std.atomic.Value(bool) = .{ .raw = false };

  fn handleSignal(sig: c_int) callconv(.C) void {
      if (sig == std.posix.SIG.USR2) {
          // Signal to start draining
          shutting_down.store(true, .release);
          log.info("Received USR2, starting graceful drain...", .{});
      }
  }

  pub fn main() !void {
      // Set up signal handler
      var sa = std.posix.Sigaction{
          .handler = .{ .handler = handleSignal },
          .mask = std.posix.empty_sigset,
          .flags = 0,
      };
      try std.posix.sigaction(std.posix.SIG.USR2, &sa, null);

      // SO_REUSEPORT allows multiple processes to bind
      const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
      try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
      try std.posix.bind(sock, address);
      try std.posix.listen(sock, 128);

      // Accept loop with drain check
      while (!shutting_down.load(.acquire)) {
          const conn = std.posix.accept(sock, null, null) catch continue;
          // Handle connection...
      }

      // Wait for in-flight requests to complete
      waitForDrain();
  }

  Upgrade script:
  #!/bin/bash
  # deploy.sh

  NEW_BINARY="./load_balancer_v2"
  OLD_PID=$(pgrep -f "load_balancer")

  # 1. Start new binary (both now accepting via SO_REUSEPORT)
  $NEW_BINARY &
  NEW_PID=$!

  # 2. Wait for new binary to be ready
  sleep 2

  # 3. Tell old binary to drain
  kill -USR2 $OLD_PID

  # 4. Wait for old binary to exit
  wait $OLD_PID

  echo "Upgrade complete: $OLD_PID → $NEW_PID"

  Option B: Socket Passing via SCM_RIGHTS (nginx-style)

                  SIGUSR2
                     │
      ┌──────────────▼──────────────┐
      │         LB v1.0             │
      │  1. Receive signal          │
      │  2. Fork child              │──────┐
      │  3. Pass FDs via UDS        │      │
      │  4. Stop accepting          │      ▼
      │  5. Drain & exit            │   ┌─────────────────────┐
      └─────────────────────────────┘   │     LB v2.0         │
                                        │  exec(new_binary)   │
                                        │  Receive FDs        │
                                        │  Start accepting    │
                                        └─────────────────────┘

  const std = @import("std");
  const posix = std.posix;

  /// Send file descriptors to another process via Unix socket
  pub fn sendFds(sock: posix.socket_t, fds: []const posix.fd_t) !void {
      const cmsg_space = @sizeOf(posix.cmsghdr) + fds.len * @sizeOf(posix.fd_t);
      var cmsg_buf: [256]u8 align(@alignOf(posix.cmsghdr)) = undefined;

      var cmsg: *posix.cmsghdr = @ptrCast(&cmsg_buf);
      cmsg.level = posix.SOL.SOCKET;
      cmsg.type = posix.SCM_RIGHTS;
      cmsg.len = @intCast(@sizeOf(posix.cmsghdr) + fds.len * @sizeOf(posix.fd_t));

      const fd_ptr: [*]posix.fd_t = @ptrCast(@alignCast(&cmsg_buf[@sizeOf(posix.cmsghdr)]));
      @memcpy(fd_ptr, fds);

      var msg = posix.msghdr{
          .name = null,
          .namelen = 0,
          .iov = &[_]posix.iovec{.{ .base = "x", .len = 1 }}, // Dummy byte required
          .iovlen = 1,
          .control = &cmsg_buf,
          .controllen = @intCast(cmsg_space),
          .flags = 0,
      };

      _ = try posix.sendmsg(sock, &msg, 0);
  }

  /// Receive file descriptors from another process
  pub fn recvFds(sock: posix.socket_t, fd_buf: []posix.fd_t) !usize {
      var cmsg_buf: [256]u8 align(@alignOf(posix.cmsghdr)) = undefined;
      var dummy: [1]u8 = undefined;

      var msg = posix.msghdr{
          .name = null,
          .namelen = 0,
          .iov = &[_]posix.iovec{.{ .base = &dummy, .len = 1 }},
          .iovlen = 1,
          .control = &cmsg_buf,
          .controllen = cmsg_buf.len,
          .flags = 0,
      };

      _ = try posix.recvmsg(sock, &msg, 0);

      const cmsg: *posix.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
      if (cmsg.level == posix.SOL.SOCKET and cmsg.type == posix.SCM_RIGHTS) {
          const fd_count = (cmsg.len - @sizeOf(posix.cmsghdr)) / @sizeOf(posix.fd_t);
          const fds: [*]posix.fd_t = @ptrCast(@alignCast(&cmsg_buf[@sizeOf(posix.cmsghdr)]));
          @memcpy(fd_buf[0..fd_count], fds[0..fd_count]);
          return fd_count;
      }
      return 0;
  }

  /// Handle upgrade signal
  fn handleUpgrade(listen_fd: posix.fd_t, shared_region: *SharedRegion) !void {
      // 1. Create Unix socket pair for FD passing
      const pair = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);

      // 2. Fork
      const pid = try posix.fork();

      if (pid == 0) {
          // Child: exec new binary
          posix.close(pair[0]);

          // Pass the socket FD via environment
          var fd_str: [16]u8 = undefined;
          const fd_env = std.fmt.bufPrint(&fd_str, "{d}", .{pair[1]}) catch unreachable;

          // Set env and exec
          const env = [_:null]?[*:0]const u8{
              "LISTEN_FD=" ++ fd_env,
              "SHARED_REGION_FD=" ++ ..., // Pass mmap'd region too
              null,
          };

          return posix.execveZ("./load_balancer_new", &.{}, &env);
      }

      // Parent: send FDs and drain
      posix.close(pair[1]);

      // Send listening socket and shared memory FD
      try sendFds(pair[0], &.{ listen_fd, shared_region.fd });
      posix.close(pair[0]);

      // Wait for new process to signal ready
      var ready_buf: [1]u8 = undefined;
      _ = try posix.read(pair[0], &ready_buf);

      // Stop accepting, drain existing connections
      log.info("New binary ready, draining...", .{});
      drainAndExit();
  }

  Option C: systemd Socket Activation (Cleanest for Linux)

  # /etc/systemd/system/lb.socket
  [Unit]
  Description=Load Balancer Socket

  [Socket]
  ListenStream=8080
  ReusePort=true

  [Install]
  WantedBy=sockets.target

  # /etc/systemd/system/lb.service
  [Unit]
  Description=Load Balancer
  Requires=lb.socket

  [Service]
  ExecStart=/usr/bin/load_balancer
  ExecReload=/bin/kill -USR2 $MAINPID
  Restart=on-failure
  NonBlocking=true

  [Install]
  WantedBy=multi-user.target

  /// Check if running under systemd socket activation
  pub fn getSystemdSocket() ?posix.fd_t {
      const listen_pid = std.posix.getenv("LISTEN_PID") orelse return null;
      const listen_fds = std.posix.getenv("LISTEN_FDS") orelse return null;

      const pid = std.fmt.parseInt(i32, listen_pid, 10) catch return null;
      if (pid != std.posix.getpid()) return null;

      const nfds = std.fmt.parseInt(usize, listen_fds, 10) catch return null;
      if (nfds < 1) return null;

      // systemd passes FDs starting at 3
      return 3;
  }

  pub fn main() !void {
      const listen_fd = getSystemdSocket() orelse blk: {
          // No systemd, create our own socket
          const sock = try posix.socket(...);
          try posix.bind(sock, ...);
          try posix.listen(sock, 128);
          break :blk sock;
      };

      // Use listen_fd...
  }

  Upgrade:
  # Replace binary and reload - systemd handles the socket
  cp load_balancer_v2 /usr/bin/load_balancer
  systemctl reload lb  # Graceful, socket stays open

  Complete Solution: All Features Combined

  ┌─────────────────────────────────────────────────────────────────────┐
  │                        Shared Memory Region                          │
  │                    (survives binary upgrade)                         │
  ├─────────────────────────────────────────────────────────────────────┤
  │  ControlBlock: backends_ptr, generation                              │
  │  HealthState: bitmap, failure_counts                                 │
  │  BackendArrays[2]: double-buffered config                           │
  └─────────────────────────────────────────────────────────────────────┘
           │                                        ▲
           │ mmap'd, FD passed to new binary       │
           ▼                                        │
  ┌─────────────────┐   SIGUSR2    ┌─────────────────┐
  │  LB v1.0        │ ──────────►  │  Fork + Exec    │
  │  - listen :8080 │              │  - Pass FDs:    │
  │  - shared mem   │              │    • listen_fd  │
  │  - connections  │              │    • shm_fd     │
  └─────────────────┘              └────────┬────────┘
           │                                 │
           │ drain                           ▼
           ▼                       ┌─────────────────┐
        (exit)                     │  LB v2.0        │
                                   │  - Same socket  │
                                   │  - Same shm     │
                                   │  - New code!    │
                                   └─────────────────┘

  What survives the upgrade:
  | Component                        | Survives? | How                               |
  |----------------------------------|-----------|-----------------------------------|
  | Listen socket                    | ✅        | Passed via SCM_RIGHTS or systemd  |
  | Shared memory (backends, health) | ✅        | FD passed, re-mmap in new process |
  | Active connections               | ⚠️        | Old process drains them           |
  | TLS sessions                     | ⚠️        | Old process completes them        |
  | Config file watchers             | ✅        | New process re-creates            |

  What gets reset:
  - Per-worker metrics (acceptable, Prometheus scrapes frequently)
  - Connection pools (rebuilt on demand)
  - In-memory caches (rebuilt on demand)

  Upgrade Flow

  #!/bin/bash
  # zero-downtime-upgrade.sh

  set -e

  NEW_BINARY=$1
  OLD_PID=$(cat /var/run/lb.pid)

  echo "Upgrading from PID $OLD_PID to $NEW_BINARY"

  # 1. Copy new binary into place
  cp "$NEW_BINARY" /usr/local/bin/load_balancer.new
  chmod +x /usr/local/bin/load_balancer.new

  # 2. Signal old process to start upgrade
  #    Old process will:
  #    - Fork
  #    - Child execs new binary
  #    - Pass listen_fd + shm_fd via Unix socket
  #    - Wait for child ready signal
  #    - Stop accepting, drain, exit
  kill -USR2 $OLD_PID

  # 3. Wait for old process to exit
  while kill -0 $OLD_PID 2>/dev/null; do
      echo "Waiting for old process to drain..."
      sleep 1
  done

  # 4. Verify new process is running
  NEW_PID=$(cat /var/run/lb.pid)
  if curl -s http://localhost:8080/health | grep -q "ok"; then
      echo "Upgrade successful: $OLD_PID → $NEW_PID"
      mv /usr/local/bin/load_balancer.new /usr/local/bin/load_balancer
  else
      echo "UPGRADE FAILED - new binary not responding"
      exit 1
  fi

  Want me to implement any of these approaches?
  ⎿  Stop says:
