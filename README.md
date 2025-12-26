<p align="center">
  <h1 align="center">zzz load balancer</h1>
  <p align="center">A load balancer that doesn't suck.</p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/17%2C000%2B-req%2Fs-blue" alt="17k+ req/s">
  <img src="https://img.shields.io/badge/HTTP%2F2-supported-blueviolet" alt="HTTP/2">
  <img src="https://img.shields.io/badge/WAF-built--in-red" alt="WAF">
  <img src="https://img.shields.io/badge/OpenTelemetry-tracing-purple" alt="OpenTelemetry">
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

That's it. Health checks, automatic failover, connection pooling, **WAF protection**, **distributed tracing**. Done.

## What's New

- **Web Application Firewall (WAF)** — Rate limiting, burst detection, request validation
- **OpenTelemetry Tracing** — Full request lifecycle visibility in Jaeger
- **Lock-free Performance** — TigerBeetle-inspired atomic operations, zero locks

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

### Rate-limited API Gateway

Protect your APIs from abuse with per-IP rate limiting and burst detection.

```bash
./load_balancer \
  -b api-service:8001 \
  --waf-config waf.json \
  --otel-endpoint localhost:4318
```

</td>
<td width="50%">

### Debug with Distributed Tracing

See every request in Jaeger with WAF decisions, backend latency, and more.

```bash
./load_balancer -b backend:8001 \
  --otel-endpoint localhost:4318
# Open http://localhost:16686 for Jaeger UI
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

# Run with WAF and tracing
./zig-out/bin/load_balancer \
  -p 8080 \
  -b 127.0.0.1:9001 \
  -b 127.0.0.1:9002 \
  --waf-config waf.json \
  --otel-endpoint localhost:4318

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
| WAF costs $$$$ | Built-in, lock-free, high-performance |
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
        │ • WAF    │         │ • WAF    │         │ • WAF    │
        └────┬─────┘         └────┬─────┘         └────┬─────┘
             │                    │                    │
             └────────────────────┼────────────────────┘
                                  │ SO_REUSEPORT
                                  ▼
                            Port 8080
                                  │
                                  ▼
                    ┌─────────────────────────────┐
                    │     Jaeger / OTLP           │
                    │   (Distributed Tracing)     │
                    └─────────────────────────────┘
```

Each worker is **fully isolated**: own connection pool, own health state, **shared WAF state** (mmap), no locks. A crash in one worker doesn't affect the others.

### Health Checking

**Passive** — 3 consecutive failures marks backend down, 2 successes brings it back. Instant failover on errors.

**Active** — Background probes every 5s catch problems before users hit them.

---

## Web Application Firewall (WAF)

Built-in, lock-free WAF with TigerBeetle-inspired design:

### Features

| Feature | Description |
|---------|-------------|
| **Rate Limiting** | Token bucket per IP+path, atomic CAS operations |
| **Burst Detection** | Anomaly detection using EMA (detects sudden traffic spikes) |
| **Request Validation** | URI length, body size, JSON depth limits |
| **Slowloris Protection** | Per-IP connection tracking |
| **Shadow Mode** | Test rules without blocking (log_only) |
| **Hot Reload** | Config changes apply without restart |

### WAF Request Flow

```
Request → WAF Check → Backend
            │
            ├─ 1. Validate request (URI, body size)
            ├─ 2. Check rate limits (token bucket)
            ├─ 3. Check burst detection (EMA anomaly)
            └─ 4. Allow / Block / Log
```

### WAF Configuration

Create `waf.json`:

```json
{
  "enabled": true,
  "shadow_mode": false,
  "burst_detection_enabled": true,
  "burst_threshold": 10,
  "rate_limits": [
    {
      "name": "login_bruteforce",
      "path": "/api/auth/login",
      "method": "POST",
      "limit": { "requests": 10, "period_sec": 60 },
      "burst": 3,
      "by": "ip",
      "action": "block"
    },
    {
      "name": "api_general",
      "path": "/api/*",
      "limit": { "requests": 100, "period_sec": 60 },
      "burst": 20,
      "by": "ip",
      "action": "block"
    }
  ],
  "slowloris": {
    "max_conns_per_ip": 50
  },
  "request_limits": {
    "max_uri_length": 2048,
    "max_body_size": 1048576,
    "max_json_depth": 20,
    "endpoints": [
      { "path": "/api/upload", "max_body_size": 10485760 }
    ]
  },
  "trusted_proxies": ["10.0.0.0/8", "172.16.0.0/12"],
  "logging": {
    "log_blocked": true,
    "log_allowed": false,
    "log_near_limit": true,
    "near_limit_threshold": 0.8
  }
}
```

Run with WAF:

```bash
./load_balancer -b backend:8001 --waf-config waf.json
```

### WAF Statistics

Every 10 seconds, the WAF logs statistics:

```
[+10000ms] info(waf_stats): WAF Stats: total=1523 allowed=1498 blocked=25 logged=0 block_rate=1% | by_reason: rate_limit=20 slowloris=0 body=3 json=2
```

### Burst Detection

Detects sudden traffic spikes using Exponential Moving Average (EMA):

- **Window**: 60 seconds
- **EMA**: `baseline = old * 0.875 + current * 0.125`
- **Trigger**: `current_rate > baseline * threshold`

Example: An IP normally sends 20 req/min. Suddenly sends 300 req/min → **blocked**.

---

## OpenTelemetry Integration

Full distributed tracing with Jaeger support.

### Setup

1. Start Jaeger:
```bash
docker run -d --name jaeger \
  -p 16686:16686 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

2. Run load balancer with tracing:
```bash
./load_balancer -b backend:8001 --otel-endpoint localhost:4318
```

3. Open Jaeger UI: http://localhost:16686

### What's Traced

Every request gets a span with:

| Attribute | Description |
|-----------|-------------|
| `http.method` | GET, POST, etc. |
| `http.url` | Request URI |
| `http.status_code` | Response status |
| `waf.decision` | allow / block / log_only |
| `waf.client_ip` | Client IP address |
| `waf.reason` | Why blocked (rate_limit, burst, etc.) |
| `waf.rule` | Which rule triggered |
| `backend.host` | Backend server |
| `backend.latency_ms` | Backend response time |

### Example Trace

```
proxy_request [12.3ms]
├─ http.method: POST
├─ http.url: /api/auth/login
├─ waf.decision: block
├─ waf.client_ip: 192.168.1.100
├─ waf.reason: rate limit exceeded
└─ waf.rule: login_bruteforce
```

### Batching

Spans are batched for efficiency:
- **Max queue**: 2048 spans
- **Batch size**: 512 spans
- **Export interval**: 5 seconds

---

## CLI Reference

```
-p, --port N           Listen port (default: 8080)
-b, --backend H:P      Backend server (repeat for multiple)
-w, --workers N        Worker count (default: CPU cores)
-s, --strategy S       round_robin | weighted | random
-c, --config FILE      JSON config file (hot-reloaded)
-l, --loglevel LVL     err | warn | info | debug
-k, --insecure         Skip TLS verification (dev only!)
-t, --trace            Dump raw HTTP payloads
--tls-trace            Show TLS handshake details
--mode mp|sp           Multi-process or single-process

WAF Options:
--waf-config FILE      WAF configuration JSON file
--waf-shadow           Enable shadow mode (log only, don't block)

Observability:
--otel-endpoint H:P    OpenTelemetry OTLP endpoint (e.g., localhost:4318)

--help                 You know what this does
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
| **WAF** | Rate limiting, burst detection, request validation |
| **Distributed tracing** | OpenTelemetry + Jaeger integration |

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
zig build test                   # 370+ tests
```

Requires Zig 0.16.0+

## Going Deeper

See [ARCHITECTURE.md](ARCHITECTURE.md) for the nerdy stuff:
- HTTP/2 protocol with HPACK header compression
- Shared memory layout and double-buffered config swaps
- Why there are no pointers in shared memory
- Binary hot reload via file descriptor passing
- SIMD HTTP parsing

See [docs/WAF_ARCHITECTURE.md](docs/WAF_ARCHITECTURE.md) for WAF internals:
- Lock-free token bucket implementation
- Burst detection with EMA algorithm
- Shared memory structures (4MB WafState)
- OpenTelemetry span propagation
- Request flow diagrams with function names

## License

MIT — do whatever you want.
