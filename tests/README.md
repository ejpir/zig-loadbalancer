# Load Balancer Integration Tests

This directory contains end-to-end integration tests for the load balancer.

## Overview

The integration tests verify the complete request/response flow through the load balancer, including:

- Request forwarding (GET, POST, PUT)
- Request body forwarding
- Header forwarding (including filtering hop-by-hop headers)
- Load balancing (round-robin distribution)
- Connection pooling
- Multiple sequential requests

## Prerequisites

- Built binaries: `zig build build-all`
- `jq` for JSON parsing: `brew install jq` (macOS) or `apt-get install jq` (Linux)
- `nc` (netcat) for port checking (usually pre-installed)

## Running Tests

### Quick Test

Run a quick sanity check to verify basic functionality:

```bash
./tests/quick_test.sh
```

This will:
1. Start one test backend
2. Test the backend directly
3. Start the load balancer
4. Test through the load balancer

### Full Integration Test Suite

Run the comprehensive test suite:

```bash
./tests/run_integration_tests.sh
```

This will run all tests including:
- GET request forwarding
- POST request with JSON body
- Custom header forwarding
- Multiple sequential requests
- Round-robin load balancing across 3 backends

Expected output:
```
========================================
Load Balancer Integration Tests
========================================

[INFO] Starting basic tests (single backend)...
[INFO] Started backend backend1 on port 19001 (PID: 12345)
[INFO] Started load balancer on port 18080 (PID: 12346)
[INFO] Testing GET request forwarding
[PASS] GET request forwarded correctly
[INFO] Testing POST request with JSON body
[PASS] POST request with JSON body forwarded correctly
[INFO] Testing custom header forwarding
[PASS] Custom headers forwarded correctly
[INFO] Testing multiple sequential requests
[PASS] Multiple sequential requests work correctly
[INFO] Testing round-robin load balancing
[PASS] Round-robin distributes requests evenly (3/3/3)

========================================
All tests passed!
========================================
```

## Test Components

### Test Backend Echo Server (`test_backend_echo.zig`)

A specialized backend server that echoes back request details in JSON format:
- Server ID
- HTTP method
- Request URI
- All headers
- Request body
- Body length

This allows tests to verify that the load balancer correctly forwards all request components.

### Integration Test Script (`run_integration_tests.sh`)

A bash script that:
1. Starts test backend servers
2. Starts the load balancer
3. Makes HTTP requests using `curl`
4. Verifies responses using `jq`
5. Cleans up all processes

### Test Coverage

**Basic Functionality:**
- ✅ GET requests proxied correctly
- ✅ POST requests with JSON body forwarded correctly
- ✅ Custom headers forwarded
- ✅ Hop-by-hop headers NOT forwarded
- ✅ Multiple sequential requests work

**Load Balancing:**
- ✅ Round-robin distributes requests evenly across backends
- ✅ All backends receive traffic

**Connection Pooling:**
- ✅ Multiple requests reuse connections
- ✅ No connection leaks

## Test Ports

The tests use the following ports:
- Load Balancer: `18080`
- Backend 1: `19001`
- Backend 2: `19002`
- Backend 3: `19003`

Make sure these ports are available before running tests.

## Troubleshooting

### Port Already in Use

If you see connection errors, check for processes using the test ports:

```bash
# Check ports
lsof -i :18080
lsof -i :19001

# Kill any stuck processes
killall test_backend_echo load_balancer_sp
```

### Tests Fail with "command not found: jq"

Install jq:

```bash
# macOS
brew install jq

# Linux
sudo apt-get install jq
```

### Tests Timeout

Increase the `STARTUP_DELAY_MS` in the test script if servers are slow to start:

```bash
# Edit tests/run_integration_tests.sh
STARTUP_DELAY_MS=1000  # Increase from 500 to 1000
```

## Adding New Tests

To add a new test case:

1. Add a test function following the pattern:
```bash
test_my_feature() {
    info "Testing my feature"

    # Make request
    local response=$(curl -s http://localhost:$LB_PORT/)

    # Verify response
    local result=$(echo "$response" | jq -r '.some_field')
    if [ "$result" != "expected" ]; then
        fail "My feature" "Expected 'expected', got '$result'"
    fi

    pass "My feature works correctly"
}
```

2. Call the function from `main()`:
```bash
main() {
    # ... existing setup ...
    test_my_feature
    # ...
}
```

## CI/CD Integration

To integrate with CI/CD pipelines:

```yaml
# Example GitHub Actions
- name: Build
  run: zig build build-all

- name: Run Integration Tests
  run: ./tests/run_integration_tests.sh
```

## Manual Testing

For manual testing with curl:

```bash
# Start backend
./zig-out/bin/test_backend_echo --port 19001 --id backend1 &

# Start load balancer
./zig-out/bin/load_balancer_sp --port 18080 --backend 127.0.0.1:19001 &

# Test GET
curl http://localhost:18080/

# Test POST with JSON
curl -X POST -H "Content-Type: application/json" \
  -d '{"test":"data"}' \
  http://localhost:18080/

# Clean up
killall test_backend_echo load_balancer_sp
```
