/// WAF Shared Memory State
///
/// Provides cache-line aligned, lock-free data structures for the Web Application
/// Firewall. Designed for multi-process shared memory with atomic operations only.
///
/// Design Philosophy (TigerBeetle-inspired):
/// - Fixed-size structures with explicit bounds
/// - Cache-line alignment to prevent false sharing
/// - Packed fields for atomic CAS operations
/// - Comptime assertions for size/alignment guarantees
/// - Zero allocation on hot path
///
/// Memory Layout:
/// - WafState: Main container (~4MB total)
///   - Token bucket table: 64K entries for rate limiting
///   - Connection tracker: 16K entries for slowloris detection
///   - Metrics: Atomic counters for observability
///   - Config epoch: Hot-reload detection
const std = @import("std");

// =============================================================================
// Constants (Single Source of Truth)
// =============================================================================

/// Maximum buckets in token bucket table (64K entries = ~4MB state)
pub const MAX_BUCKETS: usize = 65536;

/// Maximum tokens in a bucket (scaled by 1000 for sub-token precision)
pub const MAX_TOKENS: u32 = 10000;

/// Open addressing probe limit before giving up
pub const BUCKET_PROBE_LIMIT: u32 = 16;

/// Maximum CAS retry attempts before declaring exhaustion
pub const MAX_CAS_ATTEMPTS: u32 = 8;

/// Maximum tracked IPs for connection counting (slowloris prevention)
pub const MAX_TRACKED_IPS: usize = 16384;

/// Magic number for corruption detection (ASCII: "WAFSTV1\0" + version nibble)
pub const WAF_STATE_MAGIC: u64 = 0x5741465354563130; // "WAFSTV10"

/// Cache line size for alignment
const CACHE_LINE: usize = 64;

// =============================================================================
// Decision and Reason Enums
// =============================================================================

/// WAF decision for a request
pub const Decision = enum(u8) {
    /// Allow the request to proceed
    allow = 0,
    /// Block the request (return error response)
    block = 1,
    /// Log but allow (shadow mode / detection only)
    log_only = 2,

    /// Check if request should be blocked
    pub inline fn isBlocked(self: Decision) bool {
        return self == .block;
    }

    /// Check if request should be logged
    pub inline fn shouldLog(self: Decision) bool {
        return self != .allow;
    }
};

/// Reason for WAF decision
pub const Reason = enum(u8) {
    /// No violation detected
    none = 0,
    /// Rate limit exceeded
    rate_limit = 1,
    /// Slowloris attack detected (too many connections)
    slowloris = 2,
    /// Request body too large
    body_too_large = 3,
    /// JSON nesting depth exceeded
    json_depth = 4,
    /// SQL injection pattern detected
    sql_injection = 5,
    /// XSS pattern detected
    xss = 6,
    /// Path traversal attempt
    path_traversal = 7,
    /// Invalid request format
    invalid_request = 8,
    /// Request velocity burst detected (sudden spike from IP)
    burst = 9,

    /// Get human-readable description
    pub fn description(self: Reason) []const u8 {
        return switch (self) {
            .none => "no violation",
            .rate_limit => "rate limit exceeded",
            .slowloris => "too many connections from IP",
            .body_too_large => "request body too large",
            .json_depth => "JSON nesting depth exceeded",
            .sql_injection => "SQL injection pattern detected",
            .xss => "XSS pattern detected",
            .path_traversal => "path traversal attempt",
            .invalid_request => "invalid request format",
            .burst => "request velocity burst detected",
        };
    }
};

// =============================================================================
// Token Bucket (Rate Limiting)
// =============================================================================

/// Token bucket entry for rate limiting
/// Exactly one cache line (64 bytes) for optimal memory access patterns.
///
/// The `packed_state` field combines tokens and timestamp for atomic CAS:
/// - High 32 bits: last_update (seconds since epoch, wraps every ~136 years)
/// - Low 32 bits: tokens (scaled by 1000 for precision)
pub const Bucket = extern struct {
    /// Hash of (IP, path_pattern) - 0 means empty slot
    key_hash: u64 = 0,

    /// Packed token bucket state for atomic CAS operations
    /// High 32 bits: last_update timestamp, Low 32 bits: tokens
    /// Use getPackedState/setPackedState for atomic access
    packed_state: u64 = 0,

    /// Total requests seen for this bucket
    total_requests: u64 = 0,

    /// Total requests blocked for this bucket
    total_blocked: u64 = 0,

    /// Reserved for future use (alignment padding)
    _reserved: [32]u8 = undefined,

    /// Get pointer to packed_state for atomic operations
    pub inline fn getPackedStatePtr(self: *Bucket) *std.atomic.Value(u64) {
        return @ptrCast(&self.packed_state);
    }

    /// Get pointer to packed_state for atomic operations (const version)
    pub inline fn getPackedStatePtrConst(self: *const Bucket) *const std.atomic.Value(u64) {
        return @ptrCast(&self.packed_state);
    }

    /// Get pointer to total_requests for atomic operations
    pub inline fn getTotalRequestsPtr(self: *Bucket) *std.atomic.Value(u64) {
        return @ptrCast(&self.total_requests);
    }

    /// Get pointer to total_blocked for atomic operations
    pub inline fn getTotalBlockedPtr(self: *Bucket) *std.atomic.Value(u64) {
        return @ptrCast(&self.total_blocked);
    }

    /// Pack tokens and timestamp into a single u64 for atomic CAS
    pub inline fn packState(tokens: u32, timestamp: u32) u64 {
        return (@as(u64, timestamp) << 32) | @as(u64, tokens);
    }

    /// Extract tokens from packed state
    pub inline fn unpackTokens(state: u64) u32 {
        return @truncate(state);
    }

    /// Extract timestamp from packed state
    pub inline fn unpackTime(state: u64) u32 {
        return @truncate(state >> 32);
    }

    /// Check if this bucket slot is empty
    pub inline fn isEmpty(self: *const Bucket) bool {
        return self.key_hash == 0;
    }

    /// Atomically try to consume tokens using CAS
    /// Returns true if tokens were consumed, false if rate limited
    pub fn tryConsume(
        self: *Bucket,
        tokens_to_consume: u32,
        refill_rate: u32,
        max_tokens: u32,
        current_time: u32,
    ) bool {
        const state_ptr = self.getPackedStatePtr();
        var attempts: u32 = 0;
        while (attempts < MAX_CAS_ATTEMPTS) : (attempts += 1) {
            const old_state = state_ptr.load(.acquire);
            const old_tokens = Bucket.unpackTokens(old_state);
            const old_time = Bucket.unpackTime(old_state);

            // Calculate token refill based on elapsed time (wrap-safe)
            const elapsed = current_time -% old_time;

            const refilled = @min(
                @as(u64, old_tokens) + @as(u64, elapsed) * @as(u64, refill_rate),
                @as(u64, max_tokens),
            );

            // Check if we have enough tokens
            if (refilled < tokens_to_consume) {
                return false; // Rate limited
            }

            // Calculate new state
            const new_tokens: u32 = @intCast(refilled - tokens_to_consume);
            const new_state = Bucket.packState(new_tokens, current_time);

            // Attempt atomic update
            if (state_ptr.cmpxchgWeak(
                old_state,
                new_state,
                .acq_rel,
                .acquire,
            ) == null) {
                // Success
                return true;
            }
            // CAS failed, retry with new state
        }

        // CAS exhausted - treat as rate limited for safety
        return false;
    }

    /// Get pointer to key_hash for atomic operations
    pub inline fn getKeyHashPtr(self: *Bucket) *std.atomic.Value(u64) {
        return @ptrCast(&self.key_hash);
    }

    /// Initialize bucket with a key and full tokens
    pub fn init(self: *Bucket, key: u64, max_tokens: u32, current_time: u32) void {
        self.getKeyHashPtr().store(key, .release);
        self.getPackedStatePtr().store(Bucket.packState(max_tokens, current_time), .release);
        self.getTotalRequestsPtr().store(0, .release);
        self.getTotalBlockedPtr().store(0, .release);
    }

    comptime {
        // Ensure bucket is exactly one cache line
        std.debug.assert(@sizeOf(Bucket) == CACHE_LINE);
        // Ensure proper alignment for atomics
        std.debug.assert(@alignOf(Bucket) >= @alignOf(u64));
    }
};

// =============================================================================
// Connection Tracker (Slowloris Prevention)
// =============================================================================

/// Connection entry for tracking per-IP connection counts
pub const ConnEntry = extern struct {
    /// Hash of IP address - 0 means empty slot
    ip_hash: u32 = 0,

    /// Current connection count (use getConnCountPtr for atomic access)
    conn_count: u16 = 0,

    /// Padding for alignment
    _padding: u16 = 0,

    /// Get pointer to conn_count for atomic operations
    pub inline fn getConnCountPtr(self: *ConnEntry) *std.atomic.Value(u16) {
        return @ptrCast(&self.conn_count);
    }

    /// Get pointer to conn_count for atomic operations (const version)
    pub inline fn getConnCountPtrConst(self: *const ConnEntry) *const std.atomic.Value(u16) {
        return @ptrCast(&self.conn_count);
    }

    /// Check if entry is empty
    pub inline fn isEmpty(self: *const ConnEntry) bool {
        return self.ip_hash == 0;
    }

    /// Atomically increment connection count
    /// Returns the new count
    pub inline fn incrementConn(self: *ConnEntry) u16 {
        return self.getConnCountPtr().fetchAdd(1, .acq_rel) + 1;
    }

    /// Atomically decrement connection count using CAS loop
    /// Returns the new count, saturates at 0
    pub inline fn decrementConn(self: *ConnEntry) u16 {
        const ptr = self.getConnCountPtr();
        while (true) {
            const old = ptr.load(.acquire);
            if (old == 0) return 0;
            if (ptr.cmpxchgWeak(old, old - 1, .acq_rel, .acquire) == null) {
                return old - 1;
            }
        }
    }

    /// Get current connection count
    pub inline fn getConnCount(self: *const ConnEntry) u16 {
        return self.getConnCountPtrConst().load(.acquire);
    }

    comptime {
        // Ensure entry is 8 bytes (fits nicely in cache)
        std.debug.assert(@sizeOf(ConnEntry) == 8);
    }
};

/// Connection tracker for slowloris prevention
/// Fixed-size hash table with open addressing
pub const ConnTracker = extern struct {
    entries: [MAX_TRACKED_IPS]ConnEntry align(CACHE_LINE) = [_]ConnEntry{.{}} ** MAX_TRACKED_IPS,

    /// Find or create entry for an IP hash
    /// Returns null if table is full (probe limit exceeded)
    pub fn findOrCreate(self: *ConnTracker, ip_hash: u32) ?*ConnEntry {
        if (ip_hash == 0) return null; // 0 is reserved for empty

        const start_idx = @as(usize, ip_hash) % MAX_TRACKED_IPS;
        var idx = start_idx;
        var probe_count: u32 = 0;

        while (probe_count < BUCKET_PROBE_LIMIT) : (probe_count += 1) {
            const entry = &self.entries[idx];

            // Found existing entry
            if (entry.ip_hash == ip_hash) {
                return entry;
            }

            // Found empty slot - try to claim it atomically
            if (entry.ip_hash == 0) {
                // Use atomic store with release ordering to ensure visibility
                const ip_hash_ptr: *std.atomic.Value(u32) = @ptrCast(&entry.ip_hash);
                ip_hash_ptr.store(ip_hash, .release);
                return entry;
            }

            // Linear probing
            idx = (idx + 1) % MAX_TRACKED_IPS;
        }

        return null; // Table full or probe limit reached
    }

    /// Find existing entry for an IP hash
    /// Returns null if not found
    pub fn find(self: *const ConnTracker, ip_hash: u32) ?*const ConnEntry {
        if (ip_hash == 0) return null;

        const start_idx = @as(usize, ip_hash) % MAX_TRACKED_IPS;
        var idx = start_idx;
        var probe_count: u32 = 0;

        while (probe_count < BUCKET_PROBE_LIMIT) : (probe_count += 1) {
            const entry = &self.entries[idx];

            if (entry.ip_hash == ip_hash) {
                return entry;
            }

            if (entry.ip_hash == 0) {
                return null; // Empty slot means not found
            }

            idx = (idx + 1) % MAX_TRACKED_IPS;
        }

        return null;
    }

    comptime {
        // Verify size is what we expect
        std.debug.assert(@sizeOf(ConnTracker) == MAX_TRACKED_IPS * @sizeOf(ConnEntry));
    }
};

// =============================================================================
// Burst Detector (Anomaly Detection)
// =============================================================================

/// Maximum tracked IPs for burst detection
pub const MAX_BURST_TRACKED: usize = 8192;

/// Burst detection window in seconds
pub const BURST_WINDOW_SEC: u32 = 10;

/// Default burst threshold multiplier (current rate > baseline * threshold = burst)
pub const BURST_THRESHOLD_MULTIPLIER: u32 = 10;

/// Minimum baseline before burst detection activates (avoid false positives on first requests)
pub const BURST_MIN_BASELINE: u16 = 5;

/// Entry for tracking per-IP request velocity
/// Uses exponential moving average (EMA) to establish baseline
pub const BurstEntry = extern struct {
    /// Hash of IP address - 0 means empty slot
    ip_hash: u32 = 0,

    /// Baseline request rate (EMA, requests per window, scaled by 16 for precision)
    /// Stored as fixed-point: actual_rate = baseline_rate / 16
    baseline_rate: u16 = 0,

    /// Request count in current window
    current_count: u16 = 0,

    /// Last window timestamp (seconds, wrapping)
    last_window: u32 = 0,

    /// Get atomic pointer to current_count
    pub inline fn getCurrentCountPtr(self: *BurstEntry) *std.atomic.Value(u16) {
        return @ptrCast(&self.current_count);
    }

    /// Get atomic pointer to baseline_rate
    pub inline fn getBaselinePtr(self: *BurstEntry) *std.atomic.Value(u16) {
        return @ptrCast(&self.baseline_rate);
    }

    /// Get atomic pointer to last_window
    pub inline fn getLastWindowPtr(self: *BurstEntry) *std.atomic.Value(u32) {
        return @ptrCast(&self.last_window);
    }

    /// Record a request and check for burst
    /// Returns true if this is a burst (anomaly detected)
    pub fn recordAndCheck(self: *BurstEntry, current_time: u32, threshold_mult: u32) bool {
        const last = self.getLastWindowPtr().load(.acquire);
        const time_diff = current_time -% last;

        // Check if we're in a new window
        if (time_diff >= BURST_WINDOW_SEC) {
            // Window expired - update baseline and reset count
            const old_count = self.getCurrentCountPtr().swap(1, .acq_rel);
            const old_baseline = self.getBaselinePtr().load(.acquire);

            // Calculate new baseline using EMA: new = old * 0.875 + current * 0.125
            // Using fixed-point: multiply count by 16, then blend
            const current_scaled: u32 = @as(u32, old_count) * 16;
            const new_baseline: u16 = @intCast(
                (@as(u32, old_baseline) * 7 + current_scaled) / 8,
            );

            self.getBaselinePtr().store(new_baseline, .release);
            self.getLastWindowPtr().store(current_time, .release);

            return false; // New window, no burst yet
        }

        // Same window - increment count and check for burst
        const new_count = self.getCurrentCountPtr().fetchAdd(1, .acq_rel) + 1;
        const baseline = self.getBaselinePtr().load(.acquire);

        // Skip burst detection if baseline not established
        if (baseline < BURST_MIN_BASELINE * 16) {
            return false;
        }

        // Check if current rate exceeds baseline * threshold
        // baseline is scaled by 16, so: current * 16 > baseline * threshold
        const current_scaled: u32 = @as(u32, new_count) * 16;
        const threshold: u32 = @as(u32, baseline) * threshold_mult;

        return current_scaled > threshold;
    }

    comptime {
        // Ensure entry is 12 bytes
        std.debug.assert(@sizeOf(BurstEntry) == 12);
    }
};

/// Burst detector hash table
pub const BurstTracker = extern struct {
    entries: [MAX_BURST_TRACKED]BurstEntry = [_]BurstEntry{.{}} ** MAX_BURST_TRACKED,

    /// Find or create entry for an IP
    /// Returns null if table is full
    pub fn findOrCreate(self: *BurstTracker, ip_hash: u32, current_time: u32) ?*BurstEntry {
        if (ip_hash == 0) return null;

        const start_idx = ip_hash % MAX_BURST_TRACKED;
        var idx = start_idx;
        var probe_count: u32 = 0;

        while (probe_count < BUCKET_PROBE_LIMIT) : (probe_count += 1) {
            const entry = &self.entries[idx];

            // Found existing entry
            if (entry.ip_hash == ip_hash) {
                return entry;
            }

            // Found empty slot - try to claim it
            if (entry.ip_hash == 0) {
                const ptr: *std.atomic.Value(u32) = @ptrCast(&entry.ip_hash);
                if (ptr.cmpxchgStrong(0, ip_hash, .acq_rel, .acquire) == null) {
                    // Successfully claimed slot
                    entry.getLastWindowPtr().store(current_time, .release);
                    return entry;
                }
                // Someone else claimed it, check if it's ours
                if (entry.ip_hash == ip_hash) {
                    return entry;
                }
            }

            idx = (idx + 1) % MAX_BURST_TRACKED;
        }

        return null; // Table too full
    }

    /// Check if an IP is bursting (for read-only check)
    pub fn isBursting(self: *BurstTracker, ip_hash: u32, current_time: u32, threshold_mult: u32) bool {
        if (ip_hash == 0) return false;

        const start_idx = ip_hash % MAX_BURST_TRACKED;
        var idx = start_idx;
        var probe_count: u32 = 0;

        while (probe_count < BUCKET_PROBE_LIMIT) : (probe_count += 1) {
            const entry = &self.entries[idx];

            if (entry.ip_hash == ip_hash) {
                return entry.recordAndCheck(current_time, threshold_mult);
            }

            if (entry.ip_hash == 0) {
                return false; // Not found
            }

            idx = (idx + 1) % MAX_BURST_TRACKED;
        }

        return false;
    }

    comptime {
        std.debug.assert(@sizeOf(BurstTracker) == MAX_BURST_TRACKED * @sizeOf(BurstEntry));
    }
};

// =============================================================================
// WAF Metrics
// =============================================================================

/// Single cache line of metrics (64 bytes = 8 x u64)
const MetricsCacheLine = extern struct {
    values: [8]u64 = [_]u64{0} ** 8,
};

/// WAF metrics with cache-line aligned atomic counters
/// Uses cache-line sized blocks to prevent false sharing
pub const WafMetrics = extern struct {
    // Primary counters (hot path) - each in its own cache line block
    // Line 0: requests_allowed (index 0)
    line0: MetricsCacheLine align(CACHE_LINE) = .{},
    // Line 1: requests_blocked (index 0)
    line1: MetricsCacheLine = .{},
    // Line 2: requests_logged (index 0)
    line2: MetricsCacheLine = .{},

    // Block reason breakdown - grouped in one cache line
    // blocked_rate_limit (0), blocked_slowloris (1), blocked_body_too_large (2), blocked_json_depth (3)
    line3: MetricsCacheLine = .{},

    // Operational metrics - grouped in one cache line
    // bucket_table_usage (0), cas_exhausted (1), config_reloads (2)
    line4: MetricsCacheLine = .{},

    // Helper to get atomic pointer
    inline fn atomicPtr(ptr: *u64) *std.atomic.Value(u64) {
        return @ptrCast(ptr);
    }

    inline fn atomicPtrConst(ptr: *const u64) *const std.atomic.Value(u64) {
        return @ptrCast(ptr);
    }

    /// Increment allowed counter
    pub inline fn recordAllowed(self: *WafMetrics) void {
        _ = atomicPtr(&self.line0.values[0]).fetchAdd(1, .monotonic);
    }

    /// Increment blocked counter with reason breakdown
    pub inline fn recordBlocked(self: *WafMetrics, reason: Reason) void {
        _ = atomicPtr(&self.line1.values[0]).fetchAdd(1, .monotonic);
        switch (reason) {
            .rate_limit => _ = atomicPtr(&self.line3.values[0]).fetchAdd(1, .monotonic),
            .slowloris => _ = atomicPtr(&self.line3.values[1]).fetchAdd(1, .monotonic),
            .body_too_large => _ = atomicPtr(&self.line3.values[2]).fetchAdd(1, .monotonic),
            .json_depth => _ = atomicPtr(&self.line3.values[3]).fetchAdd(1, .monotonic),
            else => {},
        }
    }

    /// Increment logged counter
    pub inline fn recordLogged(self: *WafMetrics) void {
        _ = atomicPtr(&self.line2.values[0]).fetchAdd(1, .monotonic);
    }

    /// Record a CAS exhaustion event
    pub inline fn recordCasExhausted(self: *WafMetrics) void {
        _ = atomicPtr(&self.line4.values[1]).fetchAdd(1, .monotonic);
    }

    /// Record a config reload
    pub inline fn recordConfigReload(self: *WafMetrics) void {
        _ = atomicPtr(&self.line4.values[2]).fetchAdd(1, .monotonic);
    }

    /// Update bucket table usage count
    pub inline fn updateBucketUsage(self: *WafMetrics, count: u64) void {
        atomicPtr(&self.line4.values[0]).store(count, .monotonic);
    }

    /// Get snapshot of all metrics (for reporting)
    pub fn snapshot(self: *const WafMetrics) MetricsSnapshot {
        return .{
            .requests_allowed = atomicPtrConst(&self.line0.values[0]).load(.monotonic),
            .requests_blocked = atomicPtrConst(&self.line1.values[0]).load(.monotonic),
            .requests_logged = atomicPtrConst(&self.line2.values[0]).load(.monotonic),
            .blocked_rate_limit = atomicPtrConst(&self.line3.values[0]).load(.monotonic),
            .blocked_slowloris = atomicPtrConst(&self.line3.values[1]).load(.monotonic),
            .blocked_body_too_large = atomicPtrConst(&self.line3.values[2]).load(.monotonic),
            .blocked_json_depth = atomicPtrConst(&self.line3.values[3]).load(.monotonic),
            .bucket_table_usage = atomicPtrConst(&self.line4.values[0]).load(.monotonic),
            .cas_exhausted = atomicPtrConst(&self.line4.values[1]).load(.monotonic),
            .config_reloads = atomicPtrConst(&self.line4.values[2]).load(.monotonic),
        };
    }

    comptime {
        // Verify each line is cache-line sized
        std.debug.assert(@sizeOf(MetricsCacheLine) == CACHE_LINE);
        // Verify total size
        std.debug.assert(@sizeOf(WafMetrics) == 5 * CACHE_LINE);
    }
};

/// Non-atomic snapshot of metrics for reporting
pub const MetricsSnapshot = struct {
    requests_allowed: u64,
    requests_blocked: u64,
    requests_logged: u64,
    blocked_rate_limit: u64,
    blocked_slowloris: u64,
    blocked_body_too_large: u64,
    blocked_json_depth: u64,
    bucket_table_usage: u64,
    cas_exhausted: u64,
    config_reloads: u64,

    /// Calculate total requests processed
    pub fn totalRequests(self: MetricsSnapshot) u64 {
        return self.requests_allowed + self.requests_blocked + self.requests_logged;
    }

    /// Calculate block rate as percentage (scaled by 100)
    pub fn blockRatePercent(self: MetricsSnapshot) u64 {
        const total = self.totalRequests();
        if (total == 0) return 0;
        return (self.requests_blocked * 100) / total;
    }
};

// =============================================================================
// Main WAF State Structure
// =============================================================================

/// Calculate sizes for comptime assertions
const BUCKET_TABLE_SIZE: usize = MAX_BUCKETS * @sizeOf(Bucket);
const CONN_TRACKER_SIZE: usize = @sizeOf(ConnTracker);
const METRICS_SIZE: usize = @sizeOf(WafMetrics);
const HEADER_SIZE: usize = CACHE_LINE; // magic + config_epoch

/// Total WAF state size (for shared memory allocation)
pub const WAF_STATE_SIZE: usize = blk: {
    // Calculate with proper alignment padding
    var size: usize = 0;

    // Header (magic + padding to cache line)
    size += CACHE_LINE;

    // Bucket table (already cache-line aligned entries)
    size += BUCKET_TABLE_SIZE;

    // ConnTracker (cache-line aligned)
    size = std.mem.alignForward(usize, size, CACHE_LINE);
    size += CONN_TRACKER_SIZE;

    // Metrics (cache-line aligned)
    size = std.mem.alignForward(usize, size, CACHE_LINE);
    size += METRICS_SIZE;

    // Config epoch (cache-line aligned)
    size = std.mem.alignForward(usize, size, CACHE_LINE);
    size += CACHE_LINE;

    break :blk size;
};

/// Main WAF shared state structure
/// All fields are cache-line aligned to prevent false sharing across CPU cores.
pub const WafState = extern struct {
    /// Magic number for corruption detection
    magic: u64 align(CACHE_LINE) = WAF_STATE_MAGIC,

    /// Version number for compatibility
    version: u32 = 1,

    /// Reserved padding to fill first cache line
    _header_padding: [52]u8 = undefined,

    /// Token bucket table for rate limiting (fixed-size, open addressing)
    buckets: [MAX_BUCKETS]Bucket align(CACHE_LINE) = [_]Bucket{.{}} ** MAX_BUCKETS,

    /// Connection tracker for slowloris detection
    conn_tracker: ConnTracker align(CACHE_LINE) = .{},

    /// Burst detector for anomaly detection
    burst_tracker: BurstTracker align(CACHE_LINE) = .{},

    /// Global metrics with atomic counters
    metrics: WafMetrics align(CACHE_LINE) = .{},

    /// Configuration epoch for hot-reload detection
    /// Increment this when WAF config changes; workers can detect stale config
    config_epoch: u64 align(CACHE_LINE) = 0,

    /// Padding to ensure config_epoch has its own cache line
    _epoch_padding: [56]u8 = undefined,

    // =========================================================================
    // Initialization and Validation
    // =========================================================================

    /// Get atomic pointer to config_epoch
    inline fn getConfigEpochPtr(self: *WafState) *std.atomic.Value(u64) {
        return @ptrCast(&self.config_epoch);
    }

    /// Get atomic pointer to config_epoch (const version)
    inline fn getConfigEpochPtrConst(self: *const WafState) *const std.atomic.Value(u64) {
        return @ptrCast(&self.config_epoch);
    }

    /// Initialize WAF state with magic number and zeroed fields
    pub fn init() WafState {
        return .{};
    }

    /// Validate the WAF state structure (check magic for corruption)
    pub fn validate(self: *const WafState) bool {
        return self.magic == WAF_STATE_MAGIC and self.version == 1;
    }

    /// Get current config epoch
    pub inline fn getConfigEpoch(self: *const WafState) u64 {
        return self.getConfigEpochPtrConst().load(.acquire);
    }

    /// Increment config epoch (call after hot-reloading config)
    pub inline fn incrementConfigEpoch(self: *WafState) u64 {
        const new_epoch = self.getConfigEpochPtr().fetchAdd(1, .acq_rel) + 1;
        self.metrics.recordConfigReload();
        return new_epoch;
    }

    // =========================================================================
    // Bucket Table Operations
    // =========================================================================

    /// Find or create a bucket for the given key hash
    /// Uses open addressing with linear probing
    /// Returns null if probe limit exceeded (table too full)
    pub fn findOrCreateBucket(self: *WafState, key_hash: u64, current_time: u32) ?*Bucket {
        if (key_hash == 0) return null; // 0 is reserved

        const start_idx = @as(usize, @truncate(key_hash)) % MAX_BUCKETS;
        var idx = start_idx;
        var probe_count: u32 = 0;

        while (probe_count < BUCKET_PROBE_LIMIT) : (probe_count += 1) {
            const bucket = &self.buckets[idx];

            // Found existing bucket
            if (bucket.key_hash == key_hash) {
                return bucket;
            }

            // Found empty slot
            if (bucket.key_hash == 0) {
                // Initialize with full tokens
                bucket.init(key_hash, MAX_TOKENS, current_time);
                return bucket;
            }

            // Linear probing
            idx = (idx + 1) % MAX_BUCKETS;
        }

        return null; // Probe limit exceeded
    }

    /// Find an existing bucket (does not create)
    pub fn findBucket(self: *const WafState, key_hash: u64) ?*const Bucket {
        if (key_hash == 0) return null;

        const start_idx = @as(usize, @truncate(key_hash)) % MAX_BUCKETS;
        var idx = start_idx;
        var probe_count: u32 = 0;

        while (probe_count < BUCKET_PROBE_LIMIT) : (probe_count += 1) {
            const bucket = &self.buckets[idx];

            if (bucket.key_hash == key_hash) {
                return bucket;
            }

            if (bucket.key_hash == 0) {
                return null;
            }

            idx = (idx + 1) % MAX_BUCKETS;
        }

        return null;
    }

    /// Count non-empty buckets (for metrics)
    pub fn countBuckets(self: *const WafState) u64 {
        var count: u64 = 0;
        for (&self.buckets) |*bucket| {
            if (!bucket.isEmpty()) count += 1;
        }
        return count;
    }

    // =========================================================================
    // Burst Detection Operations
    // =========================================================================

    /// Check if an IP is exhibiting burst behavior (sudden velocity spike)
    /// Returns true if current request rate is significantly above baseline
    pub fn checkBurst(self: *WafState, ip_hash: u32, current_time: u32, threshold_mult: u32) bool {
        if (self.burst_tracker.findOrCreate(ip_hash, current_time)) |entry| {
            return entry.recordAndCheck(current_time, threshold_mult);
        }
        return false; // Table full, fail open
    }

    // =========================================================================
    // Comptime Assertions
    // =========================================================================

    comptime {
        // Verify magic is at offset 0 and cache-line aligned
        std.debug.assert(@offsetOf(WafState, "magic") == 0);

        // Verify all major sections are cache-line aligned
        std.debug.assert(@offsetOf(WafState, "buckets") % CACHE_LINE == 0);
        std.debug.assert(@offsetOf(WafState, "conn_tracker") % CACHE_LINE == 0);
        std.debug.assert(@offsetOf(WafState, "burst_tracker") % CACHE_LINE == 0);
        std.debug.assert(@offsetOf(WafState, "metrics") % CACHE_LINE == 0);
        std.debug.assert(@offsetOf(WafState, "config_epoch") % CACHE_LINE == 0);

        // Verify struct alignment
        std.debug.assert(@alignOf(WafState) >= CACHE_LINE);
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Pack tokens and timestamp into a single u64 for atomic CAS
/// Exported for use by external code
pub inline fn packState(tokens: u32, timestamp: u32) u64 {
    return Bucket.packState(tokens, timestamp);
}

/// Extract tokens from packed state
pub inline fn unpackTokens(state: u64) u32 {
    return Bucket.unpackTokens(state);
}

/// Extract timestamp from packed state
pub inline fn unpackTime(state: u64) u32 {
    return Bucket.unpackTime(state);
}

/// Compute hash for rate limiting key (IP + path pattern)
/// Uses FNV-1a for speed and good distribution
pub fn computeKeyHash(ip_bytes: []const u8, path: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325; // FNV offset basis

    for (ip_bytes) |b| {
        hash ^= b;
        hash *%= 0x100000001b3; // FNV prime
    }

    // Separator to avoid collisions between IP and path
    hash ^= 0xff;
    hash *%= 0x100000001b3;

    for (path) |b| {
        hash ^= b;
        hash *%= 0x100000001b3;
    }

    // Ensure non-zero (0 is reserved for empty slots)
    return if (hash == 0) 1 else hash;
}

/// Compute hash for IP address (connection tracking)
pub fn computeIpHash(ip_bytes: []const u8) u32 {
    var hash: u32 = 0x811c9dc5; // FNV-1a 32-bit offset basis

    for (ip_bytes) |b| {
        hash ^= b;
        hash *%= 0x01000193; // FNV-1a 32-bit prime
    }

    // Ensure non-zero
    return if (hash == 0) 1 else hash;
}

// =============================================================================
// Tests
// =============================================================================

test "Bucket: size and alignment" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Bucket));
    try std.testing.expect(@alignOf(Bucket) >= 8);
}

test "Bucket: pack/unpack state" {
    const tokens: u32 = 5000;
    const timestamp: u32 = 1703548800; // 2023-12-26 00:00:00 UTC

    const pack_val = packState(tokens, timestamp);
    try std.testing.expectEqual(tokens, unpackTokens(pack_val));
    try std.testing.expectEqual(timestamp, unpackTime(pack_val));
}

test "Bucket: tryConsume" {
    var bucket = Bucket{};
    bucket.init(0x12345678, MAX_TOKENS, 1000);

    // Should succeed - we have full tokens
    try std.testing.expect(bucket.tryConsume(1000, 100, MAX_TOKENS, 1000));

    // Check remaining tokens
    const bucket_state = bucket.getPackedStatePtrConst().load(.acquire);
    try std.testing.expectEqual(@as(u32, 9000), unpackTokens(bucket_state));

    // Consume more
    try std.testing.expect(bucket.tryConsume(9000, 100, MAX_TOKENS, 1000));

    // Should fail - no tokens left
    try std.testing.expect(!bucket.tryConsume(1000, 100, MAX_TOKENS, 1000));

    // Wait for refill (time advances by 10 seconds, refill rate = 100/sec)
    try std.testing.expect(bucket.tryConsume(500, 100, MAX_TOKENS, 1010));
}

test "ConnEntry: increment/decrement" {
    var entry = ConnEntry{};
    entry.ip_hash = 0x12345678;

    try std.testing.expectEqual(@as(u16, 0), entry.getConnCount());

    // Increment
    try std.testing.expectEqual(@as(u16, 1), entry.incrementConn());
    try std.testing.expectEqual(@as(u16, 2), entry.incrementConn());
    try std.testing.expectEqual(@as(u16, 2), entry.getConnCount());

    // Decrement
    try std.testing.expectEqual(@as(u16, 1), entry.decrementConn());
    try std.testing.expectEqual(@as(u16, 0), entry.decrementConn());

    // Underflow protection
    try std.testing.expectEqual(@as(u16, 0), entry.decrementConn());
}

test "ConnTracker: find and create" {
    var tracker = ConnTracker{};

    // Find non-existent
    try std.testing.expect(tracker.find(0x12345678) == null);

    // Create
    const entry = tracker.findOrCreate(0x12345678);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u32, 0x12345678), entry.?.ip_hash);

    // Find existing
    const found = tracker.find(0x12345678);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u32, 0x12345678), found.?.ip_hash);

    // Find same entry again
    const entry2 = tracker.findOrCreate(0x12345678);
    try std.testing.expect(entry2 != null);
    try std.testing.expectEqual(entry.?, entry2.?);
}

test "WafMetrics: record and snapshot" {
    var metrics = WafMetrics{};

    metrics.recordAllowed();
    metrics.recordAllowed();
    metrics.recordBlocked(.rate_limit);
    metrics.recordLogged();

    const snap = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snap.requests_allowed);
    try std.testing.expectEqual(@as(u64, 1), snap.requests_blocked);
    try std.testing.expectEqual(@as(u64, 1), snap.requests_logged);
    try std.testing.expectEqual(@as(u64, 1), snap.blocked_rate_limit);
    try std.testing.expectEqual(@as(u64, 4), snap.totalRequests());
    try std.testing.expectEqual(@as(u64, 25), snap.blockRatePercent());
}

test "WafState: init and validate" {
    const state = WafState.init();
    try std.testing.expect(state.validate());
    try std.testing.expectEqual(WAF_STATE_MAGIC, state.magic);
    try std.testing.expectEqual(@as(u32, 1), state.version);
}

test "WafState: config epoch" {
    var state = WafState.init();

    try std.testing.expectEqual(@as(u64, 0), state.getConfigEpoch());

    const epoch1 = state.incrementConfigEpoch();
    try std.testing.expectEqual(@as(u64, 1), epoch1);
    try std.testing.expectEqual(@as(u64, 1), state.getConfigEpoch());

    const epoch2 = state.incrementConfigEpoch();
    try std.testing.expectEqual(@as(u64, 2), epoch2);
}

test "WafState: bucket operations" {
    var state = WafState.init();
    const current_time: u32 = 1000;

    // Find or create bucket
    const bucket = state.findOrCreateBucket(0xDEADBEEF, current_time);
    try std.testing.expect(bucket != null);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), bucket.?.key_hash);

    // Find existing bucket
    const found = state.findBucket(0xDEADBEEF);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), found.?.key_hash);

    // Find non-existent
    try std.testing.expect(state.findBucket(0xCAFEBABE) == null);
}

test "Decision: enum operations" {
    const allow = Decision.allow;
    const block = Decision.block;
    const log_only = Decision.log_only;

    try std.testing.expect(!allow.isBlocked());
    try std.testing.expect(block.isBlocked());
    try std.testing.expect(!log_only.isBlocked());

    try std.testing.expect(!allow.shouldLog());
    try std.testing.expect(block.shouldLog());
    try std.testing.expect(log_only.shouldLog());
}

test "Reason: descriptions" {
    try std.testing.expectEqualStrings("rate limit exceeded", Reason.rate_limit.description());
    try std.testing.expectEqualStrings("too many connections from IP", Reason.slowloris.description());
}

test "computeKeyHash: basic" {
    const ip = [_]u8{ 192, 168, 1, 1 };
    const path = "/api/users";

    const hash1 = computeKeyHash(&ip, path);
    const hash2 = computeKeyHash(&ip, path);

    // Same input should produce same hash
    try std.testing.expectEqual(hash1, hash2);

    // Different path should produce different hash
    const hash3 = computeKeyHash(&ip, "/api/posts");
    try std.testing.expect(hash1 != hash3);

    // Hash should never be 0
    try std.testing.expect(hash1 != 0);
}

test "computeIpHash: basic" {
    const ip1 = [_]u8{ 192, 168, 1, 1 };
    const ip2 = [_]u8{ 192, 168, 1, 2 };

    const hash1 = computeIpHash(&ip1);
    const hash2 = computeIpHash(&ip2);

    try std.testing.expect(hash1 != hash2);
    try std.testing.expect(hash1 != 0);
    try std.testing.expect(hash2 != 0);
}

test "alignment: all structures properly aligned" {
    // Bucket must be cache-line sized
    try std.testing.expectEqual(@as(usize, CACHE_LINE), @sizeOf(Bucket));

    // ConnEntry should be 8 bytes
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ConnEntry));

    // WafState sections must be cache-line aligned
    try std.testing.expect(@offsetOf(WafState, "buckets") % CACHE_LINE == 0);
    try std.testing.expect(@offsetOf(WafState, "conn_tracker") % CACHE_LINE == 0);
    try std.testing.expect(@offsetOf(WafState, "metrics") % CACHE_LINE == 0);
    try std.testing.expect(@offsetOf(WafState, "config_epoch") % CACHE_LINE == 0);
}

test "BurstEntry: recordAndCheck detects velocity spike" {
    var entry = BurstEntry{
        .ip_hash = 0x12345678,
        .baseline_rate = 0,
        .current_count = 0,
        .last_window = 0,
    };

    const threshold: u32 = 3; // Current rate must be > baseline * 3 to trigger
    var time: u32 = 1000;

    // Establish baseline over several windows with 20 requests each
    // This builds up baseline above BURST_MIN_BASELINE (5 * 16 = 80)
    for (0..5) |_| {
        for (0..20) |_| {
            _ = entry.recordAndCheck(time, threshold);
        }
        time += BURST_WINDOW_SEC;
    }

    // Baseline should now be ~20 requests/window (scaled by 16 = ~320)
    // which is above BURST_MIN_BASELINE * 16 = 80

    // Now simulate a burst: 200 requests in one window
    // This should trigger because 200 * 16 = 3200 > 320 * 3 = 960
    var burst_detected = false;
    for (0..200) |_| {
        if (entry.recordAndCheck(time, threshold)) {
            burst_detected = true;
            break;
        }
    }

    try std.testing.expect(burst_detected);
}

test "BurstEntry: no burst for steady traffic" {
    var entry = BurstEntry{
        .ip_hash = 0x12345678,
        .baseline_rate = 0,
        .current_count = 0,
        .last_window = 0,
    };

    const threshold: u32 = 10;
    const base_time: u32 = 1000;

    // First window - establish baseline (50 requests)
    for (0..50) |_| {
        _ = entry.recordAndCheck(base_time, threshold);
    }

    // Move to next window
    const window2_time = base_time + BURST_WINDOW_SEC;
    _ = entry.recordAndCheck(window2_time, threshold);

    // Maintain similar rate - no burst
    var burst_detected = false;
    for (0..60) |_| {
        if (entry.recordAndCheck(window2_time, threshold)) {
            burst_detected = true;
        }
    }

    // Should NOT detect burst (60 is not >> 50 * 10)
    try std.testing.expect(!burst_detected);
}

test "BurstTracker: findOrCreate" {
    var tracker = BurstTracker{};
    const current_time: u32 = 1000;

    // Find or create entry
    const entry1 = tracker.findOrCreate(0x12345678, current_time);
    try std.testing.expect(entry1 != null);
    try std.testing.expectEqual(@as(u32, 0x12345678), entry1.?.ip_hash);

    // Same hash should return same entry
    const entry2 = tracker.findOrCreate(0x12345678, current_time);
    try std.testing.expectEqual(entry1, entry2);

    // Different hash should return different entry
    const entry3 = tracker.findOrCreate(0xDEADBEEF, current_time);
    try std.testing.expect(entry3 != null);
    try std.testing.expect(entry1 != entry3);
}

test "WafState: checkBurst integration" {
    var waf_state = WafState.init();

    const ip_hash: u32 = 0xCAFEBABE;
    const threshold: u32 = 3;
    var time: u32 = 1000;

    // Establish baseline over several windows with 30 requests each
    for (0..5) |_| {
        for (0..30) |_| {
            // Should not detect burst while establishing baseline
            const result = waf_state.checkBurst(ip_hash, time, threshold);
            _ = result;
        }
        time += BURST_WINDOW_SEC;
    }

    // Now burst: 300 requests in one window
    // Baseline ~30 req/window * 16 = 480, threshold 480 * 3 = 1440
    // 300 * 16 = 4800 > 1440, should trigger
    var burst_detected = false;
    for (0..300) |_| {
        if (waf_state.checkBurst(ip_hash, time, threshold)) {
            burst_detected = true;
            break;
        }
    }
    try std.testing.expect(burst_detected);
}
