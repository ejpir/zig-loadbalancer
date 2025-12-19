/// Unified Configuration for Load Balancer
///
/// Single source of truth for all configuration settings across both
/// single-process and multi-process architectures.
///
/// Design Philosophy:
/// - All configuration in one place
/// - Clear separation between config and runtime state
/// - Sensible defaults for all values
/// - Well-documented fields explaining purpose and trade-offs
const std = @import("std");
const types = @import("types.zig");

/// Backend server definition for configuration
/// This is the config-time representation of a backend.
pub const BackendDef = struct {
    /// Backend hostname or IP address (e.g., "localhost", "10.0.1.5")
    host: []const u8,

    /// Backend port number
    port: u16,

    /// Weight for weighted round-robin strategy
    /// Higher weights receive proportionally more traffic
    /// Default: 1 (all backends receive equal traffic)
    weight: u16 = 1,

    /// Use TLS for this backend
    use_tls: bool = false,
};

/// Complete Load Balancer Configuration
///
/// This struct contains all configuration settings needed to run the load balancer
/// in either single-process or multi-process mode.
///
/// Configuration Flow:
/// 1. Parse CLI args or read from file
/// 2. Build LoadBalancerConfig with desired settings
/// 3. Pass to main() or worker initialization
/// 4. Config is immutable after startup (no runtime changes)
pub const LoadBalancerConfig = struct {
    // ========================================================================
    // Server Settings
    // ========================================================================

    /// Host address to bind to
    /// - "0.0.0.0" = all interfaces (public access)
    /// - "127.0.0.1" = localhost only (local development)
    /// Default: "0.0.0.0" (listen on all interfaces)
    host: []const u8 = "0.0.0.0",

    /// Port to listen on for incoming requests
    /// Default: 8080 (common non-privileged HTTP port)
    port: u16 = 8080,

    /// Number of worker processes (multi-process mode only)
    /// - 0 = auto-detect (std.Thread.getCpuCount())
    /// - N = spawn exactly N workers
    /// Default: 0 (auto-detect CPU count)
    ///
    /// Trade-offs:
    /// - More workers = better CPU utilization but more memory
    /// - One worker per CPU core is usually optimal
    /// - Ignored in single-process mode
    worker_count: usize = 0,

    // ========================================================================
    // Backend Settings
    // ========================================================================

    /// List of backend servers to proxy requests to
    /// Must contain at least one backend at runtime
    /// Default: empty slice (must be provided)
    backends: []const BackendDef = &.{},

    /// Load balancing strategy for selecting backends
    /// - round_robin: Cycle through backends sequentially (fairest)
    /// - weighted_round_robin: Weighted distribution based on backend.weight
    /// - random: Random selection (simplest, good for stateless services)
    /// - sticky: Session-based (not yet implemented)
    /// Default: round_robin (most predictable)
    strategy: types.LoadBalancerStrategy = .round_robin,

    // ========================================================================
    // Health Check Settings
    // ========================================================================

    /// Number of consecutive failures before marking backend unhealthy
    /// Higher values = more tolerant of transient failures
    /// Lower values = faster failure detection
    /// Default: 3 (balanced between false positives and quick detection)
    unhealthy_threshold: u32 = 3,

    /// Number of consecutive successes before marking backend healthy again
    /// Higher values = more cautious recovery
    /// Lower values = faster recovery
    /// Default: 2 (quick recovery once backend responds)
    healthy_threshold: u32 = 2,

    /// Interval between active health probes in milliseconds
    /// Lower values = faster detection but more overhead
    /// Higher values = less overhead but slower detection
    /// Default: 5000ms (5 seconds - standard health check interval)
    probe_interval_ms: u64 = 5000,

    /// Timeout for health probe requests in milliseconds
    /// Should be much less than probe_interval_ms
    /// Default: 2000ms (2 seconds - allows time for slow backends)
    probe_timeout_ms: u64 = 2000,

    /// HTTP path to use for health checks
    /// Backends should return 2xx status for this endpoint when healthy
    /// Default: "/" (root path - most services support this)
    health_path: []const u8 = "/",

    // ========================================================================
    // Validation
    // ========================================================================

    /// Validate configuration settings
    /// Called after parsing CLI args or loading config file
    /// Returns error if configuration is invalid
    pub fn validate(self: *const LoadBalancerConfig) !void {
        // Validate port range
        if (self.port == 0) {
            return error.InvalidPort;
        }

        // Validate at least one backend
        if (self.backends.len == 0) {
            return error.NoBackends;
        }

        // Validate health check thresholds
        if (self.unhealthy_threshold == 0) {
            return error.InvalidUnhealthyThreshold;
        }
        if (self.healthy_threshold == 0) {
            return error.InvalidHealthyThreshold;
        }

        // Validate probe timeout is less than interval
        if (self.probe_timeout_ms >= self.probe_interval_ms) {
            return error.ProbeTimeoutTooLarge;
        }

        // Validate backend weights for weighted strategies
        if (self.strategy == .weighted_round_robin) {
            for (self.backends) |backend| {
                if (backend.weight == 0) {
                    return error.InvalidBackendWeight;
                }
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "LoadBalancerConfig: default values are valid" {
    const config = LoadBalancerConfig{
        .backends = &.{
            .{ .host = "localhost", .port = 9001 },
        },
    };
    try config.validate();
}

test "LoadBalancerConfig: validation catches no backends" {
    const config = LoadBalancerConfig{};
    try std.testing.expectError(error.NoBackends, config.validate());
}

test "LoadBalancerConfig: validation catches invalid port" {
    const config = LoadBalancerConfig{
        .port = 0,
        .backends = &.{
            .{ .host = "localhost", .port = 9001 },
        },
    };
    try std.testing.expectError(error.InvalidPort, config.validate());
}

test "LoadBalancerConfig: validation catches zero thresholds" {
    var config = LoadBalancerConfig{
        .unhealthy_threshold = 0,
        .backends = &.{
            .{ .host = "localhost", .port = 9001 },
        },
    };
    try std.testing.expectError(error.InvalidUnhealthyThreshold, config.validate());

    config.unhealthy_threshold = 3;
    config.healthy_threshold = 0;
    try std.testing.expectError(error.InvalidHealthyThreshold, config.validate());
}

test "LoadBalancerConfig: validation catches probe timeout >= interval" {
    const config = LoadBalancerConfig{
        .probe_interval_ms = 1000,
        .probe_timeout_ms = 1000,
        .backends = &.{
            .{ .host = "localhost", .port = 9001 },
        },
    };
    try std.testing.expectError(error.ProbeTimeoutTooLarge, config.validate());
}

test "LoadBalancerConfig: validation catches zero weight for weighted strategy" {
    const config = LoadBalancerConfig{
        .strategy = .weighted_round_robin,
        .backends = &.{
            .{ .host = "localhost", .port = 9001, .weight = 0 },
        },
    };
    try std.testing.expectError(error.InvalidBackendWeight, config.validate());
}

test "LoadBalancerConfig: valid weighted config passes" {
    const config = LoadBalancerConfig{
        .strategy = .weighted_round_robin,
        .backends = &.{
            .{ .host = "localhost", .port = 9001, .weight = 2 },
            .{ .host = "localhost", .port = 9002, .weight = 1 },
        },
    };
    try config.validate();
}

test "LoadBalancerConfig: custom values are preserved" {
    const config = LoadBalancerConfig{
        .host = "127.0.0.1",
        .port = 3000,
        .worker_count = 4,
        .strategy = .random,
        .unhealthy_threshold = 5,
        .healthy_threshold = 3,
        .probe_interval_ms = 10000,
        .probe_timeout_ms = 3000,
        .health_path = "/health",
        .backends = &.{
            .{ .host = "app1.local", .port = 8001, .weight = 2 },
            .{ .host = "app2.local", .port = 8002, .weight = 1 },
        },
    };

    try config.validate();

    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 3000), config.port);
    try std.testing.expectEqual(@as(usize, 4), config.worker_count);
    try std.testing.expectEqual(types.LoadBalancerStrategy.random, config.strategy);
    try std.testing.expectEqual(@as(u32, 5), config.unhealthy_threshold);
    try std.testing.expectEqual(@as(u32, 3), config.healthy_threshold);
    try std.testing.expectEqual(@as(u64, 10000), config.probe_interval_ms);
    try std.testing.expectEqual(@as(u64, 3000), config.probe_timeout_ms);
    try std.testing.expectEqualStrings("/health", config.health_path);
    try std.testing.expectEqual(@as(usize, 2), config.backends.len);
}

// ============================================================================
// RunMode Tests
// ============================================================================
// These tests are defined here but test functionality in main.zig
// The RunMode enum is exported from main.zig for use in both runtime and tests

test "BackendDef: can be created with default weight" {
    const backend = BackendDef{
        .host = "localhost",
        .port = 9001,
    };
    try std.testing.expectEqualStrings("localhost", backend.host);
    try std.testing.expectEqual(@as(u16, 9001), backend.port);
    try std.testing.expectEqual(@as(u16, 1), backend.weight);
}

test "BackendDef: can be created with custom weight" {
    const backend = BackendDef{
        .host = "localhost",
        .port = 9001,
        .weight = 5,
    };
    try std.testing.expectEqual(@as(u16, 5), backend.weight);
}
