/// WAF Structured Event Logging
///
/// Provides structured JSON logging for WAF events including blocked requests,
/// rate limit warnings, and configuration changes.
///
/// Design Philosophy (TigerBeetle-inspired):
/// - Zero allocation on hot path - fixed-size buffers only
/// - Structured JSON output for machine parsing
/// - Human-readable formatting for debugging
/// - Configurable log levels via LoggingConfig
///
/// Output Format: JSON Lines (one event per line)
/// ```json
/// {"timestamp":1703635200,"event_type":"blocked","client_ip":"192.168.1.1","method":"POST","path":"/api/login","rule_name":"login_bruteforce","reason":"rate_limit"}
/// ```
const std = @import("std");

const config = @import("config.zig");
pub const LoggingConfig = config.LoggingConfig;
pub const HttpMethod = config.HttpMethod;

const state = @import("state.zig");
pub const Reason = state.Reason;

// =============================================================================
// Constants
// =============================================================================

/// Maximum length of formatted IP string "255.255.255.255" = 15 chars
pub const MAX_IP_STRING_LEN: usize = 15;

/// Maximum length of a single log line (generous for JSON overhead)
pub const MAX_LOG_LINE_LEN: usize = 2048;

/// Maximum path length to include in logs (truncated if longer)
pub const MAX_LOG_PATH_LEN: usize = 256;

/// Maximum rule name length to include in logs
pub const MAX_LOG_RULE_NAME_LEN: usize = 64;

// =============================================================================
// EventType - Classification of WAF Events
// =============================================================================

/// Type of WAF event for structured logging
pub const EventType = enum {
    /// Request was blocked by WAF
    blocked,
    /// Request was allowed (verbose logging)
    allowed,
    /// Request is approaching rate limit threshold
    near_limit,
    /// WAF configuration was reloaded
    config_reload,

    /// Convert to JSON string representation
    pub fn toJsonString(self: EventType) []const u8 {
        return switch (self) {
            .blocked => "blocked",
            .allowed => "allowed",
            .near_limit => "near_limit",
            .config_reload => "config_reload",
        };
    }
};

// =============================================================================
// WafEvent - Structured Event Data
// =============================================================================

/// Represents a single WAF event for logging
/// All string fields are slices into external memory (no allocation)
pub const WafEvent = struct {
    /// Unix timestamp (seconds since epoch)
    timestamp: i64,
    /// Type of event
    event_type: EventType,
    /// Client IP address as string (e.g., "192.168.1.1")
    client_ip: []const u8,
    /// HTTP method (e.g., "GET", "POST")
    method: []const u8,
    /// Request path (may be truncated)
    path: []const u8,
    /// Name of the rule that triggered (if applicable)
    rule_name: ?[]const u8 = null,
    /// Human-readable reason for the decision
    reason: ?[]const u8 = null,
    /// Remaining rate limit tokens (if applicable)
    tokens_remaining: ?u32 = null,
    /// New config epoch (for config_reload events)
    config_epoch: ?u64 = null,

    /// Format event into a fixed-size buffer as JSON
    /// Returns a slice of the buffer containing the formatted output
    pub fn format(self: *const WafEvent, buffer: []u8) []const u8 {
        var pos: usize = 0;

        // Start JSON object
        if (pos + 1 > buffer.len) return buffer[0..0];
        buffer[pos] = '{';
        pos += 1;

        // timestamp
        const ts_prefix = "\"timestamp\":";
        if (pos + ts_prefix.len > buffer.len) return buffer[0..pos];
        @memcpy(buffer[pos..][0..ts_prefix.len], ts_prefix);
        pos += ts_prefix.len;
        pos = appendInt(buffer, pos, self.timestamp);

        // event_type
        pos = appendJsonField(buffer, pos, "event_type", self.event_type.toJsonString());

        // client_ip
        pos = appendJsonField(buffer, pos, "client_ip", self.client_ip);

        // method
        pos = appendJsonField(buffer, pos, "method", self.method);

        // path (escaped)
        pos = appendJsonFieldEscaped(buffer, pos, "path", self.path);

        // rule_name (optional)
        if (self.rule_name) |name| {
            pos = appendJsonFieldEscaped(buffer, pos, "rule_name", name);
        }

        // reason (optional)
        if (self.reason) |r| {
            pos = appendJsonFieldEscaped(buffer, pos, "reason", r);
        }

        // tokens_remaining (optional)
        if (self.tokens_remaining) |tokens| {
            const tok_prefix = ",\"tokens_remaining\":";
            if (pos + tok_prefix.len <= buffer.len) {
                @memcpy(buffer[pos..][0..tok_prefix.len], tok_prefix);
                pos += tok_prefix.len;
                pos = appendInt(buffer, pos, tokens);
            }
        }

        // config_epoch (optional)
        if (self.config_epoch) |epoch| {
            const epoch_prefix = ",\"config_epoch\":";
            if (pos + epoch_prefix.len <= buffer.len) {
                @memcpy(buffer[pos..][0..epoch_prefix.len], epoch_prefix);
                pos += epoch_prefix.len;
                pos = appendInt(buffer, pos, epoch);
            }
        }

        // Close JSON object and add newline
        if (pos + 2 <= buffer.len) {
            buffer[pos] = '}';
            pos += 1;
            buffer[pos] = '\n';
            pos += 1;
        }

        return buffer[0..pos];
    }

    /// Create a blocked event
    pub fn blocked(
        client_ip: []const u8,
        method: []const u8,
        path: []const u8,
        rule_name: ?[]const u8,
        reason: Reason,
        tokens_remaining: ?u32,
    ) WafEvent {
        return .{
            .timestamp = getCurrentTimestamp(),
            .event_type = .blocked,
            .client_ip = client_ip,
            .method = method,
            .path = truncatePath(path),
            .rule_name = rule_name,
            .reason = reason.description(),
            .tokens_remaining = tokens_remaining,
        };
    }

    /// Create an allowed event
    pub fn allowed(
        client_ip: []const u8,
        method: []const u8,
        path: []const u8,
        tokens_remaining: ?u32,
    ) WafEvent {
        return .{
            .timestamp = getCurrentTimestamp(),
            .event_type = .allowed,
            .client_ip = client_ip,
            .method = method,
            .path = truncatePath(path),
            .tokens_remaining = tokens_remaining,
        };
    }

    /// Create a near-limit warning event
    pub fn nearLimit(
        client_ip: []const u8,
        method: []const u8,
        path: []const u8,
        rule_name: ?[]const u8,
        tokens_remaining: u32,
    ) WafEvent {
        return .{
            .timestamp = getCurrentTimestamp(),
            .event_type = .near_limit,
            .client_ip = client_ip,
            .method = method,
            .path = truncatePath(path),
            .rule_name = rule_name,
            .tokens_remaining = tokens_remaining,
        };
    }

    /// Create a config reload event
    pub fn configReload(epoch: u64) WafEvent {
        return .{
            .timestamp = getCurrentTimestamp(),
            .event_type = .config_reload,
            .client_ip = "-",
            .method = "-",
            .path = "-",
            .config_epoch = epoch,
        };
    }
};

// =============================================================================
// EventLogger - Central Logging Coordinator
// =============================================================================

/// Central event logger for WAF
/// Coordinates logging based on configuration settings
pub const EventLogger = struct {
    /// Pointer to logging configuration
    log_config: *const LoggingConfig,
    /// Optional file handle for persistent logging
    file: ?std.fs.File,
    /// Buffer for IP formatting
    ip_buffer: [MAX_IP_STRING_LEN + 1]u8 = undefined,
    /// Buffer for log line formatting
    line_buffer: [MAX_LOG_LINE_LEN]u8 = undefined,

    /// Initialize an event logger
    pub fn init(logging_config: *const LoggingConfig) EventLogger {
        return .{
            .log_config = logging_config,
            .file = null,
        };
    }

    /// Initialize with a file for persistent logging
    pub fn initWithFile(logging_config: *const LoggingConfig, file: std.fs.File) EventLogger {
        return .{
            .log_config = logging_config,
            .file = file,
        };
    }

    /// Log a blocked request event
    /// Only logs if log_blocked is enabled in config
    pub fn logBlocked(
        self: *EventLogger,
        client_ip: u32,
        method: HttpMethod,
        path: []const u8,
        rule_name: ?[]const u8,
        reason: Reason,
        tokens_remaining: ?u32,
    ) void {
        if (!self.log_config.log_blocked) return;

        const ip_str = self.formatIpInternal(client_ip);
        const event = WafEvent.blocked(
            ip_str,
            method.toString(),
            path,
            rule_name,
            reason,
            tokens_remaining,
        );

        self.emitEvent(&event);
    }

    /// Log an allowed request event
    /// Only logs if log_allowed is enabled in config
    pub fn logAllowed(
        self: *EventLogger,
        client_ip: u32,
        method: HttpMethod,
        path: []const u8,
        tokens_remaining: ?u32,
    ) void {
        if (!self.log_config.log_allowed) return;

        const ip_str = self.formatIpInternal(client_ip);
        const event = WafEvent.allowed(
            ip_str,
            method.toString(),
            path,
            tokens_remaining,
        );

        self.emitEvent(&event);
    }

    /// Log a near-limit warning event
    /// Only logs if log_near_limit is enabled and tokens are below threshold
    pub fn logNearLimit(
        self: *EventLogger,
        client_ip: u32,
        method: HttpMethod,
        path: []const u8,
        rule_name: ?[]const u8,
        tokens_remaining: u32,
        burst_capacity: u32,
    ) void {
        if (!self.log_config.log_near_limit) return;

        // Check if we're near the limit threshold
        if (burst_capacity == 0) return;

        const usage_ratio: f32 = 1.0 - (@as(f32, @floatFromInt(tokens_remaining)) /
            @as(f32, @floatFromInt(burst_capacity)));

        if (usage_ratio < self.log_config.near_limit_threshold) return;

        const ip_str = self.formatIpInternal(client_ip);
        const event = WafEvent.nearLimit(
            ip_str,
            method.toString(),
            path,
            rule_name,
            tokens_remaining,
        );

        self.emitEvent(&event);
    }

    /// Log a configuration reload event
    /// Always logs when called (config reloads are important)
    pub fn logConfigReload(self: *EventLogger, epoch: u64) void {
        const event = WafEvent.configReload(epoch);
        self.emitEvent(&event);
    }

    /// Internal: emit an event to configured outputs
    fn emitEvent(self: *EventLogger, event: *const WafEvent) void {
        const formatted = event.format(&self.line_buffer);

        // Write to file if configured
        if (self.file) |file| {
            _ = file.write(formatted) catch {};
        }

        // Also write to stderr for visibility (development/debugging)
        const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
        _ = stderr.write(formatted) catch {};
    }

    /// Internal: format IP to internal buffer
    fn formatIpInternal(self: *EventLogger, ip: u32) []const u8 {
        return formatIpToBuffer(ip, &self.ip_buffer);
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Format IPv4 address (u32) to string representation
/// Returns a fixed-size array with the formatted IP
pub fn formatIp(ip: u32) [MAX_IP_STRING_LEN]u8 {
    var buffer: [MAX_IP_STRING_LEN]u8 = [_]u8{0} ** MAX_IP_STRING_LEN;
    _ = formatIpToBuffer(ip, &buffer);
    return buffer;
}

/// Format IPv4 address to a provided buffer
/// Returns slice of the buffer containing the formatted string
pub fn formatIpToBuffer(ip: u32, buffer: []u8) []const u8 {
    if (buffer.len < MAX_IP_STRING_LEN) return buffer[0..0];

    const formatted = std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
        @as(u8, @truncate(ip >> 24)),
        @as(u8, @truncate(ip >> 16)),
        @as(u8, @truncate(ip >> 8)),
        @as(u8, @truncate(ip)),
    }) catch return buffer[0..0];

    return formatted;
}

/// Get current Unix timestamp in seconds
pub fn getCurrentTimestamp() i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch {
        return 0;
    };
    return ts.sec;
}

/// Truncate path to maximum log length
fn truncatePath(path: []const u8) []const u8 {
    if (path.len <= MAX_LOG_PATH_LEN) return path;
    return path[0..MAX_LOG_PATH_LEN];
}

/// Append an integer to buffer, return new position
fn appendInt(buffer: []u8, pos: usize, value: anytype) usize {
    var int_buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&int_buf, "{d}", .{value}) catch return pos;
    if (pos + formatted.len > buffer.len) return pos;
    @memcpy(buffer[pos..][0..formatted.len], formatted);
    return pos + formatted.len;
}

/// Append a JSON string field (with comma prefix): ,"key":"value"
fn appendJsonField(buffer: []u8, pos: usize, key: []const u8, value: []const u8) usize {
    // Calculate required space: ,"{key}":"{value}"
    const overhead = 6; // ,"":""
    const required = overhead + key.len + value.len;
    if (pos + required > buffer.len) return pos;

    var p = pos;

    buffer[p] = ',';
    p += 1;
    buffer[p] = '"';
    p += 1;
    @memcpy(buffer[p..][0..key.len], key);
    p += key.len;
    buffer[p] = '"';
    p += 1;
    buffer[p] = ':';
    p += 1;
    buffer[p] = '"';
    p += 1;
    @memcpy(buffer[p..][0..value.len], value);
    p += value.len;
    buffer[p] = '"';
    p += 1;

    return p;
}

/// Append a JSON string field with escaping for special characters
fn appendJsonFieldEscaped(buffer: []u8, pos: usize, key: []const u8, value: []const u8) usize {
    // First, try simple path if no escaping needed
    var needs_escape = false;
    for (value) |c| {
        if (c == '"' or c == '\\' or c < 0x20) {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return appendJsonField(buffer, pos, key, value);
    }

    // Need to escape - build escaped value
    var p = pos;

    // ,"{key}":"
    const prefix_overhead = 5; // ,":"
    if (p + prefix_overhead + key.len > buffer.len) return pos;

    buffer[p] = ',';
    p += 1;
    buffer[p] = '"';
    p += 1;
    @memcpy(buffer[p..][0..key.len], key);
    p += key.len;
    buffer[p] = '"';
    p += 1;
    buffer[p] = ':';
    p += 1;
    buffer[p] = '"';
    p += 1;

    // Write escaped value
    for (value) |c| {
        switch (c) {
            '"' => {
                if (p + 2 > buffer.len) break;
                buffer[p] = '\\';
                p += 1;
                buffer[p] = '"';
                p += 1;
            },
            '\\' => {
                if (p + 2 > buffer.len) break;
                buffer[p] = '\\';
                p += 1;
                buffer[p] = '\\';
                p += 1;
            },
            '\n' => {
                if (p + 2 > buffer.len) break;
                buffer[p] = '\\';
                p += 1;
                buffer[p] = 'n';
                p += 1;
            },
            '\r' => {
                if (p + 2 > buffer.len) break;
                buffer[p] = '\\';
                p += 1;
                buffer[p] = 'r';
                p += 1;
            },
            '\t' => {
                if (p + 2 > buffer.len) break;
                buffer[p] = '\\';
                p += 1;
                buffer[p] = 't';
                p += 1;
            },
            else => {
                if (c < 0x20) {
                    // Control characters - escape as \u00XX
                    if (p + 6 > buffer.len) break;
                    const hex = std.fmt.bufPrint(buffer[p..][0..6], "\\u00{x:0>2}", .{c}) catch break;
                    p += hex.len;
                } else {
                    if (p + 1 > buffer.len) break;
                    buffer[p] = c;
                    p += 1;
                }
            },
        }
    }

    // Close quote
    if (p + 1 <= buffer.len) {
        buffer[p] = '"';
        p += 1;
    }

    return p;
}

// =============================================================================
// Tests
// =============================================================================

test "EventType: toJsonString" {
    try std.testing.expectEqualStrings("blocked", EventType.blocked.toJsonString());
    try std.testing.expectEqualStrings("allowed", EventType.allowed.toJsonString());
    try std.testing.expectEqualStrings("near_limit", EventType.near_limit.toJsonString());
    try std.testing.expectEqualStrings("config_reload", EventType.config_reload.toJsonString());
}

test "formatIp: basic formatting" {
    const ip1: u32 = 0xC0A80101; // 192.168.1.1
    var buffer1: [MAX_IP_STRING_LEN]u8 = undefined;
    const result1 = formatIpToBuffer(ip1, &buffer1);
    try std.testing.expectEqualStrings("192.168.1.1", result1);

    const ip2: u32 = 0x7F000001; // 127.0.0.1
    var buffer2: [MAX_IP_STRING_LEN]u8 = undefined;
    const result2 = formatIpToBuffer(ip2, &buffer2);
    try std.testing.expectEqualStrings("127.0.0.1", result2);

    const ip3: u32 = 0x0A000001; // 10.0.0.1
    var buffer3: [MAX_IP_STRING_LEN]u8 = undefined;
    const result3 = formatIpToBuffer(ip3, &buffer3);
    try std.testing.expectEqualStrings("10.0.0.1", result3);
}

test "formatIp: edge cases" {
    const ip_zero: u32 = 0x00000000; // 0.0.0.0
    var buffer1: [MAX_IP_STRING_LEN]u8 = undefined;
    const result1 = formatIpToBuffer(ip_zero, &buffer1);
    try std.testing.expectEqualStrings("0.0.0.0", result1);

    const ip_max: u32 = 0xFFFFFFFF; // 255.255.255.255
    var buffer2: [MAX_IP_STRING_LEN]u8 = undefined;
    const result2 = formatIpToBuffer(ip_max, &buffer2);
    try std.testing.expectEqualStrings("255.255.255.255", result2);
}

test "WafEvent: format JSON" {
    const event = WafEvent{
        .timestamp = 1703635200,
        .event_type = .blocked,
        .client_ip = "192.168.1.1",
        .method = "POST",
        .path = "/api/login",
        .rule_name = "login_bruteforce",
        .reason = "rate limit exceeded",
        .tokens_remaining = 0,
    };

    var buffer: [MAX_LOG_LINE_LEN]u8 = undefined;
    const output = event.format(&buffer);

    // Verify it's valid JSON structure
    try std.testing.expect(std.mem.startsWith(u8, output, "{"));
    try std.testing.expect(std.mem.endsWith(u8, output, "}\n"));

    // Verify key fields are present
    try std.testing.expect(std.mem.indexOf(u8, output, "\"timestamp\":1703635200") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"event_type\":\"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"client_ip\":\"192.168.1.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"method\":\"POST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"path\":\"/api/login\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"rule_name\":\"login_bruteforce\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"reason\":\"rate limit exceeded\"") != null);
}

test "WafEvent: blocked constructor" {
    const event = WafEvent.blocked(
        "10.0.0.1",
        "GET",
        "/api/resource",
        "rate_limit_rule",
        .rate_limit,
        100,
    );

    try std.testing.expectEqual(EventType.blocked, event.event_type);
    try std.testing.expectEqualStrings("10.0.0.1", event.client_ip);
    try std.testing.expectEqualStrings("GET", event.method);
    try std.testing.expectEqualStrings("/api/resource", event.path);
    try std.testing.expectEqualStrings("rate_limit_rule", event.rule_name.?);
    try std.testing.expectEqualStrings("rate limit exceeded", event.reason.?);
    try std.testing.expectEqual(@as(?u32, 100), event.tokens_remaining);
}

test "WafEvent: allowed constructor" {
    const event = WafEvent.allowed(
        "192.168.0.1",
        "POST",
        "/api/upload",
        5000,
    );

    try std.testing.expectEqual(EventType.allowed, event.event_type);
    try std.testing.expectEqualStrings("192.168.0.1", event.client_ip);
    try std.testing.expectEqualStrings("POST", event.method);
    try std.testing.expectEqualStrings("/api/upload", event.path);
    try std.testing.expect(event.rule_name == null);
    try std.testing.expect(event.reason == null);
    try std.testing.expectEqual(@as(?u32, 5000), event.tokens_remaining);
}

test "WafEvent: nearLimit constructor" {
    const event = WafEvent.nearLimit(
        "172.16.0.1",
        "GET",
        "/api/users",
        "api_rate_limit",
        500,
    );

    try std.testing.expectEqual(EventType.near_limit, event.event_type);
    try std.testing.expectEqualStrings("172.16.0.1", event.client_ip);
    try std.testing.expectEqualStrings("api_rate_limit", event.rule_name.?);
    try std.testing.expectEqual(@as(?u32, 500), event.tokens_remaining);
}

test "WafEvent: configReload constructor" {
    const event = WafEvent.configReload(42);

    try std.testing.expectEqual(EventType.config_reload, event.event_type);
    try std.testing.expectEqualStrings("-", event.client_ip);
    try std.testing.expectEqualStrings("-", event.method);
    try std.testing.expectEqualStrings("-", event.path);
    try std.testing.expectEqual(@as(?u64, 42), event.config_epoch);
}

test "WafEvent: format handles special characters" {
    const event = WafEvent{
        .timestamp = 1703635200,
        .event_type = .blocked,
        .client_ip = "10.0.0.1",
        .method = "GET",
        .path = "/api/test?q=\"hello\"&b=\\world",
        .rule_name = null,
        .reason = "test\nreason",
    };

    var buffer: [MAX_LOG_LINE_LEN]u8 = undefined;
    const output = event.format(&buffer);

    // Verify special characters are escaped
    try std.testing.expect(std.mem.indexOf(u8, output, "\\\"hello\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\\\world") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test\\nreason") != null);
}

test "EventLogger: init" {
    const logging_config = LoggingConfig{};
    const logger = EventLogger.init(&logging_config);

    try std.testing.expect(logger.log_config == &logging_config);
    try std.testing.expect(logger.file == null);
}

test "EventLogger: respects log_blocked config" {
    var logging_config = LoggingConfig{};
    logging_config.log_blocked = false;

    var logger = EventLogger.init(&logging_config);

    // This should not log anything since log_blocked is false
    // (no crash is success, actual output verification would require more setup)
    logger.logBlocked(
        0xC0A80101,
        .POST,
        "/api/login",
        "test_rule",
        .rate_limit,
        0,
    );
}

test "EventLogger: respects log_allowed config" {
    var logging_config = LoggingConfig{};
    logging_config.log_allowed = false;

    var logger = EventLogger.init(&logging_config);

    // This should not log anything since log_allowed is false
    logger.logAllowed(
        0xC0A80101,
        .GET,
        "/api/users",
        5000,
    );
}

test "truncatePath: short paths unchanged" {
    const short_path = "/api/users";
    try std.testing.expectEqualStrings(short_path, truncatePath(short_path));
}

test "truncatePath: long paths truncated" {
    var long_path: [MAX_LOG_PATH_LEN + 100]u8 = undefined;
    for (&long_path) |*c| {
        c.* = 'a';
    }
    const truncated = truncatePath(&long_path);
    try std.testing.expectEqual(MAX_LOG_PATH_LEN, truncated.len);
}

test "appendJsonField: basic field" {
    var buffer: [100]u8 = undefined;
    const new_pos = appendJsonField(&buffer, 0, "key", "value");

    try std.testing.expectEqualStrings(",\"key\":\"value\"", buffer[0..new_pos]);
}

test "appendJsonFieldEscaped: no escaping needed" {
    var buffer: [100]u8 = undefined;
    const new_pos = appendJsonFieldEscaped(&buffer, 0, "key", "simple");

    try std.testing.expectEqualStrings(",\"key\":\"simple\"", buffer[0..new_pos]);
}

test "appendJsonFieldEscaped: escapes special chars" {
    var buffer: [100]u8 = undefined;
    const new_pos = appendJsonFieldEscaped(&buffer, 0, "key", "hello\"world");

    try std.testing.expectEqualStrings(",\"key\":\"hello\\\"world\"", buffer[0..new_pos]);
}

test "WafEvent: optional fields omitted when null" {
    const event = WafEvent{
        .timestamp = 1703635200,
        .event_type = .allowed,
        .client_ip = "10.0.0.1",
        .method = "GET",
        .path = "/health",
        .rule_name = null,
        .reason = null,
        .tokens_remaining = null,
    };

    var buffer: [MAX_LOG_LINE_LEN]u8 = undefined;
    const output = event.format(&buffer);

    // Optional fields should not be present
    try std.testing.expect(std.mem.indexOf(u8, output, "rule_name") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "reason") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "tokens_remaining") == null);
}

test "getCurrentTimestamp: returns reasonable value" {
    const ts = getCurrentTimestamp();
    // Should be after year 2020 (timestamp > 1577836800)
    try std.testing.expect(ts > 1577836800);
}
