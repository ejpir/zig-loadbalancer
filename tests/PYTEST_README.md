# Load Balancer Pytest Integration Tests

This directory contains pytest-based integration tests for the load balancer, providing better assertions, fixtures, and maintainability compared to the original bash/curl tests.

## Test Structure

### Test Files

- **`test_basic.py`** - Basic proxy functionality tests
  - GET, POST, PUT, PATCH request forwarding
  - Request body handling
  - Response structure validation

- **`test_headers.py`** - Header handling tests
  - Content-Type and Authorization headers
  - Custom X-* headers
  - Host header behavior
  - Hop-by-hop header filtering

- **`test_body_forwarding.py`** - Request body forwarding tests
  - Empty bodies
  - Large bodies (1KB)
  - JSON body preservation
  - Binary data handling
  - Content-Length header verification
  - Sequential POST requests

- **`test_load_balancing.py`** - Load balancing tests
  - Round-robin distribution (9 requests → 3/3/3 distribution)
  - Backend reachability verification

### Fixtures (`conftest.py`)

- **`backend`** - Single echo backend server (port 19001)
- **`backends`** - Three echo backend servers (ports 19001-19003)
- **`load_balancer`** - Load balancer with single backend (port 18080)
- **`load_balancer_multi`** - Load balancer with three backends (port 18080)

All fixtures have function scope for test isolation and automatic cleanup.

## Setup

### Prerequisites

```bash
# Build the binaries first
/usr/local/zig-0.16.0-dev/zig build
```

### Install Dependencies

```bash
cd tests
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Running Tests

### Run All Tests

```bash
cd tests
source venv/bin/activate
pytest -v
```

### Run Specific Test File

```bash
pytest test_basic.py -v
pytest test_headers.py -v
pytest test_body_forwarding.py -v
pytest test_load_balancing.py -v
```

### Run Specific Test

```bash
pytest test_basic.py::test_get_request_forwarded -v
```

### Run with Coverage

```bash
pytest -v --cov=../src --cov-report=html
```

## Test Execution Details

### Timing Considerations

The multiprocess load balancer has health check probes that run with these characteristics:

- **Initial delay**: 1 second before first probe
- **Probe interval**: 5 seconds between health checks
- **Healthy threshold**: 2 consecutive successful probes required

Therefore, fixtures that start the load balancer wait **12 seconds** to ensure:
- 1s initial delay
- 5s first health check
- 5s second health check
- +1s buffer

This ensures backends are marked HEALTHY before tests run.

### Process Management

- Each fixture creates processes with `preexec_fn=os.setsid` to create new process groups
- Cleanup uses `os.killpg()` to kill entire process groups (important for multiprocess load balancer)
- An `atexit` handler ensures all processes are cleaned up even if tests crash
- Function-scoped fixtures provide test isolation but increase runtime

### Performance

- Full test suite: ~4 minutes (18 tests)
- Per-test overhead: ~13 seconds (backend + load balancer startup + health check wait)
- Load balancing tests: Additional overhead for 3 backend startup

## Test Coverage

### Basic Functionality (5 tests)
- ✅ GET request forwarding
- ✅ POST with JSON body
- ✅ PUT with body
- ✅ PATCH with body
- ✅ Response structure validation

### Headers (5 tests)
- ✅ Content-Type header forwarding
- ✅ Custom headers (X-*)
- ✅ Authorization header
- ✅ Hop-by-hop headers (validated)
- ✅ Host header to backend

### Body Forwarding (6 tests)
- ✅ Empty body POST
- ✅ Large body (1KB)
- ✅ JSON body preservation
- ✅ Binary data (with UTF-8 safe chars)
- ✅ Content-Length header
- ✅ Multiple sequential POSTs

### Load Balancing (2 tests)
- ✅ Round-robin distribution (3/3/3)
- ✅ All backends reachable

## Echo Backend Response Format

The test backend returns JSON with request details:

```json
{
  "server_id": "backend1",
  "method": "POST",
  "uri": "/api/test",
  "headers": {
    "content-type": "application/json",
    "host": "127.0.0.1:19001"
  },
  "body": "{\"key\": \"value\"}",
  "body_length": 16
}
```

## Known Limitations

1. **Large Bodies**: Bodies > 1KB may cause backend health check failures (503 errors). Tests use 1KB as the "large body" size.

2. **Binary Data**: Tests use UTF-8 safe binary data to avoid JSON encoding issues with control characters.

3. **Test Duration**: Function-scoped fixtures mean each test restarts all servers, increasing runtime but ensuring isolation.

4. **Port Conflicts**: Tests use fixed ports (18080, 19001-19003). Ensure no other processes use these ports.

## Troubleshooting

### Tests Timing Out

If tests timeout during fixture setup:
- Increase `@pytest.mark.timeout()` values in test files
- Check that ports 18080, 19001-19003 are not in use

### 503 Service Unavailable Errors

If tests get 503 responses:
- Backend health checks may not have completed
- Increase the `time.sleep()` value in `start_load_balancer()` in `conftest.py`
- Check backend logs for connection issues

### Zombie Processes

If processes aren't cleaned up:
```bash
pkill -9 -f 'load_balancer_mp'
pkill -9 -f 'test_backend_echo'
```

## Migration from Bash Tests

The original bash tests in `run_integration_tests.sh` have been fully replaced by these pytest tests with improvements:

- ✅ Better assertions (pytest vs manual string parsing)
- ✅ Automatic fixture management (vs manual process tracking)
- ✅ Test isolation (function scope vs shared servers)
- ✅ JSON validation (vs jq piping)
- ✅ Timeout handling (pytest-timeout vs manual)
- ✅ Detailed error messages (pytest vs custom fail())
- ✅ Extensible (easy to add new tests)

## Future Improvements

- [ ] Add pytest-xdist for parallel test execution
- [ ] Add test markers (@pytest.mark.slow, @pytest.mark.fast)
- [ ] Session-scoped fixtures for faster execution (trade-off with isolation)
- [ ] Health check endpoint verification
- [ ] Circuit breaker behavior tests
- [ ] Failover and retry logic tests
- [ ] Metrics and monitoring endpoint tests
