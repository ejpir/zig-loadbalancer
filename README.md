# Zig Load Balancer

A blazing-fast HTTP load balancer written in Zig. nginx-style architecture, zero dependencies beyond the Zig standard library.

```
Client ──► Load Balancer ──► Backend Servers
              │
              ├── Automatic failover
              ├── Health checking
              ├── TLS to HTTPS backends
              └── Hot reload (zero-downtime config)
```

## Why?

- **Fast**: 17,000+ req/s with ~10% overhead vs direct
- **Simple**: Single binary, no config files needed
- **Safe**: Memory-safe Zig, no garbage collector pauses
- **Observable**: Prometheus metrics built-in

## Quick Start

```bash
zig build -Doptimize=ReleaseFast

# Start your backends
./zig-out/bin/backend1 &
./zig-out/bin/backend2 &

# Run the load balancer (auto-selects mode based on platform)
./zig-out/bin/load_balancer -p 8080 -b 127.0.0.1:9001 -b 127.0.0.1:9002

# Or explicitly choose a mode
./zig-out/bin/load_balancer --mode mp -w 4 -p 8080 -b 127.0.0.1:9001 -b 127.0.0.1:9002

# Test it
curl http://localhost:8080
```

## How It Works

**Multi-process architecture** (like nginx):

```
Master Process
     │
     ├── fork() ──► Worker 0 ──► handles requests
     ├── fork() ──► Worker 1 ──► handles requests
     └── fork() ──► Worker N ──► handles requests
                        │
                   SO_REUSEPORT
                        │
                   Port 8080
```

Each worker is completely isolated:
- Own connection pool (no locks!)
- Own health state (no coordination!)
- Crashes don't affect siblings

The master just watches for dead workers and respawns them.

## Health Checking

Two layers of protection:

**Passive** — Learn from failures
- 3 failures in a row → backend marked down
- 2 successes → backend back up
- Instant failover on error

**Active** — Background probes
- Checks each backend every 5 seconds
- `GET /` expecting HTTP 200
- Catches problems before users hit them

## HTTPS Backends

Port 443 automatically uses TLS:

```bash
./zig-out/bin/load_balancer -b httpbin.org:443 -p 8080
curl http://localhost:8080/ip  # Proxied over TLS
```

Mix HTTP and HTTPS backends freely.

## Options

```
-m, --mode MODE      Run mode: mp (multiprocess) or sp (singleprocess)
                     Default: mp on Linux, sp on macOS
-w, --workers N      Worker count for mp mode (default: CPU cores)
-p, --port N         Listen port (default: 8080)
-h, --host HOST      Listen host (default: 0.0.0.0)
-b, --backend H:P    Backend server (repeat for multiple)
-s, --strategy S     Load balancing: round_robin, weighted, random
-c, --config FILE    JSON config file for hot reload (watches for changes)
-l, --loglevel LVL   Log level: err, warn, info, debug (default: info)
-k, --insecure       Skip TLS certificate verification (testing only!)
-t, --trace          Dump raw request/response payloads (hex + ASCII)
--help               Show help message
```

## Configuration Reference

All configuration options with defaults from `src/core/config.zig`:

### Server Settings

| Option | CLI Flag | Default | Description |
|--------|----------|---------|-------------|
| `host` | `-h, --host` | `0.0.0.0` | Listen address. Use `127.0.0.1` for localhost only |
| `port` | `-p, --port` | `8080` | Listen port |
| `worker_count` | `-w, --workers` | `0` (auto) | Worker processes. 0 = auto-detect CPU cores |

### Backend Settings

| Option | CLI Flag | Default | Description |
|--------|----------|---------|-------------|
| `backends` | `-b, --backend` | (required) | Backend servers as `host:port` |
| `strategy` | `-s, --strategy` | `round_robin` | Load balancing algorithm |

**Strategies:**
- `round_robin` — Cycle through backends sequentially (fairest)
- `weighted_round_robin` — Distribute based on backend weights
- `random` — Random selection (good for stateless services)

### Health Check Settings

| Option | Default | Description |
|--------|---------|-------------|
| `unhealthy_threshold` | `3` | Consecutive failures before marking unhealthy |
| `healthy_threshold` | `2` | Consecutive successes before marking healthy |
| `probe_interval_ms` | `5000` | Milliseconds between active health probes |
| `probe_timeout_ms` | `2000` | Timeout for health probe requests |
| `health_path` | `/` | HTTP path for health checks (expects 2xx) |

### TLS Settings

| Option | CLI Flag | Default | Description |
|--------|----------|---------|-------------|
| `insecure_tls` | `-k, --insecure` | `false` | Skip TLS verification (testing only) |
| `DEFAULT_TLS_VERIFY_CA` | — | `true` | Verify CA certificates using system trust store |
| `DEFAULT_TLS_VERIFY_HOST` | — | `true` | Verify hostname matches certificate |

TLS is automatically enabled for port 443. To disable verification for testing:

```bash
# Skip TLS verification (self-signed certs, local dev)
./zig-out/bin/load_balancer -k -b localhost:8443

# WARNING: Do not use --insecure in production!
```

### Debugging

| Option | CLI Flag | Default | Description |
|--------|----------|---------|-------------|
| `trace` | `-t, --trace` | `false` | Dump raw payloads as hex + ASCII |
| `tls_trace` | `--tls-trace` | `false` | Show detailed TLS handshake info |

#### Payload Tracing (`--trace`)

See exactly what's being sent/received:

```bash
./zig-out/bin/load_balancer -t -b httpbin.org:443 -p 8080
```

Output (hexdump -C format):
```
info(trace): === REQUEST TO BACKEND (104 bytes) ===
info(trace): 00000000  47 45 54 20 2f 69 70 20  48 54 54 50 2f 31 2e 31  |GET /ip HTTP/1.1|
info(trace): 00000010  0d 0a 48 6f 73 74 3a 20  68 74 74 70 62 69 6e 2e  |..Host: httpbin.|
...
```

#### TLS Tracing (`--tls-trace`)

See detailed TLS handshake information:

```bash
./zig-out/bin/load_balancer --tls-trace -b httpbin.org:443 -p 8080
```

Output:
```
info(tls_trace): === TLS Handshake Complete ===
info(tls_trace):   Host: httpbin.org:443
info(tls_trace):   Version: TLS 1.3
info(tls_trace):   Cipher Suite: AES_256_GCM_SHA384
info(tls_trace):   CA Verification: system trust store
info(tls_trace):   Host Verification: enabled
info(tls_trace):   CA Certificates: 165 loaded
```

TLS trace shows:
- TLS protocol version (1.2 or 1.3)
- Negotiated cipher suite
- CA verification mode (none/system/custom)
- Hostname verification mode
- Number of CA certificates loaded

**Performance:** Zero overhead when disabled (inline boolean check, branch prediction).

### Compile-Time Constants

These cannot be changed at runtime (defined in `src/core/config.zig`):

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_BACKENDS` | `64` | Maximum backends (limited by u64 health bitmap) |
| `MAX_HOST_LEN` | `253` | Maximum hostname length (RFC 1035) |
| `MAX_HEADER_BYTES` | `8192` | Maximum HTTP header size |
| `MAX_BODY_CHUNK_BYTES` | `8192` | Maximum body chunk size for streaming |
| `MAX_HEADER_LINES` | `256` | Maximum header lines per request/response |
| `MAX_IDLE_CONNS` | `128` | Idle connections per backend in pool |
| `MAX_HEADER_READ_ITERATIONS` | `1024` | Max iterations reading headers (prevents infinite loops) |
| `MAX_BODY_READ_ITERATIONS` | `1000000` | Max iterations reading body |
| `MAX_CONFIG_SIZE` | `64KB` | Maximum config file size |
| `PAGE_SIZE` | system | Memory page size for alignment |
| `VECTOR_SIZE` | `32` | SIMD vector size for parsing |
| `SIMD_THRESHOLD` | `64` | Minimum buffer size before using SIMD |
| `NS_PER_MS` | `1000000` | Nanoseconds per millisecond |

### JSON Config File

Use `-c, --config` for hot-reloadable backends:

```json
{
  "backends": [
    {"host": "127.0.0.1", "port": 9001},
    {"host": "127.0.0.1", "port": 9002, "weight": 2},
    {"host": "api.example.com", "port": 443, "tls": true}
  ]
}
```

**Backend fields:**
- `host` (required) — Hostname or IP address
- `port` (required) — Port number
- `weight` (default: 1) — Weight for weighted_round_robin strategy
- `tls` (default: false) — Enable TLS for this backend

The file is watched for changes and reloaded automatically (zero downtime).

## Modes

The unified `load_balancer` binary supports two execution modes:

**Multi-process (mp)** — nginx-style fork() with SO_REUSEPORT. Each worker is a separate process with its own event loop, connection pool, and health state. Zero lock contention, crash isolation, best for Linux production.

```bash
./zig-out/bin/load_balancer --mode mp -w 4 -p 8080 -b localhost:9001
```

**Single-process (sp)** — One process with internal thread pool. Uses shared memory region for config hot reload and shared round-robin counter. Best for macOS (where SO_REUSEPORT doesn't load-balance) or development.

```bash
./zig-out/bin/load_balancer --mode sp -p 8080 -b localhost:9001
```

Both modes support hot reload (`-c`) and binary upgrades (SIGUSR2). The binary auto-selects the best mode for your platform if `--mode` is not specified.

Legacy binaries `load_balancer_mp` and `load_balancer_sp` are still available for backwards compatibility.

See [ARCHITECTURE.md](ARCHITECTURE.md) for threading details.

## Hot Reload

### Config Hot Reload

Change backends without restarting or dropping requests:

```bash
# Start with a config file (see JSON Config File section above)
./zig-out/bin/load_balancer -m sp -c backends.json -p 8080

# Edit backends.json while running - changes apply instantly
```

**How it works:**
- File watcher (kqueue on macOS, inotify on Linux) detects changes
- New config written to inactive buffer, then atomically swapped
- Workers see new backends on next request — no locks, no drops
- Health state reset for new backend count

### Binary Hot Reload

Upgrade the load balancer binary without dropping connections:

```bash
# Rebuild with changes
zig build

# Signal the running process to upgrade
kill -USR2 $(pgrep -f load_balancer)
```

**What happens:**
1. Old process receives SIGUSR2
2. Forks and execs new binary (same arguments)
3. New process starts, binds with SO_REUSEPORT
4. Old process waits 1 second, then drains connections and exits
5. New process takes over seamlessly

Works in both `mp` and `sp` modes on Linux and macOS.

## Shared Memory Architecture

The load balancer uses mmap'd shared memory for zero-downtime operations:

```
┌─────────────────────────────────────────────────────────┐
│                 SharedRegion (mmap'd)                   │
│         Inherited across fork(), visible to all         │
├─────────────────────────────────────────────────────────┤
│  ControlBlock     │ active_index, generation, count,    │
│                   │ rr_counter (shared round-robin)     │
│  HealthState      │ 64-bit bitmap (1 = healthy)         │
│  BackendArray[0]  │ ◄── active (workers read from here) │
│  BackendArray[1]  │     inactive (config writes here)   │
└─────────────────────────────────────────────────────────┘
        ▲                    ▲                    ▲
        │                    │                    │
    Worker 0            Worker 1             Worker N
```

**Why shared memory?**
- **No IPC overhead** — Workers read directly from mmap'd region
- **Atomic updates** — Double-buffered arrays with pointer swap (RCU-style)
- **No coordination** — Each worker independently reads `active_index`
- **Cross-fork visibility** — Memory mapped before fork(), inherited by children
- **Shared round-robin** — Atomic counter ensures even distribution across all workers

**No pointers in shared memory** — Backend hostnames are inlined (max 253 bytes per RFC 1035) because pointers are process-local virtual addresses.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the complete memory layout and design rationale.

## Metrics

```bash
curl http://localhost:8080/metrics
```

Prometheus format:
- `lb_requests_total`
- `lb_backends_healthy`
- `lb_backends_unhealthy`

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for:
- C4 diagrams
- Component deep-dives
- Shared memory hot reload design
- Design decisions

## Building

```bash
zig build                        # Debug
zig build -Doptimize=ReleaseFast # Release
zig build test                   # 180 tests
```

Requires Zig 0.16.0+

## License

MIT
