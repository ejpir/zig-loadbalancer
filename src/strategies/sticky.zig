/// Sticky Session Strategy with Cookie-Based Affinity
/// 
/// Clean interface for session affinity with fallback to round-robin.
/// Uses context for cookie parsing and session management.
const std = @import("std");
const http = @import("zzz").HTTP;
const types = @import("../core/types.zig");
const round_robin = @import("round_robin.zig");

const Context = http.Context;
const BackendsList = types.BackendsList;
const LoadBalancerError = types.LoadBalancerError;

/// Configuration for sticky sessions (stored in context)
pub const StickySessionConfig = struct {
    cookie_name: []const u8,
};

/// Select backend using sticky session with hidden optimizations
pub fn select(ctx: *const Context, backends: *const BackendsList) LoadBalancerError!usize {
    // Get cookie name from context storage
    const config = ctx.storage.get(StickySessionConfig) orelse {
        // No config found - fallback to round-robin
        return round_robin.select(ctx, backends);
    };
    
    // Check for existing session cookie
    if (ctx.request.cookies.get(config.cookie_name)) |cookie_value| {
        // Parse backend index from cookie
        const backend_idx = std.fmt.parseInt(usize, cookie_value, 10) catch {
            // Invalid cookie - fallback to round-robin
            return round_robin.select(ctx, backends);
        };
        
        // Validate backend index and health
        if (backend_idx < backends.items.len and backends.items[backend_idx].isHealthy()) {
            return backend_idx;
        }
    }
    
    // No valid session - use round-robin to select new backend
    return round_robin.select(ctx, backends);
}