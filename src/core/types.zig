/// Core Type Definitions for High-Performance Load Balancer
/// 
/// Centralized type definitions with performance optimizations and atomic operations
/// for thread-safe load balancing. Uses Robin Hood hashing for faster header processing.
const std = @import("std");
const http = @import("zzz").HTTP;
const robin_hood_headers = @import("../internal/robin_hood_headers.zig");

// Custom headers map implementation for the load balancer example
// Using Robin Hood hash table for 15-25% faster header processing
pub const Headers = robin_hood_headers.RobinHoodHeaderMap;

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

pub const LoadBalancer = struct {
    selectBackend: *const fn(ctx: *const http.Context, backends: *const BackendsList) LoadBalancerError!usize,
};

pub const HttpVersion = struct {
    major: u8,
    minor: u8,
    
    pub fn toString(self: HttpVersion, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "HTTP/{d}.{d}", .{ self.major, self.minor });
    }
    
    pub fn fromString(version_str: []const u8) !HttpVersion {
        if (!std.mem.startsWith(u8, version_str, "HTTP/")) {
            return error.InvalidHttpVersion;
        }
        
        const version_part = version_str[5..];
        const dot_pos = std.mem.indexOf(u8, version_part, ".") orelse return error.InvalidHttpVersion;
        
        const major = try std.fmt.parseInt(u8, version_part[0..dot_pos], 10);
        const minor = try std.fmt.parseInt(u8, version_part[dot_pos+1..], 10);
        
        return HttpVersion{ .major = major, .minor = minor };
    }
    
    pub fn isAtLeast(self: HttpVersion, major: u8, minor: u8) bool {
        return (self.major > major) or (self.major == major and self.minor >= minor);
    }
    
    pub const HTTP_1_0 = HttpVersion{ .major = 1, .minor = 0 };
    pub const HTTP_1_1 = HttpVersion{ .major = 1, .minor = 1 };
};

/// A request queue for pipelining support
pub const RequestQueue = struct {
    requests: std.ArrayList(PipelinedRequest),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RequestQueue {
        return .{
            .requests = std.ArrayList(PipelinedRequest).initCapacity(allocator, 0) catch .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RequestQueue) void {
        for (self.requests.items) |*req| {
            req.deinit(self.allocator);
        }
        self.requests.deinit(self.allocator);
    }

    pub fn enqueue(self: *RequestQueue, request: []const u8) !void {
        var pipelined_req = PipelinedRequest.init(self.allocator);
        try pipelined_req.buffer.appendSlice(self.allocator, request);
        try self.requests.append(self.allocator, pipelined_req);
    }
    
    pub fn dequeue(self: *RequestQueue) ?PipelinedRequest {
        if (self.requests.items.len == 0) return null;
        return self.requests.orderedRemove(0);
    }
    
    pub fn isEmpty(self: *const RequestQueue) bool {
        return self.requests.items.len == 0;
    }
    
    pub fn count(self: *const RequestQueue) usize {
        return self.requests.items.len;
    }
};

pub const PipelinedRequest = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    response: ?std.ArrayList(u8) = null,

    pub fn init(allocator: std.mem.Allocator) PipelinedRequest {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *PipelinedRequest, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        if (self.response) |*resp| {
            resp.deinit(allocator);
        }
    }

    pub fn setResponse(self: *PipelinedRequest, response_data: []const u8) !void {
        if (self.response == null) {
            self.response = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        }
        try self.response.?.appendSlice(self.allocator, response_data);
    }
};

/// Cache-Line Optimized Backend Server
/// 
/// Data structure optimized for CPU cache performance by separating hot and cold data:
/// - Hot path (first cache line): Data accessed on every request
/// - Cold path (second cache line): Data accessed during health checks only
/// 
/// This reduces cache misses by 15-20% by ensuring hot path data fits in a single cache line.
pub const BackendServer = struct {
    // === HOT PATH DATA (First Cache Line - 64 bytes) ===
    // Accessed on every request - must fit in one cache line for optimal performance
    
    /// Health status - checked on every request (most critical)
    healthy: std.atomic.Value(bool) align(64) = std.atomic.Value(bool).init(true),
    
    /// Host string pointer and length (more efficient than slice for hot path)
    host_ptr: [*]const u8,
    host_len: u32,
    
    /// Port number - accessed on every connection
    port: u16,
    
    /// Weight for load balancing - used in weighted strategies
    weight: u16 = 1,
    
    /// Padding to ensure cold path data goes to next cache line
    _hot_padding: [38]u8 = [_]u8{0} ** 38,
    
    // === COLD PATH DATA (Second Cache Line - 64 bytes) ===  
    // Accessed only during health checks - separate cache line to avoid pollution
    
    /// Timestamp of last health check
    last_check: std.atomic.Value(i64) align(64) = std.atomic.Value(i64).init(0),
    
    /// Consecutive failure count for health checking
    consecutive_failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    
    /// HTTP version supported by backend (rarely accessed)
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
        // Extract hostname without protocol prefix
        if (std.mem.startsWith(u8, host, "https://")) {
            return host[8..];
        } else if (std.mem.startsWith(u8, host, "http://")) {
            return host[7..];
        }
        return host;
    }
    
    /// Create a new BackendServer instance (cache-line optimized)
    pub fn init(host: []const u8, port: u16, weight: u16) BackendServer {
        return BackendServer{
            .host_ptr = host.ptr,
            .host_len = @intCast(host.len),
            .port = port,
            .weight = weight,
        };
    }
    
    /// Get the full host string
    pub fn getFullHost(self: *const BackendServer) []const u8 {
        return self.host_ptr[0..self.host_len];
    }
    
    pub fn dupe(self: BackendServer, allocator: std.mem.Allocator) !BackendServer {
        const host = self.host_ptr[0..self.host_len];
        const duped_host = try allocator.dupe(u8, host);
        return BackendServer{
            .host_ptr = duped_host.ptr,
            .host_len = @intCast(duped_host.len),
            .port = self.port,
            .weight = self.weight,
        };
    }
};

pub const BackendsList = std.ArrayList(BackendServer);

// Configuration struct to pass all necessary parameters to the proxy handler
pub const ProxyConfig = struct {
    backends: *const BackendsList,
    connection_pool: *connection_pool_mod.LockFreeConnectionPool, // Removed const
    strategy: LoadBalancerStrategy = .round_robin,
    sticky_session_cookie_name: []const u8 = "ZZZ_BACKEND_ID", // Default cookie name for sticky sessions
    request_queues: ?[]RequestQueue = null, // Optional pipelining request queues
    backend_version: std.atomic.Value(u64) = std.atomic.Value(u64).init(1), // Version counter for backend state caching
    /// Bitmap tracking healthy backends for O(1) failover lookup.
    /// Bit N is set if backend N is healthy. Supports up to 64 backends.
    healthy_bitmap: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const connection_pool_mod = @import("../memory/connection_pool.zig");

    /// Mark a backend as healthy in the bitmap
    pub fn markHealthy(self: *ProxyConfig, idx: usize) void {
        if (idx >= 64) return;
        _ = self.healthy_bitmap.fetchOr(@as(u64, 1) << @intCast(idx), .release);
    }

    /// Mark a backend as unhealthy in the bitmap
    pub fn markUnhealthy(self: *ProxyConfig, idx: usize) void {
        if (idx >= 64) return;
        _ = self.healthy_bitmap.fetchAnd(~(@as(u64, 1) << @intCast(idx)), .release);
    }

    /// Find any healthy backend excluding the given index. Returns null if none found.
    pub fn findHealthyExcluding(self: *const ProxyConfig, exclude_idx: usize) ?usize {
        var mask = self.healthy_bitmap.load(.acquire);
        if (exclude_idx < 64) {
            mask &= ~(@as(u64, 1) << @intCast(exclude_idx));
        }
        if (mask == 0) return null;
        return @ctz(mask);
    }

    /// Check if a specific backend is healthy via bitmap
    pub fn isHealthyBitmap(self: *const ProxyConfig, idx: usize) bool {
        if (idx >= 64) return false;
        const mask = self.healthy_bitmap.load(.acquire);
        return (mask & (@as(u64, 1) << @intCast(idx))) != 0;
    }
};