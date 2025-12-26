/// Lock-free Token Bucket Rate Limiter
///
/// High-performance rate limiting using atomic CAS operations on shared memory.
/// Designed for multi-process environments with zero allocation on the hot path.
///
/// Design Philosophy (TigerBeetle-inspired):
/// - Lock-free: Uses atomic CAS operations, no mutexes
/// - Fixed-size: All structures have bounded, compile-time known sizes
/// - Fail-open: Under extreme contention, allows requests rather than blocking
/// - Token precision: Scaled by 1000 for sub-token granularity
/// - Time-safe: Uses wrapping arithmetic for timestamp handling
///
/// Token Bucket Algorithm:
/// - Tokens refill at a configurable rate per second
/// - Burst capacity limits maximum accumulated tokens
/// - Each request consumes tokens; blocked if insufficient
/// - Atomic CAS ensures correctness under concurrent access
const std = @import("std");

const state = @import("state.zig");
pub const WafState = state.WafState;
pub const Bucket = state.Bucket;
pub const Decision = state.Decision;
pub const Reason = state.Reason;
pub const MAX_BUCKETS = state.MAX_BUCKETS;
pub const MAX_CAS_ATTEMPTS = state.MAX_CAS_ATTEMPTS;
pub const BUCKET_PROBE_LIMIT = state.BUCKET_PROBE_LIMIT;
pub const packState = state.packState;
pub const unpackTokens = state.unpackTokens;
pub const unpackTime = state.unpackTime;

// =============================================================================
// Key - What to Rate Limit By
// =============================================================================

/// Represents the identity for rate limiting
/// Combines IP address and path pattern hash for fine-grained control
pub const Key = struct {
    /// IPv4 address as u32 (network byte order)
    ip: u32,
    /// Hash of the path pattern being rate limited
    path_hash: u32,

    /// Compute a 64-bit hash combining IP and path for bucket lookup
    /// Uses FNV-1a for speed and good distribution
    pub fn hash(self: Key) u64 {
        return computeKeyHash(self.ip, self.path_hash);
    }

    /// Create a key from raw IPv4 bytes
    pub fn fromIpBytes(ip_bytes: [4]u8, path_hash: u32) Key {
        return .{
            .ip = std.mem.readInt(u32, &ip_bytes, .big),
            .path_hash = path_hash,
        };
    }

    /// Create a key from IPv4 octets
    pub fn fromOctets(a: u8, b: u8, c: u8, d: u8, path_hash: u32) Key {
        return .{
            .ip = (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, c) << 8) | @as(u32, d),
            .path_hash = path_hash,
        };
    }
};

// =============================================================================
// Rule - Rate Limit Configuration
// =============================================================================

/// Rate limit rule configuration
/// Token values are scaled by 1000 for sub-token precision
pub const Rule = struct {
    /// Tokens added per second (scaled by 1000)
    /// Example: 1500 = 1.5 requests per second
    tokens_per_sec: u32,

    /// Maximum tokens the bucket can hold (scaled by 1000)
    /// This is the burst capacity - allows temporary spikes
    burst_capacity: u32,

    /// Cost per request (scaled by 1000)
    /// Default: 1000 = 1 token per request
    cost_per_request: u32 = 1000,

    /// Create a simple rule: X requests per second with Y burst
    pub fn simple(requests_per_sec: u32, burst: u32) Rule {
        return .{
            .tokens_per_sec = requests_per_sec * 1000,
            .burst_capacity = burst * 1000,
            .cost_per_request = 1000,
        };
    }

    /// Create a rule with fractional rates (milli-precision)
    /// Example: milliRate(1500, 5000, 1000) = 1.5 req/sec, 5 burst, 1 cost
    pub fn milliRate(tokens_per_sec: u32, burst_capacity: u32, cost: u32) Rule {
        return .{
            .tokens_per_sec = tokens_per_sec,
            .burst_capacity = burst_capacity,
            .cost_per_request = cost,
        };
    }

    comptime {
        // Ensure rule fits in a cache line (important for hot path)
        std.debug.assert(@sizeOf(Rule) <= 64);
    }
};

// =============================================================================
// DecisionResult - Detailed Rate Limit Response
// =============================================================================

/// Result of a rate limit check with detailed information
pub const DecisionResult = struct {
    /// The WAF decision (allow/block)
    action: Decision,
    /// Reason for the decision
    reason: Reason = .none,
    /// Remaining tokens after this request (if allowed), scaled by 1000
    remaining_tokens: u32 = 0,

    /// Check if request should be blocked
    pub inline fn isBlocked(self: DecisionResult) bool {
        return self.action == .block;
    }

    /// Check if request was allowed
    pub inline fn isAllowed(self: DecisionResult) bool {
        return self.action == .allow;
    }
};

// =============================================================================
// RateLimiter - Main Rate Limiting Engine
// =============================================================================

/// Lock-free token bucket rate limiter
/// Uses shared memory for multi-process visibility
pub const RateLimiter = struct {
    /// Pointer to shared WAF state (in mmap'd region)
    state: *WafState,

    /// Initialize a rate limiter with shared state
    pub fn init(waf_state: *WafState) RateLimiter {
        return .{ .state = waf_state };
    }

    /// Check if a request should be rate limited
    /// This is the hot path - optimized for minimal latency
    ///
    /// Returns: DecisionResult with action, reason, and remaining tokens
    ///
    /// Behavior:
    /// - Finds or creates bucket for the key
    /// - Attempts atomic token consumption via CAS
    /// - Fails open under extreme contention (CAS exhausted)
    pub fn check(self: *RateLimiter, key: Key, rule: *const Rule) DecisionResult {
        const key_hash = key.hash();
        const now_sec = getCurrentTimeSec();

        // Find or create the bucket for this key
        const bucket = self.state.findOrCreateBucket(key_hash, now_sec) orelse {
            // Probe limit exceeded - table too full
            // Fail open: allow request but log the condition
            self.state.metrics.recordCasExhausted();
            return .{
                .action = .allow,
                .reason = .none,
                .remaining_tokens = 0,
            };
        };

        // Increment total requests counter (relaxed ordering - just metrics)
        _ = bucket.getTotalRequestsPtr().fetchAdd(1, .monotonic);

        // Attempt to consume tokens using the bucket's atomic tryConsume
        if (bucket.tryConsume(rule.cost_per_request, rule.tokens_per_sec, rule.burst_capacity, now_sec)) {
            // Success - request allowed
            const current_state = bucket.getPackedStatePtrConst().load(.acquire);
            return .{
                .action = .allow,
                .reason = .none,
                .remaining_tokens = unpackTokens(current_state),
            };
        }

        // Rate limited - increment blocked counter
        _ = bucket.getTotalBlockedPtr().fetchAdd(1, .monotonic);

        // Get remaining tokens for the response
        const current_state = bucket.getPackedStatePtrConst().load(.acquire);

        return .{
            .action = .block,
            .reason = .rate_limit,
            .remaining_tokens = unpackTokens(current_state),
        };
    }

    /// Check rate limit with explicit CAS loop (alternative implementation)
    /// Provides more control over the retry behavior
    pub fn checkWithRetry(self: *RateLimiter, key: Key, rule: *const Rule) DecisionResult {
        const key_hash = key.hash();
        const now_sec = getCurrentTimeSec();

        const bucket = self.state.findOrCreateBucket(key_hash, now_sec) orelse {
            self.state.metrics.recordCasExhausted();
            return .{ .action = .allow, .reason = .none };
        };

        _ = bucket.getTotalRequestsPtr().fetchAdd(1, .monotonic);

        const state_ptr = bucket.getPackedStatePtr();
        var attempts: u32 = 0;

        while (attempts < MAX_CAS_ATTEMPTS) : (attempts += 1) {
            const old = state_ptr.load(.acquire);
            const old_tokens = unpackTokens(old);
            const old_time = unpackTime(old);

            // Refill tokens based on elapsed time (wrap-safe)
            const elapsed = now_sec -% old_time;
            const refill = @min(
                @as(u64, elapsed) * @as(u64, rule.tokens_per_sec),
                @as(u64, rule.burst_capacity),
            );
            const available: u32 = @intCast(@min(
                @as(u64, old_tokens) + refill,
                @as(u64, rule.burst_capacity),
            ));

            // Check if we have enough tokens
            if (available < rule.cost_per_request) {
                _ = bucket.getTotalBlockedPtr().fetchAdd(1, .monotonic);
                return .{
                    .action = .block,
                    .reason = .rate_limit,
                    .remaining_tokens = available,
                };
            }

            // Calculate new state
            const new_tokens = available - rule.cost_per_request;
            const new = packState(new_tokens, now_sec);

            // Attempt atomic update
            if (state_ptr.cmpxchgWeak(old, new, .acq_rel, .acquire) == null) {
                return .{
                    .action = .allow,
                    .reason = .none,
                    .remaining_tokens = new_tokens,
                };
            }
            // CAS failed, retry with fresh state
        }

        // CAS exhausted - fail open for availability
        self.state.metrics.recordCasExhausted();
        return .{
            .action = .allow,
            .reason = .none,
            .remaining_tokens = 0,
        };
    }

    /// Find the bucket index for a key using open addressing
    /// Returns the index if found, or creates a new bucket
    pub fn findBucket(self: *RateLimiter, key: Key) ?usize {
        const key_hash = key.hash();
        const start_idx = @as(usize, @truncate(key_hash)) % MAX_BUCKETS;
        var idx = start_idx;
        var probe_count: u32 = 0;

        while (probe_count < BUCKET_PROBE_LIMIT) : (probe_count += 1) {
            const bucket = &self.state.buckets[idx];

            if (bucket.key_hash == key_hash) {
                return idx;
            }

            if (bucket.key_hash == 0) {
                return null; // Not found, slot is empty
            }

            // Linear probing
            idx = (idx + 1) % MAX_BUCKETS;
        }

        return null; // Probe limit exceeded
    }

    /// Get remaining tokens for a key (for metrics/headers)
    /// Returns null if the key doesn't have an active bucket
    pub fn getRemainingTokens(self: *RateLimiter, key: Key) ?u32 {
        const key_hash = key.hash();
        const bucket = self.state.findBucket(key_hash) orelse return null;

        const current_state = bucket.getPackedStatePtrConst().load(.acquire);
        return unpackTokens(current_state);
    }

    /// Get bucket statistics for a key
    pub fn getBucketStats(self: *RateLimiter, key: Key) ?BucketStats {
        const key_hash = key.hash();
        const bucket = self.state.findBucket(key_hash) orelse return null;

        const current_state = bucket.getPackedStatePtrConst().load(.acquire);

        // Read total_requests and total_blocked atomically
        // Use pointer cast for const atomic access
        const total_requests_ptr: *const std.atomic.Value(u64) = @ptrCast(&bucket.total_requests);
        const total_blocked_ptr: *const std.atomic.Value(u64) = @ptrCast(&bucket.total_blocked);

        return .{
            .tokens = unpackTokens(current_state),
            .last_update = unpackTime(current_state),
            .total_requests = total_requests_ptr.load(.monotonic),
            .total_blocked = total_blocked_ptr.load(.monotonic),
        };
    }

    /// Reset a bucket to full tokens (useful for testing or manual intervention)
    pub fn resetBucket(self: *RateLimiter, key: Key, max_tokens: u32) bool {
        const key_hash = key.hash();
        const now_sec = getCurrentTimeSec();
        const bucket = self.state.findOrCreateBucket(key_hash, now_sec) orelse return false;

        const new_state = packState(max_tokens, now_sec);
        bucket.getPackedStatePtr().store(new_state, .release);
        return true;
    }
};

/// Statistics for a rate limit bucket
pub const BucketStats = struct {
    /// Current token count (scaled by 1000)
    tokens: u32,
    /// Last update timestamp (seconds since epoch)
    last_update: u32,
    /// Total requests to this bucket
    total_requests: u64,
    /// Total requests blocked
    total_blocked: u64,

    /// Calculate block rate as percentage
    pub fn blockRatePercent(self: BucketStats) u64 {
        if (self.total_requests == 0) return 0;
        return (self.total_blocked * 100) / self.total_requests;
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Compute a 64-bit hash from IP and path hash
/// Uses FNV-1a variant for good distribution
pub fn computeKeyHash(ip: u32, path_hash: u32) u64 {
    var hash_val: u64 = 0xcbf29ce484222325; // FNV offset basis

    // Mix in IP bytes
    hash_val ^= @as(u64, ip >> 24);
    hash_val *%= 0x100000001b3; // FNV prime
    hash_val ^= @as(u64, (ip >> 16) & 0xFF);
    hash_val *%= 0x100000001b3;
    hash_val ^= @as(u64, (ip >> 8) & 0xFF);
    hash_val *%= 0x100000001b3;
    hash_val ^= @as(u64, ip & 0xFF);
    hash_val *%= 0x100000001b3;

    // Separator to avoid collisions
    hash_val ^= 0xff;
    hash_val *%= 0x100000001b3;

    // Mix in path hash bytes
    hash_val ^= @as(u64, path_hash >> 24);
    hash_val *%= 0x100000001b3;
    hash_val ^= @as(u64, (path_hash >> 16) & 0xFF);
    hash_val *%= 0x100000001b3;
    hash_val ^= @as(u64, (path_hash >> 8) & 0xFF);
    hash_val *%= 0x100000001b3;
    hash_val ^= @as(u64, path_hash & 0xFF);
    hash_val *%= 0x100000001b3;

    // Ensure non-zero (0 is reserved for empty slots)
    return if (hash_val == 0) 1 else hash_val;
}

/// Get current timestamp in seconds (for rate limiting)
/// Returns seconds since epoch, wrapped to u32
pub inline fn getCurrentTimeSec() u32 {
    const ts = std.posix.clock_gettime(.REALTIME) catch {
        // Fallback: return 0 if clock is unavailable (shouldn't happen in practice)
        return 0;
    };
    // ts.sec is i64 (seconds since epoch), wrap to u32
    return @truncate(@as(u64, @intCast(ts.sec)));
}

/// Hash a path string to u32 (for Key.path_hash)
pub fn hashPath(path: []const u8) u32 {
    var hash_val: u32 = 0x811c9dc5; // FNV-1a 32-bit offset basis

    for (path) |b| {
        hash_val ^= b;
        hash_val *%= 0x01000193; // FNV-1a 32-bit prime
    }

    return hash_val;
}

// =============================================================================
// Tests
// =============================================================================

test "Key: hash consistency" {
    const key1 = Key{ .ip = 0xC0A80101, .path_hash = 0x12345678 };
    const key2 = Key{ .ip = 0xC0A80101, .path_hash = 0x12345678 };
    const key3 = Key{ .ip = 0xC0A80102, .path_hash = 0x12345678 };

    // Same inputs produce same hash
    try std.testing.expectEqual(key1.hash(), key2.hash());

    // Different inputs produce different hash
    try std.testing.expect(key1.hash() != key3.hash());

    // Hash is never zero
    try std.testing.expect(key1.hash() != 0);
}

test "Key: fromOctets" {
    const key = Key.fromOctets(192, 168, 1, 1, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0xC0A80101), key.ip);
    try std.testing.expectEqual(@as(u32, 0x12345678), key.path_hash);
}

test "Key: fromIpBytes" {
    const bytes = [4]u8{ 192, 168, 1, 1 };
    const key = Key.fromIpBytes(bytes, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0xC0A80101), key.ip);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), key.path_hash);
}

test "Rule: simple creation" {
    const rule = Rule.simple(10, 20);
    try std.testing.expectEqual(@as(u32, 10000), rule.tokens_per_sec);
    try std.testing.expectEqual(@as(u32, 20000), rule.burst_capacity);
    try std.testing.expectEqual(@as(u32, 1000), rule.cost_per_request);
}

test "Rule: milliRate creation" {
    const rule = Rule.milliRate(1500, 5000, 500);
    try std.testing.expectEqual(@as(u32, 1500), rule.tokens_per_sec);
    try std.testing.expectEqual(@as(u32, 5000), rule.burst_capacity);
    try std.testing.expectEqual(@as(u32, 500), rule.cost_per_request);
}

test "RateLimiter: init" {
    var waf_state = WafState.init();
    const limiter = RateLimiter.init(&waf_state);
    try std.testing.expect(limiter.state == &waf_state);
}

test "RateLimiter: check allows within limit" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key = Key.fromOctets(192, 168, 1, 1, hashPath("/api/users"));
    const rule = Rule.simple(10, 10); // 10 req/sec, 10 burst

    // First request should be allowed (bucket starts full)
    const result = limiter.check(key, &rule);
    try std.testing.expect(result.isAllowed());
    try std.testing.expectEqual(Decision.allow, result.action);
    try std.testing.expectEqual(Reason.none, result.reason);
}

test "RateLimiter: check blocks when exhausted" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key = Key.fromOctets(10, 0, 0, 1, hashPath("/api/heavy"));
    const rule = Rule.simple(1, 2); // 1 req/sec, 2 burst

    // Exhaust the bucket (starts with burst_capacity tokens)
    _ = limiter.check(key, &rule); // Uses 1 of 2
    _ = limiter.check(key, &rule); // Uses 1 of 1

    // Third request should be blocked
    const result = limiter.check(key, &rule);
    try std.testing.expect(result.isBlocked());
    try std.testing.expectEqual(Decision.block, result.action);
    try std.testing.expectEqual(Reason.rate_limit, result.reason);
}

test "RateLimiter: different keys have different buckets" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key1 = Key.fromOctets(192, 168, 1, 1, hashPath("/api/a"));
    const key2 = Key.fromOctets(192, 168, 1, 2, hashPath("/api/a"));
    const rule = Rule.simple(1, 1);

    // Exhaust key1's bucket
    _ = limiter.check(key1, &rule);
    const result1 = limiter.check(key1, &rule);
    try std.testing.expect(result1.isBlocked());

    // Key2 should still be allowed (different bucket)
    const result2 = limiter.check(key2, &rule);
    try std.testing.expect(result2.isAllowed());
}

test "RateLimiter: getRemainingTokens" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key = Key.fromOctets(172, 16, 0, 1, hashPath("/health"));
    const rule = Rule.simple(10, 5); // 5 burst = 5000 tokens

    // Non-existent key returns null
    try std.testing.expect(limiter.getRemainingTokens(key) == null);

    // After first request, bucket exists
    _ = limiter.check(key, &rule);

    // Should have tokens (5000 - 1000 = 4000)
    const remaining = limiter.getRemainingTokens(key);
    try std.testing.expect(remaining != null);
    try std.testing.expectEqual(@as(u32, 4000), remaining.?);
}

test "RateLimiter: getBucketStats" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key = Key.fromOctets(10, 10, 10, 10, hashPath("/stats"));
    const rule = Rule.simple(1, 2);

    // Non-existent returns null
    try std.testing.expect(limiter.getBucketStats(key) == null);

    // Make some requests
    _ = limiter.check(key, &rule); // Allowed
    _ = limiter.check(key, &rule); // Allowed
    _ = limiter.check(key, &rule); // Blocked

    const stats = limiter.getBucketStats(key);
    try std.testing.expect(stats != null);
    try std.testing.expectEqual(@as(u64, 3), stats.?.total_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.?.total_blocked);
}

test "RateLimiter: resetBucket" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key = Key.fromOctets(1, 2, 3, 4, hashPath("/reset"));
    const rule = Rule.simple(1, 3);

    // Exhaust bucket
    _ = limiter.check(key, &rule);
    _ = limiter.check(key, &rule);
    _ = limiter.check(key, &rule);

    // Should be blocked
    const blocked_result = limiter.check(key, &rule);
    try std.testing.expect(blocked_result.isBlocked());

    // Reset to full
    const reset_success = limiter.resetBucket(key, 3000);
    try std.testing.expect(reset_success);

    // Should be allowed again
    const allowed_result = limiter.check(key, &rule);
    try std.testing.expect(allowed_result.isAllowed());
}

test "RateLimiter: findBucket returns index" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key = Key.fromOctets(8, 8, 8, 8, hashPath("/find"));
    const rule = Rule.simple(10, 10);

    // Before any request, bucket doesn't exist
    try std.testing.expect(limiter.findBucket(key) == null);

    // Create bucket via check
    _ = limiter.check(key, &rule);

    // Now it should exist
    const idx = limiter.findBucket(key);
    try std.testing.expect(idx != null);
    try std.testing.expect(idx.? < MAX_BUCKETS);
}

test "computeKeyHash: distribution" {
    // Test that different inputs produce different hashes
    var hashes: [100]u64 = undefined;
    for (0..100) |i| {
        hashes[i] = computeKeyHash(@intCast(i), 0x12345678);
    }

    // Check for uniqueness
    for (0..100) |i| {
        for (i + 1..100) |j| {
            try std.testing.expect(hashes[i] != hashes[j]);
        }
    }
}

test "computeKeyHash: non-zero guarantee" {
    // Hash should never be zero
    for (0..1000) |i| {
        const hash_val = computeKeyHash(@intCast(i), @intCast(i));
        try std.testing.expect(hash_val != 0);
    }
}

test "hashPath: consistency" {
    const hash1 = hashPath("/api/users");
    const hash2 = hashPath("/api/users");
    const hash3 = hashPath("/api/posts");

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != hash3);
}

test "DecisionResult: helper methods" {
    const allowed = DecisionResult{ .action = .allow, .reason = .none };
    const blocked = DecisionResult{ .action = .block, .reason = .rate_limit };

    try std.testing.expect(allowed.isAllowed());
    try std.testing.expect(!allowed.isBlocked());
    try std.testing.expect(blocked.isBlocked());
    try std.testing.expect(!blocked.isAllowed());
}

test "BucketStats: blockRatePercent" {
    const stats_empty = BucketStats{
        .tokens = 0,
        .last_update = 0,
        .total_requests = 0,
        .total_blocked = 0,
    };
    try std.testing.expectEqual(@as(u64, 0), stats_empty.blockRatePercent());

    const stats_half = BucketStats{
        .tokens = 0,
        .last_update = 0,
        .total_requests = 100,
        .total_blocked = 50,
    };
    try std.testing.expectEqual(@as(u64, 50), stats_half.blockRatePercent());
}

test "RateLimiter: checkWithRetry allows within limit" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key = Key.fromOctets(192, 168, 2, 1, hashPath("/retry"));
    const rule = Rule.simple(10, 10);

    const result = limiter.checkWithRetry(key, &rule);
    try std.testing.expect(result.isAllowed());
}

test "RateLimiter: checkWithRetry blocks when exhausted" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key = Key.fromOctets(10, 0, 0, 2, hashPath("/retry-heavy"));
    const rule = Rule.simple(1, 2);

    _ = limiter.checkWithRetry(key, &rule);
    _ = limiter.checkWithRetry(key, &rule);

    const result = limiter.checkWithRetry(key, &rule);
    try std.testing.expect(result.isBlocked());
    try std.testing.expectEqual(Reason.rate_limit, result.reason);
}
