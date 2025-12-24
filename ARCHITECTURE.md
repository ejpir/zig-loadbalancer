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

Per-backend LIFO stacks, lock-free design:
```zig
const MAX_IDLE_CONNS = 8;
const MAX_BACKENDS = 64;

stacks: [MAX_BACKENDS]SimpleConnectionStack  // No mutex!
```

**No synchronization needed:**
- Each worker has its own pool instance
- I/O event loop is single-threaded (io_uring/kqueue completions are sequential)
- Health probe thread uses shared_region, NOT the connection pool
- Eliminates mutex overhead on every `getConnection()`/`returnConnection()`

### `ultra_sock.zig` — TCP/TLS Socket

Unified interface for HTTP/1.1 and HTTP/2 backends:
- Port 443 → TLS handshake via `ianic/tls.zig`
- ALPN negotiation: `["h2", "http/1.1"]` → server picks protocol
- `negotiated_protocol: AppProtocol` — Copy-safe enum (not slice pointer)
- Other ports → Plain TCP
- DNS resolution via `getaddrinfo()`

**HTTP/2 support:**
- ALPN advertises `h2` during TLS handshake
- If server selects `h2`, uses HTTP/2 framing (HPACK compression)
- Falls back to HTTP/1.1 if server doesn't support h2
- `isHttp2()` — Inlined enum check for hot path

### `http2/` — HTTP/2 Protocol Support

Backend HTTP/2 support via ALPN negotiation:

```
src/http/http2/
├── mod.zig       # Constants (INITIAL_WINDOW_SIZE, frame types)
├── frame.zig     # Frame parsing/building (HEADERS, DATA, SETTINGS, etc.)
├── hpack.zig     # HPACK header compression (static table, Huffman)
├── huffman.zig   # Huffman decoding for HPACK
├── stream.zig    # Stream state machine (unused, future multiplexing)
└── client.zig    # HTTP/2 client (connection preface, request/response)
```

**Key design:**
- ALPN negotiates protocol during TLS handshake
- `AppProtocol` enum is copy-safe (no dangling pointers)
- HPACK uses static table only (no dynamic table state)
- WINDOW_UPDATE sent after DATA frames (flow control)

## HTTP/2 over TLS — Complete Lifecycle

### Phase 1: Connection Setup

```
  Load Balancer                                                    Backend
       │                                                              │
       │  pool.getOrCreate(backend_idx, io)                           │
       │  └─► createFreshConnection()                                 │
       │      └─► UltraSock.initWithTls()                             │
       │          └─► conn.sock.connectWithBuffers()                  │
       │                                                              │
       │                    ┌──────────────────┐                      │
       │                    │   TCP HANDSHAKE  │                      │
       │                    └──────────────────┘                      │
       │                         SYN ─────────────────────────────────►
       │                     ◄───────────────────────────── SYN-ACK   │
       │                         ACK ─────────────────────────────────►
       │                                                              │
       │                    ┌──────────────────┐                      │
       │                    │   TLS HANDSHAKE  │                      │
       │                    └──────────────────┘                      │
       │                   ClientHello ───────────────────────────────►
       │                     (ALPN: h2, http/1.1)                     │
       │                   ◄─────────────────────────── ServerHello   │
       │                     (ALPN: h2)              + Certificate    │
       │                   ClientFinished ────────────────────────────►
       │                   ◄──────────────────────── ServerFinished   │
       │                                                              │
       │  conn.connect(io)                                            │
       │  └─► h2_client.connect()                                     │
       │                                                              │
       │                    ┌──────────────────┐                      │
       │                    │  HTTP/2 PREFACE  │                      │
       │                    └──────────────────┘                      │
       │              PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n ────────────────►
       │                   SETTINGS frame ────────────────────────────►
       │                   ◄──────────────────────── SETTINGS frame   │
       │                   SETTINGS ACK ──────────────────────────────►
       │                   ◄────────────────────────── SETTINGS ACK   │
       │                                                              │
       ▼                                                              ▼
  ┌──────────┐                                                  ┌──────────┐
  │ H2Conn   │                                                  │ Backend  │
  │ .ready   │                                                  │  Ready   │
  └──────────┘                                                  └──────────┘
```

### Phase 2: Request/Response Flow

```
  H2Connection                    Wire                              Backend
       │                                                              │
       │  conn.request(method, path, host, body, io)                  │
       │  │                                                           │
       │  ├─► write_mutex.lock()                                      │
       │  ├─► h2_client.sendRequest()                                 │
       │  │   └─► Queue HEADERS + DATA frames                         │
       │  ├─► h2_client.flush()                                       │
       │  │       HEADERS (stream=1, :method=GET, :path=/) ───────────►
       │  │       DATA (stream=1, body) ──────────────────────────────►
       │  ├─► write_mutex.unlock()                                    │
       │  │                                                           │
       │  ├─► stream_mutex.lock()                                     │
       │  ├─► spawnReader() [if not running]                          │
       │  │   └─► Io.async(readerTask)                                │
       │  │                                                           │
       │  └─► condition.wait()  ◄─────── [BLOCKED]                    │
       │                                                              │
       │                                                              │
       │  readerTask (async)                                          │
       │  │                                                           │
       │  ├─► sock.recv() ◄───────────────────────────────────────────│
       │  │       ◄─────────────────── HEADERS (stream=1, :status=200)│
       │  │       ◄─────────────────── DATA (stream=1, body)          │
       │  │       ◄─────────────────── DATA (stream=1, END_STREAM)    │
       │  │                                                           │
       │  ├─► dispatchFrame()                                         │
       │  │   └─► streams[slot].completed = true                      │
       │  │   └─► streams[slot].condition.signal() ───────────────────┐
       │  │                                                           │
       │  └─► [continues waiting for next frame]                      │
       │                                                              │
       │  request() resumes: ◄────────────────────────────────────────┘
       │  │                                                           │
       │  ├─► Build Response { status, headers, body }                │
       │  ├─► stream_mutex.unlock()                                   │
       │  └─► return Response                                         │
       │                                                              │
       │  pool.release(conn, success=true, io)                        │
       │  └─► state = .available  [back to pool]                      │
```

### Phase 3: Multiplexing (HTTP/2)

Multiple concurrent requests on same connection:

```
       │  Request A: stream=1                Request B: stream=3      │
       │       │                                   │                  │
       │       ├─► write_mutex.lock()              │                  │
       │       ├─► sendRequest() ──────────────────┼──────────────────►
       │       ├─► write_mutex.unlock()            │                  │
       │       │                                   │                  │
       │       │                    ├─► write_mutex.lock()            │
       │       │                    ├─► sendRequest() ────────────────►
       │       │                    ├─► write_mutex.unlock()          │
       │       │                                   │                  │
       │       ├─► condition.wait()  ├─► condition.wait()             │
       │       │                     │                                │
       │  readerTask dispatches to correct stream:                    │
       │       ◄──────────────────────────────── HEADERS (stream=3)   │
       │       ◄──────────────────────────────── HEADERS (stream=1)   │
       │       ◄──────────────────────────────── DATA (stream=1)      │
       │       ◄──────────────────────────────── DATA (stream=3)      │
       │       │                     │                                │
       │       ├─► signal(stream=1)  │                                │
       │       │                     ├─► signal(stream=3)             │
       │       ▼                     ▼                                │
       │  Response A            Response B                            │
```

### Phase 4: Shutdown Scenarios

#### Scenario A: Backend sends GOAWAY (graceful, after N requests)

```
  readerTask                      Wire                              Backend
       │                                                              │
       │  sock.recv()                                                 │
       │       ◄───────────────────────── GOAWAY (last_stream=2001)   │
       │                                                              │
       │  dispatchFrame() → handleGoaway()                            │
       │  └─► self.goaway_received = true                             │
       │  └─► return error.ConnectionGoaway                           │
       │                                                              │
       │  defer block executes:                                       │
       │  ┌────────────────────────────────────────────────────────┐  │
       │  │ was_clean_shutdown = false                             │  │
       │  │ state.* = .dead                                        │  │
       │  │ sock.sendCloseNotify(io) ─────────────────────────────────►
       │  │     └─► conn.close() → TLS close_notify alert          │  │
       │  │ sock.closeSocketOnly() ───────────────────────────────────►
       │  │     └─► posix.close(fd) → TCP FIN                      │  │
       │  │ signalAllStreams()                                     │  │
       │  │ reader_running.* = false                               │  │
       │  └────────────────────────────────────────────────────────┘  │
       │                                                              │
       │                   ◄────────────────────────── TCP FIN-ACK    │
       │                                                              │
       ▼                                                              ▼
  Connection                                                     Connection
    Closed                                                         Closed
```

#### Scenario B: Backend closes connection (idle timeout)

```
  readerTask                      Wire                              Backend
       │                                                              │
       │  sock.recv() [waiting for frame header]                      │
       │       ◄─────────────────────────────── TLS close_notify      │
       │       returns n=0 (EOF)                                      │
       │                                                              │
       │  "Reader: connection closed during header read"              │
       │  return (exits read loop)                                    │
       │                                                              │
       │  defer block executes:                                       │
       │  ┌────────────────────────────────────────────────────────┐  │
       │  │ was_clean_shutdown = false                             │  │
       │  │ state.* = .dead                                        │  │
       │  │ sock.sendCloseNotify(io) ─────────────────────────────────►
       │  │ sock.closeSocketOnly() ───────────────────────────────────►
       │  │ signalAllStreams()                                     │  │
       │  │ reader_running.* = false                               │  │
       │  └────────────────────────────────────────────────────────┘  │
       │                                                              │
       ▼                                                              ▼
  Connection                                                     Connection
    Closed                                                         Closed
```

#### Scenario C: Clean shutdown (pool.deinit or explicit close)

```
  pool/connection                 Wire                           readerTask
       │                                                              │
       │  conn.deinitAsync(io)                                        │
       │  │                                                           │
       │  ├─► shutdown_requested = true                               │
       │  │                                                           │
       │  ├─► if reader_running:                                      │
       │  │       sock.sendCloseNotify(io) ◄──────────────────────────│
       │  │           (unblocks recv)           sock.recv() returns   │
       │  │                                     with error/EOF        │
       │  │                                                           │
       │  ├─► future.await(io) ◄──────────── defer block runs:        │
       │  │       [waits]                    │ was_clean_shutdown=true│
       │  │                                  │ [skip close_notify]    │
       │  │                                  │ signalAllStreams()     │
       │  │       [resumes] ◄────────────────│ reader_running=false   │
       │  │                                  └────────────────────────│
       │  ├─► if state != .dead:                                      │
       │  │       sock.sendCloseNotify(io) ───────────────────────────►
       │  │                                                           │
       │  ├─► sock.closeSocketOnly() ─────────────────────────────────►
       │  │                                                           │
       │  └─► h2_client.deinit()                                      │
       │                                                              │
       ▼
  Connection
    Closed
```

### HTTP/2 Method Reference

| Module | Key Methods |
|--------|-------------|
| **H2ConnectionPool** (pool.zig) | `getOrCreate()` - Get/create pooled connection |
| | `release()` - Return connection to pool |
| | `destroyConnection()` - Cleanup dead connection |
| | `isConnectionStale()` - Check if conn needs cleanup |
| **H2Connection** (connection.zig) | `init()` - Create connection struct |
| | `connect()` - HTTP/2 handshake (preface) |
| | `request()` - Full request/response cycle |
| | `spawnReader()` - Start async reader task |
| | `deinitAsync()` - Graceful shutdown with Io |
| | `markDead()` - Mark connection unusable |
| **Http2Client** (client.zig) | `sendRequest()` - Queue request frames |
| | `flush()` - Send queued frames |
| | `readerTask()` - Async frame reader |
| | `dispatchFrame()` - Route frame to stream |
| | `handleGoaway()` - Process GOAWAY frame |
| | `signalAllStreams()` - Wake all waiting requests |
| **UltraSock** (ultra_sock.zig) | `connect()` - TCP + TLS connection |
| | `connectWithBuffers()` - Connect with custom TLS bufs |
| | `send_all()` - Send data (TLS encrypted) |
| | `recv()` - Receive data (TLS decrypted) |
| | `sendCloseNotify()` - Send TLS close_notify alert |
| | `closeSocketOnly()` - Close TCP (no TLS alert) |
| | `closeAsync()` - Full close (alert + TCP) |

### Protocol Layers

```
    ┌─────────────────────────────────────────────────────────────────────────┐
    │                          APPLICATION                                    │
    │                     (handler.zig, proxy)                                │
    ├─────────────────────────────────────────────────────────────────────────┤
    │                          HTTP/2 FRAMING                                 │
    │         (client.zig: HEADERS, DATA, SETTINGS, GOAWAY, etc.)             │
    ├─────────────────────────────────────────────────────────────────────────┤
    │                          TLS 1.3                                        │
    │    (ultra_sock.zig + vendor/tls: encryption, close_notify alerts)       │
    ├─────────────────────────────────────────────────────────────────────────┤
    │                          TCP                                            │
    │              (std.posix: SYN/ACK, FIN, socket I/O)                      │
    └─────────────────────────────────────────────────────────────────────────┘
```

### TLS Shutdown Critical Path

The TLS shutdown must send **both** close_notify AND close TCP:

```
  readerTask defer block:
  ┌────────────────────────────────────────────────────────────────────────┐
  │  if (!was_clean_shutdown) {                                            │
  │      state.* = .dead;                                                  │
  │      sock.sendCloseNotify(io);    ──► TLS close_notify alert           │
  │      sock.closeSocketOnly();      ──► TCP FIN                          │
  │  }                                                                     │
  │  signalAllStreams();              ──► Wake waiting requests            │
  │  reader_running.* = false;                                             │
  └────────────────────────────────────────────────────────────────────────┘

  Key insight: Backend (Python/hypercorn) waits for BOTH:
  ├── TLS close_notify  (sendCloseNotify)
  └── TCP close/FIN     (closeSocketOnly)

  Without TCP close, backend's wait_closed() times out!
```

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
