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
--help               Show help message
```

## Modes

The unified `load_balancer` binary supports two execution modes:

**Multi-process (mp)** — nginx-style fork() with SO_REUSEPORT. Each worker is a separate process with its own event loop, connection pool, and health state. Zero lock contention, crash isolation, best for Linux production.

```bash
./zig-out/bin/load_balancer --mode mp -w 4 -p 8080 -b localhost:9001
```

**Single-process (sp)** — One process with internal thread pool. Shared connection pool, simpler architecture, lower memory footprint. Best for macOS or development.

```bash
./zig-out/bin/load_balancer --mode sp -p 8080 -b localhost:9001
```

The binary auto-selects the best mode for your platform if `--mode` is not specified.

Legacy binaries `load_balancer_mp` and `load_balancer_sp` are still available for backwards compatibility.

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
