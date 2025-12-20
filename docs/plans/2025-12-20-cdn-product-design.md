# lb CDN Product Design

## Overview

Transform the lb load balancer into a CDN product with an open-core business model:
- **OSS core**: Reverse proxy with caching, static assets, API acceleration
- **Paid offering**: Managed global edge network with usage-based pricing

**Differentiators**: Fastest + cheapest. Zig's efficiency enables lower infrastructure costs passed on as savings.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         OPEN SOURCE CORE                             │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  lb proxy                                                    │    │
│  │  • L7 reverse proxy with caching layer                      │    │
│  │  • Static asset + API response caching                      │    │
│  │  • Health checks, connection pooling, hot reload            │    │
│  │  • Runs anywhere: laptop, VPS, bare metal                   │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Addons                                                      │    │
│  │  • WAF (OWASP rules, custom rules)                          │    │
│  │  • Rate limiting (per IP, per API key)                      │    │
│  │  • Geo-blocking, bot detection                              │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                    (optional: connect to managed network)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      PAID MANAGED NETWORK                            │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐      │
│  │  PoP     │◄──►│  PoP     │◄──►│  PoP     │◄──►│  PoP     │      │
│  │  US-East │    │  EU-West │    │  Asia    │    │  US-West │      │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘      │
│         ▲              ▲              ▲              ▲              │
│         └──────────────┴──────────────┴──────────────┘              │
│                    Distributed Cache Mesh (Gossip)                   │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Control Plane: API, Dashboard, Billing, Analytics          │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘

Network-level (infrastructure, not software):
• DDoS mitigation via upstream providers / colo
• BGP anycast for traffic distribution
```

## OSS Core Additions

### 1. Caching Layer

```
Request → Cache Check → HIT? → Serve from cache
                    ↓ MISS
              Forward to origin → Cache response → Serve
```

- **Cache key**: Method + Host + Path + Query (configurable)
- **Storage**: Memory (LRU) with size limits, optional disk for large assets
- **Cache-Control**: Honor origin headers, allow overrides via config
- **Purge API**: `DELETE /cache/{key}` or wildcard `DELETE /cache/images/*`
- **Metrics**: `lb_cache_hits_total`, `lb_cache_misses_total`

### 2. Static Asset Handling

```bash
./lb -b api.example.com:443 --cache-static "*.js,*.css,*.png" --ttl 86400
```

- Auto-detect cacheable content types (images, fonts, scripts)
- Configurable TTLs per extension or path pattern
- Compression: gzip/brotli on-the-fly or pre-compressed

### 3. API Response Caching

```bash
./lb -b api.example.com:443 --cache-api "/api/products/*" --ttl 60
```

- Cache GET/HEAD by default, configurable
- Vary header support (different cache per Accept-Encoding, etc.)
- Stale-while-revalidate for high availability

## Addons

### Rate Limiting

- Token bucket algorithm per IP / API key / custom header
- Configurable limits + burst allowance
- 429 responses with Retry-After header

### WAF

- OWASP Core Rule Set (SQL injection, XSS, path traversal)
- Custom rules (block paths, IPs, user agents)
- Log-only mode for testing before enforcement

### Out of Scope (Infrastructure Level)

- DDoS mitigation: Handled by upstream providers (Path.net, colo DDoS protection)
- BGP anycast: Network configuration, not application code

## Distributed Cache Protocol

### Hybrid Control + Data Plane

```
┌─────────────────────────────────────────────────────────────────┐
│                      CONTROL PLANE                               │
│  Protocol: Custom binary over TCP + TLS                         │
│  Purpose: Reliable delivery of critical messages                │
│  • Cache invalidations (MUST NOT be lost)                       │
│  • PoP health/membership                                        │
│  • Config sync                                                  │
├─────────────────────────────────────────────────────────────────┤
│                       DATA PLANE                                 │
│  Protocol: QUIC (HTTP/3)                                        │
│  Purpose: Fast content transfer                                 │
│  • Cache content replication                                    │
│  • Bulk transfers                                               │
│  • Benefits: 0-RTT, multiplexing, congestion control            │
└─────────────────────────────────────────────────────────────────┘
```

### Control Plane Message Format

```
┌──────────┬──────────┬──────────┬─────────────────┐
│ Magic(4) │ Type(1)  │ Len(4)   │ Payload(var)    │
│ "LBCP"   │ 0x01-0xFF│ u32 BE   │ MessagePack/raw │
└──────────┴──────────┴──────────┴─────────────────┘

Messages:
  0x01 CACHE_SET    {key, hash, size, ttl, pop_id}
  0x02 CACHE_DEL    {key} or {prefix/*}
  0x03 CACHE_SYNC   {key[], hash[]} (bulk reconciliation)
  0x10 POP_JOIN     {pop_id, endpoints, capacity}
  0x11 POP_LEAVE    {pop_id}
  0x12 POP_HEALTH   {pop_id, load, cache_size, uptime}
  0x20 CONFIG_PUSH  {version, config_blob}
```

### Delivery Guarantees

| Message Type | Delivery | Reason |
|--------------|----------|--------|
| CACHE_SET | Best-effort | Missing = cache miss, origin handles it |
| CACHE_DEL | Exactly-once | Stale content is unacceptable |
| POP_* | Reliable | Cluster membership must be consistent |
| CONFIG_PUSH | Reliable + ACK | Config drift breaks everything |

### Invalidation Protocol

```
Purge request arrives at any PoP
         │
         ▼
┌─────────────────────────┐
│ Assign sequence number  │
│ (Lamport clock per key) │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ Broadcast to all PoPs   │
│ (TCP, wait for ACKs)    │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ Quorum ACK (N/2 + 1)?   │──No──► Retry with backoff
└───────────┬─────────────┘
            │ Yes
            ▼
       Purge confirmed
```

### Performance Optimizations

1. **Batch gossip**: Aggregate cache events, send every 50ms
2. **Bloom filters**: "Do you have any of these 1000 keys?" in 1KB
3. **Delta sync**: On PoP reconnect, exchange only missing entries
4. **Priority queues**: Invalidations before SET, small assets before large
5. **Regional clustering**: EU PoPs gossip more frequently with each other

## CLI Design

```bash
# Getting started
lb init                           # Create lb.json config
lb login                          # Auth with managed network

# Local development (OSS, no account needed)
lb serve -b api.example.com:443   # Run locally with caching
lb serve -c lb.json               # Run from config file

# Managed network
lb deploy                         # Push config to edge network
lb status                         # Show PoPs, cache stats, health
lb logs --tail                    # Real-time logs from all PoPs
lb purge /images/*                # Instant global cache purge
lb purge --all                    # Nuclear option

# Analytics
lb stats                          # Requests, bandwidth, cache ratio
lb stats --pop us-east            # Per-PoP breakdown
```

## Config File (lb.json)

```json
{
  "origins": [
    {"host": "api.example.com", "port": 443}
  ],
  "cache": {
    "static": {"match": "*.js,*.css,*.png,*.woff2", "ttl": 86400},
    "api": {"match": "/api/products/*", "ttl": 60}
  },
  "addons": {
    "rate_limit": {"requests_per_second": 100, "by": "ip"},
    "waf": {"ruleset": "owasp-core", "mode": "block"}
  }
}
```

## Control Plane API

```
POST   /v1/sites                 # Create site
GET    /v1/sites/{id}/stats      # Analytics
POST   /v1/sites/{id}/purge      # Cache invalidation
GET    /v1/sites/{id}/logs       # Log stream (SSE)
PUT    /v1/sites/{id}/config     # Update config (triggers deploy)
```

## Dashboard (Minimal)

- Usage graphs (requests, bandwidth, cache hit ratio)
- PoP health map
- Billing / invoices
- API key management

## Pricing

```
┌─────────────────────────────────────────────────────────────────┐
│                         FREE TIER                                │
│  • 100 GB bandwidth / month                                     │
│  • 1 million requests / month                                   │
│  • 1 site                                                       │
│  • Community support                                            │
├─────────────────────────────────────────────────────────────────┤
│                         PAY AS YOU GO                            │
│  • $0.01 / GB bandwidth                                         │
│  • $0.10 / million requests                                     │
│  • Unlimited sites                                              │
│  • No minimums, no contracts                                    │
├─────────────────────────────────────────────────────────────────┤
│                         PRO ($49/mo)                             │
│  • Everything above                                             │
│  • WAF included                                                 │
│  • Advanced rate limiting                                       │
│  • 30-day log retention                                         │
│  • Priority support                                             │
└─────────────────────────────────────────────────────────────────┘
```

### Competitive Positioning

| Competitor | Bandwidth/GB | lb price | Savings |
|------------|--------------|----------|---------|
| CloudFront | $0.085 | $0.01 | 88% |
| Fastly | $0.12 | $0.01 | 92% |
| Cloudflare Pro | $20/mo flat | Usage-based | Fairer |

### Cost Efficiency

- Zig = lower CPU/memory = fewer servers per Gbps
- Bare metal (Hetzner, OVH) vs cloud = 5-10x cheaper
- No bloated enterprise sales team
- Pass savings to customers

## Implementation Roadmap

### Phase 1: OSS Core (Caching)

1. In-memory LRU cache with size limits
2. Cache key generation (method + host + path + query)
3. Cache-Control header parsing & honoring
4. Content-type detection for auto-caching
5. Configurable TTLs per pattern
6. Gzip/Brotli compression
7. Vary header support
8. Stale-while-revalidate
9. Purge API
10. Cache metrics

### Phase 2: Addons

1. Rate limiting (token bucket, per IP/key)
2. WAF (OWASP rules, custom rules, log-only mode)

### Phase 3: Managed Network

1. Control plane API
2. CLI (lb deploy, lb purge, lb stats)
3. Minimal dashboard
4. Deploy 3 PoPs (US-East, EU-West, Asia)
5. PoP-to-PoP gossip protocol
6. Distributed cache mesh
7. DNS (Anycast or geo-DNS)
8. Usage metering + Stripe billing

### Phase 4: Scale

1. Add PoPs based on customer demand
2. Origin shield
3. Bot detection addon
4. Geo-blocking addon
5. Enterprise features (SSO, custom contracts)

## Infrastructure Strategy

- Start with 3-5 PoPs in major regions
- Use bare metal providers (Vultr, Hetzner, OVH) for cost efficiency
- Colocate in key markets as scale justifies
- DDoS protection via upstream providers
