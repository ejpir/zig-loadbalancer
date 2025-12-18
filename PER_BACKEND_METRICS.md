# Per-Backend Metrics

## Overview

The load balancer now tracks detailed metrics for each backend separately, allowing you to identify which backends are slow, failing, or have poor connection pool performance.

## Implementation Details

### Added Metrics Arrays

In `/src/utils/metrics.zig`, the following per-backend metric arrays were added:

```zig
const MAX_BACKENDS: u32 = 64;

// Per-backend counters
requests_per_backend: [MAX_BACKENDS]std.atomic.Value(u64)
success_per_backend: [MAX_BACKENDS]std.atomic.Value(u64)
errors_per_backend: [MAX_BACKENDS]std.atomic.Value(u64)
pool_hits_per_backend: [MAX_BACKENDS]std.atomic.Value(u64)
pool_misses_per_backend: [MAX_BACKENDS]std.atomic.Value(u64)
latency_total_ms_per_backend: [MAX_BACKENDS]std.atomic.Value(u64)
bytes_to_backend: [MAX_BACKENDS]std.atomic.Value(u64)
bytes_from_backend_per_backend: [MAX_BACKENDS]std.atomic.Value(u64)
```

### New Recording Methods

```zig
recordRequestForBackend(backend_idx: u32, duration_ms: i64, status_code: u16)
recordPoolHitForBackend(backend_idx: u32)
recordPoolMissForBackend(backend_idx: u32)
recordBytesForBackend(backend_idx: u32, to_backend: u64, from_backend: u64)
```

### Integration with Proxy

Modified `/src/multiprocess/proxy.zig` to call per-backend recording methods:

- Pool hits/misses: `streamingProxy_acquireConnection()`
- Request metrics: `streamingProxy_finalize()`
- Bytes transferred: `streamingProxy_finalize()`

## Prometheus Metrics Format

### Per-Backend Metrics

The metrics endpoint at `http://localhost:9090/metrics` now includes:

```prometheus
# HELP zzz_lb_backend_requests_total Total requests per backend
# TYPE zzz_lb_backend_requests_total counter
zzz_lb_backend_requests_total{backend="0"} 150
zzz_lb_backend_requests_total{backend="1"} 148
zzz_lb_backend_requests_total{backend="2"} 152

# HELP zzz_lb_backend_requests_success Successful requests per backend
# TYPE zzz_lb_backend_requests_success counter
zzz_lb_backend_requests_success{backend="0"} 148
zzz_lb_backend_requests_success{backend="1"} 140
zzz_lb_backend_requests_success{backend="2"} 150

# HELP zzz_lb_backend_requests_error Error requests per backend
# TYPE zzz_lb_backend_requests_error counter
zzz_lb_backend_requests_error{backend="0"} 2
zzz_lb_backend_requests_error{backend="1"} 8
zzz_lb_backend_requests_error{backend="2"} 2

# HELP zzz_lb_backend_latency_total_ms Total latency per backend
# TYPE zzz_lb_backend_latency_total_ms counter
zzz_lb_backend_latency_total_ms{backend="0"} 7500
zzz_lb_backend_latency_total_ms{backend="1"} 37000
zzz_lb_backend_latency_total_ms{backend="2"} 7600

# HELP zzz_lb_backend_pool_hits Pool hits per backend
# TYPE zzz_lb_backend_pool_hits counter
zzz_lb_backend_pool_hits{backend="0"} 148
zzz_lb_backend_pool_hits{backend="1"} 145
zzz_lb_backend_pool_hits{backend="2"} 150

# HELP zzz_lb_backend_pool_misses Pool misses per backend
# TYPE zzz_lb_backend_pool_misses counter
zzz_lb_backend_pool_misses{backend="0"} 2
zzz_lb_backend_pool_misses{backend="1"} 3
zzz_lb_backend_pool_misses{backend="2"} 2

# HELP zzz_lb_backend_bytes_sent Bytes sent to backend
# TYPE zzz_lb_backend_bytes_sent counter
zzz_lb_backend_bytes_sent{backend="0"} 153600
zzz_lb_backend_bytes_sent{backend="1"} 151552
zzz_lb_backend_bytes_sent{backend="2"} 155648

# HELP zzz_lb_backend_bytes_received Bytes received from backend
# TYPE zzz_lb_backend_bytes_received counter
zzz_lb_backend_bytes_received{backend="0"} 307200
zzz_lb_backend_bytes_received{backend="1"} 303104
zzz_lb_backend_bytes_received{backend="2"} 311296
```

## Use Cases

### 1. Identify Slow Backends

Calculate average latency per backend:

```
avg_latency = zzz_lb_backend_latency_total_ms{backend="N"} / zzz_lb_backend_requests_total{backend="N"}
```

Example PromQL query:
```promql
zzz_lb_backend_latency_total_ms / zzz_lb_backend_requests_total
```

From the example above:
- Backend 0: 7500ms / 150 = 50ms avg
- Backend 1: 37000ms / 148 = 250ms avg (SLOW!)
- Backend 2: 7600ms / 152 = 50ms avg

### 2. Identify Failing Backends

Error rate per backend:

```promql
rate(zzz_lb_backend_requests_error[5m]) / rate(zzz_lb_backend_requests_total[5m])
```

From the example:
- Backend 0: 2/150 = 1.3% error rate
- Backend 1: 8/148 = 5.4% error rate (HIGH!)
- Backend 2: 2/152 = 1.3% error rate

### 3. Connection Pool Efficiency

Pool hit rate per backend:

```promql
zzz_lb_backend_pool_hits / (zzz_lb_backend_pool_hits + zzz_lb_backend_pool_misses)
```

From the example:
- Backend 0: 148/(148+2) = 98.7%
- Backend 1: 145/(145+3) = 98.0%
- Backend 2: 150/(150+2) = 98.7%

### 4. Traffic Distribution

Check if load is evenly distributed:

```promql
zzz_lb_backend_requests_total
```

From the example: 150, 148, 152 - well balanced!

## Alerting Examples

### Backend Latency Alert

```yaml
- alert: BackendHighLatency
  expr: |
    (zzz_lb_backend_latency_total_ms / zzz_lb_backend_requests_total) > 200
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Backend {{ $labels.backend }} has high latency"
    description: "Backend {{ $labels.backend }} average latency is {{ $value }}ms"
```

### Backend Error Rate Alert

```yaml
- alert: BackendHighErrorRate
  expr: |
    rate(zzz_lb_backend_requests_error[5m]) /
    rate(zzz_lb_backend_requests_total[5m]) > 0.05
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Backend {{ $labels.backend }} has high error rate"
    description: "Backend {{ $labels.backend }} error rate is {{ $value | humanizePercentage }}"
```

### Backend Pool Degradation Alert

```yaml
- alert: BackendPoolDegraded
  expr: |
    rate(zzz_lb_backend_pool_hits[5m]) /
    (rate(zzz_lb_backend_pool_hits[5m]) + rate(zzz_lb_backend_pool_misses[5m])) < 0.90
  for: 5m
  labels:
    severity: info
  annotations:
    summary: "Backend {{ $labels.backend }} pool hit rate degraded"
    description: "Backend {{ $labels.backend }} pool hit rate is {{ $value | humanizePercentage }}"
```

## Design Decisions

1. **Static Arrays vs HashMap**: Used fixed-size arrays (`MAX_BACKENDS = 64`) to avoid heap allocation and maintain zero-allocation metrics.

2. **Atomic Counters**: Same `std.atomic.Value(u64)` type as global metrics for thread-safe increments across worker processes.

3. **Bounds Checking**: All recording methods check `backend_idx < MAX_BACKENDS` to prevent out-of-bounds access.

4. **Sparse Output**: Only backends with non-zero metrics are included in Prometheus output to reduce payload size.

5. **Backward Compatibility**: Global metrics are preserved - per-backend metrics are additional, not replacement.

## Testing

Added comprehensive tests in `src/utils/metrics.zig`:

- `test "per-backend metrics initialization"` - Verify all counters start at 0
- `test "per-backend request recording"` - Test request/success/error tracking
- `test "per-backend pool metrics"` - Test pool hit/miss tracking
- `test "per-backend bytes tracking"` - Test bytes sent/received
- `test "per-backend bounds checking"` - Test out-of-bounds safety
- `test "prometheus format includes per-backend metrics"` - Test Prometheus output
- `test "prometheus format only includes backends with data"` - Test sparse output
- `test "global and per-backend metrics work together"` - Test integration

All tests pass (153/153 tests passed).

## Buffer Size

Increased metrics buffer from 4KB to 16KB to accommodate per-backend metrics:

```zig
threadlocal var metrics_buffer: [16384]u8 = undefined;
```

With 64 backends and ~200 bytes per backend, this provides ample headroom.

## Performance Impact

- **Memory**: +512 bytes per atomic counter array × 8 arrays = ~4KB per MetricsCollector instance
- **CPU**: Negligible - atomic increments are already used for global metrics
- **Network**: Only active backends appear in metrics output (sparse encoding)

## Future Enhancements

Potential additions (not implemented):

- Average latency gauge (calculated from total/count)
- Per-backend timeout counters
- Per-backend connection failures
- Histogram of latency distribution per backend
- Backend-specific circuit breaker state
