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
- Crash isolation (one worker dies, others continue)
- ~17,770 req/s on macOS

### Multi-Threaded
```bash
./zig-out/bin/load_balancer --port 8080
```

Traditional multi-threaded with shared state:
- Lock-free connection pooling
- Atomic health bitmap
- ~17,148 req/s on macOS

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
├── main.zig              # Multi-threaded entry point
├── main_multiprocess.zig # Multi-process entry point (nginx-style)
├── src/
│   ├── core/            # Proxy logic, load balancing
│   ├── memory/          # Connection pools, arena allocators
│   ├── internal/        # SIMD parsing, optimizations
│   └── http/            # HTTP utilities
└── vendor/              # Vendored dependencies (zzz, tardy, etc.)
```

## Dependencies

All dependencies are vendored in `vendor/` and patched for Zig 0.15.2:
- **zzz** - HTTP framework
- **tardy** - Async runtime (io_uring on Linux, kqueue on macOS)
- **secsock** - TLS support
- **zig-clap** - CLI parsing

## Building

```bash
# Debug build
zig build

# Release build (recommended for benchmarks)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

## License

MIT
