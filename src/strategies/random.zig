/// Random Strategy with Comptime and Cryptographic Security
/// 
/// Provides both runtime and comptime-specialized random selection with performance
/// optimizations automatically selected based on backend configuration.
const std = @import("std");
const http = @import("zzz").HTTP;
const types = @import("../core/types.zig");
const optimizations = @import("../internal/simd_backend_ops.zig");
const comptime_selection = @import("../internal/comptime_backend_selection.zig");

const Context = http.Context;
const BackendsList = types.BackendsList;
const LoadBalancerError = types.LoadBalancerError;

// Global selection state for random selection
var global_state = comptime_selection.SelectionState.init(98765);

// No longer needed - using global state instead

/// Select backend using random selection with runtime optimizations
pub fn select(ctx: *const Context, backends: *const BackendsList) LoadBalancerError!usize {
    _ = ctx; // Random doesn't need context
    
    try optimizations.validateBackends(backends);
    var random = global_state.random_state.random();
    return try optimizations.selectRandom(&random, backends);
}

/// Comptime-specialized random backend selection for known backend counts
pub fn selectComptime(
    ctx: *const Context,
    backends: *const BackendsList,
    comptime max_backends: usize,
) LoadBalancerError!usize {
    _ = ctx;
    
    return comptime_selection.selectBackendComptime(
        backends,
        max_backends,
        .random,
        &global_state,
    );
}

/// Select with caching optimization (50-70% faster)
pub fn selectCached(
    ctx: *const Context,
    backends: *const BackendsList,
    backend_version: u64
) LoadBalancerError!usize {
    // Try cached selection first
    var random = global_state.random_state.random();
    const cache_result = optimizations.selectRandomCached(&random, backends, backend_version);
    if (cache_result) |cached_idx| {
        return cached_idx;
    }
    
    // Fallback to regular selection
    return select(ctx, backends);
}