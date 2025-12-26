# WAF Architecture Documentation

High-performance Web Application Firewall for the zzz load balancer with OpenTelemetry observability.

## Table of Contents
- [Overview](#overview)
- [Architecture](#architecture)
- [Request Flow](#request-flow)
- [Components](#components)
- [OpenTelemetry Integration](#opentelemetry-integration)
- [Configuration](#configuration)
- [Data Structures](#data-structures)

---

## Overview

The WAF provides:
- **Lock-free rate limiting** using atomic CAS operations
- **Request validation** (URI length, body size, JSON depth)
- **Burst detection** (anomaly detection for sudden traffic spikes)
- **Slowloris protection** (connection tracking)
- **Shadow mode** for safe rule testing
- **Hot-reload configuration**
- **Full OpenTelemetry tracing**

Design Philosophy: **TigerBeetle-style**
- Fixed-size structures with compile-time bounds
- Cache-line alignment to prevent false sharing
- Zero allocation on hot path
- Atomic operations only (no locks)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Load Balancer                                   │
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────────┐ │
│  │   main.zig      │    │  handler.zig    │    │   telemetry/mod.zig     │ │
│  │                 │    │                 │    │                         │ │
│  │ • CLI args      │───▶│ • Request entry │───▶│ • OTLP exporter         │ │
│  │ • WAF init      │    │ • WAF check     │    │ • Batching processor    │ │
│  │ • Stats thread  │    │ • OTEL spans    │    │ • Span attributes       │ │
│  └─────────────────┘    └────────┬────────┘    └─────────────────────────┘ │
│                                  │                                          │
│                                  ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                         WAF Module (src/waf/)                         │  │
│  │                                                                       │  │
│  │  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐  ┌────────────┐  │  │
│  │  │  mod.zig    │  │  engine.zig  │  │  config.zig │  │ events.zig │  │  │
│  │  │             │  │              │  │             │  │            │  │  │
│  │  │ Public API  │  │ Orchestrator │  │ JSON parser │  │ Structured │  │  │
│  │  │ Re-exports  │  │ Main check() │  │ Hot-reload  │  │ logging    │  │  │
│  │  └─────────────┘  └──────┬───────┘  └─────────────┘  └────────────┘  │  │
│  │                          │                                            │  │
│  │         ┌────────────────┼────────────────┐                          │  │
│  │         ▼                ▼                ▼                          │  │
│  │  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐                  │  │
│  │  │rate_limiter │  │ validator.zig│  │  state.zig  │                  │  │
│  │  │    .zig     │  │              │  │             │                  │  │
│  │  │             │  │ URI/body/JSON│  │ Shared mem  │                  │  │
│  │  │ Token bucket│  │ validation   │  │ structures  │                  │  │
│  │  │ Atomic CAS  │  │ Streaming    │  │ 64K buckets │                  │  │
│  │  └─────────────┘  └──────────────┘  │ Burst track │                  │  │
│  │                                      │ Metrics     │                  │  │
│  │                                      └─────────────┘                  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
                    ┌─────────────────────────────────┐
                    │         Jaeger / OTLP           │
                    │     (Distributed Tracing)       │
                    └─────────────────────────────────┘
```

---

## Request Flow

```
                              ┌──────────────────────┐
                              │   Incoming Request   │
                              └──────────┬───────────┘
                                         │
                                         ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  handler.zig:handle()                                                       │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  1. telemetry.startServerSpan("proxy_request")                      │   │
│  │     ├─ setStringAttribute("http.method", method)                    │   │
│  │     └─ setStringAttribute("http.url", uri)                          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                                         ▼                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  2. main.getWafEngine() -> WafEngine                                │   │
│  │     └─ Returns engine with (WafState*, WafConfig*)                  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                                         ▼                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  3. Build waf.Request                                               │   │
│  │     ├─ convertHttpMethod(ctx.request.method)                        │   │
│  │     ├─ Extract body length from ctx.request.body                    │   │
│  │     └─ Request.init() or Request.withContentLength()                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                                         ▼                                   │
└─────────────────────────────────────────┼──────────────────────────────────┘
                                          │
                                          ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  engine.zig:WafEngine.check(&request)                                       │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Step 1: Fast path check                                            │   │
│  │  if (!self.waf_config.enabled) return CheckResult.allow()           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                                         ▼                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Step 2: getClientIp(request)                                       │   │
│  │  ├─ Check if source_ip is trusted proxy                             │   │
│  │  ├─ If trusted, parse X-Forwarded-For header                        │   │
│  │  └─ Return real client IP (u32)                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                                         ▼                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Step 3: validateRequest(request)                                   │   │
│  │  ├─ Check URI length <= max_uri_length                              │   │
│  │  ├─ Check body size <= getMaxBodySize(path)                         │   │
│  │  └─ Return CheckResult.block(.invalid_request) if failed            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                                         ▼                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Step 4: checkRateLimit(request, client_ip)                         │   │
│  │  ├─ findMatchingRule(request) -> RateLimitRule                      │   │
│  │  ├─ Build Key from (client_ip, hashPath(path))                      │   │
│  │  ├─ RateLimiter.check(key, rule) -> DecisionResult                  │   │
│  │  │   └─ Bucket.tryConsume() with atomic CAS                         │   │
│  │  └─ Return CheckResult.block(.rate_limit) if exhausted              │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                                         ▼                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Step 5: checkBurst(client_ip)  [if burst_detection_enabled]        │   │
│  │  ├─ getCurrentTimeSec()                                             │   │
│  │  ├─ WafState.checkBurst(ip_hash, time, threshold)                   │   │
│  │  │   ├─ BurstTracker.findOrCreate(ip_hash)                          │   │
│  │  │   └─ BurstEntry.recordAndCheck(time, threshold)                  │   │
│  │  │       ├─ Update EMA baseline (0.875 * old + 0.125 * current)     │   │
│  │  │       └─ Return true if current > baseline * threshold           │   │
│  │  └─ Return CheckResult.block(.burst) if burst detected              │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                                         ▼                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Step 6: recordDecision(&result)                                    │   │
│  │  ├─ metrics.recordAllowed() / recordBlocked(reason)                 │   │
│  │  └─ Atomic increment of counters                                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                                         ▼                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Step 7: applyMode(result)                                          │   │
│  │  ├─ If shadow_mode: result.toShadowMode() (block -> log_only)       │   │
│  │  └─ Return final CheckResult                                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────┬──────────────────────────────────┘
                                          │
                                          ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  Back to handler.zig                                                        │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Add WAF attributes to OTEL span:                                   │   │
│  │  ├─ span.setStringAttribute("waf.decision", decision)               │   │
│  │  ├─ span.setStringAttribute("waf.client_ip", formatIpv4(ip))        │   │
│  │  ├─ span.setStringAttribute("waf.reason", reason.description())     │   │
│  │  └─ span.setStringAttribute("waf.rule", rule_name)                  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                         │                                   │
│                         ┌───────────────┴───────────────┐                   │
│                         ▼                               ▼                   │
│               ┌─────────────────┐             ┌─────────────────┐           │
│               │  result.isBlocked()           │  Proceed to     │           │
│               │  Return 429/403 │             │  Backend        │           │
│               │  + WAF headers  │             │  Proxy request  │           │
│               └─────────────────┘             └─────────────────┘           │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. `mod.zig` - Public API Module

Re-exports all public types for clean external interface.

```zig
// Usage
const waf = @import("waf");
var engine = waf.WafEngine.init(&state, &config);
const result = engine.check(&request);
```

**Exported Types:**
| Type | Source | Purpose |
|------|--------|---------|
| `WafState` | state.zig | Shared memory container |
| `WafEngine` | engine.zig | Main orchestrator |
| `WafConfig` | config.zig | JSON configuration |
| `Request` | engine.zig | Request representation |
| `CheckResult` | engine.zig | Decision output |
| `Decision` | state.zig | allow/block/log_only |
| `Reason` | state.zig | Why blocked |
| `RateLimiter` | rate_limiter.zig | Token bucket |
| `RequestValidator` | validator.zig | Size/format checks |
| `EventLogger` | events.zig | Structured logging |

---

### 2. `engine.zig` - WAF Engine

The orchestrator that coordinates all security checks.

```
┌─────────────────────────────────────────────────────────────────┐
│                        WafEngine                                 │
├─────────────────────────────────────────────────────────────────┤
│ Fields:                                                          │
│   waf_state: *WafState      (mmap'd shared memory)              │
│   waf_config: *const WafConfig                                   │
│   limiter: RateLimiter                                          │
├─────────────────────────────────────────────────────────────────┤
│ Methods:                                                         │
│   init(state, config) -> WafEngine                              │
│   check(request) -> CheckResult         ◀── Main entry point    │
│   getClientIp(request) -> u32                                   │
│   validateRequest(request) -> CheckResult                       │
│   checkRateLimit(request, ip) -> CheckResult                    │
│   checkBurst(ip) -> CheckResult                                 │
│   applyMode(result) -> CheckResult                              │
│   recordDecision(result) -> void                                │
└─────────────────────────────────────────────────────────────────┘
```

**Key Functions:**

| Function | Lines | Purpose |
|----------|-------|---------|
| `check()` | 192-227 | Main entry, orchestrates all checks |
| `getClientIp()` | 234-255 | Extract real IP from X-Forwarded-For |
| `validateRequest()` | 258-275 | URI/body size validation |
| `checkRateLimit()` | 278-314 | Token bucket rate limiting |
| `checkBurst()` | 317-326 | Anomaly detection |
| `applyMode()` | 329-334 | Shadow mode transformation |

---

### 3. `state.zig` - Shared Memory Structures

Lock-free data structures for multi-process sharing.

```
┌─────────────────────────────────────────────────────────────────┐
│                    WafState (~4MB)                               │
│                    64-byte aligned                               │
├─────────────────────────────────────────────────────────────────┤
│ magic: u64                 │ Corruption detection "WAFSTV10"    │
├─────────────────────────────────────────────────────────────────┤
│ buckets: [65536]Bucket     │ Token bucket table                 │
│   └─ Each Bucket: 64 bytes │   └─ key_hash: u64                 │
│      (cache-line aligned)  │   └─ packed_state: u64 (atomic)    │
│                            │      └─ tokens: u32 (scaled x1000) │
│                            │      └─ timestamp: u32             │
├─────────────────────────────────────────────────────────────────┤
│ conn_tracker: ConnTracker  │ Per-IP connection counting         │
│   └─ [16384]ConnEntry      │   └─ Slowloris detection           │
├─────────────────────────────────────────────────────────────────┤
│ burst_tracker: BurstTracker│ Anomaly detection                  │
│   └─ [8192]BurstEntry      │   └─ baseline_rate (EMA)           │
│                            │   └─ current_count                 │
│                            │   └─ last_window                   │
├─────────────────────────────────────────────────────────────────┤
│ metrics: WafMetrics        │ Atomic counters                    │
│   └─ requests_allowed      │                                    │
│   └─ requests_blocked      │                                    │
│   └─ requests_logged       │                                    │
│   └─ blocked_by_reason[10] │                                    │
├─────────────────────────────────────────────────────────────────┤
│ config_epoch: u64          │ Hot-reload detection               │
└─────────────────────────────────────────────────────────────────┘
```

**Bucket CAS Operation:**

```
┌──────────────────────────────────────────────────────────────────┐
│  Bucket.tryConsume(current_time, rate, max, cost)                │
│                                                                  │
│  1. Load packed_state atomically                                 │
│     ┌────────────────────────────────────────┐                   │
│     │ packed_state (u64)                     │                   │
│     │ [  tokens (u32)  |  timestamp (u32)  ] │                   │
│     └────────────────────────────────────────┘                   │
│                                                                  │
│  2. Calculate token refill based on elapsed time                 │
│     elapsed = current_time - old_timestamp                       │
│     new_tokens = min(old_tokens + elapsed * rate, max)           │
│                                                                  │
│  3. Attempt consumption                                          │
│     if new_tokens >= cost:                                       │
│         new_tokens -= cost                                       │
│                                                                  │
│  4. CAS (Compare-And-Swap) atomically                            │
│     if cmpxchgWeak(old_packed, new_packed):                      │
│         return SUCCESS                                           │
│     else:                                                        │
│         retry (up to MAX_CAS_ATTEMPTS)                           │
│                                                                  │
│  5. Fail-open: If CAS exhausted, allow request                   │
└──────────────────────────────────────────────────────────────────┘
```

---

### 4. `rate_limiter.zig` - Token Bucket

Lock-free rate limiting with atomic operations.

```
┌─────────────────────────────────────────────────────────────────┐
│                       RateLimiter                                │
├─────────────────────────────────────────────────────────────────┤
│ state: *WafState            (pointer to shared memory)          │
├─────────────────────────────────────────────────────────────────┤
│ check(key, rule) -> DecisionResult                              │
│   ├─ findOrCreateBucket(key.hash())                             │
│   ├─ bucket.tryConsume(time, rate, capacity, cost)              │
│   └─ Return allow/block with remaining tokens                   │
├─────────────────────────────────────────────────────────────────┤
│ findOrCreateBucket(hash) -> ?*Bucket                            │
│   └─ Open addressing with linear probing                        │
│   └─ Probe limit: 16 attempts                                   │
├─────────────────────────────────────────────────────────────────┤
│ Key Structure:                                                   │
│   ip: u32          (IPv4 address)                               │
│   path_hash: u32   (FNV-1a hash of path)                        │
└─────────────────────────────────────────────────────────────────┘
```

---

### 5. `validator.zig` - Request Validation

Zero-allocation request validation with streaming JSON support.

```
┌─────────────────────────────────────────────────────────────────┐
│                    RequestValidator                              │
├─────────────────────────────────────────────────────────────────┤
│ config: *const ValidatorConfig                                  │
├─────────────────────────────────────────────────────────────────┤
│ validateRequest(uri, content_length, headers)                   │
│   ├─ Check URI length                                           │
│   ├─ Check body size                                            │
│   └─ Check query parameter count                                │
├─────────────────────────────────────────────────────────────────┤
│ validateJsonStream(chunk, state) -> ValidationResult            │
│   └─ Streaming JSON validation (constant memory)                │
│   └─ Tracks nesting depth and key count                         │
├─────────────────────────────────────────────────────────────────┤
│ ValidatorConfig:                                                 │
│   max_uri_length: 2048                                          │
│   max_query_params: 50                                          │
│   max_body_size: 1MB                                            │
│   max_json_depth: 20                                            │
│   max_json_keys: 1000                                           │
└─────────────────────────────────────────────────────────────────┘
```

---

### 6. `config.zig` - Configuration

JSON configuration parsing with validation.

```json
{
  "enabled": true,
  "shadow_mode": false,
  "burst_detection_enabled": true,
  "burst_threshold": 10,
  "rate_limits": [
    {
      "name": "login_bruteforce",
      "path": "/api/auth/login",
      "method": "POST",
      "limit": { "requests": 10, "period_sec": 60 },
      "burst": 3,
      "by": "ip",
      "action": "block"
    }
  ],
  "slowloris": {
    "max_conns_per_ip": 50
  },
  "request_limits": {
    "max_uri_length": 2048,
    "max_body_size": 1048576,
    "max_json_depth": 20
  },
  "trusted_proxies": ["10.0.0.0/8"],
  "logging": {
    "log_blocked": true,
    "log_allowed": false
  }
}
```

---

### 7. `events.zig` - Structured Logging

JSON Lines output for machine parsing.

```json
{"timestamp":1703635200,"event_type":"blocked","client_ip":"192.168.1.1","method":"POST","path":"/api/login","rule_name":"login_bruteforce","reason":"rate_limit"}
```

---

## OpenTelemetry Integration

### Initialization Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  main.zig                                                        │
│                                                                  │
│  telemetry.init(allocator, "localhost:4318")                    │
│       │                                                          │
│       ▼                                                          │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  telemetry/mod.zig:init()                                   ││
│  │                                                             ││
│  │  1. Create ConfigOptions (OTLP endpoint, HTTP protobuf)     ││
│  │  2. Create OTLPExporter with service name                   ││
│  │  3. Create RandomIDGenerator with seeded PRNG               ││
│  │  4. Create TracerProvider                                   ││
│  │  5. Create BatchingProcessor                                ││
│  │     └─ max_queue_size: 2048                                 ││
│  │     └─ scheduled_delay_millis: 5000                         ││
│  │     └─ max_export_batch_size: 512                           ││
│  │  6. Add processor to provider                               ││
│  │  7. Get tracer ("zzz-load-balancer", "0.1.0")               ││
│  │  8. Store in global_state                                   ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

### Request Tracing Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  handler.zig:handle()                                            │
│                                                                  │
│  var span = telemetry.startServerSpan("proxy_request");         │
│  defer span.end();                                               │
│       │                                                          │
│       ▼                                                          │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  engine.checkWithSpan(&request, &span, telemetry)           ││
│  │                                                             ││
│  │  Creates child spans for each WAF step:                     ││
│  │                                                             ││
│  │  proxy_request (Server)                                     ││
│  │  └── waf.check (Internal)                                   ││
│  │      ├── waf.validate_request (Internal)                    ││
│  │      │   └─ waf.step: "validate_request"                    ││
│  │      │   └─ waf.passed: true/false                          ││
│  │      ├── waf.rate_limit (Internal)                          ││
│  │      │   └─ waf.step: "rate_limit"                          ││
│  │      │   └─ waf.passed: true/false                          ││
│  │      │   └─ waf.tokens_remaining: 42                        ││
│  │      │   └─ waf.rule: "api_rate_limit"                      ││
│  │      └── waf.burst_detection (Internal)                     ││
│  │          └─ waf.step: "burst_detection"                     ││
│  │          └─ waf.passed: true/false                          ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  // Summary attributes on parent span                            │
│  span.setStringAttribute("waf.decision", "allow");              │
│  span.setStringAttribute("waf.client_ip", "192.168.1.1");       │
│                                                                  │
│  span.end();  // Automatically queued for batch export          │
└─────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  BatchingProcessor (background thread)                           │
│                                                                  │
│  Every 5 seconds OR when 512 spans accumulated:                 │
│    └─ OTLPExporter.export(batch)                                │
│        └─ HTTP POST to http://localhost:4318/v1/traces          │
│        └─ Protobuf-encoded spans                                │
└─────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Jaeger UI                                    │
│                                                                  │
│  Trace: proxy_request [12.5ms]                                   │
│  ├─ waf.check [0.8ms]                                           │
│  │   ├─ waf.validate_request [0.05ms]                           │
│  │   ├─ waf.rate_limit [0.5ms]                                  │
│  │   └─ waf.burst_detection [0.2ms]                             │
│  └─ backend_request [11.2ms]                                    │
│                                                                  │
│  Span Attributes:                                                │
│  ├─ http.method: GET                                            │
│  ├─ http.url: /api/users                                        │
│  ├─ waf.decision: block                                         │
│  │   ├─ waf.client_ip: 192.168.1.100                            │
│  │   ├─ waf.reason: rate_limit                                  │
│  │   └─ waf.rule: api_rate_limit                                │
│  └─ Duration: 1.2ms                                             │
└─────────────────────────────────────────────────────────────────┘
```

### Span Attributes Reference

**Parent Span (proxy_request):**

| Attribute | Type | Description |
|-----------|------|-------------|
| `http.method` | string | HTTP method (GET, POST, etc.) |
| `http.url` | string | Request URI |
| `http.status_code` | int | Response status code |
| `waf.decision` | string | "allow", "block", or "log_only" |
| `waf.client_ip` | string | Client IP address |
| `waf.reason` | string | Reason description if blocked |
| `waf.rule` | string | Rule name if blocked |
| `backend.host` | string | Backend server address |
| `backend.port` | int | Backend server port |

**WAF Child Spans (waf.check, waf.validate_request, waf.rate_limit, waf.burst_detection):**

| Attribute | Type | Description |
|-----------|------|-------------|
| `waf.step` | string | Current step name |
| `waf.passed` | bool | Whether this step passed |
| `waf.tokens_remaining` | int | Remaining rate limit tokens (rate_limit only) |
| `waf.rule` | string | Matched rule name (rate_limit only) |
| `waf.reason` | string | Block reason if failed |
| `waf.blocked_by` | string | Which step blocked (on waf.check span) |
| `waf.result` | string | Final result "allow" (on waf.check span) |
| `waf.enabled` | string | "false" if WAF disabled (fast path) |

---

## Burst Detection (Anomaly Detection)

Detects sudden traffic spikes using Exponential Moving Average (EMA).

```
┌─────────────────────────────────────────────────────────────────┐
│  BurstEntry (12 bytes per IP)                                    │
├─────────────────────────────────────────────────────────────────┤
│  ip_hash: u32        │ FNV-1a hash of client IP                 │
│  baseline_rate: u16  │ EMA of requests/window (scaled x16)      │
│  current_count: u16  │ Requests in current window               │
│  last_window: u32    │ Timestamp of current window start        │
└─────────────────────────────────────────────────────────────────┘

Algorithm:
┌─────────────────────────────────────────────────────────────────┐
│  Window = 60 seconds                                             │
│                                                                  │
│  On each request:                                                │
│    if (current_time - last_window >= 60):                       │
│        # New window - update baseline with EMA                  │
│        new_baseline = old_baseline * 0.875 + current_count * 0.125│
│        current_count = 1                                        │
│        last_window = current_time                               │
│        return false  # No burst on window transition            │
│    else:                                                        │
│        # Same window - increment and check                      │
│        current_count += 1                                       │
│        if baseline < MIN_BASELINE:                              │
│            return false  # Not enough history                   │
│        if current_count * 16 > baseline * threshold:            │
│            return true   # BURST DETECTED                       │
│        return false                                             │
└─────────────────────────────────────────────────────────────────┘

Example:
  Baseline: 20 req/min (established over time)
  Threshold: 10x

  Window 1: 18 requests -> baseline updates to ~20
  Window 2: 22 requests -> baseline updates to ~20
  Window 3: 250 requests
    -> 250 * 16 = 4000 > 320 * 10 = 3200
    -> BURST DETECTED at request ~200
```

---

## WAF Stats Thread

Background thread logs statistics every 10 seconds.

```
┌─────────────────────────────────────────────────────────────────┐
│  main.zig:wafStatsLoop()                                         │
│                                                                  │
│  while (true):                                                   │
│      std.posix.nanosleep(10, 0)  # Sleep 10 seconds             │
│      stats = global_waf_state.metrics.snapshot()                │
│                                                                  │
│      log.info("WAF Stats: total={} allowed={} blocked={} ...")  │
└─────────────────────────────────────────────────────────────────┘

Output:
[+10000ms] info(waf_stats): WAF Stats: total=1523 allowed=1498 blocked=25 logged=0 block_rate=1% | by_reason: rate_limit=20 slowloris=0 body=3 json=2
```

---

## Memory Layout

```
Total WafState size: ~4.2MB

┌──────────────────────────────────────────────────────────────────┐
│ Offset    │ Size      │ Field                                    │
├───────────┼───────────┼──────────────────────────────────────────┤
│ 0x000000  │ 8 bytes   │ magic ("WAFSTV10")                       │
│ 0x000040  │ 4,194,304 │ buckets[65536] (64 bytes each)           │
│ 0x400040  │ 131,072   │ conn_tracker[16384] (8 bytes each)       │
│ 0x420040  │ 98,304    │ burst_tracker[8192] (12 bytes each)      │
│ 0x438040  │ 128       │ metrics (atomic counters)                │
│ 0x4380C0  │ 8         │ config_epoch                             │
└──────────────────────────────────────────────────────────────────┘

Cache-line alignment (64 bytes) at:
  - buckets array start
  - conn_tracker start
  - burst_tracker start
  - metrics start
  - config_epoch
```

---

## File Reference

| File | Lines | Purpose |
|------|-------|---------|
| `src/waf/mod.zig` | ~190 | Public API, re-exports |
| `src/waf/engine.zig` | ~400 | Main orchestrator |
| `src/waf/state.zig` | ~1240 | Shared memory structures |
| `src/waf/rate_limiter.zig` | ~350 | Token bucket implementation |
| `src/waf/validator.zig` | ~350 | Request validation |
| `src/waf/config.zig` | ~600 | JSON config parsing |
| `src/waf/events.zig` | ~300 | Structured logging |
| `src/telemetry/mod.zig` | ~220 | OpenTelemetry integration |
| `src/proxy/handler.zig` | ~500 | Request handler with WAF |
| `main.zig` | ~400 | Entry point, WAF init |

---

## Test Coverage

129 unit tests covering:
- Bucket operations and CAS
- Rate limiter logic
- Burst detection (EMA, spike detection)
- Request validation
- JSON streaming validation
- Config parsing
- Event formatting
- Integration tests

Run tests:
```bash
zig test src/waf/mod.zig
```
