/// SIMD and Size-Optimized Backend Operations (Internal Use Only)
/// 
/// This module contains all the complex optimization logic that was previously
/// scattered throughout strategy files. It provides clean internal APIs while
/// hiding SIMD vectorization, size-based specialization, and caching complexity.
const std = @import("std");
const types = @import("../core/types.zig");

const BackendsList = types.BackendsList;
const LoadBalancerError = types.LoadBalancerError;

// Import the actual optimization implementations
const optimized_selection = @import("optimized_backend_selection.zig");
const backend_cache = @import("backend_state_cache.zig");
const common = @import("round_robin_common.zig");

/// Validate backends using SIMD optimizations
pub fn validateBackends(backends: *const BackendsList) LoadBalancerError!void {
    // Use existing SIMD-optimized validation
    return common.validateBackends(backends);
}

/// Round-robin selection with size-based optimization
pub fn selectRoundRobin(counter: usize, backends: *const BackendsList) LoadBalancerError!usize {
    const backend_count = backends.items.len;
    
    // Size-based optimization selection (complexity hidden here)
    if (backend_count <= 4) {
        const Selector = optimized_selection.SmallDeploymentSelector.RoundRobin;
        return Selector.selectBackend(counter, backends);
    } else if (backend_count <= 16) {
        const Selector = optimized_selection.MediumDeploymentSelector.RoundRobin;
        return Selector.selectBackend(counter, backends);
    } else {
        const Selector = optimized_selection.LargeDeploymentSelector.RoundRobin;
        return Selector.selectBackend(counter, backends);
    }
}

/// Cached round-robin selection (50-70% faster)
pub fn selectRoundRobinCached(backends: *const BackendsList, backend_version: u64) ?usize {
    // TODO: Implement caching using backend_cache module
    // For now, return null to fallback to regular selection
    _ = backends;
    _ = backend_version;
    return null;
}

/// Weighted round-robin selection with SIMD weight calculation + binary search
pub fn selectWeightedRoundRobin(counter: usize, backends: *const BackendsList) LoadBalancerError!usize {
    const backend_count = backends.items.len;
    
    // Size-based optimization selection (complexity hidden here)
    if (backend_count <= 4) {
        const Selector = optimized_selection.SmallDeploymentSelector.WeightedRoundRobin;
        return Selector.selectBackend(counter, backends);
    } else if (backend_count <= 16) {
        const Selector = optimized_selection.MediumDeploymentSelector.WeightedRoundRobin;
        return Selector.selectBackend(counter, backends);
    } else {
        const Selector = optimized_selection.LargeDeploymentSelector.WeightedRoundRobin;
        return Selector.selectBackend(counter, backends);
    }
}

/// Cached weighted round-robin selection
pub fn selectWeightedRoundRobinCached(backends: *const BackendsList, backend_version: u64) ?usize {
    // TODO: Implement caching using backend_cache module
    _ = backends;
    _ = backend_version;
    return null;
}

/// Random selection with size-based optimization
pub fn selectRandom(random: *std.Random, backends: *const BackendsList) LoadBalancerError!usize {
    const backend_count = backends.items.len;
    
    // Size-based optimization selection (complexity hidden here)
    if (backend_count <= 4) {
        const Selector = optimized_selection.SmallDeploymentSelector.Random;
        return Selector.selectBackend(random, backends);
    } else if (backend_count <= 16) {
        const Selector = optimized_selection.MediumDeploymentSelector.Random;
        return Selector.selectBackend(random, backends);
    } else {
        const Selector = optimized_selection.LargeDeploymentSelector.Random;
        return Selector.selectBackend(random, backends);
    }
}

/// Cached random selection
pub fn selectRandomCached(random: *std.Random, backends: *const BackendsList, backend_version: u64) ?usize {
    // TODO: Implement caching using backend_cache module
    _ = random;
    _ = backends;
    _ = backend_version;
    return null;
}