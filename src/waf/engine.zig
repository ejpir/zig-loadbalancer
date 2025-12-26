/// WAF Engine - Request Evaluation Orchestrator
///
/// The heart of the Web Application Firewall. Orchestrates rate limiting,
/// request validation, and decision-making into a unified request evaluation flow.
///
/// Design Philosophy (TigerBeetle-inspired):
/// - Single entry point for all WAF decisions
/// - Zero allocation on hot path
/// - Deterministic, predictable behavior
/// - Shadow mode for safe rule testing
/// - Composable with existing load balancer infrastructure
///
/// Request Flow:
/// 1. WAF enabled check (fast path for disabled WAF)
/// 2. Client IP extraction (handles trusted proxies)
/// 3. Rate limit evaluation
/// 4. Request validation (URI length, body size)
/// 5. Metrics recording
/// 6. Decision return
///
/// Shadow Mode:
/// When enabled, all blocking decisions are converted to log_only decisions.
/// This allows testing rules in production without affecting traffic.
const std = @import("std");

const state = @import("state.zig");
pub const WafState = state.WafState;
pub const Decision = state.Decision;
pub const Reason = state.Reason;

const rate_limiter = @import("rate_limiter.zig");
pub const RateLimiter = rate_limiter.RateLimiter;
pub const Key = rate_limiter.Key;
pub const Rule = rate_limiter.Rule;
pub const hashPath = rate_limiter.hashPath;

const config = @import("config.zig");
pub const WafConfig = config.WafConfig;
pub const HttpMethod = config.HttpMethod;
pub const RateLimitRule = config.RateLimitRule;
pub const ipToBytes = config.ipToBytes;


// =============================================================================
// Request - Incoming HTTP Request Representation
// =============================================================================

/// Represents an incoming HTTP request for WAF evaluation
/// Designed to be lightweight and stack-allocated
pub const Request = struct {
    /// HTTP method of the request
    method: HttpMethod,
    /// Request URI (path + query string)
    uri: []const u8,
    /// Content-Length header value, if present
    content_length: ?usize = null,
    /// Direct connection IP (network byte order, u32)
    source_ip: u32,
    /// X-Forwarded-For header value, if present (for trusted proxy handling)
    x_forwarded_for: ?[]const u8 = null,

    /// Create a request from basic parameters
    pub fn init(method: HttpMethod, uri: []const u8, source_ip: u32) Request {
        return .{
            .method = method,
            .uri = uri,
            .source_ip = source_ip,
        };
    }

    /// Create a request with content length
    pub fn withContentLength(method: HttpMethod, uri: []const u8, source_ip: u32, content_length: usize) Request {
        return .{
            .method = method,
            .uri = uri,
            .source_ip = source_ip,
            .content_length = content_length,
        };
    }

    /// Extract just the path portion of the URI (before query string)
    pub fn getPath(self: *const Request) []const u8 {
        if (std.mem.indexOf(u8, self.uri, "?")) |query_start| {
            return self.uri[0..query_start];
        }
        return self.uri;
    }
};

// =============================================================================
// CheckResult - WAF Decision Output
// =============================================================================

/// Result of WAF request evaluation
/// Contains the decision, reason, and additional context for logging/headers
pub const CheckResult = struct {
    /// The WAF decision (allow, block, or log_only)
    decision: Decision,
    /// Reason for blocking (if blocked or logged)
    reason: Reason = .none,
    /// Name of the rule that triggered (if any)
    rule_name: ?[]const u8 = null,
    /// Remaining tokens after rate limit check (for rate limit headers)
    tokens_remaining: ?u32 = null,

    /// Create an allow result
    pub fn allow() CheckResult {
        return .{
            .decision = .allow,
            .reason = .none,
        };
    }

    /// Create a block result with reason and optional rule name
    pub fn block(reason: Reason, rule_name: ?[]const u8) CheckResult {
        return .{
            .decision = .block,
            .reason = reason,
            .rule_name = rule_name,
        };
    }

    /// Create a log_only result (shadow mode)
    pub fn logOnly(reason: Reason, rule_name: ?[]const u8) CheckResult {
        return .{
            .decision = .log_only,
            .reason = reason,
            .rule_name = rule_name,
        };
    }

    /// Check if request should proceed
    pub inline fn isAllowed(self: CheckResult) bool {
        return self.decision == .allow or self.decision == .log_only;
    }

    /// Check if request was blocked
    pub inline fn isBlocked(self: CheckResult) bool {
        return self.decision == .block;
    }

    /// Check if this result should be logged
    pub inline fn shouldLog(self: CheckResult) bool {
        return self.decision.shouldLog();
    }

    /// Convert block to log_only (for shadow mode)
    pub fn toShadowMode(self: CheckResult) CheckResult {
        if (self.decision == .block) {
            return .{
                .decision = .log_only,
                .reason = self.reason,
                .rule_name = self.rule_name,
                .tokens_remaining = self.tokens_remaining,
            };
        }
        return self;
    }
};

// =============================================================================
// WafEngine - Main WAF Orchestrator
// =============================================================================

/// Main WAF engine that orchestrates all security checks
/// Thread-safe through atomic operations in underlying state
pub const WafEngine = struct {
    /// Pointer to shared WAF state (mmap'd region)
    waf_state: *WafState,
    /// Pointer to current configuration
    waf_config: *const WafConfig,
    /// Rate limiter instance
    limiter: RateLimiter,

    /// Initialize the WAF engine with shared state and configuration
    pub fn init(waf_state: *WafState, waf_config: *const WafConfig) WafEngine {
        return .{
            .waf_state = waf_state,
            .waf_config = waf_config,
            .limiter = RateLimiter.init(waf_state),
        };
    }

    /// Main entry point - evaluate a request through all WAF checks
    ///
    /// This is the hot path. Designed for minimal latency:
    /// 1. Fast-path if WAF disabled
    /// 2. Extract real client IP
    /// 3. Validate request format
    /// 4. Check rate limits
    /// 5. Record metrics
    /// 6. Return decision (converted to log_only if shadow mode)
    pub fn check(self: *WafEngine, request: *const Request) CheckResult {
        // Fast path: WAF disabled
        if (!self.waf_config.enabled) {
            return CheckResult.allow();
        }

        // Extract real client IP (handles trusted proxies)
        const client_ip = self.getClientIp(request);

        // Validate request (URI length, body size)
        const validation_result = self.validateRequest(request);
        if (validation_result.decision != .allow) {
            self.recordDecision(&validation_result);
            return self.applyMode(validation_result);
        }

        // Check rate limits
        const rate_limit_result = self.checkRateLimit(request, client_ip);
        if (rate_limit_result.decision != .allow) {
            self.recordDecision(&rate_limit_result);
            return self.applyMode(rate_limit_result);
        }

        // Check for burst behavior (sudden velocity spike)
        if (self.waf_config.burst_detection_enabled) {
            const burst_result = self.checkBurst(client_ip);
            if (burst_result.decision != .allow) {
                self.recordDecision(&burst_result);
                return self.applyMode(burst_result);
            }
        }

        // All checks passed
        self.recordDecision(&rate_limit_result);
        return self.applyMode(rate_limit_result);
    }

    /// Main entry point with OpenTelemetry tracing
    ///
    /// Creates child spans for each WAF check step, providing visibility
    /// into the WAF decision process in Jaeger/OTLP.
    ///
    /// The telemetry_mod parameter uses duck typing - any module that provides
    /// startChildSpan(span, name, kind) -> Span works.
    ///
    /// Span hierarchy:
    ///   proxy_request (parent)
    ///   └── waf.check
    ///       ├── waf.validate_request
    ///       ├── waf.rate_limit
    ///       └── waf.burst_detection
    pub fn checkWithSpan(
        self: *WafEngine,
        request: *const Request,
        parent_span: anytype,
        comptime telemetry_mod: type,
    ) CheckResult {
        // Create WAF check span as child of parent
        var waf_span = telemetry_mod.startChildSpan(parent_span, "waf.check", .Internal);
        defer waf_span.end();

        // Fast path: WAF disabled
        if (!self.waf_config.enabled) {
            waf_span.setStringAttribute("waf.enabled", "false");
            return CheckResult.allow();
        }

        // Extract real client IP (handles trusted proxies)
        const client_ip = self.getClientIp(request);

        // Step 1: Validate request (URI length, body size)
        {
            var validate_span = telemetry_mod.startChildSpan(&waf_span, "waf.validate_request", .Internal);
            defer validate_span.end();

            const validation_result = self.validateRequest(request);
            validate_span.setStringAttribute("waf.step", "validate_request");
            validate_span.setBoolAttribute("waf.passed", validation_result.decision == .allow);

            if (validation_result.decision != .allow) {
                validate_span.setStringAttribute("waf.reason", validation_result.reason.description());
                waf_span.setStringAttribute("waf.blocked_by", "validate_request");
                self.recordDecision(&validation_result);
                return self.applyMode(validation_result);
            }
        }

        // Step 2: Check rate limits
        const rate_limit_result = blk: {
            var rate_span = telemetry_mod.startChildSpan(&waf_span, "waf.rate_limit", .Internal);
            defer rate_span.end();

            const result = self.checkRateLimit(request, client_ip);
            rate_span.setStringAttribute("waf.step", "rate_limit");
            rate_span.setBoolAttribute("waf.passed", result.decision == .allow);

            if (result.tokens_remaining) |remaining| {
                rate_span.setIntAttribute("waf.tokens_remaining", @intCast(remaining));
            }
            if (result.rule_name) |rule| {
                rate_span.setStringAttribute("waf.rule", rule);
            }

            if (result.decision != .allow) {
                rate_span.setStringAttribute("waf.reason", result.reason.description());
                waf_span.setStringAttribute("waf.blocked_by", "rate_limit");
                self.recordDecision(&result);
                break :blk self.applyMode(result);
            }
            break :blk result;
        };

        // Early return if rate limited
        if (rate_limit_result.decision != .allow) {
            return rate_limit_result;
        }

        // Step 3: Check for burst behavior (sudden velocity spike)
        if (self.waf_config.burst_detection_enabled) {
            var burst_span = telemetry_mod.startChildSpan(&waf_span, "waf.burst_detection", .Internal);
            defer burst_span.end();

            const burst_result = self.checkBurst(client_ip);
            burst_span.setStringAttribute("waf.step", "burst_detection");
            burst_span.setBoolAttribute("waf.passed", burst_result.decision == .allow);

            if (burst_result.decision != .allow) {
                burst_span.setStringAttribute("waf.reason", burst_result.reason.description());
                waf_span.setStringAttribute("waf.blocked_by", "burst_detection");
                self.recordDecision(&burst_result);
                return self.applyMode(burst_result);
            }
        }

        // All checks passed
        waf_span.setStringAttribute("waf.result", "allow");
        self.recordDecision(&rate_limit_result);
        return self.applyMode(rate_limit_result);
    }

    /// Extract the real client IP, handling trusted proxies
    ///
    /// If the direct connection is from a trusted proxy and X-Forwarded-For
    /// is present, parse and return the first (client) IP from the chain.
    /// Otherwise, return the direct connection IP.
    pub fn getClientIp(self: *WafEngine, request: *const Request) u32 {
        // Check if source IP is from a trusted proxy
        if (!self.waf_config.isTrustedProxy(request.source_ip)) {
            return request.source_ip;
        }

        // Source is trusted proxy - try to parse X-Forwarded-For
        const xff = request.x_forwarded_for orelse return request.source_ip;
        if (xff.len == 0) return request.source_ip;

        // X-Forwarded-For format: "client, proxy1, proxy2"
        // We want the leftmost IP (original client)
        const first_ip = blk: {
            if (std.mem.indexOf(u8, xff, ",")) |comma_pos| {
                break :blk std.mem.trim(u8, xff[0..comma_pos], " ");
            }
            break :blk std.mem.trim(u8, xff, " ");
        };

        // Parse the IP address
        return parseIpv4(first_ip) catch request.source_ip;
    }

    /// Validate request against size and format limits
    fn validateRequest(self: *WafEngine, request: *const Request) CheckResult {
        const limits = &self.waf_config.request_limits;

        // Check URI length
        if (request.uri.len > limits.max_uri_length) {
            return CheckResult.block(.invalid_request, null);
        }

        // Check body size (if Content-Length present)
        if (request.content_length) |content_len| {
            const max_body = self.waf_config.getMaxBodySize(request.getPath());
            if (content_len > max_body) {
                return CheckResult.block(.body_too_large, null);
            }
        }

        return CheckResult.allow();
    }

    /// Check rate limits for the request
    fn checkRateLimit(self: *WafEngine, request: *const Request, client_ip: u32) CheckResult {
        // Find matching rate limit rule
        const rule = self.waf_config.findRateLimitRule(
            request.getPath(),
            request.method,
        ) orelse {
            // No matching rule - allow by default
            return CheckResult.allow();
        };

        // Create rate limit key (IP + path hash)
        const path_hash = hashPath(rule.path);
        const key = Key{
            .ip = client_ip,
            .path_hash = path_hash,
        };

        // Convert config rule to rate limiter rule
        const limiter_rule = Rule{
            .tokens_per_sec = rule.tokensPerSec(),
            .burst_capacity = rule.burstCapacity(),
            .cost_per_request = 1000, // 1 token per request (scaled by 1000)
        };

        // Check rate limit
        const decision = self.limiter.check(key, &limiter_rule);

        if (decision.action == .block) {
            var result = CheckResult.block(.rate_limit, rule.name);
            result.tokens_remaining = decision.remaining_tokens;
            return result;
        }

        var result = CheckResult.allow();
        result.tokens_remaining = decision.remaining_tokens;
        return result;
    }

    /// Check for burst behavior (sudden velocity spike)
    fn checkBurst(self: *WafEngine, client_ip: u32) CheckResult {
        const current_time = rate_limiter.getCurrentTimeSec();
        const threshold = self.waf_config.burst_threshold;

        if (self.waf_state.checkBurst(client_ip, current_time, threshold)) {
            return CheckResult.block(.burst, null);
        }

        return CheckResult.allow();
    }

    /// Apply shadow mode transformation if enabled
    fn applyMode(self: *WafEngine, result: CheckResult) CheckResult {
        if (self.waf_config.shadow_mode) {
            return result.toShadowMode();
        }
        return result;
    }

    /// Record decision in metrics
    fn recordDecision(self: *WafEngine, result: *const CheckResult) void {
        switch (result.decision) {
            .allow => self.waf_state.metrics.recordAllowed(),
            .block => self.waf_state.metrics.recordBlocked(result.reason),
            .log_only => self.waf_state.metrics.recordLogged(),
        }
    }

    /// Get current metrics snapshot
    pub fn getMetrics(self: *WafEngine) state.MetricsSnapshot {
        return self.waf_state.metrics.snapshot();
    }

    /// Check if config epoch has changed (for hot-reload detection)
    pub fn configEpochChanged(self: *WafEngine, last_epoch: u64) bool {
        return self.waf_state.getConfigEpoch() != last_epoch;
    }

    /// Get current config epoch
    pub fn getConfigEpoch(self: *WafEngine) u64 {
        return self.waf_state.getConfigEpoch();
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Parse IPv4 address string to u32 (host byte order)
fn parseIpv4(ip_str: []const u8) !u32 {
    var octets: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var current: u32 = 0;

    for (ip_str) |c| {
        if (c == '.') {
            if (octet_idx >= 3) return error.InvalidIpAddress;
            if (current > 255) return error.InvalidIpAddress;
            octets[octet_idx] = @intCast(current);
            octet_idx += 1;
            current = 0;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
            if (current > 255) return error.InvalidIpAddress;
        } else {
            return error.InvalidIpAddress;
        }
    }

    if (octet_idx != 3) return error.InvalidIpAddress;
    octets[3] = @intCast(current);

    return (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        @as(u32, octets[3]);
}

// =============================================================================
// Tests
// =============================================================================

test "Request: init and getPath" {
    const req = Request.init(.GET, "/api/users?page=1", 0xC0A80101);

    try std.testing.expectEqual(HttpMethod.GET, req.method);
    try std.testing.expectEqualStrings("/api/users?page=1", req.uri);
    try std.testing.expectEqualStrings("/api/users", req.getPath());
    try std.testing.expectEqual(@as(u32, 0xC0A80101), req.source_ip);
}

test "Request: withContentLength" {
    const req = Request.withContentLength(.POST, "/api/upload", 0x0A000001, 1024);

    try std.testing.expectEqual(HttpMethod.POST, req.method);
    try std.testing.expectEqual(@as(?usize, 1024), req.content_length);
}

test "Request: getPath without query string" {
    const req = Request.init(.GET, "/api/users", 0xC0A80101);
    try std.testing.expectEqualStrings("/api/users", req.getPath());
}

test "CheckResult: allow" {
    const result = CheckResult.allow();

    try std.testing.expect(result.isAllowed());
    try std.testing.expect(!result.isBlocked());
    try std.testing.expect(!result.shouldLog());
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(Reason.none, result.reason);
}

test "CheckResult: block" {
    const result = CheckResult.block(.rate_limit, "login_bruteforce");

    try std.testing.expect(!result.isAllowed());
    try std.testing.expect(result.isBlocked());
    try std.testing.expect(result.shouldLog());
    try std.testing.expectEqual(Decision.block, result.decision);
    try std.testing.expectEqual(Reason.rate_limit, result.reason);
    try std.testing.expectEqualStrings("login_bruteforce", result.rule_name.?);
}

test "CheckResult: logOnly" {
    const result = CheckResult.logOnly(.body_too_large, null);

    try std.testing.expect(result.isAllowed()); // log_only still allows
    try std.testing.expect(!result.isBlocked());
    try std.testing.expect(result.shouldLog());
    try std.testing.expectEqual(Decision.log_only, result.decision);
    try std.testing.expectEqual(Reason.body_too_large, result.reason);
}

test "CheckResult: toShadowMode converts block to log_only" {
    const blocked = CheckResult.block(.rate_limit, "test_rule");
    const shadowed = blocked.toShadowMode();

    try std.testing.expectEqual(Decision.log_only, shadowed.decision);
    try std.testing.expectEqual(Reason.rate_limit, shadowed.reason);
    try std.testing.expectEqualStrings("test_rule", shadowed.rule_name.?);
}

test "CheckResult: toShadowMode preserves allow" {
    const allowed = CheckResult.allow();
    const shadowed = allowed.toShadowMode();

    try std.testing.expectEqual(Decision.allow, shadowed.decision);
}

test "parseIpv4: valid addresses" {
    try std.testing.expectEqual(@as(u32, 0x7F000001), try parseIpv4("127.0.0.1"));
    try std.testing.expectEqual(@as(u32, 0xC0A80101), try parseIpv4("192.168.1.1"));
    try std.testing.expectEqual(@as(u32, 0x0A000001), try parseIpv4("10.0.0.1"));
}

test "parseIpv4: invalid addresses" {
    try std.testing.expectError(error.InvalidIpAddress, parseIpv4("256.0.0.0"));
    try std.testing.expectError(error.InvalidIpAddress, parseIpv4("10.0.0"));
    try std.testing.expectError(error.InvalidIpAddress, parseIpv4("10.0.0.0.0"));
}

test "WafEngine: init" {
    var waf_state = WafState.init();
    const waf_config = WafConfig{};
    const engine = WafEngine.init(&waf_state, &waf_config);

    try std.testing.expect(engine.waf_state == &waf_state);
    try std.testing.expect(engine.waf_config == &waf_config);
}

test "WafEngine: check with disabled WAF" {
    var waf_state = WafState.init();
    var waf_config = WafConfig{};
    waf_config.enabled = false;

    var engine = WafEngine.init(&waf_state, &waf_config);
    const req = Request.init(.GET, "/api/users", 0xC0A80101);
    const result = engine.check(&req);

    try std.testing.expect(result.isAllowed());
    try std.testing.expectEqual(Decision.allow, result.decision);
}

test "WafEngine: check allows valid request" {
    var waf_state = WafState.init();
    const waf_config = WafConfig{}; // No rate limit rules

    var engine = WafEngine.init(&waf_state, &waf_config);
    const req = Request.init(.GET, "/api/users", 0xC0A80101);
    const result = engine.check(&req);

    try std.testing.expect(result.isAllowed());
}

test "WafEngine: check blocks oversized URI" {
    var waf_state = WafState.init();
    var waf_config = WafConfig{};
    waf_config.request_limits.max_uri_length = 10;

    var engine = WafEngine.init(&waf_state, &waf_config);
    const req = Request.init(.GET, "/this/is/a/very/long/uri/that/exceeds/the/limit", 0xC0A80101);
    const result = engine.check(&req);

    try std.testing.expect(result.isBlocked());
    try std.testing.expectEqual(Reason.invalid_request, result.reason);
}

test "WafEngine: check blocks oversized body" {
    var waf_state = WafState.init();
    var waf_config = WafConfig{};
    waf_config.request_limits.max_body_size = 100;

    var engine = WafEngine.init(&waf_state, &waf_config);
    const req = Request.withContentLength(.POST, "/api/upload", 0xC0A80101, 1000);
    const result = engine.check(&req);

    try std.testing.expect(result.isBlocked());
    try std.testing.expectEqual(Reason.body_too_large, result.reason);
}

test "WafEngine: shadow mode converts block to log_only" {
    var waf_state = WafState.init();
    var waf_config = WafConfig{};
    waf_config.shadow_mode = true;
    waf_config.request_limits.max_uri_length = 10;

    var engine = WafEngine.init(&waf_state, &waf_config);
    const req = Request.init(.GET, "/this/is/a/very/long/uri", 0xC0A80101);
    const result = engine.check(&req);

    // In shadow mode, should be log_only instead of block
    try std.testing.expect(result.isAllowed());
    try std.testing.expectEqual(Decision.log_only, result.decision);
    try std.testing.expectEqual(Reason.invalid_request, result.reason);
}

test "WafEngine: getClientIp returns source IP when not trusted" {
    var waf_state = WafState.init();
    const waf_config = WafConfig{}; // No trusted proxies

    var engine = WafEngine.init(&waf_state, &waf_config);
    var req = Request.init(.GET, "/api/users", 0xC0A80101);
    req.x_forwarded_for = "10.0.0.1";

    const client_ip = engine.getClientIp(&req);
    try std.testing.expectEqual(@as(u32, 0xC0A80101), client_ip);
}

test "WafEngine: getClientIp returns source IP when no XFF" {
    var waf_state = WafState.init();
    const waf_config = WafConfig{};

    var engine = WafEngine.init(&waf_state, &waf_config);
    const req = Request.init(.GET, "/api/users", 0xC0A80101);

    const client_ip = engine.getClientIp(&req);
    try std.testing.expectEqual(@as(u32, 0xC0A80101), client_ip);
}

test "WafEngine: metrics recording" {
    var waf_state = WafState.init();
    var waf_config = WafConfig{};
    waf_config.request_limits.max_uri_length = 10;

    var engine = WafEngine.init(&waf_state, &waf_config);

    // Make a valid request
    const valid_req = Request.init(.GET, "/api", 0xC0A80101);
    _ = engine.check(&valid_req);

    // Make an invalid request
    const invalid_req = Request.init(.GET, "/very/long/uri/path", 0xC0A80101);
    _ = engine.check(&invalid_req);

    // Check metrics
    const metrics = engine.getMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics.requests_allowed);
    try std.testing.expectEqual(@as(u64, 1), metrics.requests_blocked);
}

test "WafEngine: config epoch" {
    var waf_state = WafState.init();
    const waf_config = WafConfig{};

    var engine = WafEngine.init(&waf_state, &waf_config);

    const epoch1 = engine.getConfigEpoch();
    try std.testing.expectEqual(@as(u64, 0), epoch1);
    try std.testing.expect(!engine.configEpochChanged(0));

    // Increment epoch
    _ = waf_state.incrementConfigEpoch();

    try std.testing.expect(engine.configEpochChanged(0));
    try std.testing.expectEqual(@as(u64, 1), engine.getConfigEpoch());
}
