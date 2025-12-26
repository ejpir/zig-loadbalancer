//! Web Application Firewall (WAF) Module
//!
//! High-performance WAF for the zzz load balancer with:
//! - Lock-free rate limiting (token bucket)
//! - Request validation (URI, body, JSON depth)
//! - Slowloris detection
//! - Shadow mode for safe rollout
//! - Hot-reload configuration
//!
//! ## Quick Start
//! ```zig
//! const waf = @import("waf");
//!
//! // Load configuration
//! var config = try waf.WafConfig.loadFromFile(allocator, "waf.json");
//! defer config.deinit();
//!
//! // Initialize shared state
//! var state = waf.WafState.init();
//!
//! // Create engine
//! var engine = waf.WafEngine.init(&state, &config);
//!
//! // Check requests
//! const result = engine.check(&request);
//! if (result.isBlocked()) {
//!     // Return 403/429
//! }
//! ```

// =============================================================================
// Re-export core types from state.zig
// =============================================================================

pub const WafState = @import("state.zig").WafState;
pub const Decision = @import("state.zig").Decision;
pub const Reason = @import("state.zig").Reason;
pub const Bucket = @import("state.zig").Bucket;
pub const ConnEntry = @import("state.zig").ConnEntry;
pub const ConnTracker = @import("state.zig").ConnTracker;
pub const WafMetrics = @import("state.zig").WafMetrics;
pub const MetricsSnapshot = @import("state.zig").MetricsSnapshot;

// State constants
pub const MAX_BUCKETS = @import("state.zig").MAX_BUCKETS;
pub const MAX_TOKENS = @import("state.zig").MAX_TOKENS;
pub const BUCKET_PROBE_LIMIT = @import("state.zig").BUCKET_PROBE_LIMIT;
pub const MAX_CAS_ATTEMPTS = @import("state.zig").MAX_CAS_ATTEMPTS;
pub const MAX_TRACKED_IPS = @import("state.zig").MAX_TRACKED_IPS;
pub const WAF_STATE_MAGIC = @import("state.zig").WAF_STATE_MAGIC;
pub const WAF_STATE_SIZE = @import("state.zig").WAF_STATE_SIZE;

// State helper functions
pub const packState = @import("state.zig").packState;
pub const unpackTokens = @import("state.zig").unpackTokens;
pub const unpackTime = @import("state.zig").unpackTime;
pub const computeKeyHash = @import("state.zig").computeKeyHash;
pub const computeIpHash = @import("state.zig").computeIpHash;

// =============================================================================
// Re-export configuration types from config.zig
// =============================================================================

pub const WafConfig = @import("config.zig").WafConfig;
pub const RateLimitRule = @import("config.zig").RateLimitRule;
pub const SlowlorisConfig = @import("config.zig").SlowlorisConfig;
pub const RequestLimitsConfig = @import("config.zig").RequestLimitsConfig;
pub const LoggingConfig = @import("config.zig").LoggingConfig;
pub const EndpointOverride = @import("config.zig").EndpointOverride;
pub const CidrRange = @import("config.zig").CidrRange;
pub const HttpMethod = @import("config.zig").HttpMethod;
pub const RateLimitBy = @import("config.zig").RateLimitBy;
pub const Action = @import("config.zig").Action;

// Config constants
pub const MAX_RATE_LIMIT_RULES = @import("config.zig").MAX_RATE_LIMIT_RULES;
pub const MAX_ENDPOINT_OVERRIDES = @import("config.zig").MAX_ENDPOINT_OVERRIDES;
pub const MAX_TRUSTED_PROXIES = @import("config.zig").MAX_TRUSTED_PROXIES;
pub const MAX_PATH_LENGTH = @import("config.zig").MAX_PATH_LENGTH;
pub const MAX_NAME_LENGTH = @import("config.zig").MAX_NAME_LENGTH;
pub const MAX_HEADER_NAME_LENGTH = @import("config.zig").MAX_HEADER_NAME_LENGTH;
pub const MAX_CONFIG_SIZE = @import("config.zig").MAX_CONFIG_SIZE;

// Config helper functions
pub const ipToBytes = @import("config.zig").ipToBytes;

// =============================================================================
// Re-export engine types from engine.zig
// =============================================================================

pub const WafEngine = @import("engine.zig").WafEngine;
pub const Request = @import("engine.zig").Request;
pub const CheckResult = @import("engine.zig").CheckResult;

// =============================================================================
// Re-export rate limiter types from rate_limiter.zig
// =============================================================================

pub const RateLimiter = @import("rate_limiter.zig").RateLimiter;
pub const Key = @import("rate_limiter.zig").Key;
pub const Rule = @import("rate_limiter.zig").Rule;
pub const DecisionResult = @import("rate_limiter.zig").DecisionResult;
pub const BucketStats = @import("rate_limiter.zig").BucketStats;

// Rate limiter helper functions
pub const hashPath = @import("rate_limiter.zig").hashPath;
pub const getCurrentTimeSec = @import("rate_limiter.zig").getCurrentTimeSec;

// =============================================================================
// Re-export validator types from validator.zig
// =============================================================================

pub const RequestValidator = @import("validator.zig").RequestValidator;
pub const ValidatorConfig = @import("validator.zig").ValidatorConfig;
pub const ValidationResult = @import("validator.zig").ValidationResult;
pub const JsonState = @import("validator.zig").JsonState;

// =============================================================================
// Re-export events types from events.zig
// =============================================================================

pub const EventLogger = @import("events.zig").EventLogger;
pub const WafEvent = @import("events.zig").WafEvent;
pub const EventType = @import("events.zig").EventType;

// Events helper functions
pub const formatIp = @import("events.zig").formatIp;
pub const getCurrentTimestamp = @import("events.zig").getCurrentTimestamp;

// =============================================================================
// Tests - ensure all imports are valid
// =============================================================================

test {
    // Import all submodules to ensure they compile
    _ = @import("state.zig");
    _ = @import("config.zig");
    _ = @import("engine.zig");
    _ = @import("rate_limiter.zig");
    _ = @import("validator.zig");
    _ = @import("events.zig");
}

test "mod: WafState and WafConfig integration" {
    const std = @import("std");

    // Test that the exported types work together
    var waf_state = WafState.init();
    try std.testing.expect(waf_state.validate());

    const waf_config = WafConfig{};
    try waf_config.validate();

    var engine = WafEngine.init(&waf_state, &waf_config);
    const request = Request.init(.GET, "/api/users", 0xC0A80101);
    const result = engine.check(&request);

    try std.testing.expect(result.isAllowed());
}

test "mod: RateLimiter integration" {
    var waf_state = WafState.init();
    var limiter = RateLimiter.init(&waf_state);

    const key = Key.fromOctets(192, 168, 1, 1, hashPath("/api/test"));
    const rule = Rule.simple(10, 10);

    const decision = limiter.check(key, &rule);
    const std = @import("std");
    try std.testing.expect(decision.isAllowed());
}

test "mod: RequestValidator integration" {
    const std = @import("std");

    const config = ValidatorConfig{};
    const validator = RequestValidator.init(&config);

    const result = validator.validateRequest("/api/users", null, null);
    try std.testing.expect(result.isValid());

    var json_state = JsonState{};
    const json_result = validator.validateJsonStream("{\"key\": \"value\"}", &json_state);
    try std.testing.expect(json_result.isValid());
}
