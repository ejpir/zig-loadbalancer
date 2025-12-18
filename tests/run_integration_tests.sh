#!/bin/bash

# Integration Tests for Load Balancer
# This script starts backends and load balancer, then runs tests using curl

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BACKEND1_PORT=19001
BACKEND2_PORT=19002
BACKEND3_PORT=19003
LB_PORT=18080

# Process tracking
PIDS=()

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    for pid in "${PIDS[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            echo "Killing process $pid"
            kill $pid 2>/dev/null || true
        fi
    done
    wait 2>/dev/null || true
    echo "Cleanup complete"
}

# Register cleanup on exit
trap cleanup EXIT INT TERM

# Helper functions
pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    echo "  $2"
    exit 1
}

info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# Start a backend server
start_backend() {
    local port=$1
    local id=$2

    ./zig-out/bin/test_backend_echo --port $port --id $id > /dev/null 2>&1 &
    local pid=$!
    PIDS+=($pid)
    info "Started backend $id on port $port (PID: $pid)"
}

# Start load balancer
start_load_balancer() {
    local backends="$@"

    ./zig-out/bin/load_balancer_sp --port $LB_PORT $backends > /dev/null 2>&1 &
    local pid=$!
    PIDS+=($pid)
    info "Started load balancer on port $LB_PORT (PID: $pid)"
}

# Wait for server to be ready
wait_for_server() {
    local port=$1
    local max_attempts=20
    local attempt=0

    while ! nc -z localhost $port 2>/dev/null; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            fail "Server on port $port failed to start" "Timeout waiting for server"
        fi
        sleep 0.1
    done
}

# Test: GET request
test_get_request() {
    info "Testing GET request forwarding"

    local response=$(curl -s -w "\n%{http_code}" http://localhost:$LB_PORT/)
    local status=$(echo "$response" | tail -n 1)
    local body=$(echo "$response" | sed '$d')

    if [ "$status" != "200" ]; then
        fail "GET request" "Expected status 200, got $status"
    fi

    # Check if response is JSON
    if ! echo "$body" | jq . > /dev/null 2>&1; then
        fail "GET request" "Response is not valid JSON: $body"
    fi

    local method=$(echo "$body" | jq -r '.method')
    local uri=$(echo "$body" | jq -r '.uri')

    if [ "$method" != "GET" ]; then
        fail "GET request" "Expected method GET, got $method"
    fi

    if [ "$uri" != "/" ]; then
        fail "GET request" "Expected URI /, got $uri"
    fi

    pass "GET request forwarded correctly"
}

# Test: POST request with JSON body
test_post_with_body() {
    info "Testing POST request with JSON body"

    local request_body='{"test":"data","number":42}'
    local response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$request_body" \
        http://localhost:$LB_PORT/)

    local status=$(echo "$response" | tail -n 1)
    local body=$(echo "$response" | sed '$d')

    if [ "$status" != "200" ]; then
        fail "POST with body" "Expected status 200, got $status"
    fi

    local method=$(echo "$body" | jq -r '.method')
    local uri=$(echo "$body" | jq -r '.uri')
    local response_body=$(echo "$body" | jq -r '.body')
    local body_length=$(echo "$body" | jq -r '.body_length')

    if [ "$method" != "POST" ]; then
        fail "POST with body" "Expected method POST, got $method"
    fi

    if [ "$uri" != "/" ]; then
        fail "POST with body" "Expected URI /, got $uri"
    fi

    if [ "$response_body" != "$request_body" ]; then
        fail "POST with body" "Body mismatch. Expected: $request_body, Got: $response_body"
    fi

    local expected_len=${#request_body}
    if [ "$body_length" != "$expected_len" ]; then
        fail "POST with body" "Body length mismatch. Expected: $expected_len, Got: $body_length"
    fi

    pass "POST request with JSON body forwarded correctly"
}

# Test: Custom headers
test_custom_headers() {
    info "Testing custom header forwarding"

    local response=$(curl -s \
        -H "X-Custom-Header: CustomValue" \
        -H "X-Request-ID: test-123" \
        -H "Authorization: Bearer token123" \
        http://localhost:$LB_PORT/)

    local custom_header=$(echo "$response" | jq -r '.headers["X-Custom-Header"]')
    local request_id=$(echo "$response" | jq -r '.headers["X-Request-ID"]')
    local auth=$(echo "$response" | jq -r '.headers.Authorization')

    if [ "$custom_header" != "CustomValue" ]; then
        fail "Custom headers" "X-Custom-Header not forwarded correctly. Got: $custom_header"
    fi

    if [ "$request_id" != "test-123" ]; then
        fail "Custom headers" "X-Request-ID not forwarded correctly. Got: $request_id"
    fi

    if [ "$auth" != "Bearer token123" ]; then
        fail "Custom headers" "Authorization not forwarded correctly. Got: $auth"
    fi

    pass "Custom headers forwarded correctly"
}

# Test: Round-robin load balancing
test_round_robin() {
    info "Testing round-robin load balancing"

    # Clean up previous test
    cleanup
    PIDS=()

    # Start 3 backends
    start_backend $BACKEND1_PORT "backend1"
    start_backend $BACKEND2_PORT "backend2"
    start_backend $BACKEND3_PORT "backend3"

    # Start load balancer with all 3 backends
    start_load_balancer \
        --backend "127.0.0.1:$BACKEND1_PORT" \
        --backend "127.0.0.1:$BACKEND2_PORT" \
        --backend "127.0.0.1:$BACKEND3_PORT"

    # Wait for servers
    sleep 1
    wait_for_server $LB_PORT

    # Make 9 requests and track which backend handles each
    local backend1_count=0
    local backend2_count=0
    local backend3_count=0

    for i in {1..9}; do
        local response=$(curl -s http://localhost:$LB_PORT/)
        local server_id=$(echo "$response" | jq -r '.server_id')

        case "$server_id" in
            "backend1") backend1_count=$((backend1_count + 1)) ;;
            "backend2") backend2_count=$((backend2_count + 1)) ;;
            "backend3") backend3_count=$((backend3_count + 1)) ;;
        esac
    done

    # Each backend should handle exactly 3 requests
    if [ $backend1_count -ne 3 ] || [ $backend2_count -ne 3 ] || [ $backend3_count -ne 3 ]; then
        fail "Round-robin" "Distribution not even. Backend1: $backend1_count, Backend2: $backend2_count, Backend3: $backend3_count"
    fi

    pass "Round-robin distributes requests evenly (3/3/3)"
}

# Test: Multiple sequential requests
test_sequential_requests() {
    info "Testing multiple sequential requests"

    for i in {1..5}; do
        local response=$(curl -s http://localhost:$LB_PORT/)
        local uri=$(echo "$response" | jq -r '.uri')

        if [ "$uri" != "/" ]; then
            fail "Sequential requests" "Request $i failed. Expected URI /, got $uri"
        fi
    done

    pass "Multiple sequential requests work correctly"
}

# Main test execution
main() {
    echo "========================================"
    echo "Load Balancer Integration Tests"
    echo "========================================"
    echo ""

    # Check if binaries exist
    if [ ! -f "./zig-out/bin/test_backend_echo" ]; then
        fail "Setup" "test_backend_echo binary not found. Run 'zig build' first."
    fi

    if [ ! -f "./zig-out/bin/load_balancer_sp" ]; then
        fail "Setup" "load_balancer_sp binary not found. Run 'zig build' first."
    fi

    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        fail "Setup" "jq is required for JSON parsing. Please install it."
    fi

    # Check if nc is available
    if ! command -v nc &> /dev/null; then
        fail "Setup" "nc (netcat) is required for port checking. Please install it."
    fi

    info "Starting basic tests (single backend)..."

    # Start single backend for basic tests
    start_backend $BACKEND1_PORT "backend1"
    start_load_balancer --backend "127.0.0.1:$BACKEND1_PORT"

    # Wait for servers to start
    sleep 1
    wait_for_server $BACKEND1_PORT
    wait_for_server $LB_PORT

    # Run basic tests
    test_get_request
    test_post_with_body
    test_custom_headers
    test_sequential_requests

    # Run round-robin test (requires restarting with multiple backends)
    test_round_robin

    echo ""
    echo "========================================"
    echo -e "${GREEN}All tests passed!${NC}"
    echo "========================================"
}

# Run tests
main
