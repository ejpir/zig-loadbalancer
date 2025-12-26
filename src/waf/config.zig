/// WAF Configuration - JSON Parsing and Validation
///
/// Parses waf.json configuration for the Web Application Firewall.
/// Supports hot-reload through config epoch tracking.
///
/// Design Philosophy (TigerBeetle-inspired):
/// - Fixed-size arrays with explicit compile-time bounds
/// - No unbounded allocations - all limits are known at compile time
/// - Validation before application - invalid configs are rejected early
/// - Hot-reload support via config epoch
///
/// Example waf.json:
/// ```json
/// {
///   "enabled": true,
///   "shadow_mode": false,
///   "rate_limits": [
///     {
///       "name": "login_bruteforce",
///       "path": "/api/auth/login",
///       "method": "POST",
///       "limit": { "requests": 10, "period_sec": 60 },
///       "burst": 3,
///       "by": "ip",
///       "action": "block"
///     }
///   ],
///   "slowloris": {
///     "header_timeout_ms": 5000,
///     "body_timeout_ms": 30000,
///     "min_bytes_per_sec": 100,
///     "max_conns_per_ip": 50
///   },
///   "request_limits": {
///     "max_uri_length": 2048,
///     "max_body_size": 1048576,
///     "max_json_depth": 20,
///     "endpoints": [
///       { "path": "/api/upload", "max_body_size": 10485760 }
///     ]
///   },
///   "trusted_proxies": ["10.0.0.0/8", "172.16.0.0/12"],
///   "logging": {
///     "log_blocked": true,
///     "log_allowed": false,
///     "log_near_limit": true,
///     "near_limit_threshold": 0.8
///   }
/// }
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Constants (TigerBeetle-style: fixed sizes, explicit bounds)
// =============================================================================

/// Maximum rate limit rules in config
pub const MAX_RATE_LIMIT_RULES: usize = 64;

/// Maximum endpoint-specific overrides
pub const MAX_ENDPOINT_OVERRIDES: usize = 32;

/// Maximum trusted proxy CIDR ranges
pub const MAX_TRUSTED_PROXIES: usize = 16;

/// Maximum path length for rules
pub const MAX_PATH_LENGTH: usize = 256;

/// Maximum name length for rules
pub const MAX_NAME_LENGTH: usize = 64;

/// Maximum header name length for rate limiting by header
pub const MAX_HEADER_NAME_LENGTH: usize = 64;

/// Maximum config file size
pub const MAX_CONFIG_SIZE: usize = 64 * 1024;

// =============================================================================
// Enums
// =============================================================================

/// HTTP methods for rate limiting
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,

    /// Parse HTTP method from string (case-insensitive)
    pub fn parse(str: []const u8) ?HttpMethod {
        const method_map = std.StaticStringMap(HttpMethod).initComptime(.{
            .{ "GET", .GET },
            .{ "POST", .POST },
            .{ "PUT", .PUT },
            .{ "DELETE", .DELETE },
            .{ "PATCH", .PATCH },
            .{ "HEAD", .HEAD },
            .{ "OPTIONS", .OPTIONS },
            .{ "TRACE", .TRACE },
            .{ "CONNECT", .CONNECT },
            // Lowercase variants
            .{ "get", .GET },
            .{ "post", .POST },
            .{ "put", .PUT },
            .{ "delete", .DELETE },
            .{ "patch", .PATCH },
            .{ "head", .HEAD },
            .{ "options", .OPTIONS },
            .{ "trace", .TRACE },
            .{ "connect", .CONNECT },
        });
        return method_map.get(str);
    }

    /// Convert to string representation
    pub fn toString(self: HttpMethod) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .TRACE => "TRACE",
            .CONNECT => "CONNECT",
        };
    }
};

/// What to rate limit by
pub const RateLimitBy = enum {
    /// Rate limit by client IP address
    ip,
    /// Rate limit by specific header value (e.g., API key)
    header,
    /// Rate limit by request path
    path,

    /// Parse from string
    pub fn parse(str: []const u8) ?RateLimitBy {
        const by_map = std.StaticStringMap(RateLimitBy).initComptime(.{
            .{ "ip", .ip },
            .{ "header", .header },
            .{ "path", .path },
        });
        return by_map.get(str);
    }
};

/// Action to take when rule matches
pub const Action = enum {
    /// Block the request immediately
    block,
    /// Log but allow the request (shadow mode)
    log,
    /// Slow down response (tarpit attackers)
    tarpit,

    /// Parse from string
    pub fn parse(str: []const u8) ?Action {
        const action_map = std.StaticStringMap(Action).initComptime(.{
            .{ "block", .block },
            .{ "log", .log },
            .{ "tarpit", .tarpit },
        });
        return action_map.get(str);
    }
};

// =============================================================================
// CIDR Range (for trusted proxies)
// =============================================================================

/// IPv4 CIDR range for trusted proxy detection
pub const CidrRange = struct {
    /// Network address (host byte order)
    network: u32,
    /// Netmask (host byte order, e.g., 0xFFFFFF00 for /24)
    mask: u32,

    /// Parse CIDR notation (e.g., "10.0.0.0/8", "192.168.1.0/24")
    pub fn parse(cidr: []const u8) !CidrRange {
        // Find the slash separator
        const slash_pos = std.mem.indexOf(u8, cidr, "/") orelse return error.InvalidCidr;

        const ip_part = cidr[0..slash_pos];
        const prefix_part = cidr[slash_pos + 1 ..];

        // Parse IP address
        const ip = try parseIpv4(ip_part);

        // Parse prefix length (0-32 valid for IPv4)
        const prefix_len = std.fmt.parseInt(u8, prefix_part, 10) catch return error.InvalidCidrPrefix;
        if (prefix_len > 32) return error.InvalidCidrPrefix;

        // Calculate mask from prefix length
        const mask: u32 = if (prefix_len == 0)
            0
        else if (prefix_len == 32)
            0xFFFFFFFF
        else
            @as(u32, 0xFFFFFFFF) << @intCast(32 - @as(u6, @intCast(prefix_len)));

        // Validate that IP is actually the network address
        if ((ip & mask) != ip) {
            return error.IpNotNetworkAddress;
        }

        return .{
            .network = ip,
            .mask = mask,
        };
    }

    /// Check if an IP address falls within this CIDR range
    pub fn contains(self: CidrRange, ip: u32) bool {
        return (ip & self.mask) == self.network;
    }

    /// Format as CIDR string (for debugging)
    pub fn format(
        self: CidrRange,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const prefix_len = @popCount(self.mask);
        try writer.print("{d}.{d}.{d}.{d}/{d}", .{
            @as(u8, @truncate(self.network >> 24)),
            @as(u8, @truncate(self.network >> 16)),
            @as(u8, @truncate(self.network >> 8)),
            @as(u8, @truncate(self.network)),
            prefix_len,
        });
    }
};

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

/// Convert u32 IP to bytes (for display)
pub fn ipToBytes(ip: u32) [4]u8 {
    return .{
        @truncate(ip >> 24),
        @truncate(ip >> 16),
        @truncate(ip >> 8),
        @truncate(ip),
    };
}

// =============================================================================
// Sub-Configurations
// =============================================================================

/// Slowloris attack prevention configuration
pub const SlowlorisConfig = struct {
    /// Timeout for receiving all headers (milliseconds)
    header_timeout_ms: u32 = 5000,
    /// Timeout for receiving request body (milliseconds)
    body_timeout_ms: u32 = 30000,
    /// Minimum bytes per second for body transfer
    min_bytes_per_sec: u32 = 100,
    /// Maximum concurrent connections per IP
    max_conns_per_ip: u16 = 50,
};

/// Endpoint-specific body size override
pub const EndpointOverride = struct {
    /// Path pattern (supports * wildcard at end)
    path: []const u8,
    /// Maximum body size for this endpoint
    max_body_size: u32,
};

/// Request size and depth limits configuration
pub const RequestLimitsConfig = struct {
    /// Maximum URI length in bytes
    max_uri_length: u32 = 2048,
    /// Maximum request body size in bytes (default 1MB)
    max_body_size: u32 = 1048576,
    /// Maximum JSON nesting depth
    max_json_depth: u8 = 20,
    /// Endpoint-specific overrides (e.g., larger limit for upload endpoints)
    endpoints: []const EndpointOverride = &.{},
};

/// Logging configuration
pub const LoggingConfig = struct {
    /// Log blocked requests
    log_blocked: bool = true,
    /// Log allowed requests (verbose)
    log_allowed: bool = false,
    /// Log requests approaching rate limit
    log_near_limit: bool = true,
    /// Threshold for "near limit" (0.0-1.0, e.g., 0.8 = 80% of limit)
    near_limit_threshold: f32 = 0.8,
};

// =============================================================================
// Rate Limit Rule
// =============================================================================

/// Rate limit rule configuration
pub const RateLimitRule = struct {
    /// Human-readable name for this rule
    name: []const u8,
    /// Path pattern to match (supports * wildcard at end)
    path: []const u8,
    /// HTTP method to match (null = all methods)
    method: ?HttpMethod = null,
    /// Requests allowed per period
    requests: u32,
    /// Period in seconds
    period_sec: u32,
    /// Burst allowance (extra requests allowed in short burst)
    burst: u32,
    /// What to rate limit by
    by: RateLimitBy = .ip,
    /// Header name when by=header
    header_name: ?[]const u8 = null,
    /// Action to take when limit exceeded
    action: Action = .block,

    /// Check if this rule matches a given path and method
    pub fn matches(self: *const RateLimitRule, request_path: []const u8, request_method: ?HttpMethod) bool {
        // Check method match (null rule method means match all)
        if (self.method) |rule_method| {
            if (request_method) |req_method| {
                if (rule_method != req_method) return false;
            } else {
                return false;
            }
        }

        // Check path match with wildcard support
        return pathMatches(self.path, request_path);
    }

    /// Calculate tokens per second for rate limiter
    /// Scaled by 1000 for sub-token precision
    pub fn tokensPerSec(self: *const RateLimitRule) u32 {
        if (self.period_sec == 0) return 0;
        return (self.requests * 1000) / self.period_sec;
    }

    /// Calculate burst capacity for rate limiter
    /// Scaled by 1000 for sub-token precision
    pub fn burstCapacity(self: *const RateLimitRule) u32 {
        return (self.requests + self.burst) * 1000;
    }
};

/// Check if a path pattern matches a request path
/// Supports * wildcard at end of pattern
fn pathMatches(pattern: []const u8, path: []const u8) bool {
    // Empty pattern matches nothing
    if (pattern.len == 0) return false;

    // Check for wildcard at end
    if (pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, path, prefix);
    }

    // Exact match
    return std.mem.eql(u8, pattern, path);
}

// =============================================================================
// Main WAF Configuration
// =============================================================================

/// Main WAF configuration structure
/// Parsed from waf.json with all settings for the firewall
pub const WafConfig = struct {
    /// Master enable/disable switch
    enabled: bool = true,
    /// Shadow mode: log but don't block (for testing rules)
    shadow_mode: bool = false,
    /// Rate limiting rules
    rate_limits: []const RateLimitRule = &.{},
    /// Slowloris attack prevention
    slowloris: SlowlorisConfig = .{},
    /// Request size limits
    request_limits: RequestLimitsConfig = .{},
    /// Trusted proxy CIDR ranges (for X-Forwarded-For)
    trusted_proxies: []const CidrRange = &.{},
    /// Logging configuration
    logging: LoggingConfig = .{},
    /// Config epoch for hot-reload detection
    epoch: u64 = 0,

    /// Internal: allocator used for parsing (needed for deinit)
    _allocator: ?Allocator = null,

    // =========================================================================
    // Parsing
    // =========================================================================

    /// Parse WAF config from JSON string
    pub fn parse(allocator: Allocator, json: []const u8) !WafConfig {
        // Parse JSON
        const parsed = std.json.parseFromSlice(
            JsonWafConfig,
            allocator,
            json,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch {
            return error.InvalidJson;
        };
        defer parsed.deinit();

        return try fromJson(allocator, parsed.value);
    }

    /// Convert from JSON representation to WafConfig
    fn fromJson(allocator: Allocator, json: JsonWafConfig) !WafConfig {
        var config = WafConfig{
            .enabled = json.enabled,
            .shadow_mode = json.shadow_mode,
            ._allocator = allocator,
        };
        errdefer config.deinit();

        // Parse rate limits
        if (json.rate_limits.len > MAX_RATE_LIMIT_RULES) {
            return error.TooManyRateLimitRules;
        }
        if (json.rate_limits.len > 0) {
            const rate_limits = try allocator.alloc(RateLimitRule, json.rate_limits.len);
            // Initialize to empty for safe cleanup during errdefer
            for (rate_limits) |*rl| {
                rl.* = .{
                    .name = &.{},
                    .path = &.{},
                    .requests = 0,
                    .period_sec = 1,
                    .burst = 0,
                };
            }
            config.rate_limits = rate_limits;

            for (json.rate_limits, 0..) |jrl, i| {
                rate_limits[i] = try parseRateLimitRule(allocator, jrl);
            }
        }

        // Parse trusted proxies
        if (json.trusted_proxies.len > MAX_TRUSTED_PROXIES) {
            return error.TooManyTrustedProxies;
        }
        if (json.trusted_proxies.len > 0) {
            const proxies = try allocator.alloc(CidrRange, json.trusted_proxies.len);
            config.trusted_proxies = proxies;

            for (json.trusted_proxies, 0..) |cidr_str, i| {
                proxies[i] = CidrRange.parse(cidr_str) catch {
                    return error.InvalidTrustedProxy;
                };
            }
        }

        // Parse endpoint overrides
        if (json.request_limits) |jrl| {
            config.request_limits = .{
                .max_uri_length = jrl.max_uri_length,
                .max_body_size = jrl.max_body_size,
                .max_json_depth = jrl.max_json_depth,
                .endpoints = &.{},
            };

            if (jrl.endpoints.len > 0) {
                const endpoints = try allocator.alloc(EndpointOverride, jrl.endpoints.len);
                // Initialize to empty for safe cleanup
                for (endpoints) |*ep| {
                    ep.* = .{ .path = &.{}, .max_body_size = 0 };
                }
                config.request_limits.endpoints = endpoints;

                for (jrl.endpoints, 0..) |je, i| {
                    const path = try allocator.dupe(u8, je.path);
                    endpoints[i] = .{
                        .path = path,
                        .max_body_size = je.max_body_size,
                    };
                }
            }
        }

        // Parse slowloris config
        if (json.slowloris) |js| {
            config.slowloris = .{
                .header_timeout_ms = js.header_timeout_ms,
                .body_timeout_ms = js.body_timeout_ms,
                .min_bytes_per_sec = js.min_bytes_per_sec,
                .max_conns_per_ip = js.max_conns_per_ip,
            };
        }

        // Parse logging config
        if (json.logging) |jl| {
            config.logging = .{
                .log_blocked = jl.log_blocked,
                .log_allowed = jl.log_allowed,
                .log_near_limit = jl.log_near_limit,
                .near_limit_threshold = jl.near_limit_threshold,
            };
        }

        // Validate before returning
        try config.validate();

        return config;
    }

    /// Free all allocated memory
    pub fn deinit(self: *WafConfig) void {
        const allocator = self._allocator orelse return;

        // Free rate limit rules - only free strings that were actually allocated
        for (self.rate_limits) |rule| {
            if (rule.name.len > 0) allocator.free(rule.name);
            if (rule.path.len > 0) allocator.free(rule.path);
            if (rule.header_name) |h| {
                if (h.len > 0) allocator.free(h);
            }
        }
        // Free the array itself if it was allocated
        if (self.rate_limits.len > 0) {
            allocator.free(self.rate_limits);
        }

        // Free endpoint overrides - only free paths that were actually allocated
        for (self.request_limits.endpoints) |ep| {
            if (ep.path.len > 0) allocator.free(ep.path);
        }
        // Free the array itself if it was allocated
        if (self.request_limits.endpoints.len > 0) {
            allocator.free(self.request_limits.endpoints);
        }

        // Free trusted proxies array if it was allocated
        if (self.trusted_proxies.len > 0) {
            allocator.free(self.trusted_proxies);
        }

        self._allocator = null;
    }

    // =========================================================================
    // File Loading
    // =========================================================================

    /// Load WAF config from file
    pub fn loadFromFile(allocator: Allocator, path: []const u8) !WafConfig {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => error.ConfigFileNotFound,
                else => error.ConfigFileOpenFailed,
            };
        };
        defer file.close();

        // Read file content
        var content = try allocator.alloc(u8, MAX_CONFIG_SIZE);
        defer allocator.free(content);

        var total_read: usize = 0;
        while (total_read < MAX_CONFIG_SIZE) {
            const bytes_read = file.read(content[total_read..]) catch |err| {
                if (err == error.EndOfStream) break;
                return error.ConfigFileReadFailed;
            };
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        if (total_read == MAX_CONFIG_SIZE) {
            return error.ConfigFileTooLarge;
        }

        return try parse(allocator, content[0..total_read]);
    }

    // =========================================================================
    // Validation
    // =========================================================================

    /// Validate configuration consistency
    pub fn validate(self: *const WafConfig) !void {
        // Validate rate limit rules
        for (self.rate_limits) |rule| {
            if (rule.name.len == 0) return error.EmptyRuleName;
            if (rule.name.len > MAX_NAME_LENGTH) return error.RuleNameTooLong;
            if (rule.path.len == 0) return error.EmptyRulePath;
            if (rule.path.len > MAX_PATH_LENGTH) return error.RulePathTooLong;
            if (rule.requests == 0) return error.ZeroRequests;
            if (rule.period_sec == 0) return error.ZeroPeriod;
            if (rule.by == .header and rule.header_name == null) {
                return error.MissingHeaderName;
            }
        }

        // Validate slowloris config
        if (self.slowloris.header_timeout_ms == 0) return error.ZeroHeaderTimeout;
        if (self.slowloris.body_timeout_ms == 0) return error.ZeroBodyTimeout;

        // Validate request limits
        if (self.request_limits.max_uri_length == 0) return error.ZeroMaxUriLength;
        if (self.request_limits.max_body_size == 0) return error.ZeroMaxBodySize;

        // Validate endpoint overrides
        for (self.request_limits.endpoints) |ep| {
            if (ep.path.len == 0) return error.EmptyEndpointPath;
            if (ep.path.len > MAX_PATH_LENGTH) return error.EndpointPathTooLong;
            if (ep.max_body_size == 0) return error.ZeroEndpointBodySize;
        }

        // Validate logging threshold
        if (self.logging.near_limit_threshold <= 0.0 or self.logging.near_limit_threshold > 1.0) {
            return error.InvalidNearLimitThreshold;
        }
    }

    // =========================================================================
    // Lookups
    // =========================================================================

    /// Find the first matching rate limit rule for a request
    pub fn findRateLimitRule(self: *const WafConfig, path: []const u8, method: ?HttpMethod) ?*const RateLimitRule {
        for (self.rate_limits) |*rule| {
            if (rule.matches(path, method)) {
                return rule;
            }
        }
        return null;
    }

    /// Get the effective max body size for a path
    pub fn getMaxBodySize(self: *const WafConfig, path: []const u8) u32 {
        // Check endpoint-specific overrides first
        for (self.request_limits.endpoints) |ep| {
            if (pathMatches(ep.path, path)) {
                return ep.max_body_size;
            }
        }
        return self.request_limits.max_body_size;
    }

    /// Check if an IP is from a trusted proxy
    pub fn isTrustedProxy(self: *const WafConfig, ip: u32) bool {
        for (self.trusted_proxies) |cidr| {
            if (cidr.contains(ip)) {
                return true;
            }
        }
        return false;
    }
};

// =============================================================================
// JSON Schema Types (for std.json parsing)
// =============================================================================

const JsonRateLimitRule = struct {
    name: []const u8,
    path: []const u8,
    method: ?[]const u8 = null,
    limit: struct {
        requests: u32,
        period_sec: u32,
    },
    burst: u32 = 0,
    by: []const u8 = "ip",
    header_name: ?[]const u8 = null,
    action: []const u8 = "block",
};

const JsonSlowlorisConfig = struct {
    header_timeout_ms: u32 = 5000,
    body_timeout_ms: u32 = 30000,
    min_bytes_per_sec: u32 = 100,
    max_conns_per_ip: u16 = 50,
};

const JsonEndpointOverride = struct {
    path: []const u8,
    max_body_size: u32,
};

const JsonRequestLimitsConfig = struct {
    max_uri_length: u32 = 2048,
    max_body_size: u32 = 1048576,
    max_json_depth: u8 = 20,
    endpoints: []const JsonEndpointOverride = &.{},
};

const JsonLoggingConfig = struct {
    log_blocked: bool = true,
    log_allowed: bool = false,
    log_near_limit: bool = true,
    near_limit_threshold: f32 = 0.8,
};

const JsonWafConfig = struct {
    enabled: bool = true,
    shadow_mode: bool = false,
    rate_limits: []const JsonRateLimitRule = &.{},
    slowloris: ?JsonSlowlorisConfig = null,
    request_limits: ?JsonRequestLimitsConfig = null,
    trusted_proxies: []const []const u8 = &.{},
    logging: ?JsonLoggingConfig = null,
};

/// Parse a JSON rate limit rule to RateLimitRule
fn parseRateLimitRule(allocator: Allocator, jrl: JsonRateLimitRule) !RateLimitRule {
    // Validate lengths
    if (jrl.name.len > MAX_NAME_LENGTH) return error.RuleNameTooLong;
    if (jrl.path.len > MAX_PATH_LENGTH) return error.RulePathTooLong;

    // Parse method
    const method: ?HttpMethod = if (jrl.method) |m|
        HttpMethod.parse(m) orelse return error.InvalidHttpMethod
    else
        null;

    // Parse "by" field
    const by = RateLimitBy.parse(jrl.by) orelse return error.InvalidRateLimitBy;

    // Parse action
    const action = Action.parse(jrl.action) orelse return error.InvalidAction;

    // Copy strings
    const name = try allocator.dupe(u8, jrl.name);
    errdefer allocator.free(name);

    const path = try allocator.dupe(u8, jrl.path);
    errdefer allocator.free(path);

    const header_name: ?[]const u8 = if (jrl.header_name) |h| blk: {
        if (h.len > MAX_HEADER_NAME_LENGTH) return error.HeaderNameTooLong;
        break :blk try allocator.dupe(u8, h);
    } else null;

    return .{
        .name = name,
        .path = path,
        .method = method,
        .requests = jrl.limit.requests,
        .period_sec = jrl.limit.period_sec,
        .burst = jrl.burst,
        .by = by,
        .header_name = header_name,
        .action = action,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "CidrRange: parse valid CIDR" {
    const cidr = try CidrRange.parse("10.0.0.0/8");
    try std.testing.expectEqual(@as(u32, 0x0A000000), cidr.network);
    try std.testing.expectEqual(@as(u32, 0xFF000000), cidr.mask);
}

test "CidrRange: parse /24 network" {
    const cidr = try CidrRange.parse("192.168.1.0/24");
    try std.testing.expectEqual(@as(u32, 0xC0A80100), cidr.network);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), cidr.mask);
}

test "CidrRange: parse /32 (single host)" {
    const cidr = try CidrRange.parse("192.168.1.100/32");
    try std.testing.expectEqual(@as(u32, 0xC0A80164), cidr.network);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cidr.mask);
}

test "CidrRange: contains" {
    const cidr = try CidrRange.parse("10.0.0.0/8");

    // Should contain
    try std.testing.expect(cidr.contains(0x0A000001)); // 10.0.0.1
    try std.testing.expect(cidr.contains(0x0AFFFFFF)); // 10.255.255.255

    // Should not contain
    try std.testing.expect(!cidr.contains(0x0B000000)); // 11.0.0.0
    try std.testing.expect(!cidr.contains(0xC0A80101)); // 192.168.1.1
}

test "CidrRange: invalid - not network address" {
    const result = CidrRange.parse("10.0.0.1/8");
    try std.testing.expectError(error.IpNotNetworkAddress, result);
}

test "CidrRange: invalid - no slash" {
    const result = CidrRange.parse("10.0.0.0");
    try std.testing.expectError(error.InvalidCidr, result);
}

test "parseIpv4: valid addresses" {
    try std.testing.expectEqual(@as(u32, 0x7F000001), try parseIpv4("127.0.0.1"));
    try std.testing.expectEqual(@as(u32, 0xC0A80101), try parseIpv4("192.168.1.1"));
    try std.testing.expectEqual(@as(u32, 0x00000000), try parseIpv4("0.0.0.0"));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), try parseIpv4("255.255.255.255"));
}

test "parseIpv4: invalid addresses" {
    try std.testing.expectError(error.InvalidIpAddress, parseIpv4("256.0.0.0"));
    try std.testing.expectError(error.InvalidIpAddress, parseIpv4("10.0.0"));
    try std.testing.expectError(error.InvalidIpAddress, parseIpv4("10.0.0.0.0"));
    try std.testing.expectError(error.InvalidIpAddress, parseIpv4("abc.def.ghi.jkl"));
}

test "HttpMethod: parse" {
    try std.testing.expectEqual(HttpMethod.GET, HttpMethod.parse("GET").?);
    try std.testing.expectEqual(HttpMethod.POST, HttpMethod.parse("post").?);
    try std.testing.expect(HttpMethod.parse("INVALID") == null);
}

test "RateLimitBy: parse" {
    try std.testing.expectEqual(RateLimitBy.ip, RateLimitBy.parse("ip").?);
    try std.testing.expectEqual(RateLimitBy.header, RateLimitBy.parse("header").?);
    try std.testing.expectEqual(RateLimitBy.path, RateLimitBy.parse("path").?);
    try std.testing.expect(RateLimitBy.parse("invalid") == null);
}

test "Action: parse" {
    try std.testing.expectEqual(Action.block, Action.parse("block").?);
    try std.testing.expectEqual(Action.log, Action.parse("log").?);
    try std.testing.expectEqual(Action.tarpit, Action.parse("tarpit").?);
    try std.testing.expect(Action.parse("invalid") == null);
}

test "pathMatches: exact match" {
    try std.testing.expect(pathMatches("/api/users", "/api/users"));
    try std.testing.expect(!pathMatches("/api/users", "/api/posts"));
}

test "pathMatches: wildcard" {
    try std.testing.expect(pathMatches("/api/*", "/api/users"));
    try std.testing.expect(pathMatches("/api/*", "/api/users/123"));
    try std.testing.expect(!pathMatches("/api/*", "/other/path"));
}

test "RateLimitRule: matches" {
    const rule = RateLimitRule{
        .name = "test",
        .path = "/api/*",
        .method = .POST,
        .requests = 100,
        .period_sec = 60,
        .burst = 10,
    };

    try std.testing.expect(rule.matches("/api/users", .POST));
    try std.testing.expect(!rule.matches("/api/users", .GET));
    try std.testing.expect(!rule.matches("/other", .POST));
}

test "RateLimitRule: tokensPerSec and burstCapacity" {
    const rule = RateLimitRule{
        .name = "test",
        .path = "/api/*",
        .requests = 60, // 60 requests per minute = 1 per second
        .period_sec = 60,
        .burst = 10,
    };

    try std.testing.expectEqual(@as(u32, 1000), rule.tokensPerSec()); // 1 * 1000
    try std.testing.expectEqual(@as(u32, 70000), rule.burstCapacity()); // (60 + 10) * 1000
}

test "WafConfig: parse minimal config" {
    const json =
        \\{"enabled": true, "shadow_mode": false}
    ;

    var config = try WafConfig.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expect(config.enabled);
    try std.testing.expect(!config.shadow_mode);
    try std.testing.expectEqual(@as(usize, 0), config.rate_limits.len);
}

test "WafConfig: parse with rate limits" {
    const json =
        \\{
        \\  "enabled": true,
        \\  "shadow_mode": false,
        \\  "rate_limits": [
        \\    {
        \\      "name": "login_bruteforce",
        \\      "path": "/api/auth/login",
        \\      "method": "POST",
        \\      "limit": { "requests": 10, "period_sec": 60 },
        \\      "burst": 3,
        \\      "by": "ip",
        \\      "action": "block"
        \\    }
        \\  ]
        \\}
    ;

    var config = try WafConfig.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.rate_limits.len);
    try std.testing.expectEqualStrings("login_bruteforce", config.rate_limits[0].name);
    try std.testing.expectEqualStrings("/api/auth/login", config.rate_limits[0].path);
    try std.testing.expectEqual(HttpMethod.POST, config.rate_limits[0].method.?);
    try std.testing.expectEqual(@as(u32, 10), config.rate_limits[0].requests);
    try std.testing.expectEqual(@as(u32, 60), config.rate_limits[0].period_sec);
    try std.testing.expectEqual(@as(u32, 3), config.rate_limits[0].burst);
    try std.testing.expectEqual(RateLimitBy.ip, config.rate_limits[0].by);
    try std.testing.expectEqual(Action.block, config.rate_limits[0].action);
}

test "WafConfig: parse with trusted proxies" {
    const json =
        \\{
        \\  "trusted_proxies": ["10.0.0.0/8", "172.16.0.0/12"]
        \\}
    ;

    var config = try WafConfig.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.trusted_proxies.len);

    // Test 10.0.0.0/8
    try std.testing.expectEqual(@as(u32, 0x0A000000), config.trusted_proxies[0].network);
    try std.testing.expect(config.isTrustedProxy(0x0A010203)); // 10.1.2.3

    // Test 172.16.0.0/12
    try std.testing.expectEqual(@as(u32, 0xAC100000), config.trusted_proxies[1].network);
    try std.testing.expect(config.isTrustedProxy(0xAC1F0001)); // 172.31.0.1
}

test "WafConfig: parse with slowloris config" {
    const json =
        \\{
        \\  "slowloris": {
        \\    "header_timeout_ms": 3000,
        \\    "body_timeout_ms": 20000,
        \\    "min_bytes_per_sec": 50,
        \\    "max_conns_per_ip": 25
        \\  }
        \\}
    ;

    var config = try WafConfig.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 3000), config.slowloris.header_timeout_ms);
    try std.testing.expectEqual(@as(u32, 20000), config.slowloris.body_timeout_ms);
    try std.testing.expectEqual(@as(u32, 50), config.slowloris.min_bytes_per_sec);
    try std.testing.expectEqual(@as(u16, 25), config.slowloris.max_conns_per_ip);
}

test "WafConfig: parse with request limits and endpoint overrides" {
    const json =
        \\{
        \\  "request_limits": {
        \\    "max_uri_length": 4096,
        \\    "max_body_size": 2097152,
        \\    "max_json_depth": 10,
        \\    "endpoints": [
        \\      { "path": "/api/upload", "max_body_size": 10485760 }
        \\    ]
        \\  }
        \\}
    ;

    var config = try WafConfig.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 4096), config.request_limits.max_uri_length);
    try std.testing.expectEqual(@as(u32, 2097152), config.request_limits.max_body_size);
    try std.testing.expectEqual(@as(u8, 10), config.request_limits.max_json_depth);
    try std.testing.expectEqual(@as(usize, 1), config.request_limits.endpoints.len);

    // Test getMaxBodySize
    try std.testing.expectEqual(@as(u32, 10485760), config.getMaxBodySize("/api/upload"));
    try std.testing.expectEqual(@as(u32, 2097152), config.getMaxBodySize("/api/other"));
}

test "WafConfig: parse with logging config" {
    const json =
        \\{
        \\  "logging": {
        \\    "log_blocked": true,
        \\    "log_allowed": true,
        \\    "log_near_limit": false,
        \\    "near_limit_threshold": 0.9
        \\  }
        \\}
    ;

    var config = try WafConfig.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expect(config.logging.log_blocked);
    try std.testing.expect(config.logging.log_allowed);
    try std.testing.expect(!config.logging.log_near_limit);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), config.logging.near_limit_threshold, 0.001);
}

test "WafConfig: parse full example config" {
    const json =
        \\{
        \\  "enabled": true,
        \\  "shadow_mode": false,
        \\  "rate_limits": [
        \\    {
        \\      "name": "login_bruteforce",
        \\      "path": "/api/auth/login",
        \\      "method": "POST",
        \\      "limit": { "requests": 10, "period_sec": 60 },
        \\      "burst": 3,
        \\      "by": "ip",
        \\      "action": "block"
        \\    },
        \\    {
        \\      "name": "api_global",
        \\      "path": "/api/*",
        \\      "limit": { "requests": 1000, "period_sec": 60 },
        \\      "burst": 100,
        \\      "by": "ip",
        \\      "action": "block"
        \\    }
        \\  ],
        \\  "slowloris": {
        \\    "header_timeout_ms": 5000,
        \\    "body_timeout_ms": 30000,
        \\    "min_bytes_per_sec": 100,
        \\    "max_conns_per_ip": 50
        \\  },
        \\  "request_limits": {
        \\    "max_uri_length": 2048,
        \\    "max_body_size": 1048576,
        \\    "max_json_depth": 20,
        \\    "endpoints": [
        \\      { "path": "/api/upload", "max_body_size": 10485760 }
        \\    ]
        \\  },
        \\  "trusted_proxies": ["10.0.0.0/8", "172.16.0.0/12"],
        \\  "logging": {
        \\    "log_blocked": true,
        \\    "log_allowed": false,
        \\    "log_near_limit": true,
        \\    "near_limit_threshold": 0.8
        \\  }
        \\}
    ;

    var config = try WafConfig.parse(std.testing.allocator, json);
    defer config.deinit();

    // Verify everything parsed correctly
    try std.testing.expect(config.enabled);
    try std.testing.expect(!config.shadow_mode);
    try std.testing.expectEqual(@as(usize, 2), config.rate_limits.len);
    try std.testing.expectEqual(@as(usize, 2), config.trusted_proxies.len);
    try std.testing.expectEqual(@as(usize, 1), config.request_limits.endpoints.len);

    // Test findRateLimitRule - should match login rule (more specific)
    const login_rule = config.findRateLimitRule("/api/auth/login", .POST);
    try std.testing.expect(login_rule != null);
    try std.testing.expectEqualStrings("login_bruteforce", login_rule.?.name);

    // Test findRateLimitRule - should match global API rule
    const api_rule = config.findRateLimitRule("/api/users", .GET);
    try std.testing.expect(api_rule != null);
    try std.testing.expectEqualStrings("api_global", api_rule.?.name);

    // Test findRateLimitRule - no match
    const no_rule = config.findRateLimitRule("/static/file.js", .GET);
    try std.testing.expect(no_rule == null);
}

test "WafConfig: validation catches zero requests" {
    const json =
        \\{
        \\  "rate_limits": [
        \\    {
        \\      "name": "test",
        \\      "path": "/api/*",
        \\      "limit": { "requests": 0, "period_sec": 60 }
        \\    }
        \\  ]
        \\}
    ;

    const result = WafConfig.parse(std.testing.allocator, json);
    try std.testing.expectError(error.ZeroRequests, result);
}

test "WafConfig: validation catches zero period" {
    const json =
        \\{
        \\  "rate_limits": [
        \\    {
        \\      "name": "test",
        \\      "path": "/api/*",
        \\      "limit": { "requests": 10, "period_sec": 0 }
        \\    }
        \\  ]
        \\}
    ;

    const result = WafConfig.parse(std.testing.allocator, json);
    try std.testing.expectError(error.ZeroPeriod, result);
}

test "WafConfig: validation catches invalid near_limit_threshold" {
    const json =
        \\{
        \\  "logging": {
        \\    "near_limit_threshold": 1.5
        \\  }
        \\}
    ;

    const result = WafConfig.parse(std.testing.allocator, json);
    try std.testing.expectError(error.InvalidNearLimitThreshold, result);
}

test "WafConfig: invalid JSON returns error" {
    const json = \\{invalid json}
    ;

    const result = WafConfig.parse(std.testing.allocator, json);
    try std.testing.expectError(error.InvalidJson, result);
}

test "WafConfig: invalid trusted proxy returns error" {
    const json =
        \\{
        \\  "trusted_proxies": ["invalid-cidr"]
        \\}
    ;

    const result = WafConfig.parse(std.testing.allocator, json);
    try std.testing.expectError(error.InvalidTrustedProxy, result);
}

test "WafConfig: defaults are sensible" {
    var config = WafConfig{};

    // All defaults should pass validation
    try config.validate();

    try std.testing.expect(config.enabled);
    try std.testing.expect(!config.shadow_mode);
    try std.testing.expectEqual(@as(u32, 5000), config.slowloris.header_timeout_ms);
    try std.testing.expectEqual(@as(u32, 2048), config.request_limits.max_uri_length);
    try std.testing.expect(config.logging.log_blocked);
}
