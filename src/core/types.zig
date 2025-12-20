/// Core Type Definitions for Load Balancer
///
/// Minimal type definitions for the multi-process load balancer.
const std = @import("std");

pub const LoadBalancerStrategy = enum {
    round_robin,
    weighted_round_robin,
    random,
    sticky,

    /// Comptime string map for O(1) strategy lookup
    const strategy_map = std.StaticStringMap(LoadBalancerStrategy).initComptime(.{
        .{ "round-robin", .round_robin },
        .{ "weighted-round-robin", .weighted_round_robin },
        .{ "random", .random },
        .{ "sticky", .sticky },
    });

    pub fn fromString(str: []const u8) !LoadBalancerStrategy {
        return strategy_map.get(str) orelse error.InvalidStrategy;
    }
};

pub const LoadBalancerError = error{
    NoBackendsAvailable,
    NoHealthyBackends,
    BackendSelectionFailed,
};

pub const HttpVersion = struct {
    major: u8,
    minor: u8,

    pub fn isAtLeast(self: HttpVersion, major: u8, minor: u8) bool {
        return (self.major > major) or
            (self.major == major and self.minor >= minor);
    }

    pub const HTTP_1_0 = HttpVersion{ .major = 1, .minor = 0 };
    pub const HTTP_1_1 = HttpVersion{ .major = 1, .minor = 1 };
};

/// Cache-Line Optimized Backend Server
///
/// Data structure optimized for CPU cache performance by separating hot and cold data.
pub const BackendServer = struct {
    // === HOT PATH DATA (First Cache Line - 64 bytes) ===
    /// Align to cache line boundary to prevent false sharing across threads
    healthy: std.atomic.Value(bool) align(64) = std.atomic.Value(bool).init(true),

    /// Host string pointer and length
    host_ptr: [*]const u8,
    host_len: u32,

    /// Port number
    port: u16,

    /// Weight for load balancing
    weight: u16 = 1,

    /// Padding to ensure cold path data goes to next cache line
    _hot_padding: [38]u8 = [_]u8{0} ** 38,

    // === COLD PATH DATA (Second Cache Line - 64 bytes) ===
    /// Timestamp of last health check
    last_check: std.atomic.Value(i64) align(64) = std.atomic.Value(i64).init(0),

    /// Consecutive failure count
    consecutive_failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// HTTP version supported by backend
    supported_version: HttpVersion = HttpVersion.HTTP_1_1,

    /// Padding to complete cache line
    _cold_padding: [47]u8 = [_]u8{0} ** 47,

    pub fn isHealthy(self: *const BackendServer) bool {
        return self.healthy.load(.acquire);
    }

    pub fn isHttps(self: *const BackendServer) bool {
        const host = self.host_ptr[0..self.host_len];
        return self.port == 443 or std.mem.startsWith(u8, host, "https://");
    }

    pub fn getHost(self: *const BackendServer) []const u8 {
        const host = self.host_ptr[0..self.host_len];
        if (std.mem.startsWith(u8, host, "https://")) {
            return host[8..];
        } else if (std.mem.startsWith(u8, host, "http://")) {
            return host[7..];
        }
        return host;
    }

    pub fn init(host: []const u8, port: u16, weight: u16) BackendServer {
        return BackendServer{
            .host_ptr = host.ptr,
            .host_len = @intCast(host.len),
            .port = port,
            .weight = weight,
        };
    }

    /// Get full host string (inlined - hot path, simple slice)
    pub inline fn getFullHost(self: *const BackendServer) []const u8 {
        return self.host_ptr[0..self.host_len];
    }
};

pub const BackendsList = std.ArrayList(BackendServer);
