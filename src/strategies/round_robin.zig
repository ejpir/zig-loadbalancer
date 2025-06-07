/// Simplified Optimized Round Robin - Single Implementation with Smart Defaults
/// 
/// This replaces all complex optimization paths with one intelligent implementation
/// that automatically adapts while keeping the code simple and maintainable.
const std = @import("std");
const http = @import("zzz").HTTP;
const types = @import("../core/types.zig");

const Context = http.Context;
const BackendsList = types.BackendsList;
const LoadBalancerError = types.LoadBalancerError;

// Single global counter - simple and effective
var global_counter = std.atomic.Value(usize).init(0);

/// Single optimized selection function that handles all cases efficiently
pub fn select(ctx: *const Context, backends: *const BackendsList) LoadBalancerError!usize {
    _ = ctx;
    
    const backend_count = backends.items.len;
    if (backend_count == 0) return error.NoBackendsAvailable;
    
    // Get next counter value
    const counter = global_counter.fetchAdd(1, .acq_rel);
    
    // Smart selection based on backend count - no complex branching
    return switch (backend_count) {
        1 => selectSingle(backends),
        2 => selectDual(backends, counter),
        else => selectMultiple(backends, counter),
    };
}

/// Ultra-fast single backend (comptime specialized automatically)
inline fn selectSingle(backends: *const BackendsList) LoadBalancerError!usize {
    return if (backends.items[0].isHealthy()) 0 else error.NoHealthyBackends;
}

/// Optimized dual backend selection (most common case)
inline fn selectDual(backends: *const BackendsList, counter: usize) LoadBalancerError!usize {
    const healthy0 = backends.items[0].isHealthy();
    const healthy1 = backends.items[1].isHealthy();
    
    if (!healthy0 and !healthy1) return error.NoHealthyBackends;
    if (!healthy0) return 1;
    if (!healthy1) return 0;
    
    // Both healthy - simple round robin with bit flip (faster than modulo)
    return counter & 1;
}

/// General case for 3+ backends - simple and fast
fn selectMultiple(backends: *const BackendsList, counter: usize) LoadBalancerError!usize {
    const backend_count = backends.items.len;
    
    // Simple round robin with health checking
    var attempts: usize = 0;
    while (attempts < backend_count) : (attempts += 1) {
        const idx = (counter + attempts) % backend_count;
        if (backends.items[idx].isHealthy()) {
            return idx;
        }
    }
    
    return error.NoHealthyBackends;
}