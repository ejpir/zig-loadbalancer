# HTTP Load Balancer Example

This example implements a simple HTTP load balancer using the zzz framework. The load balancer distributes incoming HTTP requests across multiple backend servers using various load balancing strategies.

## Components:

1. **Load Balancer**: Listens on a configurable port (default 9000) and forwards requests to backend servers
2. **Backend Server 1**: Default runs on port 9001
3. **Backend Server 2**: Default runs on port 9002 with a different styling

## Command Line Options

The load balancer supports the following command line arguments:

```
-h, --help             Display this help and exit.
-H, --host <str>       Host address to bind to (default: 0.0.0.0).
-p, --port <u16>       Port to listen on (default: 9000).
-c, --config <str>     YAML config file for backend servers.
-s, --strategy <str>   Load balancer strategy: 'round-robin', 'weighted-round-robin', 'random', or 'sticky' (default: random).
--cookie-name <str>    Cookie name for sticky sessions (default: ZZZ_BACKEND_ID).
--log-file <str>       Log file path (default: logs/lb-<timestamp>.log).
-w, --watch            Watch config file for changes and reload backends automatically.
-i, --interval <u32>   Config file watch interval in milliseconds (default: 2000).
```

## Hot Reload Support

The load balancer now supports hot reloading of backend configurations from a YAML file. When enabled with the `-w` flag, the load balancer will monitor the configuration file for changes and dynamically update the backend server list without restarting.

### YAML Configuration Format

Create a YAML file with your backend configuration:

```yaml
# Load Balancer Backend Configuration
backends:
  - host: "127.0.0.1"
    port: 9001
    weight: 2  # Optional weight for weighted-round-robin

  - host: "127.0.0.1"
    port: 9002

  # Additional backends
  - host: "127.0.0.1"
    port: 9003
```

### Using Hot Reload

Start the load balancer with config watching enabled:

```bash
zig-out/bin/load_balancer -c config/backends.yaml -w
```

While the load balancer is running, you can modify the YAML file to:
- Add new backend servers
- Remove existing backend servers
- Change backend server weights

The changes will be automatically detected and applied without service interruption.

## How to run:

First build all the components:

```
zig build load_balancer lb_backend1 lb_backend2
```

Then run all three components in separate terminals:

### Terminal 1 - Start Backend 1:
```
zig build run_lb_backend1
```

### Terminal 2 - Start Backend 2:
```
zig build run_lb_backend2
```

### Terminal 3 - Start Load Balancer:
```
# Default configuration
zig build run_load_balancer

# Or with custom configuration
zig-out/bin/load_balancer --host 127.0.0.1 --port 8080 -c config/backends.yaml -w
```

### Or run everything with one script:
```
# Default configuration
./examples/load_balancer/run_all.sh

# Custom configuration
./examples/load_balancer/run_all.sh --port 8080 -c config/backends.yaml
```

## Testing:

Once all servers are running, open your browser or use curl to access the load balancer:

```
curl http://localhost:9000
```

Refresh multiple times to see requests being distributed between backend servers.

To test hot reload, modify the backends.yaml file while the load balancer is running and observe the changes in the logs.

## Features:

- Multiple load balancing strategies:
  - Round-robin
  - Weighted round-robin
  - Random
  - Sticky sessions (cookie-based)
- Hot reload of backend configuration
- Backend response forwarding with support for:
  - Standard responses with Content-Length
  - Chunked transfer encoding
  - Connection close semantics
- HTTP header handling
- Error handling for backend failures
- Health checks for backends
- Connection pooling
- Logging and metrics

## Implementation:

This implementation includes many production-ready features:

1. ✅ Health checks for backends
2. ✅ Multiple load balancing algorithms
3. ✅ Connection pooling
4. ✅ Hot reload of backend configurations
5. ✅ Comprehensive logging
6. ✅ Cookie-based sticky sessions
7. ✅ Support for both HTTP and HTTPS backends
8. ✅ Efficient memory management with ArenaAllocator
9. ✅ Chunked transfer encoding support
10.    TLS sessions
11.    mTLS
12.    mesh/HA
13.    control-vs-dataplane
14.    opentelemtry/jaeger
15.    hot swapping code runtime
16.    WASM support
17.    header filering
18.    ebpf tracking
19.    layer7 routing

## Memory Management

The load balancer uses different memory management strategies for optimal performance:

### ArenaAllocator

The load balancer uses `std.heap.ArenaAllocator` for processing HTTP responses.
This provides several benefits:

**Advantages of ArenaAllocator:**
- Single deallocation point - all memory freed at once with `arena.deinit()`
- Eliminates tedious tracking of individual allocations
- Faster allocations (bump allocator with minimal bookkeeping)
- Simplifies error handling (no manual cleanup in error paths)
- Cleaner code without explicit memory management

**Disadvantages of ArenaAllocator:**
- Memory is only freed at the end of the function
- Can use more memory than strictly necessary during processing
- Not suitable for long-lived operations or repeated use

**Comparison with Manual Memory Management:**
The load balancer previously used manual memory management which required:
- Explicitly tracking each allocation
- Paired allocations and deallocations throughout the code
- Complex cleanup in error paths
- Potential for memory leaks if deallocation was missed

ArenaAllocator is particularly well-suited for HTTP request handling because:
- HTTP requests have a well-defined lifecycle
- All allocations have the same lifetime (the duration of request processing)
- Performance benefits from batched deallocation
- Simpler code improves maintainability

### Connection Pool

The connection pool uses a specialized Pool implementation with bitset tracking:
- Efficiently manages socket connections
- Uses atomic operations for thread safety
- Avoids unnecessary allocation/deallocation cycles
- Provides clear ownership semantics

## HTTP Protocol Support

The load balancer properly handles various HTTP protocol features to ensure compatibility with modern web servers and applications.

### Chunked Transfer Encoding

The load balancer fully supports chunked transfer encoding in responses from backend servers:

- Automatically detects `Transfer-Encoding: chunked` headers
- Properly forwards the complete chunked response to clients
- Handles end-of-chunk markers to determine when the response is complete
- Uses a smart timeout system to prevent hanging connections
- Preserves chunked encoding headers in the forwarded response

This enables the load balancer to proxy modern web applications that use chunked encoding for streaming responses, server-sent events, or when content length is not known in advance.

### HTTP/HTTPS Support

The load balancer can now connect to both HTTP and HTTPS backends thanks to the new UltraSock module. This provides a secure socket abstraction that transparently handles both protocols with a unified API.

### UltraSock Module

The `UltraSock` module provides the following features:

- Automatic detection of HTTP vs HTTPS based on:
  - Port number (443 is treated as HTTPS)
  - URL scheme (https:// prefix)
- Transparent protocol handling
- Consistent API for both protocols
- Integration with the connection pool
- Support for health checks

### Backend Configuration for HTTPS

You can specify HTTPS backends in the configuration using either of these methods:

```yaml
backends:
  # Method 1: Use port 443
  - host: "secure-api.example.com"
    port: 443

  # Method 2: Use https:// prefix
  - host: "https://api.example.com"
    port: 8443
```

**Note:** The current implementation recognizes HTTPS backends and is designed with a forward-compatible architecture that will automatically enable TLS security when supported. Currently:

1. The load balancer detects HTTPS backends based on port 443 or the 'https://' URL prefix
2. It currently establishes unencrypted connections to HTTPS backends (with a warning)
3. The code is structured to automatically use secure TLS connections once client TLS mode is implemented
4. This ensures a seamless upgrade path without code changes when full HTTPS support is added
