const std = @import("std");
const log = std.log.scoped(.@"round-robin-common");
const http = @import("zzz").HTTP;
const types = @import("../core/types.zig");
const BackendsList = types.BackendsList;

/// SIMD-optimized health checking for better assembly generation
/// Uses vectorized operations when beneficial, falls back to optimized scalar code for small counts
pub fn countHealthyBackends(backends: *const BackendsList) usize {
    const backend_count = backends.items.len;
    
    // For very small backend counts, use comptime-unrolled loops
    if (backend_count <= 4) {
        return countHealthyBackendsSmall(backends);
    }
    
    // For larger counts, use SIMD vectorization
    return countHealthyBackendsVectorized(backends);
}

/// Optimized for small backend counts (1-4 backends) using comptime unrolling
inline fn countHealthyBackendsSmall(backends: *const BackendsList) usize {
    const backend_count = backends.items.len;
    var count: usize = 0;
    
    // Comptime-unrolled loop for maximum efficiency
    comptime var i = 0;
    inline while (i < 4) : (i += 1) {
        if (i < backend_count) {
            if (backends.items[i].isHealthy()) {
                count += 1;
            }
        }
    }
    
    return count;
}

/// SIMD-vectorized health checking for larger backend counts
fn countHealthyBackendsVectorized(backends: *const BackendsList) usize {
    const backend_count = backends.items.len;
    
    // Determine optimal vector length for current CPU
    const vector_len = std.simd.suggestVectorLength(u8) orelse 8;
    const Vector = @Vector(vector_len, u8);
    
    var total: usize = 0;
    var i: usize = 0;
    
    // Process backends in vectorized chunks
    while (i + vector_len <= backend_count) : (i += vector_len) {
        var health_vector: Vector = undefined;
        
        // Load health status into vector (1 for healthy, 0 for unhealthy)
        comptime var j = 0;
        inline while (j < vector_len) : (j += 1) {
            health_vector[j] = if (backends.items[i + j].isHealthy()) 1 else 0;
        }
        
        // Sum all health values in the vector using SIMD reduction
        total += @reduce(.Add, health_vector);
    }
    
    // Handle remaining backends that don't fit in a full vector
    while (i < backend_count) : (i += 1) {
        if (backends.items[i].isHealthy()) {
            total += 1;
        }
    }
    
    return total;
}

/// Legacy scalar implementation (kept for reference and fallback)
pub fn countHealthyBackendsScalar(backends: *const BackendsList) usize {
    var healthy_count: usize = 0;
    for (backends.items) |backend| {
        if (backend.isHealthy()) {
            healthy_count += 1;
        }
    }
    return healthy_count;
}

/// SIMD-optimized total weight calculation for healthy backends
pub fn calculateTotalWeight(backends: *const BackendsList) u32 {
    const backend_count = backends.items.len;
    
    // For small counts, use unrolled loops
    if (backend_count <= 4) {
        return calculateTotalWeightSmall(backends);
    }
    
    // For larger counts, use SIMD when beneficial
    return calculateTotalWeightVectorized(backends);
}

/// Optimized weight calculation for small backend counts
inline fn calculateTotalWeightSmall(backends: *const BackendsList) u32 {
    const backend_count = backends.items.len;
    var total_weight: u32 = 0;
    
    // Comptime-unrolled loop
    comptime var i = 0;
    inline while (i < 4) : (i += 1) {
        if (i < backend_count) {
            if (backends.items[i].isHealthy()) {
                total_weight += backends.items[i].weight;
            }
        }
    }
    
    return total_weight;
}

/// SIMD-vectorized weight calculation for larger backend counts
fn calculateTotalWeightVectorized(backends: *const BackendsList) u32 {
    const backend_count = backends.items.len;
    
    // Use 32-bit vectors for weights (since weights are u16, but we want u32 math)
    const vector_len = std.simd.suggestVectorLength(u32) orelse 4;
    const Vector = @Vector(vector_len, u32);
    
    var total_weight: u32 = 0;
    var i: usize = 0;
    
    // Process in vectorized chunks
    while (i + vector_len <= backend_count) : (i += vector_len) {
        var weight_vector: Vector = @splat(0);
        
        // Load weights conditionally based on health status
        comptime var j = 0;
        inline while (j < vector_len) : (j += 1) {
            if (backends.items[i + j].isHealthy()) {
                weight_vector[j] = @as(u32, backends.items[i + j].weight);
            }
        }
        
        // Sum all weights in the vector
        total_weight += @reduce(.Add, weight_vector);
    }
    
    // Handle remaining backends
    while (i < backend_count) : (i += 1) {
        if (backends.items[i].isHealthy()) {
            total_weight += backends.items[i].weight;
        }
    }
    
    return total_weight;
}

/// Legacy scalar weight calculation (kept for reference)
pub fn calculateTotalWeightScalar(backends: *const BackendsList) u32 {
    var total_weight: u32 = 0;
    for (backends.items) |backend| {
        if (backend.isHealthy()) {
            total_weight += backend.weight;
        }
    }
    return total_weight;
}

/// SIMD-optimized search for the first healthy backend
pub fn findFirstHealthyBackend(backends: *const BackendsList) ?usize {
    const backend_count = backends.items.len;
    
    // For small counts, use unrolled search
    if (backend_count <= 4) {
        return findFirstHealthyBackendSmall(backends);
    }
    
    // For larger counts, use vectorized search when beneficial
    return findFirstHealthyBackendVectorized(backends);
}

/// Optimized first healthy backend search for small counts
inline fn findFirstHealthyBackendSmall(backends: *const BackendsList) ?usize {
    const backend_count = backends.items.len;
    
    // Comptime-unrolled search
    comptime var i = 0;
    inline while (i < 4) : (i += 1) {
        if (i < backend_count) {
            if (backends.items[i].isHealthy()) {
                return i;
            }
        }
    }
    
    return null;
}

/// SIMD-vectorized search for first healthy backend
fn findFirstHealthyBackendVectorized(backends: *const BackendsList) ?usize {
    const backend_count = backends.items.len;
    const vector_len = std.simd.suggestVectorLength(u8) orelse 8;
    const Vector = @Vector(vector_len, u8);
    
    var i: usize = 0;
    
    // Process in vectorized chunks to find any healthy backend quickly
    while (i + vector_len <= backend_count) : (i += vector_len) {
        var health_vector: Vector = undefined;
        
        // Load health status into vector
        comptime var j = 0;
        inline while (j < vector_len) : (j += 1) {
            health_vector[j] = if (backends.items[i + j].isHealthy()) 1 else 0;
        }
        
        // Check if any backend in this vector is healthy
        if (@reduce(.Or, health_vector != @as(Vector, @splat(0)))) {
            // Found a healthy backend in this chunk, search linearly within it
            var k: usize = 0;
            while (k < vector_len) : (k += 1) {
                if (backends.items[i + k].isHealthy()) {
                    return i + k;
                }
            }
        }
    }
    
    // Handle remaining backends
    while (i < backend_count) : (i += 1) {
        if (backends.items[i].isHealthy()) {
            return i;
        }
    }
    
    return null;
}

/// SIMD-optimized backend validation with enhanced error checking
pub fn validateBackends(backends: *const BackendsList) types.LoadBalancerError!void {
    const backend_count = backends.items.len;
    if (backend_count == 0) {
        return error.NoBackendsAvailable;
    }
    
    // Use optimized health counting
    const healthy_count = countHealthyBackends(backends);
    if (healthy_count == 0) {
        return error.NoHealthyBackends;
    }
}

/// Comptime-specialized validation for known backend counts
pub fn validateBackendsComptime(backends: *const BackendsList, comptime max_backends: usize) types.LoadBalancerError!void {
    const backend_count = backends.items.len;
    if (backend_count == 0) {
        return error.NoBackendsAvailable;
    }
    
    // Use comptime-optimized counting for small, known sizes
    if (comptime max_backends <= 4) {
        const healthy_count = countHealthyBackendsSmall(backends);
        if (healthy_count == 0) {
            return error.NoHealthyBackends;
        }
    } else {
        // Use regular optimized path
        const healthy_count = countHealthyBackends(backends);
        if (healthy_count == 0) {
            return error.NoHealthyBackends;
        }
    }
}

/// Legacy first healthy backend search (kept for reference)
pub fn findFirstHealthyBackendScalar(backends: *const BackendsList) ?usize {
    for (backends.items, 0..) |backend, i| {
        if (backend.isHealthy()) {
            return i;
        }
    }
    return null;
}