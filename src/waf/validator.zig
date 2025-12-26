/// Request Validation - Size and Structure Limits
///
/// High-performance request validation for the Web Application Firewall.
/// Validates URI length, body size, cookie size, and JSON structure.
///
/// Design Philosophy (TigerBeetle-inspired):
/// - Zero allocation on hot path
/// - Streaming JSON validation (constant memory)
/// - Early rejection of invalid requests
/// - Pre-body validation for fast fail
///
/// Validation Flow:
/// 1. validateRequest() - Check URI, Content-Length, headers before body
/// 2. validateJsonStream() - Incremental JSON validation during body receipt
///
/// Memory Characteristics:
/// - ValidatorConfig: ~20 bytes (inline configuration)
/// - JsonState: 4 bytes (streaming state)
/// - No heap allocation during validation
const std = @import("std");

const state = @import("state.zig");
pub const Reason = state.Reason;

// =============================================================================
// Validation Result
// =============================================================================

/// Result of a validation check
pub const ValidationResult = struct {
    /// Whether the request passed validation
    valid: bool,
    /// Reason for rejection (null if valid)
    reason: ?Reason,

    /// Create a passing result
    pub inline fn pass() ValidationResult {
        return .{ .valid = true, .reason = null };
    }

    /// Create a failing result with reason
    pub inline fn fail(reason: Reason) ValidationResult {
        return .{ .valid = false, .reason = reason };
    }

    /// Check if validation passed
    pub inline fn isValid(self: ValidationResult) bool {
        return self.valid;
    }

    /// Check if validation failed
    pub inline fn isInvalid(self: ValidationResult) bool {
        return !self.valid;
    }
};

// =============================================================================
// Validator Configuration
// =============================================================================

/// Configuration for request validation limits
/// Mirrors RequestLimitsConfig from config.zig with additional fields
/// for comprehensive validation
pub const ValidatorConfig = struct {
    /// Maximum URI length in bytes (default 2KB)
    max_uri_length: u32 = 2048,

    /// Maximum number of query parameters
    max_query_params: u16 = 50,

    /// Maximum header value length (default 8KB)
    max_header_value_length: u32 = 8192,

    /// Maximum cookie size in bytes (default 4KB)
    max_cookie_size: u32 = 4096,

    /// Maximum request body size in bytes (default 1MB)
    max_body_size: u32 = 1_048_576,

    /// Maximum JSON nesting depth
    max_json_depth: u8 = 20,

    /// Maximum JSON keys (protects against hash collision attacks)
    max_json_keys: u16 = 1000,

    /// Create configuration from RequestLimitsConfig
    pub fn fromRequestLimits(limits: anytype) ValidatorConfig {
        return .{
            .max_uri_length = limits.max_uri_length,
            .max_body_size = limits.max_body_size,
            .max_json_depth = limits.max_json_depth,
        };
    }

    comptime {
        // Ensure config fits in a cache line
        std.debug.assert(@sizeOf(ValidatorConfig) <= 64);
    }
};

// =============================================================================
// JSON Streaming State
// =============================================================================

/// State for streaming JSON validation
/// Tracks nesting depth and key count with constant memory usage
/// Properly handles string escapes to avoid false positives
pub const JsonState = struct {
    /// Current nesting depth (objects and arrays)
    depth: u8 = 0,

    /// Total keys seen (colons outside strings)
    key_count: u16 = 0,

    /// Currently inside a string literal
    in_string: bool = false,

    /// Next character is escaped (preceded by backslash)
    escape_next: bool = false,

    /// Reset state for new request
    pub inline fn reset(self: *JsonState) void {
        self.* = .{};
    }

    /// Check if parsing is complete (all brackets closed)
    pub inline fn isComplete(self: *const JsonState) bool {
        return self.depth == 0 and !self.in_string;
    }

    comptime {
        // Ensure state is minimal (6 bytes with alignment)
        std.debug.assert(@sizeOf(JsonState) <= 8);
    }
};

// =============================================================================
// Request Validator
// =============================================================================

/// Validates HTTP requests against configured limits
/// Zero allocation, suitable for hot path
pub const RequestValidator = struct {
    /// Configuration reference (immutable during request processing)
    config: *const ValidatorConfig,

    /// Initialize validator with configuration
    pub fn init(config: *const ValidatorConfig) RequestValidator {
        return .{ .config = config };
    }

    // =========================================================================
    // Pre-Body Validation
    // =========================================================================

    /// Validate request before reading body
    /// Fast path for rejecting obviously invalid requests
    ///
    /// Checks:
    /// - URI length
    /// - Content-Length vs max body size
    /// - Cookie size
    ///
    /// Parameters:
    /// - uri: Request URI (path + query string)
    /// - content_length: Value of Content-Length header (null if not present)
    /// - headers: Iterator or slice of header name-value pairs
    ///
    /// Returns: ValidationResult with pass/fail and reason
    pub fn validateRequest(
        self: *const RequestValidator,
        uri: ?[]const u8,
        content_length: ?u32,
        headers: anytype,
    ) ValidationResult {
        // Check URI length
        if (uri) |u| {
            if (u.len > self.config.max_uri_length) {
                return ValidationResult.fail(.invalid_request);
            }

            // Count query parameters if present
            if (std.mem.indexOf(u8, u, "?")) |query_start| {
                const query = u[query_start + 1 ..];
                const param_count = countQueryParams(query);
                if (param_count > self.config.max_query_params) {
                    return ValidationResult.fail(.invalid_request);
                }
            }
        }

        // Check Content-Length against max body size
        if (content_length) |len| {
            if (len > self.config.max_body_size) {
                return ValidationResult.fail(.body_too_large);
            }
        }

        // Check headers for cookie size
        return self.validateHeaders(headers);
    }

    /// Validate specific headers
    /// Separate method for when you only have headers to check
    fn validateHeaders(self: *const RequestValidator, headers: anytype) ValidationResult {
        const HeadersType = @TypeOf(headers);
        const type_info = @typeInfo(HeadersType);

        // Handle different header representations
        switch (type_info) {
            .pointer => |ptr| {
                // Slice of header pairs
                if (ptr.size == .Slice) {
                    for (headers) |header| {
                        const result = self.checkHeader(header[0], header[1]);
                        if (result.isInvalid()) return result;
                    }
                }
            },
            .@"struct" => {
                // Iterator-like struct with next() method
                if (@hasDecl(HeadersType, "next")) {
                    var iter = headers;
                    while (iter.next()) |header| {
                        const result = self.checkHeader(header.name, header.value);
                        if (result.isInvalid()) return result;
                    }
                }
            },
            .null => {
                // No headers to check
            },
            else => {
                // Unsupported type - skip header validation
            },
        }

        return ValidationResult.pass();
    }

    /// Check a single header against limits
    fn checkHeader(self: *const RequestValidator, name: []const u8, value: []const u8) ValidationResult {
        // Check header value length
        if (value.len > self.config.max_header_value_length) {
            return ValidationResult.fail(.invalid_request);
        }

        // Check cookie size specifically
        if (std.ascii.eqlIgnoreCase(name, "cookie")) {
            if (value.len > self.config.max_cookie_size) {
                return ValidationResult.fail(.invalid_request);
            }
        }

        return ValidationResult.pass();
    }

    // =========================================================================
    // Streaming JSON Validation
    // =========================================================================

    /// Validate a chunk of JSON data
    /// Call repeatedly as body chunks arrive
    /// Maintains state between calls for streaming validation
    ///
    /// Features:
    /// - Constant memory (O(1) space)
    /// - Proper string escape handling
    /// - Depth limiting (prevents stack exhaustion attacks)
    /// - Key counting (prevents hash collision attacks)
    ///
    /// Parameters:
    /// - chunk: Bytes of JSON data
    /// - json_state: Mutable state tracking depth and keys
    ///
    /// Returns: ValidationResult - pass to continue, fail to reject
    pub fn validateJsonStream(
        self: *const RequestValidator,
        chunk: []const u8,
        json_state: *JsonState,
    ) ValidationResult {
        for (chunk) |byte| {
            // Handle escape sequences in strings
            if (json_state.escape_next) {
                json_state.escape_next = false;
                continue;
            }

            // Handle string state
            if (json_state.in_string) {
                switch (byte) {
                    '\\' => json_state.escape_next = true,
                    '"' => json_state.in_string = false,
                    else => {},
                }
                continue;
            }

            // Not in string - check structural characters
            switch (byte) {
                '"' => json_state.in_string = true,

                '{', '[' => {
                    // Use saturating add to prevent overflow
                    json_state.depth +|= 1;

                    if (json_state.depth > self.config.max_json_depth) {
                        return ValidationResult.fail(.json_depth);
                    }
                },

                '}', ']' => {
                    // Use saturating subtract to prevent underflow
                    json_state.depth -|= 1;
                },

                ':' => {
                    // Colon indicates a key-value pair in object
                    json_state.key_count +|= 1;

                    if (json_state.key_count > self.config.max_json_keys) {
                        return ValidationResult.fail(.json_depth);
                    }
                },

                else => {},
            }
        }

        return ValidationResult.pass();
    }

    /// Validate complete JSON body (non-streaming)
    /// Convenience method for when entire body is available
    pub fn validateJsonBody(self: *const RequestValidator, body: []const u8) ValidationResult {
        var json_state = JsonState{};
        return self.validateJsonStream(body, &json_state);
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Count query parameters in a query string
/// Parameters are separated by & and contain key=value or just key
fn countQueryParams(query: []const u8) u16 {
    if (query.len == 0) return 0;

    var count: u16 = 1; // At least one param if query exists
    for (query) |c| {
        if (c == '&') {
            count +|= 1;
        }
    }
    return count;
}

// =============================================================================
// Tests
// =============================================================================

test "ValidationResult: pass and fail" {
    const pass_result = ValidationResult.pass();
    try std.testing.expect(pass_result.isValid());
    try std.testing.expect(!pass_result.isInvalid());
    try std.testing.expect(pass_result.reason == null);

    const fail_result = ValidationResult.fail(.body_too_large);
    try std.testing.expect(!fail_result.isValid());
    try std.testing.expect(fail_result.isInvalid());
    try std.testing.expectEqual(Reason.body_too_large, fail_result.reason.?);
}

test "ValidatorConfig: default values" {
    const config = ValidatorConfig{};
    try std.testing.expectEqual(@as(u32, 2048), config.max_uri_length);
    try std.testing.expectEqual(@as(u32, 4096), config.max_cookie_size);
    try std.testing.expectEqual(@as(u32, 1_048_576), config.max_body_size);
    try std.testing.expectEqual(@as(u8, 20), config.max_json_depth);
    try std.testing.expectEqual(@as(u16, 1000), config.max_json_keys);
}

test "JsonState: size and reset" {
    var json_state = JsonState{ .depth = 5, .key_count = 100, .in_string = true };
    try std.testing.expect(@sizeOf(JsonState) <= 8);

    json_state.reset();
    try std.testing.expectEqual(@as(u8, 0), json_state.depth);
    try std.testing.expectEqual(@as(u16, 0), json_state.key_count);
    try std.testing.expect(!json_state.in_string);
}

test "JsonState: isComplete" {
    var json_state = JsonState{};
    try std.testing.expect(json_state.isComplete());

    json_state.depth = 1;
    try std.testing.expect(!json_state.isComplete());

    json_state.depth = 0;
    json_state.in_string = true;
    try std.testing.expect(!json_state.isComplete());
}

test "RequestValidator: init" {
    const config = ValidatorConfig{};
    const validator = RequestValidator.init(&config);
    try std.testing.expectEqual(&config, validator.config);
}

test "RequestValidator: validateRequest passes valid URI" {
    const config = ValidatorConfig{ .max_uri_length = 100 };
    const validator = RequestValidator.init(&config);

    const result = validator.validateRequest("/api/users", null, null);
    try std.testing.expect(result.isValid());
}

test "RequestValidator: validateRequest rejects long URI" {
    const config = ValidatorConfig{ .max_uri_length = 10 };
    const validator = RequestValidator.init(&config);

    const result = validator.validateRequest("/api/users/very/long/path", null, null);
    try std.testing.expect(result.isInvalid());
    try std.testing.expectEqual(Reason.invalid_request, result.reason.?);
}

test "RequestValidator: validateRequest rejects large body" {
    const config = ValidatorConfig{ .max_body_size = 1000 };
    const validator = RequestValidator.init(&config);

    const result = validator.validateRequest("/api/upload", 5000, null);
    try std.testing.expect(result.isInvalid());
    try std.testing.expectEqual(Reason.body_too_large, result.reason.?);
}

test "RequestValidator: validateRequest allows valid body size" {
    const config = ValidatorConfig{ .max_body_size = 10000 };
    const validator = RequestValidator.init(&config);

    const result = validator.validateRequest("/api/upload", 5000, null);
    try std.testing.expect(result.isValid());
}

test "RequestValidator: validateJsonStream passes simple JSON" {
    const config = ValidatorConfig{};
    const validator = RequestValidator.init(&config);

    var json_state = JsonState{};
    const json = "{\"name\": \"test\", \"value\": 123}";

    const result = validator.validateJsonStream(json, &json_state);
    try std.testing.expect(result.isValid());
    try std.testing.expectEqual(@as(u8, 0), json_state.depth); // All closed
    try std.testing.expectEqual(@as(u16, 2), json_state.key_count); // Two keys
}

test "RequestValidator: validateJsonStream rejects deep nesting" {
    const config = ValidatorConfig{ .max_json_depth = 3 };
    const validator = RequestValidator.init(&config);

    var json_state = JsonState{};
    const json = "{{{{"; // 4 levels of nesting

    const result = validator.validateJsonStream(json, &json_state);
    try std.testing.expect(result.isInvalid());
    try std.testing.expectEqual(Reason.json_depth, result.reason.?);
}

test "RequestValidator: validateJsonStream rejects too many keys" {
    const config = ValidatorConfig{ .max_json_keys = 3 };
    const validator = RequestValidator.init(&config);

    var json_state = JsonState{};
    const json = "{\"a\":1,\"b\":2,\"c\":3,\"d\":4}"; // 4 keys

    const result = validator.validateJsonStream(json, &json_state);
    try std.testing.expect(result.isInvalid());
    try std.testing.expectEqual(Reason.json_depth, result.reason.?);
}

test "RequestValidator: validateJsonStream handles strings correctly" {
    const config = ValidatorConfig{ .max_json_depth = 2 };
    const validator = RequestValidator.init(&config);

    var json_state = JsonState{};
    // Braces inside strings should be ignored
    const json = "{\"data\": \"{{{{{{{\"}";

    const result = validator.validateJsonStream(json, &json_state);
    try std.testing.expect(result.isValid());
    try std.testing.expectEqual(@as(u8, 0), json_state.depth);
}

test "RequestValidator: validateJsonStream handles escapes" {
    const config = ValidatorConfig{};
    const validator = RequestValidator.init(&config);

    var json_state = JsonState{};
    // Escaped quote should not end string
    const json = "{\"data\": \"test\\\"quote\"}";

    const result = validator.validateJsonStream(json, &json_state);
    try std.testing.expect(result.isValid());
    try std.testing.expect(!json_state.in_string);
}

test "RequestValidator: validateJsonStream chunked" {
    const config = ValidatorConfig{};
    const validator = RequestValidator.init(&config);

    var json_state = JsonState{};

    // Send JSON in chunks
    var result = validator.validateJsonStream("{\"na", &json_state);
    try std.testing.expect(result.isValid());
    try std.testing.expectEqual(@as(u8, 1), json_state.depth);

    result = validator.validateJsonStream("me\":\"te", &json_state);
    try std.testing.expect(result.isValid());
    try std.testing.expect(json_state.in_string);

    result = validator.validateJsonStream("st\"}", &json_state);
    try std.testing.expect(result.isValid());
    try std.testing.expectEqual(@as(u8, 0), json_state.depth);
    try std.testing.expect(!json_state.in_string);
}

test "RequestValidator: validateJsonBody convenience" {
    const config = ValidatorConfig{};
    const validator = RequestValidator.init(&config);

    const result = validator.validateJsonBody("{\"key\": [1, 2, 3]}");
    try std.testing.expect(result.isValid());
}

test "RequestValidator: validateJsonStream handles nested arrays" {
    const config = ValidatorConfig{ .max_json_depth = 5 };
    const validator = RequestValidator.init(&config);

    var json_state = JsonState{};
    const json = "{\"arr\": [[1, 2], [3, 4]]}";

    const result = validator.validateJsonStream(json, &json_state);
    try std.testing.expect(result.isValid());
    try std.testing.expectEqual(@as(u8, 0), json_state.depth);
}

test "countQueryParams: basic" {
    try std.testing.expectEqual(@as(u16, 0), countQueryParams(""));
    try std.testing.expectEqual(@as(u16, 1), countQueryParams("a=1"));
    try std.testing.expectEqual(@as(u16, 2), countQueryParams("a=1&b=2"));
    try std.testing.expectEqual(@as(u16, 3), countQueryParams("a=1&b=2&c=3"));
}

test "RequestValidator: validateRequest rejects too many query params" {
    const config = ValidatorConfig{ .max_query_params = 2 };
    const validator = RequestValidator.init(&config);

    const result = validator.validateRequest("/api?a=1&b=2&c=3", null, null);
    try std.testing.expect(result.isInvalid());
    try std.testing.expectEqual(Reason.invalid_request, result.reason.?);
}

test "RequestValidator: validateRequest allows valid query params" {
    const config = ValidatorConfig{ .max_query_params = 5 };
    const validator = RequestValidator.init(&config);

    const result = validator.validateRequest("/api?a=1&b=2", null, null);
    try std.testing.expect(result.isValid());
}
