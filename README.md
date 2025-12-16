# Zig Load Balancer

A high-performance HTTP load balancer implemented in Zig using the zzz framework. Features nginx-style multi-process architecture, SIMD-accelerated parsing, and lock-free data structures.

**Requirements:** Zig 0.15.2+

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

## Architectures

### Multi-Process (Recommended)
```bash
./zig-out/bin/load_balancer_mp --workers 4 --port 8080
```

nginx-style architecture with separate worker processes:
- Each worker is single-threaded (no locks!)
- SO_REUSEPORT for kernel-level load balancing
- Crash isolation (one worker dies, master restarts it)
- Health checking with circuit breaker and failover
- ~17,770 req/s on macOS

### Multi-Threaded
```bash
./zig-out/bin/load_balancer --port 8080
```

Traditional multi-threaded with shared state:
- Lock-free connection pooling
- Atomic health bitmap
- ~17,148 req/s on macOS

## Health Checking & Failover

The multi-process load balancer includes a hybrid health checking system:

### Circuit Breaker (Passive)
Learns from actual request failures:
- Tracks consecutive failures per backend
- Marks backend **unhealthy** after 3 consecutive failures
- Marks backend **healthy** after 2 consecutive successes
- Instant failover to healthy backend on failure

### Health Probes (Active)
Async probes run in the event loop without blocking requests:
- Probes each backend every 5 seconds
- Sends `GET /` and expects HTTP 200
- Updates health state based on probe results
- Non-blocking: uses tardy's async I/O

### Automatic Failover
```
Request → Backend 1 (fails) → Backend 2 (success) → Response
              │                    │
              └── Circuit breaker  └── Success recorded
                  failure recorded
```

### Configuration
Health settings in `src/multiprocess/config.zig`:
```zig
pub const HealthConfig = struct {
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
--workers, -w N    Worker processes (default: CPU count)
--port, -p N       Listen port (default: 8080)
--host, -h IP      Listen address (default: 0.0.0.0)
```

### YAML Config (multi-threaded only)
```yaml
backends:
  - host: "127.0.0.1"
    port: 9001
    weight: 2
  - host: "127.0.0.1"
    port: 9002
    weight: 1
```

## Project Structure

```
├── main.zig                    # Multi-threaded entry point
├── main_multiprocess.zig       # Multi-process entry point
├── src/
│   ├── multiprocess/           # Multi-process module
│   │   ├── mod.zig             # Re-exports
│   │   ├── config.zig          # Config, health state, circuit breaker
│   │   ├── proxy.zig           # Streaming proxy, failover
│   │   └── health.zig          # Async health probes
│   ├── core/                   # Proxy logic, load balancing
│   ├── memory/                 # Connection pools, arena allocators
│   ├── internal/               # SIMD parsing, optimizations
│   └── http/                   # HTTP utilities
└── vendor/                     # Vendored dependencies
```

## Dependencies

All dependencies are vendored in `vendor/` and patched for Zig 0.15.2:
- **zzz** - HTTP framework
- **tardy** - Async runtime (io_uring on Linux, kqueue on macOS)
- **secsock** - TLS support
- **zig-clap** - CLI parsing

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
