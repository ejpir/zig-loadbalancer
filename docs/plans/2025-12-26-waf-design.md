# ZZZ WAF Design

**Date:** 2025-12-26
**Status:** Approved
**Scope:** Integrated WAF for zzz load balancer

## Overview

A high-performance Web Application Firewall integrated into the zzz load balancer, focusing on API protection and DDoS/abuse mitigation. Designed with TigerBeetle-style patterns for zero-allocation hot paths and lock-free shared state.

### Goals

- **API Protection:** Rate limiting, authentication abuse prevention, JSON depth attacks
- **DDoS Mitigation:** Slowloris, request flooding, volume-based attacks
- **Production-Ready:** Shadow mode, hot-reload config, full observability
- **TigerBeetle-Style:** Fixed-size structures, lock-free atomics, bounded everything

### Non-Goals (Future Work)

- OWASP pattern matching (SQLi, XSS) - requires regex engine
- Multi-node state sync (Redis) - can layer on later
- Bot detection / CAPTCHA integration

---

## Architecture

```
Request → Router → [WAF Layer] → Proxy Handler → Backend
                       ↓
              ┌────────┴────────┐
              │   WAF Engine    │
              ├─────────────────┤
              │ • RateLimiter   │ ← Token bucket per IP/path
              │ • SlowlorisGuard│ ← Connection timing
              │ • RequestValidator│ ← Size limits, JSON depth
              │ • DecisionLogger│ ← Events + traces
              └────────┬────────┘
                       ↓
              ┌────────┴────────┐
              │  Shared State   │ (mmap'd region)
              ├─────────────────┤
              │ • BucketTable   │ ← Fixed-size hash table
              │ • ConnTracker   │ ← Per-IP connection counts
              │ • Metrics       │ ← Atomic counters
              └─────────────────┘
```

### Design Principles

- **Zero allocation on hot path** - All structures pre-allocated at startup
- **Lock-free reads** - Atomic operations only, no mutexes during request handling
- **Fail-open option** - If WAF state is corrupted, configurable to allow or deny
- **Comptime rule compilation** - Rule matching logic generated at compile time where possible

---

## Shared State Design (TigerBeetle-Style)

### Main State Structure

```zig
/// Cache-line aligned for atomic access
pub const WafState = extern struct {
    // Magic + version for corruption detection
    magic: u64 = 0xWAF_STATE_V1,

    // Token bucket table - fixed size, open addressing
    buckets: [MAX_BUCKETS]Bucket align(64),

    // Connection tracking for slowloris
    conn_tracker: ConnTracker align(64),

    // Global metrics - atomic counters
    metrics: WafMetrics align(64),

    // Configuration epoch - for hot-reload detection
    config_epoch: u64 align(64),

    comptime {
        std.debug.assert(@sizeOf(WafState) == WAF_STATE_SIZE);
    }
};
```

### Token Bucket Entry

```zig
pub const Bucket = extern struct {
    // Key: hash of (IP, path_pattern)
    key_hash: u64,

    // Token bucket state (packed for atomic CAS)
    tokens: u32,          // Current tokens (scaled by 1000)
    last_update: u32,     // Timestamp in seconds

    // Stats for this bucket
    total_requests: u64,
    total_blocked: u64,

    comptime {
        std.debug.assert(@sizeOf(Bucket) == 64); // One cache line
    }
};
```

### Constants

```zig
const MAX_BUCKETS = 65536;        // 64K entries = 4MB state
const MAX_TOKENS = 10000;         // Scaled for precision
const BUCKET_PROBE_LIMIT = 16;    // Open addressing probe limit
const MAX_CAS_ATTEMPTS = 8;       // Retry limit for atomic ops
const MAX_TRACKED_IPS = 16384;    // For connection counting
```

---

## Rate Limiter (Token Bucket)

Lock-free token bucket with atomic compare-and-swap. O(1) per request.

```zig
pub const RateLimiter = struct {
    state: *WafState,

    pub fn check(self: *RateLimiter, key: Key, rule: *const Rule) Decision {
        const bucket_idx = self.findBucket(key);
        const bucket = &self.state.buckets[bucket_idx];

        const now_sec: u32 = @truncate(std.time.timestamp());

        var attempts: u32 = 0;
        while (attempts < MAX_CAS_ATTEMPTS) : (attempts += 1) {
            const old = @atomicLoad(u64, &bucket.packed, .acquire);
            const old_tokens = unpackTokens(old);
            const old_time = unpackTime(old);

            // Refill tokens based on elapsed time
            const elapsed = now_sec -% old_time;
            const refill = @min(elapsed * rule.tokens_per_sec, rule.burst_capacity);
            const available = @min(old_tokens + refill, rule.burst_capacity);

            if (available < rule.cost_per_request) {
                return .{ .action = .block, .reason = .rate_limit_exceeded };
            }

            const new_tokens = available - rule.cost_per_request;
            const new = packState(new_tokens, now_sec);

            if (@cmpxchgWeak(u64, &bucket.packed, old, new, .release, .monotonic)) |_| {
                continue;
            }

            return .{ .action = .allow };
        }

        // Fail-open under extreme contention
        @atomicAdd(&self.state.metrics.cas_exhausted, 1, .monotonic);
        return .{ .action = .allow, .reason = .cas_exhausted };
    }
};
```

### Key Properties

- No mutex, no blocking
- Timestamps wrap-safe using wrapping subtraction
- Bounded CAS retries (fail-open under extreme contention)
- Token precision: scaled by 1000 for sub-integer rates

---

## Slowloris & Connection Abuse Detection

Per-connection state tracking with timeout enforcement.

```zig
pub const SlowlorisGuard = struct {
    pub const ConnState = struct {
        first_byte_time: u64,
        headers_complete_time: u64,
        bytes_received: u32,
        last_activity: u64,
    };

    pub const Config = struct {
        header_timeout_ms: u32 = 5_000,
        body_timeout_ms: u32 = 30_000,
        min_bytes_per_sec: u32 = 100,
        max_conns_per_ip: u16 = 100,
    };

    pub fn onDataReceived(self: *SlowlorisGuard, conn: *ConnState, bytes: u32) Decision {
        const now = std.time.milliTimestamp();
        conn.bytes_received += bytes;
        conn.last_activity = now;

        // Header timeout check
        if (conn.headers_complete_time == 0) {
            if (now - conn.first_byte_time > self.config.header_timeout_ms) {
                return .{ .action = .block, .reason = .header_timeout };
            }
        }

        // Transfer rate check (after initial burst window)
        const elapsed_sec = (now - conn.first_byte_time) / 1000;
        if (elapsed_sec > 2) {
            const rate = conn.bytes_received / elapsed_sec;
            if (rate < self.config.min_bytes_per_sec) {
                return .{ .action = .block, .reason = .slow_transfer };
            }
        }

        return .{ .action = .allow };
    }
};
```

### Connection Tracking (Shared Memory)

```zig
pub const ConnTracker = extern struct {
    entries: [MAX_TRACKED_IPS]ConnEntry align(64),
};

pub const ConnEntry = extern struct {
    ip_hash: u32,
    conn_count: u16,  // Atomic increment/decrement
    _padding: u16,
};
```

---

## API Protection (Request Validation)

Streaming validation with constant memory usage.

```zig
pub const RequestValidator = struct {
    pub const Config = struct {
        max_uri_length: u16 = 2048,
        max_query_params: u8 = 50,
        max_header_value_length: u16 = 8192,
        max_cookie_size: u16 = 4096,
        max_body_size: u32 = 1_048_576,
        max_json_depth: u8 = 20,
        max_json_keys: u16 = 1000,
        endpoint_overrides: []const EndpointConfig,
    };

    /// Fast pre-body validation
    pub fn validateHeaders(self: *RequestValidator, req: *const Request) Decision {
        if ((req.uri orelse "").len > self.config.max_uri_length) {
            return .{ .action = .block, .reason = .uri_too_long };
        }

        if (req.getHeader("content-length")) |cl| {
            const len = std.fmt.parseInt(u32, cl, 10) catch 0;
            if (len > self.config.max_body_size) {
                return .{ .action = .block, .reason = .body_too_large };
            }
        }

        if (req.getHeader("cookie")) |cookie| {
            if (cookie.len > self.config.max_cookie_size) {
                return .{ .action = .block, .reason = .cookie_too_large };
            }
        }

        return .{ .action = .allow };
    }

    /// Streaming JSON validation (constant memory)
    pub fn validateJsonStream(self: *RequestValidator, chunk: []const u8, state: *JsonState) Decision {
        for (chunk) |byte| {
            switch (byte) {
                '{', '[' => {
                    state.depth += 1;
                    if (state.depth > self.config.max_json_depth) {
                        return .{ .action = .block, .reason = .json_too_deep };
                    }
                },
                '}', ']' => state.depth -|= 1,
                ':' => {
                    state.key_count += 1;
                    if (state.key_count > self.config.max_json_keys) {
                        return .{ .action = .block, .reason = .json_too_many_keys };
                    }
                },
                else => {},
            }
        }
        return .{ .action = .allow };
    }
};
```

---

## Configuration

### Example `waf.json`

```json
{
  "enabled": true,
  "shadow_mode": false,

  "rate_limits": [
    {
      "name": "login_bruteforce",
      "path": "/api/auth/login",
      "method": "POST",
      "limit": { "requests": 10, "period_sec": 60 },
      "burst": 3,
      "by": "ip",
      "action": "block"
    },
    {
      "name": "api_global",
      "path": "/api/*",
      "limit": { "requests": 1000, "period_sec": 60 },
      "burst": 100,
      "by": "ip",
      "action": "block"
    }
  ],

  "slowloris": {
    "header_timeout_ms": 5000,
    "body_timeout_ms": 30000,
    "min_bytes_per_sec": 100,
    "max_conns_per_ip": 50
  },

  "request_limits": {
    "max_uri_length": 2048,
    "max_body_size": 1048576,
    "max_json_depth": 20,
    "endpoints": [
      { "path": "/api/upload", "max_body_size": 10485760 }
    ]
  },

  "trusted_proxies": ["10.0.0.0/8", "172.16.0.0/12"],

  "logging": {
    "log_blocked": true,
    "log_allowed": false,
    "log_near_limit": true,
    "near_limit_threshold": 0.8
  }
}
```

### Hot-Reload Behavior

- Config file watched using existing `config_watcher.zig` pattern
- Atomic epoch increment signals workers to re-read
- Rate limit buckets NOT cleared on reload (existing limits preserved)
- Only rule definitions change

### CLI Integration

```
./load_balancer --backend 127.0.0.1:8080 --waf waf.json --waf-shadow
```

---

## Observability

### Metrics (Prometheus format via `/metrics`)

```zig
pub const WafMetrics = extern struct {
    requests_allowed: u64 align(64),
    requests_blocked: u64 align(64),
    requests_logged: u64 align(64),

    blocked_rate_limit: u64,
    blocked_slowloris: u64,
    blocked_body_too_large: u64,
    blocked_json_depth: u64,

    bucket_table_usage: u64,
    cas_exhausted: u64,
    config_reloads: u64,
};
```

### OpenTelemetry Spans

Child span of `proxy_request`:

```zig
fn createWafSpan(parent: Span, decision: Decision, rule: ?*const Rule) Span {
    var span = parent.child("waf_check");
    span.setAttribute("waf.decision", @tagName(decision.action));
    span.setAttribute("waf.shadow_mode", config.shadow_mode);

    if (decision.action != .allow) {
        span.setAttribute("waf.reason", @tagName(decision.reason));
        if (rule) |r| span.setAttribute("waf.rule", r.name);
    }

    return span;
}
```

### Structured Event Log

JSON events on interesting events (blocks, near-limit warnings):

```zig
pub const WafEvent = struct {
    timestamp: i64,
    event_type: enum { blocked, near_limit, config_reload },
    client_ip: []const u8,
    method: []const u8,
    path: []const u8,
    rule_name: ?[]const u8,
    reason: ?[]const u8,
    tokens_remaining: ?u32,
};
```

---

## Integration Points

### 1. Router Layer (main.zig)

```zig
var router = try Router.init(allocator, &.{
    Route.init("/metrics").get({}, metrics.metricsHandler).layer(),
    Route.init("/").all(waf_ctx, wafMiddleware).layer(),
    Route.init("/%r").all(handler_ctx, generateHandler(strategy)).layer(),
}, .{});
```

### 2. Shared Memory Region

Extend existing `shared_region.zig`:

```zig
pub const SharedRegion = struct {
    health_state: *SharedHealthState,
    waf_state: *WafState,
    backend_config: *BackendConfig,
};
```

### 3. CLI Arguments

```
--waf <path>       Path to WAF config JSON
--waf-shadow       Force shadow mode (log only)
--waf-disabled     Disable WAF entirely
```

---

## File Structure

```
src/
├── waf/
│   ├── mod.zig           # Public API
│   ├── engine.zig        # Main WAF engine
│   ├── rate_limiter.zig  # Token bucket implementation
│   ├── slowloris.zig     # Connection abuse detection
│   ├── validator.zig     # Request validation
│   ├── state.zig         # Shared memory structures
│   ├── config.zig        # JSON config parsing
│   └── events.zig        # Structured logging
```

---

## Testing Strategy

1. **Unit tests** - Each module in isolation (rate_limiter, validator, etc.)
2. **Integration tests** - Add `tests/suites/waf.zig` using existing harness
3. **Load tests** - Verify zero-allocation claims under traffic
4. **Fuzz tests** - JSON parser, config parser edge cases

---

## Implementation Order

1. `src/waf/state.zig` - Shared memory structures
2. `src/waf/rate_limiter.zig` - Token bucket core
3. `src/waf/config.zig` - JSON parsing
4. `src/waf/engine.zig` - Main orchestration
5. `main.zig` integration - CLI + middleware
6. `src/waf/slowloris.zig` - Connection tracking
7. `src/waf/validator.zig` - Request validation
8. `src/waf/events.zig` - Observability
9. Tests + documentation
