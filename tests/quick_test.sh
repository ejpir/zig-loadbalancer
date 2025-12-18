#!/bin/bash

echo "Starting backend..."
./zig-out/bin/test_backend_echo --port 19001 --id backend1 &
sleep 2

echo "Testing backend directly..."
curl -s http://localhost:19001/test | jq .server_id

echo ""
echo "Starting load balancer..."
./zig-out/bin/load_balancer_sp --port 18080 --backend 127.0.0.1:19001 &
sleep 2

echo "Testing load balancer..."
curl -s http://localhost:18080/test | jq .server_id

echo ""
echo "Cleaning up..."
killall test_backend_echo load_balancer_sp 2>/dev/null
