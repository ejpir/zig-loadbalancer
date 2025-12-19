/// Shared Health State for Multi-Process Load Balancer
///
/// Provides lock-free bitmap-based health tracking that can be shared
/// across forked worker processes via shared memory.
///
/// Features:
/// - Single atomic u64 bitmap for health status (1 = healthy, 0 = unhealthy)
/// - Per-backend failure counters for threshold-based circuit breaking
/// - Optimized bit manipulation using CPU intrinsics (ctz, popcount)
/// - Cache-line aligned to prevent false sharing
const std = @import("std");

/// Maximum backends supported (fits in 64-bit bitmap)
pub const MAX_BACKENDS = 64;

/// Shared health state for all backends
/// Aligned to separate cache line to prevent false sharing
pub const SharedHealthState = extern struct {
    /// Bitmap: bit N = 1 means backend N is healthy
    bitmap: std.atomic.Value(u64) align(64) = .{ .raw = std.math.maxInt(u64) },

    /// Consecutive failure count per backend
    failure_counts: [MAX_BACKENDS]std.atomic.Value(u8) =
        [_]std.atomic.Value(u8){.{ .raw = 0 }} ** MAX_BACKENDS,

    /// Check if a backend is healthy
    pub fn isHealthy(self: *const SharedHealthState, idx: usize) bool {
        std.debug.assert(idx < MAX_BACKENDS);
        const mask = @as(u64, 1) << @intCast(idx);
        return (self.bitmap.load(.acquire) & mask) != 0;
    }

    /// Mark a backend as unhealthy
    pub fn markUnhealthy(self: *SharedHealthState, idx: usize) void {
        std.debug.assert(idx < MAX_BACKENDS);
        const mask = ~(@as(u64, 1) << @intCast(idx));
        _ = self.bitmap.fetchAnd(mask, .release);
    }

    /// Mark a backend as healthy and reset failure count
    pub fn markHealthy(self: *SharedHealthState, idx: usize) void {
        std.debug.assert(idx < MAX_BACKENDS);
        const mask = @as(u64, 1) << @intCast(idx);
        _ = self.bitmap.fetchOr(mask, .release);
        self.failure_counts[idx].store(0, .release);
    }

    /// Record a failure, returns true if backend became unhealthy
    pub fn recordFailure(self: *SharedHealthState, idx: usize, threshold: u8) bool {
        std.debug.assert(idx < MAX_BACKENDS);
        const prev = self.failure_counts[idx].fetchAdd(1, .acq_rel);
        if (prev + 1 >= threshold) {
            self.markUnhealthy(idx);
            return true;
        }
        return false;
    }

    /// Count healthy backends
    pub inline fn countHealthy(self: *const SharedHealthState) usize {
        return @popCount(self.bitmap.load(.acquire));
    }

    /// Find the first healthy backend, optionally excluding one
    /// Uses CPU ctz intrinsic - single instruction on modern CPUs
    pub inline fn findFirstHealthy(self: *const SharedHealthState, exclude_idx: ?usize) ?usize {
        var mask = self.bitmap.load(.acquire);
        if (exclude_idx) |idx| {
            if (idx < MAX_BACKENDS) {
                mask &= ~(@as(u64, 1) << @intCast(idx));
            }
        }
        if (mask == 0) return null;
        return @ctz(mask);
    }

    /// Find the Nth healthy backend (0-indexed) using bit manipulation
    /// O(popcount) instead of O(backend_count) iteration
    pub inline fn findNthHealthy(self: *const SharedHealthState, n: usize) ?usize {
        var mask = self.bitmap.load(.acquire);
        var remaining = n;
        while (mask != 0) {
            const idx = @ctz(mask);
            if (remaining == 0) return idx;
            remaining -= 1;
            mask &= mask - 1; // Clear lowest set bit
        }
        return null;
    }

    /// Mark all backends in range as healthy
    pub fn markAllHealthy(self: *SharedHealthState, count: usize) void {
        if (count == 0) return;
        const n = @min(count, MAX_BACKENDS);
        const mask = if (n >= 64)
            std.math.maxInt(u64)
        else
            (@as(u64, 1) << @intCast(n)) - 1;
        self.bitmap.store(mask, .release);
        for (0..n) |i| {
            self.failure_counts[i].store(0, .release);
        }
    }

    /// Mark all backends as unhealthy
    pub fn markAllUnhealthy(self: *SharedHealthState) void {
        self.bitmap.store(0, .release);
    }

    /// Reset all backends to healthy (alias for markAllHealthy)
    pub fn resetAll(self: *SharedHealthState, count: usize) void {
        self.markAllHealthy(count);
    }

    /// Get the raw bitmap value (for iterators)
    pub inline fn getBitmap(self: *const SharedHealthState) u64 {
        return self.bitmap.load(.acquire);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "SharedHealthState: basic operations" {
    var health = SharedHealthState{};

    // Initially all healthy
    try std.testing.expect(health.isHealthy(0));
    try std.testing.expect(health.isHealthy(63));

    // Mark unhealthy
    health.markUnhealthy(5);
    try std.testing.expect(!health.isHealthy(5));
    try std.testing.expect(health.isHealthy(4));
    try std.testing.expect(health.isHealthy(6));

    // Mark healthy again
    health.markHealthy(5);
    try std.testing.expect(health.isHealthy(5));
}

test "SharedHealthState: failure threshold" {
    var health = SharedHealthState{};
    const threshold: u8 = 3;

    // Record failures below threshold
    try std.testing.expect(!health.recordFailure(0, threshold));
    try std.testing.expect(health.isHealthy(0));
    try std.testing.expect(!health.recordFailure(0, threshold));
    try std.testing.expect(health.isHealthy(0));

    // Third failure crosses threshold
    try std.testing.expect(health.recordFailure(0, threshold));
    try std.testing.expect(!health.isHealthy(0));
}

test "SharedHealthState: count healthy" {
    var health = SharedHealthState{};

    health.resetAll(8); // 8 backends
    try std.testing.expectEqual(@as(usize, 8), health.countHealthy());

    health.markUnhealthy(2);
    health.markUnhealthy(5);
    try std.testing.expectEqual(@as(usize, 6), health.countHealthy());
}

test "SharedHealthState: findFirstHealthy" {
    var health = SharedHealthState{};

    // All healthy - should find 0
    health.resetAll(8);
    try std.testing.expectEqual(@as(?usize, 0), health.findFirstHealthy(null));

    // Exclude 0 - should find 1
    try std.testing.expectEqual(@as(?usize, 1), health.findFirstHealthy(0));

    // Mark 0,1,2 unhealthy - should find 3
    health.markUnhealthy(0);
    health.markUnhealthy(1);
    health.markUnhealthy(2);
    try std.testing.expectEqual(@as(?usize, 3), health.findFirstHealthy(null));

    // Exclude 3 - should find 4
    try std.testing.expectEqual(@as(?usize, 4), health.findFirstHealthy(3));

    // All unhealthy - should return null
    health.markAllUnhealthy();
    try std.testing.expectEqual(@as(?usize, null), health.findFirstHealthy(null));
}

test "SharedHealthState: findNthHealthy" {
    var health = SharedHealthState{};
    health.resetAll(8);

    // Find 0th healthy (first)
    try std.testing.expectEqual(@as(?usize, 0), health.findNthHealthy(0));

    // Find 3rd healthy
    try std.testing.expectEqual(@as(?usize, 3), health.findNthHealthy(3));

    // Find 7th healthy (last)
    try std.testing.expectEqual(@as(?usize, 7), health.findNthHealthy(7));

    // Beyond count - should return null
    try std.testing.expectEqual(@as(?usize, null), health.findNthHealthy(8));

    // With gaps: mark 1,3,5 unhealthy
    health.markUnhealthy(1);
    health.markUnhealthy(3);
    health.markUnhealthy(5);

    // Now healthy are: 0,2,4,6,7
    try std.testing.expectEqual(@as(?usize, 0), health.findNthHealthy(0));
    try std.testing.expectEqual(@as(?usize, 2), health.findNthHealthy(1));
    try std.testing.expectEqual(@as(?usize, 4), health.findNthHealthy(2));
    try std.testing.expectEqual(@as(?usize, 6), health.findNthHealthy(3));
    try std.testing.expectEqual(@as(?usize, 7), health.findNthHealthy(4));
    try std.testing.expectEqual(@as(?usize, null), health.findNthHealthy(5));
}
