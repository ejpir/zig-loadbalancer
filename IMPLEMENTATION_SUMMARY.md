# Per-Backend Metrics Implementation Summary

## What Was Implemented

Added comprehensive per-backend metrics to the load balancer, enabling detailed monitoring and troubleshooting of individual backend servers.

## Files Modified

### 1. `/src/utils/metrics.zig`

**Added:**
- `MAX_BACKENDS` constant (64)
- 8 per-backend metric arrays using atomic counters:
  - `requests_per_backend`
  - `success_per_backend`
  - `errors_per_backend`
  - `pool_hits_per_backend`
  - `pool_misses_per_backend`
  - `latency_total_ms_per_backend`
  - `bytes_to_backend`
  - `bytes_from_backend_per_backend`

**New Methods:**
- `recordRequestForBackend(backend_idx, duration_ms, status_code)` - Records request with latency and status
- `recordPoolHitForBackend(backend_idx)` - Records connection pool hit
- `recordPoolMissForBackend(backend_idx)` - Records connection pool miss
- `recordBytesForBackend(backend_idx, to_backend, from_backend)` - Records bytes transferred

**Modified:**
- `toPrometheusFormat()` - Now outputs per-backend metrics with labels
- Increased `metrics_buffer` size from 4KB to 16KB

**Added 8 Comprehensive Tests:**
1. Per-backend metrics initialization
2. Per-backend request recording
3. Per-backend pool metrics
4. Per-backend bytes tracking
5. Per-backend bounds checking
6. Prometheus format includes per-backend metrics
7. Prometheus format only includes backends with data
8. Global and per-backend metrics work together

### 2. `/src/multiprocess/proxy.zig`

**Modified Functions:**

- `streamingProxy_acquireConnection()` - Lines 328-329, 354-355
  - Added `recordPoolHitForBackend(backend_idx)` on pool hit
  - Added `recordPoolMissForBackend(backend_idx)` on pool miss

- `streamingProxy_finalize()` - Lines 1115-1125
  - Added `recordRequestForBackend()` to track per-backend latency and status
  - Added `recordBytesForBackend()` to track per-backend byte transfer

## Test Results

```
Build Summary: 3/3 steps succeeded; 153/153 tests passed
test success
+- run test unit_tests 153 pass (153 total)
```

All existing tests continue to pass, plus 8 new tests for per-backend metrics.

## Backward Compatibility

- Global metrics unchanged and continue to work
- Per-backend metrics are additional, not replacement
- No breaking changes to existing API
- Metrics buffer increased to handle larger output

## Key Features

1. **Zero Allocation**: Uses static arrays and atomic counters, no heap allocation
2. **Thread Safe**: Atomic operations for multi-process safety
3. **Bounds Checked**: All recording methods validate `backend_idx < MAX_BACKENDS`
4. **Sparse Output**: Only backends with data appear in Prometheus output
5. **Label-Based**: Uses Prometheus label syntax `{backend="N"}`

## Example Prometheus Output

```prometheus
zzz_lb_backend_requests_total{backend="0"} 150
zzz_lb_backend_requests_total{backend="1"} 148
zzz_lb_backend_latency_total_ms{backend="0"} 7500
zzz_lb_backend_latency_total_ms{backend="1"} 37000
zzz_lb_backend_pool_hits{backend="0"} 148
zzz_lb_backend_pool_hits{backend="1"} 145
```

## Use Cases Enabled

1. **Identify Slow Backends**: Calculate avg latency per backend
2. **Identify Failing Backends**: Track error rate per backend
3. **Monitor Pool Efficiency**: Calculate pool hit rate per backend
4. **Check Load Distribution**: Verify requests are balanced
5. **Alert on Issues**: Set up backend-specific alerts

## Performance Impact

- **Memory**: ~4KB per MetricsCollector (8 arrays × 64 backends × 8 bytes)
- **CPU**: Negligible (atomic increments already used globally)
- **Network**: Minimal (sparse output, only active backends)

## Documentation

Created:
- `/PER_BACKEND_METRICS.md` - Full documentation with examples and PromQL queries
- `/IMPLEMENTATION_SUMMARY.md` - This file

## What Questions Can Now Be Answered

✅ Which backend is slow?
- Compare `zzz_lb_backend_latency_total_ms / zzz_lb_backend_requests_total` across backends

✅ Which backend is failing?
- Check `zzz_lb_backend_requests_error{backend="N"}`

✅ What's the pool hit rate per backend?
- Calculate `pool_hits / (pool_hits + pool_misses)` per backend

✅ Is traffic evenly distributed?
- Compare `zzz_lb_backend_requests_total` across backends

✅ Which backend is receiving/sending the most data?
- Check `zzz_lb_backend_bytes_sent` and `zzz_lb_backend_bytes_received`

## Next Steps (Not Implemented)

Future enhancements could include:
- Per-backend histogram of latency distribution
- Per-backend connection timeout counters
- Per-backend circuit breaker state metrics
- Per-backend active connection gauge
- PromQL recording rules for common calculations
