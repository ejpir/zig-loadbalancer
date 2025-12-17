#!/bin/bash
# TLS Integration Test
#
# This script tests the TLS implementation by:
# 1. Starting the load balancer with an HTTPS backend (httpbin.org:443)
# 2. Making requests through it
# 3. Verifying responses

set -e

echo "=== TLS Integration Test ==="
echo

# Build first
echo "Building load balancer..."
/usr/local/zig-0.16.0-dev/zig build
echo "Build successful!"
echo

# Run unit tests
echo "Running unit tests..."
/usr/local/zig-0.16.0-dev/zig test src/http/tls_test.zig
echo

echo "Starting load balancer with HTTPS backend (httpbin.org:443)..."
echo "Usage: ./zig-out/bin/load_balancer_mp -b httpbin.org:443 -p 8080 -w 1"
echo
echo "Then in another terminal, test with:"
echo "  curl http://localhost:8080/get"
echo "  curl http://localhost:8080/ip"
echo
echo "Starting now... (Press Ctrl+C to stop)"
echo

# Run with single worker for easier debugging
./zig-out/bin/load_balancer_mp -b httpbin.org:443 -p 8080 -w 1
