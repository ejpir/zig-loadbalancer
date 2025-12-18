# Zig Load Balancer

A high-performance HTTP/HTTPS load balancer implemented in Zig using zzz.io (Zig 0.16's native async I/O). Features nginx-style multi-process architecture, TLS termination to HTTPS backends, SIMD-accelerated parsing, and lock-free data structures.

**Requirements:** Zig 0.16.0+

## Quick Start

```bash
# Clone the repo
git clone https://github.com/ejpir/zig-loadbalancer.git
cd zig-loadbalancer

# Build everything (dependencies are vendored)
zig build -Doptimize=ReleaseFast

# Start backends (in separate terminals)
./zig-out/bin/backend1  # Port 9001
./zig-out/bin/backend2  # Port 9002

# Start load balancer (multi-process, 4 workers)
./zig-out/bin/load_balancer_mp --workers 4 --port 8080

# Test it
curl http://localhost:8080
```

## Architecture

### C4 Model

**Level 1: System Context**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SYSTEM CONTEXT                                 │
└─────────────────────────────────────────────────────────────────────────────┘

    ┌──────────┐                                           ┌──────────────┐
    │  Client  │                                           │   Backend    │
    │ (Browser,│         ┌────────────────────┐            │   Servers    │
    │   CLI,   │────────►│   Load Balancer    │───────────►│  (HTTP/S)    │
    │   App)   │  HTTP   │                    │  HTTP/TLS  │              │
    └──────────┘         │  [Zig Application] │            └──────────────┘
                         └────────────────────┘
                                   │
                                   ▼
                         ┌────────────────────┐
                         │     Metrics        │
                         │   (Prometheus)     │
                         └────────────────────┘
```

**Level 2: Container (Multi-Process)**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CONTAINER: Load Balancer                            │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ MASTER PROCESS                                                              │
│ ┌─────────────────┐                                                         │
│ │  Process Mgr    │  • fork() workers                                       │
│ │                 │  • waitpid() monitor                                    │
│ │                 │  • Restart on crash                                     │
│ └─────────────────┘                                                         │
└───────────┬───────────────────────┬───────────────────────┬─────────────────┘
            │ fork()                │ fork()                │ fork()
            ▼                       ▼                       ▼
┌───────────────────┐   ┌───────────────────┐   ┌───────────────────┐
│ WORKER 0          │   │ WORKER 1          │   │ WORKER N          │
│ ┌───────────────┐ │   │ ┌───────────────┐ │   │ ┌───────────────┐ │
│ │ HTTP Server   │ │   │ │ HTTP Server   │ │   │ │ HTTP Server   │ │
│ │ (zzz.io)      │ │   │ │ (zzz.io)      │ │   │ │ (zzz.io)      │ │
│ └───────┬───────┘ │   │ └───────┬───────┘ │   │ └───────┬───────┘ │
│         ▼         │   │         ▼         │   │         ▼         │
│ ┌───────────────┐ │   │ ┌───────────────┐ │   │ ┌───────────────┐ │
│ │ Proxy Engine  │ │   │ │ Proxy Engine  │ │   │ │ Proxy Engine  │ │
│ └───────┬───────┘ │   │ └───────┬───────┘ │   │ └───────┬───────┘ │
│         ▼         │   │         ▼         │   │         ▼         │
│ ┌───────────────┐ │   │ ┌───────────────┐ │   │ ┌───────────────┐ │
│ │ Connection    │ │   │ │ Connection    │ │   │ │ Connection    │ │
│ │ Pool          │ │   │ │ Pool          │ │   │ │ Pool          │ │
│ └───────────────┘ │   │ └───────────────┘ │   │ └───────────────┘ │
│ ┌───────────────┐ │   │ ┌───────────────┐ │   │ ┌───────────────┐ │
│ │ Health Thread │ │   │ │ Health Thread │ │   │ │ Health Thread │ │
│ └───────────────┘ │   │ └───────────────┘ │   │ └───────────────┘ │
└─────────┬─────────┘   └─────────┬─────────┘   └─────────┬─────────┘
          │ SO_REUSEPORT          │                       │
          └───────────────────────┼───────────────────────┘
                                  ▼
                           ┌────────────┐
                           │ Port 8080  │◄─── Clients
                           └────────────┘
```

**Level 2: Container (Single-Process)**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    CONTAINER: Load Balancer (Single-Process)                │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ SINGLE PROCESS                                                              │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ MAIN THREAD (std.Io.Threaded async runtime)                         │   │
│  │                                                                      │   │
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐              │   │
│  │  │ HTTP Server │───►│   Router    │───►│   Proxy     │              │   │
│  │  │  (zzz.io)   │    │             │    │  Engine     │              │   │
│  │  └─────────────┘    └─────────────┘    └──────┬──────┘              │   │
│  │                                               │                      │   │
│  │                                               ▼                      │   │
│  │                                        ┌─────────────┐               │   │
│  │                                        │ UltraSock   │               │   │
│  │                                        │ (TCP/TLS)   │               │   │
│  │                                        └─────────────┘               │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌────────────────────────┐    ┌────────────────────────────────────────┐  │
│  │ HEALTH THREAD          │    │ SHARED STATE                           │  │
│  │                        │    │                                        │  │
│  │ • Probe backends       │◄──►│ ┌──────────────┐  ┌─────────────────┐ │  │
│  │ • Update health bitmap │    │ │ WorkerState  │  │ ConnectionPool  │ │  │
│  │ • Blocking I/O         │    │ │ (circuit brk)│  │ (per-backend)   │ │  │
│  │                        │    │ └──────────────┘  └─────────────────┘ │  │
│  └────────────────────────┘    └────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                ┌──────┴──────┐
                                │  Port 8080  │◄─── Clients
                                └─────────────┘
```

**Level 3: Component (Proxy Engine)**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          COMPONENT: Proxy Engine                            │
└─────────────────────────────────────────────────────────────────────────────┘

                    ┌─────────────────────────────────────┐
                    │            proxy.zig                │
 HTTP Request ─────►│                                     │
                    │  ┌───────────────────────────────┐  │
                    │  │     Backend Selector          │  │
                    │  │  ┌─────────────────────────┐  │  │
                    │  │  │ • Round-robin           │  │  │
                    │  │  │ • Random                │  │  │
                    │  │  │ • Weighted round-robin  │  │  │
                    │  │  │ • Sticky sessions       │  │  │
                    │  │  └─────────────────────────┘  │  │
                    │  └───────────────┬───────────────┘  │
                    │                  │                  │
                    │                  ▼                  │
                    │  ┌───────────────────────────────┐  │
                    │  │     Circuit Breaker           │  │
                    │  │  ┌─────────────────────────┐  │  │
                    │  │  │ Health bitmap (u64)     │  │  │
                    │  │  │ Failure counters        │  │  │
                    │  │  │ Success counters        │  │  │
                    │  │  └─────────────────────────┘  │  │
                    │  └───────────────┬───────────────┘  │
                    │                  │                  │
                    │                  ▼                  │
                    │  ┌───────────────────────────────┐  │
                    │  │     Connection Pool           │  │
                    │  │  ┌─────────────────────────┐  │  │
                    │  │  │ Per-backend stacks      │  │  │
                    │  │  │ LIFO reuse              │  │  │
                    │  │  └─────────────────────────┘  │  │
                    │  └───────────────┬───────────────┘  │
                    │                  │                  │
                    │                  ▼                  │
                    │  ┌───────────────────────────────┐  │
                    │  │     UltraSock                 │  │
                    │  │  ┌─────────────────────────┐  │  │
                    │  │  │ TCP (port != 443)       │  │  │
                    │  │  │ TLS (port == 443)       │  │  │
                    │  │  │ DNS resolution          │  │  │
                    │  │  └─────────────────────────┘  │  │
                    │  └───────────────┬───────────────┘  │
                    │                  │                  │
                    └──────────────────┼──────────────────┘
                                       │
                                       ▼
                              ┌─────────────────┐
                              │ Backend Server  │
                              │ (HTTP or HTTPS) │
                              └─────────────────┘
```

### Multi-Process Overview (Recommended)

```
                            ┌─────────────────────────────────────────────────────────┐
                            │                    MASTER PROCESS                       │
                            │                                                         │
                            │   • Forks worker processes                              │
                            │   • Monitors workers via waitpid()                      │
                            │   • Restarts crashed workers                            │
                            │   • Does NOT handle requests                            │
                            │                                                         │
                            └────────────────────────┬────────────────────────────────┘
                                                     │ fork()
                       ┌─────────────────────────────┼─────────────────────────────┐
                       │                             │                             │
                       ▼                             ▼                             ▼
        ┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐
        │       WORKER 0           │  │       WORKER 1           │  │       WORKER N           │
        │                          │  │                          │  │                          │
        │  ┌────────────────────┐  │  │  ┌────────────────────┐  │  │  ┌────────────────────┐  │
        │  │   std.Io Runtime   │  │  │  │   std.Io Runtime   │  │  │  │   std.Io Runtime   │  │
        │  │  (single-threaded) │  │  │  │  (single-threaded) │  │  │  │  (single-threaded) │  │
        │  └────────────────────┘  │  │  └────────────────────┘  │  │  └────────────────────┘  │
        │                          │  │                          │  │                          │
        │  ┌────────────────────┐  │  │  ┌────────────────────┐  │  │  ┌────────────────────┐  │
        │  │  Connection Pool   │  │  │  │  Connection Pool   │  │  │  │  Connection Pool   │  │
        │  │   (no atomics!)    │  │  │  │   (no atomics!)    │  │  │  │   (no atomics!)    │  │
        │  └────────────────────┘  │  │  └────────────────────┘  │  │  └────────────────────┘  │
        │                          │  │                          │  │                          │
        │  ┌────────────────────┐  │  │  ┌────────────────────┐  │  │  ┌────────────────────┐  │
        │  │   Health State     │  │  │  │   Health State     │  │  │  │   Health State     │  │
        │  │ (circuit breaker)  │  │  │  │ (circuit breaker)  │  │  │  │ (circuit breaker)  │  │
        │  └────────────────────┘  │  │  └────────────────────┘  │  │  └────────────────────┘  │
        │                          │  │                          │  │                          │
        └──────────┬───────────────┘  └──────────┬───────────────┘  └──────────┬───────────────┘
                   │                             │                             │
                   │ SO_REUSEPORT                │ SO_REUSEPORT                │ SO_REUSEPORT
                   │                             │                             │
                   └─────────────────────────────┼─────────────────────────────┘
                                                 │
                                          ┌──────┴──────┐
                                          │  Port 8080  │
                                          │   (kernel   │
                                          │   balances) │
                                          └──────┬──────┘
                                                 │
                                            Clients
```

**Key Benefits:**
- **Zero lock contention**: Each worker has its own state (no shared memory)
- **Crash isolation**: One worker dies, others continue serving
- **SO_REUSEPORT**: Kernel distributes connections across workers
- **CPU affinity**: Each worker pinned to a CPU core (Linux)

### Multi-Process Request Flow

```
┌────────┐     ┌──────────────────────────────────────────────────────────────────────┐
│ Client │     │                         WORKER PROCESS                               │
└───┬────┘     │                                                                      │
    │          │  ┌─────────┐    ┌─────────────┐    ┌─────────────┐    ┌───────────┐  │
    │ Request  │  │  HTTP   │    │   Router    │    │   Proxy     │    │  Backend  │  │
    ├─────────►│  │ Server  ├───►│ (strategy)  ├───►│ (streaming) ├───►│  Select   │  │
    │          │  └─────────┘    └─────────────┘    └──────┬──────┘    └─────┬─────┘  │
    │          │                                          │                  │        │
    │          │                                          │   ┌──────────────┴─────┐  │
    │          │                                          │   │ Health-aware pick: │  │
    │          │                                          │   │ • Round-robin      │  │
    │          │                                          │   │ • Skip unhealthy   │  │
    │          │                                          │   └──────────────┬─────┘  │
    │          │                                          │                  │        │
    │          │                                          ▼                  │        │
    │          │                                   ┌─────────────┐           │        │
    │          │                                   │ Connection  │◄──────────┘        │
    │          │                                   │    Pool     │                    │
    │          │                                   │ (get/return)│                    │
    │          │                                   └──────┬──────┘                    │
    │          │                                          │                           │
    │          └──────────────────────────────────────────┼───────────────────────────┘
    │                                                     │
    │                                                     ▼
    │                                              ┌─────────────┐
    │                                              │  UltraSock  │
    │                                              │ (TCP/TLS)   │
    │                                              └──────┬──────┘
    │                                                     │
    │                                        Port 443? ───┼───► TLS handshake
    │                                                     │     (ianic/tls.zig)
    │                                                     ▼
    │                                              ┌─────────────┐
    │                                              │  Backend 1  │──► Success: record success
    │                                              │  (primary)  │    Update circuit breaker
    │                                              └──────┬──────┘
    │                                                     │
    │                                                     │ Fail?
    │                                                     ▼
    │                                              ┌─────────────┐
    │                                              │  Backend 2  │──► Failover attempt
    │                                              │ (failover)  │    Record failure on primary
    │                                              └──────┬──────┘
    │                                                     │
    │          ┌──────────────────────────────────────────┘
    │          │
    │◄─────────┤  Response (streamed back)
    │          │
    │          │  Meanwhile, health probe thread runs:
    │          │  ┌─────────────────────────────────────┐
    │          │  │  sleep(5s) ──► Probe backends       │
    │          │  │  Update health bitmap               │
    │          │  │  (blocking I/O, separate thread)    │
    │          │  └─────────────────────────────────────┘
    │          │
└───┴──────────┘
```

### Startup Flow

```
main() ─────────────────────────────────────────────────────────────────────────────────►

    │
    ├─► Parse CLI args (--workers, --port, --backend)
    │
    ├─► for worker_id in 0..worker_count:
    │       │
    │       ├─► fork()
    │       │     │
    │       │     ├─► [CHILD] workerMain(config)
    │       │     │             ├─► Create GPA (thread_safe=true for health thread)
    │       │     │             ├─► Create ConnectionPool
    │       │     │             ├─► Create BackendsList
    │       │     │             ├─► Create WorkerState (circuit breaker, health)
    │       │     │             ├─► Start health probe background thread
    │       │     │             ├─► Create std.Io runtime (captures CPU count)
    │       │     │             ├─► setCpuAffinity(worker_id)  // AFTER Io.init!
    │       │     │             ├─► Create Router with proxy handler
    │       │     │             ├─► Socket.listen() with SO_REUSEPORT
    │       │     │             └─► HTTP server.serve()
    │       │     │
    │       │     └─► [PARENT] worker_pids[worker_id] = pid
    │
    └─► [MASTER] Loop forever:
            waitpid(-1) ──► Worker died? ──► Fork replacement
```

### Multi-Process Architecture

```bash
# Start with 4 worker processes
./zig-out/bin/load_balancer_mp --workers 4 --port 8080
```

| Aspect | Benefit |
|--------|---------|
| Isolation | Full process isolation - one worker crash doesn't affect others |
| Locks | None (nothing shared between workers) |
| Crash handling | Master process monitors and restarts crashed workers |
| Memory | Separate heaps per worker - no contention |
| Connection pool | SimpleConnectionPool - no atomics needed |
| Health probes | Background thread per worker - independent health state |

### Single-Process Architecture (Alternative)

For simpler deployments or macOS (where SO_REUSEPORT doesn't provide kernel load balancing):

```bash
# Start single-process load balancer
./zig-out/bin/load_balancer_sp --port 8080 --strategy round_robin
```

```
┌─────────────────────────────────────────────────────────────┐
│                    SINGLE PROCESS                           │
│                                                             │
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │  std.Io.Threaded │    │  Health Probe   │                │
│  │  (async runtime) │    │    Thread       │                │
│  └────────┬────────┘    └────────┬────────┘                │
│           │                      │                          │
│           ▼                      ▼                          │
│  ┌─────────────────────────────────────────┐               │
│  │           Shared State                   │               │
│  │  ┌─────────────┐  ┌──────────────────┐  │               │
│  │  │ Connection  │  │  WorkerState     │  │               │
│  │  │    Pool     │  │ (circuit breaker)│  │               │
│  │  └─────────────┘  └──────────────────┘  │               │
│  └─────────────────────────────────────────┘               │
│                                                             │
└──────────────────────────┬──────────────────────────────────┘
                           │
                    ┌──────┴──────┐
                    │  Port 8080  │
                    └──────┬──────┘
                           │
                      Clients
```

**Single-Process Startup Flow:**

```
main() ──────────────────────────────────────────────────────────────────────►

    │
    ├─► Parse CLI args (--port, --host, --backend, --strategy)
    │
    ├─► Create GPA (thread_safe=true for health thread)
    │
    ├─► Create shared ConnectionPool
    │
    ├─► Create BackendsList
    │
    ├─► Create WorkerState (circuit breaker, health)
    │
    ├─► Start health probe background thread
    │
    ├─► Create std.Io.Threaded runtime (internal thread pool)
    │
    ├─► Create Router with proxy handler
    │
    ├─► Socket.listen() (no SO_REUSEPORT needed)
    │
    └─► HTTP server.serve()
```

| Aspect | Multi-Process | Single-Process |
|--------|---------------|----------------|
| **Concurrency** | fork() per worker | std.Io.Threaded async runtime |
| **Isolation** | Full process isolation | Shared memory |
| **macOS support** | Limited (SO_REUSEPORT) | Full support |
| **Memory** | Higher (process duplication) | Lower footprint |
| **Connection pool** | Per-worker (no locks) | Shared (GPA thread-safe) |
| **Crash handling** | Master restarts workers | Process dies |
| **Best for** | Linux production | macOS, simple deployments |

**CLI Options (Single-Process):**
```
--port, -p N         Listen port (default: 8080)
--host, -h IP        Listen address (default: 0.0.0.0)
--backend, -b H:P    Add backend server (can specify multiple)
--strategy, -s NAME  Load balancing strategy: round_robin, random, weighted
```

## Health Checking & Failover

The multi-process load balancer includes a hybrid health checking system:

### Circuit Breaker (Passive)
Learns from actual request failures:
- Tracks consecutive failures per backend
- Marks backend **unhealthy** after 3 consecutive failures
- Marks backend **healthy** after 2 consecutive successes
- Instant failover to healthy backend on failure

### Health Probes (Active)
Background thread probes run independently of request handling:
- Probes each backend every 5 seconds
- Sends `GET /` and expects HTTP 200
- Updates health state based on probe results
- Uses blocking I/O in dedicated thread (no event loop interference)

### Automatic Failover
```
Request → Backend 1 (fails) → Backend 2 (success) → Response
              │                    │
              └── Circuit breaker  └── Success recorded
                  failure recorded
```

### Configuration
Health settings in `src/multiprocess/worker_state.zig`:
```zig
pub const Config = struct {
    unhealthy_threshold: u32 = 3,      // Failures before unhealthy
    healthy_threshold: u32 = 2,        // Successes before healthy
    probe_interval_ms: u64 = 5000,     // Probe every 5s
    probe_timeout_ms: u64 = 2000,      // 2s timeout
    health_path: []const u8 = "/",     // Health check endpoint
};
```

## High Availability

For production HA, run multiple load balancer instances:

### Active-Passive with Keepalived (Recommended)
```
            Virtual IP (192.168.1.100)
                     │
         ┌───────────┴───────────┐
         ▼                       ▼
   ┌───────────┐           ┌───────────┐
   │  Primary  │◄─────────►│ Secondary │
   │    LB     │ heartbeat │    LB     │
   │ (MASTER)  │           │ (BACKUP)  │
   └───────────┘           └───────────┘
```

Install keepalived on both nodes:
```bash
apt install keepalived
```

Primary node (`/etc/keepalived/keepalived.conf`):
```
vrrp_instance LB_VIP {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    virtual_ipaddress {
        192.168.1.100
    }
}
```

Secondary node (same, but `state BACKUP` and `priority 50`).

Failover happens in ~1-3 seconds when primary dies.

### Other HA Patterns

| Pattern | Description | Use Case |
|---------|-------------|----------|
| **DNS Failover** | Multiple A records, health checks remove failed nodes | Cloud/managed DNS |
| **Anycast + BGP** | Same IP from multiple locations, network routes to nearest | Global distribution |
| **L4 in front** | NLB/HAProxy L4 distributes to multiple L7 LBs | High scale |

### How ALB Works (Reference)
```
                    Route 53 (DNS)
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
     ┌─────────┐   ┌─────────┐   ┌─────────┐
     │  AZ-1   │   │  AZ-2   │   │  AZ-3   │
     │ LB Nodes│   │ LB Nodes│   │ LB Nodes│
     └────┬────┘   └────┬────┘   └────┬────┘
          └──────────────┼──────────────┘
                         ▼
                   Backend Targets
```
- Multiple stateless LB nodes per AZ
- DNS returns IPs for each AZ
- Auto-scales nodes based on traffic
- Cross-zone load balancing

## Performance

**Benchmark:** 100,000 requests, 200 concurrent connections, ReleaseFast

| Mode | Throughput | p50 Latency | Efficiency |
|------|-----------|-------------|------------|
| Backend direct | 20,063 req/s | - | 100% |
| Multi-process | 17,770 req/s | 9.0ms | 89% |
| Multi-threaded | 17,148 req/s | 9.1ms | 85% |

### Optimizations
- **SIMD parsing**: AVX2-accelerated header boundary detection
- **Arena allocators**: Per-request bulk allocation/deallocation
- **SimpleConnectionPool**: No atomics in single-threaded workers
- **StaticStringMap**: O(1) header filtering
- **Streaming proxy**: Zero-buffering response forwarding

## Configuration

### Command Line
```
--workers, -w N      Worker processes (default: CPU count)
--port, -p N         Listen port (default: 8080)
--host, -h IP        Listen address (default: 0.0.0.0)
--backend, -b H:P    Add backend server (can specify multiple)
```

### Dynamic Backend Configuration
```bash
# Configure backends via command line
./zig-out/bin/load_balancer_mp -b 192.168.1.10:8080 -b 192.168.1.11:8080
```

## TLS/HTTPS Support

The load balancer supports both HTTP and HTTPS backends automatically.

### HTTPS Backends
Backends on port 443 are automatically connected via TLS:
```bash
# Proxy to HTTPS backend (e.g., httpbin.org)
./zig-out/bin/load_balancer_mp -b httpbin.org:443 -p 8080

# Test it
curl http://localhost:8080/ip
```

### Mixed Backends
You can mix HTTP and HTTPS backends:
```bash
# Mix local HTTP and remote HTTPS backends
./zig-out/bin/load_balancer_mp \
  -b localhost:9001 \
  -b httpbin.org:443 \
  -p 8080
```

### TLS Implementation
- Uses [ianic/tls.zig](https://github.com/ianic/tls.zig) for TLS 1.2/1.3
- System CA trust store for certificate verification
- Async I/O via `std.Io` (io_uring/kqueue)
- Automatic protocol detection based on port (443 = HTTPS)

### Architecture
```
Client ──► Load Balancer ──► Backend (HTTP or HTTPS)
           (HTTP)              │
                               ├── Port 80/8080: Plain TCP
                               └── Port 443: TLS encrypted
```

The load balancer accepts plain HTTP from clients and can proxy to either HTTP or HTTPS backends. TLS connections to backends use the system CA bundle for certificate verification.

## Project Structure

```
├── main_multiprocess.zig       # Multi-process entry point (recommended)
├── main_singleprocess.zig      # Single-process threaded entry point
├── backend1.zig                # Test backend server 1
├── backend2.zig                # Test backend server 2
├── src/
│   ├── core/
│   │   └── types.zig           # BackendServer, LoadBalancerStrategy
│   ├── http/
│   │   ├── ultra_sock.zig      # HTTP/HTTPS socket with TLS support
│   │   └── http_utils.zig      # RFC 7230 message length detection
│   ├── internal/
│   │   └── simd_parse.zig      # SIMD header/chunk boundary detection
│   ├── memory/
│   │   └── simple_connection_pool.zig  # Lock-free connection pooling
│   ├── multiprocess/
│   │   ├── mod.zig             # Module re-exports
│   │   ├── proxy.zig           # Streaming proxy with failover
│   │   ├── worker_state.zig    # Per-worker state management
│   │   ├── circuit_breaker.zig # Circuit breaker pattern
│   │   ├── backend_selector.zig# Load balancing strategies
│   │   ├── health_state.zig    # Health bitmap (u64-based)
│   │   ├── health.zig          # Background health probes
│   │   └── connection_reuse.zig# Keep-alive detection
│   ├── utils/
│   │   └── metrics.zig         # Prometheus metrics endpoint
│   └── test_load_balancer.zig  # Unit test runner
├── vendor/
│   ├── zzz.io/                 # HTTP framework (vendored)
│   └── tls/                    # TLS 1.2/1.3 library (vendored)
```

## Dependencies

All dependencies are vendored (no network fetch required):

- **zzz.io** - HTTP framework using Zig 0.16's native `std.Io` async runtime (io_uring on Linux, kqueue on macOS)
- **ianic/tls.zig** - TLS 1.2/1.3 implementation with system CA support

## Building

```bash
# Debug build (verbose logging)
zig build

# Release build (recommended)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

### Log Levels
Set in `main_multiprocess.zig`:
```zig
.log_level = .debug,  // Verbose: all probe results
.log_level = .warn,   // Health state changes only
.log_level = .err,    // Silent (for benchmarks)
```

## License

MIT
