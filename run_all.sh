#!/bin/bash

# Function to cleanup background processes
cleanup() {
    echo ""
    echo "Shutting down..."
    if [ -n "$PID_BACKEND1" ]; then
        kill $PID_BACKEND1 2>/dev/null
        echo "Stopped backend 1"
    fi
    if [ -n "$PID_BACKEND2" ]; then
        kill $PID_BACKEND2 2>/dev/null
        echo "Stopped backend 2"
    fi
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Change to script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building load balancer and backends..."
zig build

# Check if build succeeded
if [ $? -ne 0 ]; then
    echo "Build failed. Exiting."
    exit 1
fi

# Create logs directory if it doesn't exist
mkdir -p logs

echo "Starting backend servers..."

# Start backend1 in the background
echo "Starting backend 1 on port 9001..."
zig build run-backend1 &
PID_BACKEND1=$!

# Start backend2 in the background  
echo "Starting backend 2 on port 9002..."
zig build run-backend2 &
PID_BACKEND2=$!

# Wait a bit for backends to start
sleep 2

# Check if backends are running
if ! kill -0 $PID_BACKEND1 2>/dev/null; then
    echo "Backend 1 failed to start"
    cleanup
fi

if ! kill -0 $PID_BACKEND2 2>/dev/null; then
    echo "Backend 2 failed to start"
    cleanup
fi

echo "Backends started successfully"
echo "Starting load balancer on port 9000..."

# Start load balancer with arguments
if [ $# -gt 0 ]; then
    echo "Using custom arguments: $@"
    ./zig-out/bin/load_balancer "$@"
else
    echo "Using default configuration"
    zig build run-lb
fi

# Cleanup when load balancer exits
cleanup