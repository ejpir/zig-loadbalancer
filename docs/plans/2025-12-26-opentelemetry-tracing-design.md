# OpenTelemetry Tracing Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add distributed tracing to the load balancer for debugging request lifecycle, HTTP/2 streams, and GOAWAY retry issues.

**Architecture:** Traces exported via OTLP/HTTP to Jaeger. Spans created per-request with child spans for pool acquire, TLS handshake, H2 connection, and response forwarding.

**Tech Stack:** zig-o11y/opentelemetry-sdk, Jaeger

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Load Balancer                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Tracer    │  │   Spans     │  │    OTLP Exporter        │  │
│  │  (global)   │──│  (per-req)  │──│  HTTP/JSON → Jaeger     │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ OTLP/HTTP (port 4318)
                    ┌─────────────────────┐
                    │      Jaeger         │
                    │   localhost:16686   │
                    └─────────────────────┘
```

## Span Hierarchy (Implemented)

### HTTP/2 (HTTPS) Path
```
proxy_request (root, SERVER span)
├─ http.method, http.url, http.status_code
├─ backend.id, backend.host
│
├── backend_selection (INTERNAL)
│   ├─ lb.backend_count
│   ├─ lb.healthy_count
│   └─ lb.strategy
│
└── backend_request_h2 (CLIENT)
    ├─ http.method, http.url
    ├─ http.status_code, http.response_content_length
    ├─ h2.retry_count
    │
    ├── dns_resolution (INTERNAL)
    │   └─ dns.hostname
    │
    ├── tcp_connect (INTERNAL)
    │   ├─ net.peer.name
    │   └─ net.peer.port
    │
    ├── tls_handshake (INTERNAL)
    │   ├─ tls.server_name
    │   ├─ tls.cipher
    │   └─ tls.alpn
    │
    ├── h2_handshake (INTERNAL)
    │   └─ HTTP/2 preface + SETTINGS exchange
    │
    └── response_streaming (INTERNAL)
        ├─ http.body.type: "h2_buffered"
        ├─ http.body.length
        ├─ http.body.bytes_written
        └─ http.body.had_error
```

### HTTP/1.1 Path
```
proxy_request (root, SERVER span)
├─ http.method, http.url, http.status_code
│
├── backend_selection (INTERNAL)
│   ├─ lb.backend_count, lb.healthy_count, lb.strategy
│
├── backend_connection (INTERNAL)
│   │
│   ├── dns_resolution (INTERNAL)
│   │   └─ dns.hostname
│   │
│   ├── tcp_connect (INTERNAL)
│   │   ├─ net.peer.name
│   │   └─ net.peer.port
│   │
│   └── tls_handshake (INTERNAL, if HTTPS)
│       ├─ tls.server_name, tls.cipher, tls.alpn
│
├── backend_request (CLIENT)
│   └─ http.method, http.url
│
└── response_streaming (INTERNAL)
    ├─ http.body.type: "content_length" | "chunked" | "until_close"
    ├─ http.body.expected_length
    ├─ http.body.bytes_transferred
    └─ http.body.had_error
```

## Files to Create

### src/telemetry/mod.zig
Public API for tracing:
- `init(endpoint: []const u8)` - Initialize tracer with Jaeger endpoint
- `shutdown()` - Flush and close exporter
- `startSpan(name, parent)` - Create new span
- Global tracer instance

### src/telemetry/exporter.zig
OTLP/HTTP exporter:
- Batch spans (100 or 5 seconds)
- Non-blocking export in background
- Flush on shutdown

### src/telemetry/span.zig
Span wrapper:
- setAttribute(key, value)
- addEvent(name)
- setStatus(error)
- end()

## Files to Modify

### build.zig
```zig
const otel = b.dependency("opentelemetry-sdk", .{
    .target = target,
    .optimize = optimize,
});
load_balancer_mod.addImport("opentelemetry", otel.module("opentelemetry"));
```

### build.zig.zon
```zig
.@"opentelemetry-sdk" = .{
    .url = "git+https://github.com/zig-o11y/opentelemetry-sdk",
},
```

### main.zig
- Add `--otel-endpoint` CLI flag
- Call `telemetry.init(endpoint)` at startup
- Call `telemetry.shutdown()` on exit

### src/proxy/handler.zig
- Create root span in `streamingProxy()`
- Add `trace_context` field to `ProxyState`
- End span in `streamingProxy_finalize()`

### src/proxy/connection.zig
- Create `pool_acquire` child span in `acquireConnection()`

### src/http/http2/connection.zig
- Create `h2_connect` span in `connect()`
- Create `h2_request` span in `request()`
- Add `goaway_received` event when GOAWAY detected

### src/http/http2/pool.zig
- Add `retry_triggered` event on retry

### src/http/tls.zig
- Create `tls_handshake` span during TLS setup

## Context Passing

```zig
pub const ProxyState = struct {
    // ... existing fields ...
    trace_span: ?*Span = null,  // Root span for this request
};
```

Child spans access parent via `proxy_state.trace_span`.

## CLI Usage

```bash
# With tracing
./load_balancer --port 8080 --backend 127.0.0.1:9000 \
    --otel-endpoint http://localhost:4318

# Without tracing (default)
./load_balancer --port 8080 --backend 127.0.0.1:9000
```

## Testing

```bash
# Start Jaeger
docker run -d --name jaeger \
  -p 16686:16686 -p 4318:4318 \
  jaegertracing/all-in-one:latest

# Run LB with tracing
./zig-out/bin/load_balancer --otel-endpoint http://localhost:4318 ...

# View traces
open http://localhost:16686
```

## Verification Checklist

- [x] Normal request shows complete span hierarchy
- [x] Backend selection shows lb.strategy, backend_count, healthy_count
- [x] DNS resolution span with hostname
- [x] TCP connect span with peer name/port
- [x] TLS handshake span with cipher and ALPN protocol
- [x] H2 handshake span for HTTP/2 connections
- [x] Response streaming span with body type and bytes transferred
- [x] Errors mark spans with error status
- [x] GOAWAY shows retry events in h2 span

## Implementation Status

**Completed:**
- Vendored OpenTelemetry SDK from zig-o11y
- OTLP/HTTP exporter to Jaeger (port 4318)
- `--otel-endpoint` CLI flag
- Full span hierarchy for HTTP/1.1 and HTTP/2 paths
- Connection phase spans (DNS, TCP, TLS, H2 handshake)
- Response streaming spans
- Proper parent-child span relationships
- Span attributes following OpenTelemetry semantic conventions
