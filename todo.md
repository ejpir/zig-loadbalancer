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
