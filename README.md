<p align="center">
  <h1 align="center">zzz load balancer</h1>
  <p align="center">A load balancer that doesn't suck.</p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/17%2C000%2B-req%2Fs-blue" alt="17k+ req/s">
  <img src="https://img.shields.io/badge/HTTP%2F2-supported-blueviolet" alt="HTTP/2">
  <img src="https://img.shields.io/badge/single_binary-4MB-green" alt="Single binary">
  <img src="https://img.shields.io/badge/dependencies-zero-green" alt="Zero dependencies">
  <img src="https://img.shields.io/badge/zig-0.16%2B-orange" alt="Zig 0.16+">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT">
</p>

<p align="center">
  <code>No YAML. No Docker required. No 47-page config reference.</code>
</p>

---

```bash
./load_balancer -b localhost:9001 -b localhost:9002 -p 8080
```

That's it. Health checks, automatic failover, connection pooling. Done.

## Use Cases

<table>
<tr>
<td width="50%">

### Proxy to HTTPS APIs

Accept plain HTTP, forward over TLS. Great for local dev against production APIs.

```bash
./load_balancer -b api.stripe.com:443 -p 8080
curl http://localhost:8080/v1/charges
```

</td>
<td width="50%">

### Zero-downtime deploys

Hot reload config or upgrade the binary without dropping a single request.

```bash
# Config reload
./load_balancer -c backends.json

# Binary upgrade
kill -USR2 $(pgrep load_balancer)
```

</td>
</tr>
<tr>
<td width="50%">

### Local microservices gateway

One port, multiple backends. Round-robin or weighted distribution.

```bash
./load_balancer \
  -b auth-service:8001 \
  -b api-service:8002 \
  -b cache-service:8003 \
  -s round_robin
```

</td>
<td width="50%">

### Debug HTTP/TLS issues

See exactly what's on the wire. Hex dumps, TLS cipher info, the works.

```bash
./load_balancer --trace --tls-trace \
  -b httpbin.org:443 -p 8080
```

</td>
</tr>
<tr>
<td width="50%">

### HTTP/2 to modern APIs

ALPN negotiates h2 automatically with HTTPS backends.

```bash
./load_balancer -b api.cloudflare.com:443 -p 8080
# HTTP/2 used automatically
```

</td>
<td width="50%">

### Sidecar proxy

Drop in front of legacy services. Single-process mode for containers.

```bash
./load_balancer -b legacy-app:80 \
  --mode sp -p 8080
```

</td>
</tr>
</table>

## Quick Start

```bash
# Build
zig build -Doptimize=ReleaseFast

# Start backends (or use your own)
./zig-out/bin/backend1 &
./zig-out/bin/backend2 &

# Run
./zig-out/bin/load_balancer -p 8080 -b 127.0.0.1:9001 -b 127.0.0.1:9002

# Test
curl http://localhost:8080
```

## Why This Exists

| Problem | Solution |
|---------|----------|
| nginx config is a dark art | CLI flags. That's it. |
| HAProxy needs a PhD | One binary, zero setup |
| Envoy downloads half the internet | No dependencies beyond Zig stdlib |
| Node/Go proxies have GC pauses | Memory-safe Zig, no garbage collector |
| "Just use Kubernetes" | This is 4MB, not a lifestyle |

**The numbers:** 17,000+ req/s with ~10% overhead vs direct backend access.

## How It Works

```
                    ┌─────────────────────────────────────┐
                    │            Master Process           │
                    │  (watches workers, respawns dead)   │
                    └──────────────┬──────────────────────┘
                                   │ fork()
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
        ┌──────────┐         ┌──────────┐         ┌──────────┐
        │ Worker 0 │         │ Worker 1 │         │ Worker N │
        │          │         │          │         │          │
        │ • pool   │         │ • pool   │         │ • pool   │
        │ • health │         │ • health │         │ • health │
        └────┬─────┘         └────┬─────┘         └────┬─────┘
             │                    │                    │
             └────────────────────┼────────────────────┘
                                  │ SO_REUSEPORT
                                  ▼
                            Port 8080
```

Each worker is **fully isolated**: own connection pool, own health state, no locks. A crash in one worker doesn't affect the others.

### Health Checking

**Passive** — 3 consecutive failures marks backend down, 2 successes brings it back. Instant failover on errors.

**Active** — Background probes every 5s catch problems before users hit them.

## CLI Reference

```
-p, --port N         Listen port (default: 8080)
-b, --backend H:P    Backend server (repeat for multiple)
-w, --workers N      Worker count (default: CPU cores)
-s, --strategy S     round_robin | weighted | random
-c, --config FILE    JSON config file (hot-reloaded)
-l, --loglevel LVL   err | warn | info | debug
-k, --insecure       Skip TLS verification (dev only!)
-t, --trace          Dump raw HTTP payloads
--tls-trace          Show TLS handshake details
--mode mp|sp         Multi-process or single-process
--help               You know what this does
```

## Config File

Optional. Enables hot reload and weighted backends.

```json
{
  "backends": [
    {"host": "127.0.0.1", "port": 9001},
    {"host": "127.0.0.1", "port": 9002, "weight": 2},
    {"host": "api.example.com", "port": 443}
  ]
}
```

Changes detected via kqueue (macOS) / inotify (Linux). Zero-downtime reload.

## Features at a Glance

| Feature | How |
|---------|-----|
| **HTTP/2 backends** | Auto-negotiated via ALPN. Falls back to HTTP/1.1. |
| **HTTPS backends** | Port 443 auto-enables TLS. Mix HTTP/HTTPS freely. |
| **Config hot reload** | `-c config.json` watches for changes |
| **Binary hot reload** | `kill -USR2` hands off socket to new binary |
| **Health checks** | Passive (from failures) + active (background probes) |
| **Load balancing** | Round-robin, weighted, or random |
| **Prometheus metrics** | `GET /metrics` |
| **Connection pooling** | Per-backend, per-worker pools |
| **Crash isolation** | Workers are separate processes |

## HTTP/2 Support

Automatic HTTP/2 for HTTPS backends:

```bash
./load_balancer -b api.cloudflare.com:443 -p 8080
# ALPN negotiates h2 automatically
```

**What's supported:**
- ALPN protocol negotiation during TLS handshake
- HPACK header compression (static table)
- Flow control (WINDOW_UPDATE frames)
- Stream multiplexing (up to 8 concurrent requests per connection)
- Graceful fallback to HTTP/1.1 if server doesn't support h2

**What's not (yet):**
- Server push
- Connection pooling for HTTP/2 (fresh connection each request)

Use `--tls-trace` to see the negotiated protocol:
```
info(tls_trace): ALPN Protocol: http2
```

## Building

```bash
zig build                        # Debug
zig build -Doptimize=ReleaseFast # Production
zig build test                   # 242 tests
```

Requires Zig 0.16.0+

## Going Deeper

See [ARCHITECTURE.md](ARCHITECTURE.md) for the nerdy stuff:
- HTTP/2 protocol with HPACK header compression
- Shared memory layout and double-buffered config swaps
- Why there are no pointers in shared memory
- Binary hot reload via file descriptor passing
- SIMD HTTP parsing

## License

MIT — do whatever you want.
