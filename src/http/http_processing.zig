/// Clean HTTP Processing Interface
/// 
/// Provides simple interface for HTTP operations while hiding complex
/// optimization implementations (SIMD headers, zero-copy buffers, etc.)
const std = @import("std");
const types = @import("../core/types.zig");
const RequestContext = @import("../memory/request_context.zig").RequestContext;

// Import complex optimizations (hidden from public API)
const optimized_headers = @import("../internal/optimized_headers.zig");
const zero_copy = @import("../internal/zero_copy_buffer.zig");
const optimized_formatter = @import("../internal/optimized_request_formatter.zig");

/// Detect MIME type with SIMD optimizations (complexity hidden)
pub fn detectMimeType(content_type: []const u8) @import("zzz").HTTP.Mime {
    return optimized_headers.detectMimeTypeOptimized(content_type);
}

/// Process headers with strategy-specific optimizations (complexity hidden)
pub fn processHeaders(
    comptime strategy: types.LoadBalancerStrategy,
    parsed: anytype,
    allocator: std.mem.Allocator
) !std.ArrayList([2][]const u8) {
    // Strategy-specific header processing (complexity hidden)
    const HeaderProcessor = comptime if (strategy == .sticky) blk: {
        // Sticky sessions need Set-Cookie headers
        break :blk optimized_headers.generateHeaderProcessor(&[_]optimized_headers.CommonHeaders{
            .cache_control,
            .etag,
            .transfer_encoding,
            .set_cookie,
        });
    } else blk: {
        // Other strategies use basic proxy headers
        break :blk optimized_headers.ProxyHeaderProcessor;
    };
    
    return HeaderProcessor.processHeaders(parsed, allocator);
}

/// Build zero-copy HTTP request (complexity hidden)
pub fn buildZeroCopyRequest(
    ctx: *RequestContext,
    method: []const u8,
    uri: []const u8,
    headers: anytype,
    body: []const u8,
    backend_host: []const u8,
    backend_port: u16
) ![]u8 {
    _ = headers; // Headers will be processed in future iteration
    // Zero-copy processing complexity hidden here
    var processor = zero_copy.ZeroCopyProcessor.init(ctx.allocator(), ""); // Empty for now
    defer processor.deinit();
    
    // For now, use simple request building (TODO: implement zero-copy)
    return ctx.printf(
        "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: keep-alive\r\n\r\n{s}",
        .{ method, uri, backend_host, backend_port, body }
    );
}

/// Add standard proxy headers (Via, X-Response-Time, etc.)
pub fn addProxyHeaders(
    headers: *std.ArrayList([2][]const u8),
    req_ctx: *RequestContext,
    duration_ms: i64
) !void {
    // Add Via header for HTTP transparency
    const via_value = try req_ctx.printf("1.1 zzz-load-balancer", .{});
    try headers.append(.{ "Via", via_value });
    
    // Add response time header
    const response_time = try req_ctx.printf("{d}ms", .{duration_ms});
    try headers.append(.{ "X-Response-Time", response_time });
}