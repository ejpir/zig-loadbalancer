# Load Balancer Integration Tests

This directory contains end-to-end integration tests for the load balancer, written entirely in Zig.

## Overview

The integration tests verify the complete request/response flow through the load balancer:

- Request forwarding (GET, POST, PUT, PATCH)
- Request body forwarding
- Header forwarding (including filtering hop-by-hop headers)
- Load balancing (round-robin distribution)
- Multiple sequential requests

## Running Tests

Build and run the integration tests:

```bash
zig build test-integration
```

Expected output:
```
╔══════════════════════════════════════╗
║   Load Balancer Integration Tests   ║
╚══════════════════════════════════════╝

Basic Proxy Functionality
  ✓ forwards GET requests correctly
  ✓ forwards POST requests with JSON body
  ✓ forwards PUT requests with body
  ✓ forwards PATCH requests with body
  ✓ returns complete response structure

  5 passed, 0 failed

Header Handling
  ✓ forwards Content-Type header
  ✓ forwards custom X-* headers
  ✓ forwards Authorization header
  ✓ filters hop-by-hop headers
  ✓ includes Host header to backend

  5 passed, 0 failed

Body Forwarding
  ✓ handles empty POST body
  ✓ handles large body (1KB)
  ✓ preserves JSON body exactly
  ✓ handles binary data
  ✓ sets Content-Length correctly
  ✓ handles multiple sequential POSTs

  6 passed, 0 failed

Load Balancing
  ✓ distributes requests with round-robin (3/3/3)
  ✓ reaches all configured backends

  2 passed, 0 failed

════════════════════════════════════════
✓ All test suites passed!
```

## Test Architecture

### Test Harness (`harness.zig`)

A minimal Jest-like test framework providing:
- `describe`/`it` semantics
- `beforeAll`/`afterAll` lifecycle hooks
- Colorized output
- Pass/fail counting

### Test Utilities (`test_utils.zig`)

HTTP client helpers:
- `waitForPort()` - Wait for a server to accept connections
- `httpRequest()` - Make HTTP requests and get responses
- JSON parsing helpers for response validation

### Process Manager (`process_manager.zig`)

Manages backend and load balancer processes:
- Spawns test backends on ports 19001-19003
- Spawns load balancer on port 18080
- Handles cleanup on test completion

### Test Suites (`suites/`)

- `basic.zig` - Basic HTTP method forwarding
- `headers.zig` - Header handling and filtering
- `body.zig` - Request body forwarding
- `load_balancing.zig` - Round-robin distribution

## Test Ports

| Component | Port |
|-----------|------|
| Load Balancer | 18080 |
| Backend 1 | 19001 |
| Backend 2 | 19002 |
| Backend 3 | 19003 |

## Adding New Tests

1. Create a test function in the appropriate suite:

```zig
fn testMyFeature(allocator: std.mem.Allocator) !void {
    const response = try test_utils.httpRequest(
        allocator, "GET", test_utils.LB_PORT, "/my-path", null, null
    );
    defer allocator.free(response);

    const body = try test_utils.extractJsonBody(response);
    const method = try test_utils.getJsonString(allocator, body, "method");
    defer allocator.free(method);

    try std.testing.expectEqualStrings("GET", method);
}
```

2. Add the test to the suite's `tests` array:

```zig
pub const suite = harness.Suite{
    .name = "My Suite",
    .tests = &.{
        harness.it("tests my feature", testMyFeature),
        // ...
    },
};
```

## Manual Testing

For manual testing with curl:

```bash
# Build all components
zig build

# Start backend manually
./zig-out/bin/test_backend_echo --port 19001 --id backend1 &

# Start load balancer
./zig-out/bin/load_balancer --port 18080 --mode sp --backend 127.0.0.1:19001 &

# Test GET
curl http://localhost:18080/

# Test POST with JSON
curl -X POST -H "Content-Type: application/json" \
  -d '{"test":"data"}' \
  http://localhost:18080/

# Clean up
killall test_backend_echo load_balancer
```
