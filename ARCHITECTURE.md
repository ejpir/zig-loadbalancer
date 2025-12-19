# Architecture

## C4 Model

### Level 1: System Context
```
    ┌──────────┐                                           ┌──────────────┐
    │  Client  │         ┌────────────────────┐            │   Backend    │
    │ (Browser,│────────►│   Load Balancer    │───────────►│   Servers    │
    │   CLI)   │  HTTP   │  [Zig Application] │  HTTP/TLS  │  (HTTP/S)    │
    └──────────┘         └────────────────────┘            └──────────────┘
```

### Level 2: Container (Multi-Process)
```
┌─────────────────────────────────────────────────────────────────────────────┐
│ MASTER PROCESS                                                              │
│   • fork() workers  • waitpid() monitor  • Restart on crash                 │
└───────────┬───────────────────────┬───────────────────────┬─────────────────┘
            │ fork()                │ fork()                │ fork()
            ▼                       ▼                       ▼
┌───────────────────┐   ┌───────────────────┐   ┌───────────────────┐
│ WORKER 0          │   │ WORKER 1          │   │ WORKER N          │
│ ┌───────────────┐ │   │ ┌───────────────┐ │   │ ┌───────────────┐ │
│ │ HTTP Server   │ │   │ │ HTTP Server   │ │   │ │ HTTP Server   │ │
│ │ (zzz.io)      │ │   │ │ (zzz.io)      │ │   │ │ (zzz.io)      │ │
│ └───────┬───────┘ │   │ └───────┬───────┘ │   │ └───────┬───────┘ │
│ ┌───────┴───────┐ │   │ ┌───────┴───────┐ │   │ ┌───────┴───────┐ │
│ │ Proxy Engine  │ │   │ │ Proxy Engine  │ │   │ │ Proxy Engine  │ │
│ └───────┬───────┘ │   │ └───────┬───────┘ │   │ └───────┬───────┘ │
│ ┌───────┴───────┐ │   │ ┌───────┴───────┐ │   │ ┌───────┴───────┐ │
│ │ Conn Pool     │ │   │ │ Conn Pool     │ │   │ │ Conn Pool     │ │
│ │ Health Thread │ │   │ │ Health Thread │ │   │ │ Health Thread │ │
│ └───────────────┘ │   │ └───────────────┘ │   │ └───────────────┘ │
└─────────┬─────────┘   └─────────┬─────────┘   └─────────┬─────────┘
          └─────────── SO_REUSEPORT ──────────────────────┘
                              │
                       ┌──────┴──────┐
                       │  Port 8080  │◄─── Clients
                       └─────────────┘
```

### Level 2: Container (Single-Process)
```
┌─────────────────────────────────────────────────────────────────────────────┐
│ SINGLE PROCESS                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ MAIN THREAD (std.Io.Threaded async runtime)                           │  │
│  │  HTTP Server ──► Router ──► Proxy Engine ──► UltraSock (TCP/TLS)      │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│  ┌─────────────────────┐    ┌──────────────────────────────────────────┐   │
│  │ HEALTH THREAD       │◄──►│ SHARED STATE (WorkerState, ConnPool)     │   │
│  │ (blocking probes)   │    └──────────────────────────────────────────┘   │
│  └─────────────────────┘                                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Level 3: Component (Proxy Engine)
```
                    ┌─────────────────────────────────────┐
 HTTP Request ─────►│            proxy.zig                │
                    │  ┌───────────────────────────────┐  │
                    │  │ Backend Selector              │  │
                    │  │ (round-robin, random, sticky) │  │
                    │  └───────────────┬───────────────┘  │
                    │                  ▼                  │
                    │  ┌───────────────────────────────┐  │
                    │  │ Circuit Breaker               │  │
                    │  │ (health bitmap, counters)     │  │
                    │  └───────────────┬───────────────┘  │
                    │                  ▼                  │
                    │  ┌───────────────────────────────┐  │
                    │  │ Connection Pool (LIFO stacks) │  │
                    │  └───────────────┬───────────────┘  │
                    │                  ▼                  │
                    │  ┌───────────────────────────────┐  │
                    │  │ UltraSock (TCP/TLS)           │  │
                    │  └───────────────┬───────────────┘  │
                    └──────────────────┼──────────────────┘
                                       ▼
                              Backend Server
```

## Startup Flows

### Multi-Process (`main_multiprocess.zig`)
```
main()
  ├─► parseArgs()                    # CLI: --workers, --port, --backend
  ├─► spawnWorkers()
  │     └─► for each worker:
  │           fork()
  │             ├─► [CHILD] workerMain()
  │             │     ├─► GPA (thread_safe=true)
  │             │     ├─► SimpleConnectionPool
  │             │     ├─► BackendsList
  │             │     ├─► WorkerState (circuit breaker)
  │             │     ├─► health.startHealthProbes()  # Background thread
  │             │     ├─► Io.Threaded.init()
  │             │     ├─► setCpuAffinity()            # AFTER Io.init!
  │             │     ├─► Router + proxy handler
  │             │     ├─► socket.listen() + SO_REUSEPORT
  │             │     └─► server.serve()
  │             └─► [PARENT] store pid
  └─► waitpid() loop                 # Restart crashed workers
```

### Single-Process (`runSingleProcess()`)
```
main()
  ├─► parseArgs()                    # CLI: --port, --backend, --strategy
  ├─► GPA (thread_safe=true)
  ├─► SharedRegionAllocator.init()   # Shared memory (same as mp mode)
  ├─► initSharedBackends()           # Load backends into shared region
  ├─► startConfigWatcher()           # Hot reload thread (if -c provided)
  ├─► SimpleConnectionPool
  ├─► BackendsList
  ├─► WorkerState + setSharedRegion()
  ├─► health.startHealthProbes()     # Background thread
  ├─► setupSignalHandlers()          # SIGTERM, SIGINT, SIGUSR2
  ├─► Io.Threaded.init()
  ├─► Router + proxy handler
  ├─► socket.listen()
  └─► server.serve()
```

**Key difference from old sp mode:** Now uses SharedRegion like mp mode, enabling:
- Config hot reload (`-c backends.json`)
- Shared round-robin counter
- Binary hot reload (SIGUSR2)

## Components

### `proxy.zig` — Streaming Proxy

Request flow:
1. `generateHandler()` creates comptime-specialized handler
2. Select backend via `WorkerState.selectBackend(strategy)`
3. Get/create connection via `ConnectionPool` or `UltraSock.init()`
4. Forward request, stream response
5. On failure: `recordFailure()`, try failover backend
6. On success: `recordSuccess()`, return connection to pool

Key functions:
- `handleProxyRequest()` — Main proxy logic
- `forwardRequestToBackend()` — Send client request
- `streamBackendResponse()` — Stream response back
- `tryFailover()` — Attempt alternate backend

### `circuit_breaker.zig` — Health State Machine

```
HEALTHY ──[N failures]──► UNHEALTHY
   ▲                          │
   └───[M successes]──────────┘
```

State:
- `health: HealthState` — u64 bitmap (1=healthy, 0=unhealthy)
- `consecutive_failures[64]` — Per-backend failure count
- `consecutive_successes[64]` — Per-backend success count

Config defaults:
- `unhealthy_threshold: 3`
- `healthy_threshold: 2`

### `health.zig` — Active Probes

Runs in dedicated thread per worker:
```
loop forever:
  for each backend:
    connect(backend)
    send("GET / HTTP/1.1")
    if response contains "200":
      recordSuccess()
    else:
      recordFailure()
  sleep(5 seconds)
```

Uses blocking POSIX I/O (not async) to avoid event loop interference.

### `backend_selector.zig` — Load Balancing

Strategies (comptime-specialized):
- **round_robin**: Rotate through healthy backends
- **random**: Crypto-random selection
- **weighted_round_robin**: Proportional distribution
- **sticky**: Session affinity (placeholder)

Uses `HealthState` bitmap for O(1) health checks via `@popCount`/`@ctz`.

### `simple_connection_pool.zig` — Connection Reuse

Per-backend LIFO stacks:
```zig
const MAX_IDLE_CONNS = 8;
const MAX_BACKENDS = 64;

stacks: [MAX_BACKENDS]SimpleConnectionStack
```

No atomics needed — each worker has its own pool.

### `ultra_sock.zig` — TCP/TLS Socket

Unified interface for HTTP and HTTPS backends:
- Port 443 → TLS handshake via `ianic/tls.zig`
- Other ports → Plain TCP
- DNS resolution via `getaddrinfo()`
- `fixTlsPointersAfterCopy()` — Required after struct copy

### `http_utils.zig` — Message Framing

RFC 7230 compliance:
- `determineMessageLength()` — Content-Length vs chunked vs close-delimited
- Handles HEAD requests, 1xx/204/304 responses

### `worker_state.zig` — Composite State

Combines all per-worker state:
```zig
pub const WorkerState = struct {
    backends: *const BackendsList,        // Local backends (fallback)
    shared_region: ?*SharedRegion,        // Shared memory for hot reload
    connection_pool: *SimpleConnectionPool,
    circuit_breaker: CircuitBreaker,
    config: Config,
    rr_state: usize,                      // Local round-robin counter (fallback)
    total_requests: usize,
};
```

Key methods for hot reload:
- `setSharedRegion(region)` — Enable shared memory backend source
- `getBackendCount()` — Returns count from SharedRegion if available
- `getSharedBackend(idx)` — Returns backend from SharedRegion for routing
- `selectBackend(strategy)` — Uses shared `rr_counter` when SharedRegion available

**Shared round-robin:** When SharedRegion is set, round-robin selection uses the atomic `rr_counter` in ControlBlock instead of local `rr_state`. This ensures even distribution across all workers, not just within each worker.

### `metrics.zig` — Prometheus Metrics

Endpoint: `GET /metrics`

Counters:
- `lb_requests_total`
- `lb_backend_failures_total`
- `lb_backends_healthy`
- `lb_backends_unhealthy`

## Shared Memory Architecture (Hot Reload)

The load balancer supports zero-downtime configuration changes and binary upgrades via shared memory.

### Memory Layout

```
┌─────────────────────────────────────────────────────────────────────┐
│                         SharedRegion (mmap'd)                        │
│                    Inherited across fork(), survives upgrades        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ Header (64 bytes, cache-aligned)                             │   │
│  │   magic: 0x5A5A_4C42_5348_4152  ("ZZSHAR_LB")                │   │
│  │   version: 1                                                 │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ ControlBlock (64 bytes, separate cache line)                 │   │
│  │   active_index: atomic u64  ← Points to BackendArray[0|1]    │   │
│  │   generation: atomic u64    ← ABA prevention counter         │   │
│  │   backend_count: atomic u32 ← Number of configured backends  │   │
│  │   rr_counter: atomic u32    ← Shared round-robin counter     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ SharedHealthState (64+ bytes, separate cache line)           │   │
│  │   bitmap: atomic u64        ← Bit N = backend N healthy      │   │
│  │   failure_counts[64]: u8    ← Per-backend failure counters   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ BackendArray[0] — Active or Inactive (double-buffered)       │   │
│  │   backends[64]: SharedBackend                                │   │
│  │     • host[254]: null-terminated (no pointers!)              │   │
│  │     • port: u16                                              │   │
│  │     • weight: u16                                            │   │
│  │     • use_tls: bool                                          │   │
│  ├──────────────────────────────────────────────────────────────┤   │
│  │ BackendArray[1] — Inactive or Active                         │   │
│  │   (same structure, used for atomic swap)                     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
         ▲              ▲              ▲              ▲
         │              │              │              │
    ┌────┴────┐    ┌────┴────┐    ┌────┴────┐    ┌────┴────┐
    │Worker 0 │    │Worker 1 │    │Worker 2 │    │Worker 3 │
    └─────────┘    └─────────┘    └─────────┘    └─────────┘
```

### Key Design Decisions

**Why no pointers in SharedBackend?**
- Pointers are process-local virtual addresses
- After fork(), parent and child have same addresses (copy-on-write)
- But after exec() or socket passing to new binary, addresses differ
- Solution: Inline the hostname string (max 253 bytes per RFC 1035)

**Why double-buffered backend arrays?**
- Enables atomic configuration updates without locks
- Writer updates inactive array, then atomically swaps pointer
- Readers always see consistent state (RCU-style)
- No reader-writer coordination needed

**Why cache-line alignment?**
- ControlBlock and HealthState on separate 64-byte cache lines
- Prevents false sharing between workers
- Health bitmap updates don't invalidate backend config cache

### Platform Support

| Platform | Mechanism | FD Passing |
|----------|-----------|------------|
| Linux | `memfd_create()` + `mmap()` | Yes (for upgrades) |
| macOS | `mmap(MAP_ANONYMOUS \| MAP_SHARED)` | Via fork() inheritance |
| FreeBSD | `mmap(MAP_ANONYMOUS \| MAP_SHARED)` | Via fork() inheritance |

### Hot Reload Flow

The config watcher runs in a dedicated thread in the master process, using platform-specific file monitoring:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ MASTER PROCESS                                                          │
│  ┌────────────────────┐     ┌─────────────────────────────────────────┐ │
│  │ Config Watcher     │     │ SharedRegion (mmap'd)                   │ │
│  │ Thread             │────►│                                         │ │
│  │                    │     │  BackendArray[0] ◄── active_index = 0   │ │
│  │ kqueue (macOS)     │     │  BackendArray[1]     (inactive)         │ │
│  │ inotify (Linux)    │     │                                         │ │
│  └────────────────────┘     └─────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
         │                              ▲
         │ watches                      │ workers read via
         ▼                              │ getSharedBackend()
┌─────────────────┐            ┌────────┴────────┐
│ backends.json   │            │ Worker Processes │
└─────────────────┘            └─────────────────┘
```

**Detailed flow:**

```
1. Config watcher (kqueue/inotify) detects backends.json modified
2. Parse JSON config:
   {
     "backends": [
       {"host": "backend1.local", "port": 8001, "weight": 5},
       {"host": "backend2.local", "port": 8002, "weight": 3, "tls": true}
     ]
   }
3. Write backends to INACTIVE array (BackendArray[1 - active_index])
4. Atomic swap: generation++, flip active_index, update backend_count
5. Reset health bitmap for new backend count
6. Workers see new backends on next request via getSharedBackend()
```

**Config file format (`backends.json`):**

```json
{
  "backends": [
    {"host": "127.0.0.1", "port": 8001},
    {"host": "127.0.0.1", "port": 8002, "weight": 2},
    {"host": "secure.example.com", "port": 443, "tls": true}
  ]
}
```

**Zero-downtime guarantees:**
- No locks — workers read atomically via `active_index`
- No request drops — old backends serve until next request reads new config
- No coordination — each worker independently reads from SharedRegion

### Hot Binary Upgrade Flow

Binary hot reload allows upgrading the load balancer without dropping connections:

```bash
# Trigger upgrade
kill -USR2 $(pgrep -f load_balancer)
```

**Flow:**

```
1. Old process receives SIGUSR2
2. Old process forks
3. Child execs new binary (same argv)
4. New binary starts, binds with SO_REUSEPORT (shares port)
5. Old process waits 1 second for new process to be ready
6. Old process stops accepting, drains existing connections
7. Old process exits cleanly
8. New process continues serving
```

**Key design points:**
- Uses SO_REUSEPORT for seamless port sharing during transition
- Fork+exec preserves original arguments
- 1 second delay ensures new process is listening before old stops
- Works in both mp and sp modes

### Components

| File | Purpose |
|------|---------|
| `src/memory/shared_region.zig` | SharedRegion, ControlBlock, SharedHealthState, SharedBackend |
| `src/config/config_watcher.zig` | JSON config parser, kqueue/inotify file watcher |

### Usage Example

```zig
const shared_region = @import("memory/shared_region.zig");

// Parent process: create shared region
var allocator = shared_region.SharedRegionAllocator{};
const region = try allocator.init();

// Configure backends (before fork)
var inactive = region.getInactiveBackends();
inactive[0].setHost("backend1.example.com");
inactive[0].port = 8080;
inactive[0].weight = 5;
inactive[1].setHost("backend2.example.com");
inactive[1].port = 8080;
inactive[1].weight = 3;

// Atomically activate
_ = region.control.switchActiveArray(2);

// Fork workers - they inherit the mmap'd region
const pid = try posix.fork();
if (pid == 0) {
    // Child: region is already visible
    const backends = region.getActiveBackends();
    // Use backends...
}
```

## File Structure

```
├── main.zig                     # Unified entry point (--mode mp|sp)
├── backends.json                # Example config for hot reload
├── backend_9001.py              # Test backend server
├── backend_9002.py              # Test backend server
├── src/
│   ├── core/
│   │   ├── types.zig            # BackendServer, LoadBalancerStrategy
│   │   └── config.zig           # LoadBalancerConfig
│   ├── config/
│   │   └── config_watcher.zig   # JSON parser + file watcher (kqueue/inotify)
│   ├── multiprocess/
│   │   ├── mod.zig              # Re-exports
│   │   ├── proxy.zig            # Streaming proxy + failover + SharedBackend support
│   │   ├── worker_state.zig     # Per-worker state + SharedRegion integration
│   │   ├── circuit_breaker.zig  # Health state machine
│   │   ├── health.zig           # Background probes
│   │   ├── backend_selector.zig # LB strategies
│   │   └── connection_reuse.zig # Keep-alive detection
│   ├── http/
│   │   ├── ultra_sock.zig       # TCP/TLS socket (duck-typed for SharedBackend)
│   │   └── http_utils.zig       # RFC 7230 framing
│   ├── memory/
│   │   ├── simple_connection_pool.zig  # Per-worker connection pooling
│   │   └── shared_region.zig    # Shared memory for hot reload
│   ├── internal/
│   │   └── simd_parse.zig       # Header boundary detection
│   └── utils/
│       └── metrics.zig          # Prometheus
└── vendor/
    ├── zzz.io/                  # HTTP framework
    └── tls/                     # TLS 1.2/1.3
```

## Design Decisions

### Why multi-process over multi-threaded?

1. **No shared state** — Each worker isolated, no locks needed
2. **Crash isolation** — One worker dies, others unaffected
3. **CPU affinity** — Pin workers to cores (Linux)
4. **Simple debugging** — Single-threaded within each worker

### Why blocking I/O for health probes?

Health probes run in a separate OS thread using `posix.connect()`, `posix.send()`, `posix.recv()`. This avoids:
- Competing with request handling for event loop resources
- Complex async state management for periodic tasks
- Timer/timeout integration with zzz.io

### Why comptime strategy specialization?

```zig
// Runtime dispatch (slow):
strategy_fn(ctx)  // Indirect call, no inlining

// Comptime switch (fast):
switch (strategy) {
    inline .round_robin => |s| s.select(ctx),  // Direct call, inlined
}
```

Eliminates vtable overhead for hot path.

### Why u64 bitmap for health?

- `@popCount(bitmap)` — Count healthy backends in 1 instruction
- `@ctz(bitmap)` — Find first healthy in 1 instruction
- 64 backends max is sufficient for most deployments
- Cache-friendly: entire health state in one cache line

### Single-process threading model

Single-process mode (`main_singleprocess.zig`) uses `std.Io.Threaded`:

```zig
var threaded: Io.Threaded = .init(allocator);
```

This is Zig's async I/O runtime which may use internal threads for I/O operations. Key implications:

1. **GPA must be thread-safe** — Health probe thread runs concurrently
   ```zig
   var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
   ```

2. **Shared state** — Unlike multi-process, connection pool and worker state are shared
   - `SimpleConnectionPool` — Designed for single-threaded access
   - `WorkerState` — Circuit breaker updates from health thread

3. **When to use**:
   - macOS (SO_REUSEPORT doesn't provide kernel load balancing)
   - Development/testing
   - Lower memory footprint needed
   - Simpler deployment

For production on Linux, prefer multi-process mode for full isolation.

### Runtime log level

The `--loglevel` flag allows changing verbosity without recompiling:

```bash
./zig-out/bin/load_balancer -l debug  # All logs
./zig-out/bin/load_balancer -l info   # Default
./zig-out/bin/load_balancer -l warn   # Warnings and errors only
./zig-out/bin/load_balancer -l err    # Errors only
```

Implemented via custom `std_options.logFn` that checks a runtime variable before delegating to `std.log.defaultLog`.
