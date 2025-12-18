# Zig Load Balancer

A blazing-fast HTTP load balancer written in Zig. nginx-style architecture, zero dependencies beyond the Zig standard library.

```
Client ──► Load Balancer ──► Backend Servers
              │
              ├── Automatic failover
              ├── Health checking
              └── TLS to HTTPS backends
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

# Run the load balancer
./zig-out/bin/load_balancer_mp -w 4 -p 8080 -b 127.0.0.1:9001 -b 127.0.0.1:9002

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
./zig-out/bin/load_balancer_mp -b httpbin.org:443 -p 8080
curl http://localhost:8080/ip  # Proxied over TLS
```

Mix HTTP and HTTPS backends freely.

## Options

```
-w, --workers N      Worker count (default: CPU cores)
-p, --port N         Listen port (default: 8080)
-b, --backend H:P    Backend server (repeat for multiple)
```

## Modes

**Multi-process** (`load_balancer_mp`) — nginx-style fork() with SO_REUSEPORT. Best for Linux production.

**Single-process** (`load_balancer_sp`) — One process, internal thread pool. Best for macOS or lower memory footprint.

```bash
./zig-out/bin/load_balancer_sp -p 8080 -b localhost:9001
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for threading details.

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
- Design decisions

## Building

```bash
zig build                        # Debug
zig build -Doptimize=ReleaseFast # Release
zig build test                   # 127 tests
```

Requires Zig 0.16.0+

## License

MIT
