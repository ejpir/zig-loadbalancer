#!/bin/bash

# Build the backends
cd /Users/nick/repos/zzz
zig build -C examples/load_balancer build-all

# Start backend1 in the background
terminal-notifier -title "Starting Backend 1" -message "Backend 1 starting on port 9001" -sound default
zig build -C examples/load_balancer run-backend1 &
PID_BACKEND1=$!

# Start backend2 in the background
terminal-notifier -title "Starting Backend 2" -message "Backend 2 starting on port 9002" -sound default
zig build -C examples/load_balancer run-backend2 &
PID_BACKEND2=$!

# Wait a bit for backends to start
sleep 2

# Start load balancer
terminal-notifier -title "Starting Load Balancer" -message "Load balancer starting on port 9000" -sound default

# Get command line arguments for the load balancer, if any
LB_ARGS=""
if [ $# -gt 0 ]; then
    LB_ARGS="$@"
    echo "Starting load balancer with custom arguments: $LB_ARGS"
    zig-out/bin/load_balancer $LB_ARGS
else
    echo "Starting load balancer with default configuration"
    zig build run_load_balancer
fi

# When load balancer exits, kill the backends
kill $PID_BACKEND1
kill $PID_BACKEND2