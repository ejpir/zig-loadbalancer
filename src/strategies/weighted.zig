/// Simplified Weighted Round-Robin Strategy
/// 
/// Clean and efficient weighted selection with smart optimizations built-in.
const std = @import("std");
const http = @import("zzz").HTTP;
const types = @import("../core/types.zig");

const Context = http.Context;
const BackendsList = types.BackendsList;
const LoadBalancerError = types.LoadBalancerError;

// Simple atomic weights for weighted round-robin
var current_weights: [32]std.atomic.Value(i32) = blk: {
    var weights: [32]std.atomic.Value(i32) = undefined;
    for (&weights) |*weight| {
        weight.* = std.atomic.Value(i32).init(0);
    }
    break :blk weights;
};

/// Simple weighted round-robin selection
pub fn select(ctx: *const Context, backends: *const BackendsList) LoadBalancerError!usize {
    _ = ctx;
    
    const backend_count = backends.items.len;
    if (backend_count == 0) return error.NoBackendsAvailable;
    if (backend_count > 32) return error.BackendSelectionFailed; // Safety limit
    
    // Collect healthy backends and calculate total weight
    var healthy_indices: [32]usize = undefined;
    var healthy_count: usize = 0;
    var total_weight: i32 = 0;
    
    for (backends.items, 0..) |backend, i| {
        if (backend.isHealthy()) {
            healthy_indices[healthy_count] = i;
            healthy_count += 1;
            total_weight += @as(i32, @intCast(backend.weight));
        }
    }
    
    if (healthy_count == 0) return error.NoHealthyBackends;
    if (healthy_count == 1) return healthy_indices[0];
    
    // Find backend with highest current_weight + weight
    var max_combined_weight: i32 = std.math.minInt(i32);
    var selected_idx: usize = 0;
    
    for (0..healthy_count) |i| {
        const backend_idx = healthy_indices[i];
        const weight = @as(i32, @intCast(backends.items[backend_idx].weight));
        const current_weight = current_weights[backend_idx].fetchAdd(weight, .acq_rel);
        const combined = current_weight + weight;
        
        if (combined > max_combined_weight) {
            max_combined_weight = combined;
            selected_idx = backend_idx;
        }
    }
    
    // Reduce selected backend's weight by total weight
    _ = current_weights[selected_idx].fetchSub(total_weight, .acq_rel);
    
    return selected_idx;
}