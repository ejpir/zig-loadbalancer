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

### Single-Process (`main_singleprocess.zig`)
```
main()
  ├─► parseArgs()                    # CLI: --port, --backend, --strategy
  ├─► GPA (thread_safe=true)
  ├─► SimpleConnectionPool (shared)
  ├─► BackendsList
  ├─► WorkerState
  ├─► health.startHealthProbes()     # Background thread
  ├─► Io.Threaded.init()
  ├─► Router + proxy handler
  ├─► socket.listen()
  └─► server.serve()
```

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
    backends: *const BackendsList,
    connection_pool: *SimpleConnectionPool,
    circuit_breaker: CircuitBreaker,
    config: Config,
    rr_state: usize,           // Round-robin counter
    total_requests: usize,
};
```

### `metrics.zig` — Prometheus Metrics

Endpoint: `GET /metrics`

Counters:
- `lb_requests_total`
- `lb_backend_failures_total`
- `lb_backends_healthy`
- `lb_backends_unhealthy`

## File Structure

```
├── main_multiprocess.zig        # Entry: nginx-style fork()
├── main_singleprocess.zig       # Entry: single process
├── src/
│   ├── core/
│   │   └── types.zig            # BackendServer, LoadBalancerStrategy
│   ├── multiprocess/
│   │   ├── mod.zig              # Re-exports
│   │   ├── proxy.zig            # Streaming proxy + failover
│   │   ├── worker_state.zig     # Per-worker state
│   │   ├── circuit_breaker.zig  # Health state machine
│   │   ├── health_state.zig     # u64 bitmap
│   │   ├── health.zig           # Background probes
│   │   ├── backend_selector.zig # LB strategies
│   │   └── connection_reuse.zig # Keep-alive detection
│   ├── http/
│   │   ├── ultra_sock.zig       # TCP/TLS socket
│   │   └── http_utils.zig       # RFC 7230 framing
│   ├── memory/
│   │   └── simple_connection_pool.zig
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
