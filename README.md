# Zig Load Balancer

A high-performance, "production-ready -- SOON :D" HTTP load balancer implemented in Zig using the zzz framework. Features advanced optimizations including SIMD operations, zero-copy buffers, lock-free data structures, and comprehensive load balancing strategies.


`FOR SSL: git clone https://github.com/tardy-org/secsock/pull/5 and put it in ../../vendor/secsock or adjust build.zig.zon`

NOTE: THIS IS A WIP/ALPHA, it does work, but there are bugs to fix and code needs to be cleaned up.

## Features

### Core Functionality
- **Multiple Load Balancing Strategies**: Round-robin, weighted round-robin, random, and sticky sessions (cookie-based)
- **Hot Configuration Reload**: Dynamic backend updates from YAML configuration without restart
- **Health Checking**: Automatic backend health monitoring with circuit breaker patterns
- **Connection Pooling**: Lock-free atomic connection pool for optimal performance
- **Protocol Support**: HTTP and HTTPS backends with transparent handling

### Performance Optimizations
- **SIMD Operations**: Vectorized header parsing and backend selection
- **Zero-Copy Buffers**: Minimize memory allocations during request processing
- **Lock-Free Data Structures**: Atomic operations for thread-safe connection management
- **Arena Memory Management**: Efficient memory allocation patterns for request lifecycle
- **Comptime Specialization**: Build-time optimizations for specific backend configurations

### Production Features
- **Comprehensive Logging**: Structured logging with configurable log levels and file output
- **Metrics Collection**: Performance metrics and request tracking
- **Chunked Transfer Encoding**: Full support for streaming responses
- **Error Handling**: Graceful degradation and backend failure recovery
- **Configuration Validation**: YAML schema validation with helpful error messages

## Quick Start

### Building

```bash
# Build all components (load balancer + test backends)
zig build

# Build specific components
zig build-exe main.zig -O ReleaseFast  # Just the load balancer
```

### Running

#### Option 1: Using the automated script
```bash
# Start all components with default configuration
./run_all.sh

# Start with custom configuration
./run_all.sh --port 8080 -c config/backends.yaml
```

#### Option 2: Manual startup
Start the test backends:
```bash
# Terminal 1: Backend server on port 9001
zig build run-backend1

# Terminal 2: Backend server on port 9002  
zig build run-backend2
```

Start the load balancer:
```bash
# Terminal 3: Load balancer with default settings
zig build run-lb

# Or with custom configuration
./zig-out/bin/load_balancer --host 127.0.0.1 --port 8080 -c config/backends.yaml -w
```

### Testing

```bash
# Test load balancing
curl http://localhost:9000

# Test with multiple requests to see distribution
for i in {1..10}; do curl http://localhost:9000; done

# Test sticky sessions (if enabled)
curl -c cookies.txt -b cookies.txt http://localhost:9000
```

## Configuration

### Command Line Options

```
-h, --help             Display help and exit
-H, --host <str>       Host address to bind to (default: 0.0.0.0)
-p, --port <u16>       Port to listen on (default: 9000)
-c, --config <str>     YAML configuration file for backend servers
-s, --strategy <str>   Load balancing strategy: 'round-robin', 'weighted', 'random', or 'sticky'
--cookie-name <str>    Cookie name for sticky sessions (default: ZZZ_BACKEND_ID)
--log-file <str>       Log file path (default: logs/lb-<timestamp>.log)
-w, --watch            Watch config file for changes and reload automatically
-i, --interval <u32>   Config file watch interval in milliseconds (default: 2000)
```

### YAML Configuration

Create a `config/backends.yaml` file:

```yaml
# Load Balancer Backend Configuration
backends:
  - host: "127.0.0.1"
    port: 9001
    weight: 2  # Higher weight for weighted round-robin

  - host: "127.0.0.1" 
    port: 9002
    weight: 1

  # HTTPS backend (automatically detected)
  - host: "api.example.com"
    port: 443

  # Explicit HTTPS with custom port
  - host: "https://secure-api.example.com"
    port: 8443
```

**HTTPS Support Status:** The load balancer currently detects HTTPS backends based on port 443 or `https://` URL prefix. Full HTTPS client support is actively being developed in `client.zig` and will be released soon. The architecture is designed for seamless integration once the client implementation is complete.

### Hot Reload

Enable configuration hot reloading to update backends without restart:

```bash
./zig-out/bin/load_balancer -c config/backends.yaml -w
```

While running, modify the YAML file to:
- Add/remove backend servers
- Change backend weights
- Update host/port configurations

Changes are automatically detected and applied within the configured interval.

## Architecture

### High-Level Design

```
┌─────────────┐    ┌─────────────────┐    ┌─────────────┐
│   Client    │───▶│  Load Balancer  │───▶│  Backend 1  │
└─────────────┘    │                 │    └─────────────┘
                   │   ┌─────────────┤    ┌─────────────┐
                   │   │ Strategy    │───▶│  Backend 2  │
                   │   │ Selection   │    └─────────────┘
                   │   └─────────────┤    ┌─────────────┐
                   │   ┌─────────────┤───▶│  Backend N  │
                   │   │ Health      │    └─────────────┘
                   │   │ Checking    │
                   │   └─────────────┤
                   │   ┌─────────────┤
                   │   │ Connection  │
                   │   │ Pooling     │
                   │   └─────────────┘
                   └─────────────────┘
```

### Key Components

- **`src/core/`**: Core load balancing logic and HTTP proxy functionality
- **`src/strategies/`**: Pluggable load balancing algorithms
- **`src/memory/`**: Connection pooling and memory management
- **`src/health/`**: Health checking and monitoring
- **`src/config/`**: Configuration management and hot reload
- **`src/http/`**: HTTP protocol handling and optimizations
- **`src/internal/`**: Performance optimizations (SIMD, zero-copy, etc.)

### Performance Features

#### SIMD Optimizations
- Vectorized header parsing using AVX2/SSE instructions
- Parallel backend selection for improved throughput
- SIMD-accelerated content type detection

#### Memory Management
- **Arena Allocators**: Single deallocation point for request processing
- **Connection Pooling**: Lock-free atomic pool with efficient reuse
- **Zero-Copy Buffers**: Minimize allocations during data transfer

#### Lock-Free Data Structures
- Atomic connection stack for thread-safe pool management
- Lock-free backend state caching
- Atomic counters for round-robin distribution

## Development

### Project Structure

```
├── src/
│   ├── core/           # Core load balancing logic
│   ├── strategies/     # Load balancing algorithms  
│   ├── memory/         # Memory management
│   ├── health/         # Health monitoring
│   ├── config/         # Configuration handling
│   ├── http/           # HTTP protocol support
│   ├── internal/       # Performance optimizations
│   └── utils/          # Utilities (logging, CLI, metrics)
├── config/             # Configuration files
├── main.zig           # Application entry point
├── backend1.zig       # Test backend server 1
├── backend2.zig       # Test backend server 2
└── build.zig          # Build configuration
```

### Build Targets

```bash
zig build                    # Build all components
zig build run-lb            # Run load balancer
zig build run-backend1      # Run test backend 1
zig build run-backend2      # Run test backend 2
zig build test              # Run unit tests
```

### Dependencies

- **[zzz](https://github.com/zigzap/zzz)**: Core HTTP framework
- **[tardy](https://github.com/tardy-org/tardy)**: Async runtime
- **[secsock](https://github.com/tardy-org/secsock)**: Secure socket abstractions for HTTPS support
- **[clap](https://github.com/Hejsil/zig-clap)**: Command line argument parsing
- **[yaml](https://github.com/kubkon/zig-yaml)**: YAML configuration parsing

## Performance

The load balancer is designed for high performance with several optimizations:

- **Sub-microsecond request routing** through SIMD-optimized backend selection
- **Zero-allocation request paths** using arena allocators and connection pooling
- **Lock-free operation** for maximum concurrency
- **Comptime specialization** for optimal code generation

Benchmarks show significant performance improvements over traditional mutex-based designs, particularly under high concurrency.

## License

This project is part of the zzz framework examples and follows the same licensing terms.

## Contributing

Contributions are welcome! Areas of particular interest:

- Additional load balancing strategies
- Performance optimizations
- Protocol support (HTTP/2, WebSocket proxying)
- Observability features (OpenTelemetry integration)
- Security enhancements (mTLS, authentication)

Please ensure all contributions maintain the high-performance design principles and include appropriate tests.
