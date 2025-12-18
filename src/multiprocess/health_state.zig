/// Health State
///
/// Bitmap-based health tracking for backend servers.
/// Single-threaded design - no atomics needed.
///
/// ## Limitation: 64 Backend Maximum
///
/// The health state uses a `u64` bitmap for O(1) operations via CPU intrinsics
/// (`@popCount`, `@ctz`). This limits the system to 64 backends maximum.
///
/// To support more backends, replace the bitmap with:
/// - `std.StaticBitSet(256)` for up to 256 backends (still fast)
/// - `std.DynamicBitSet` for runtime-sized (heap allocated)
/// - `[N]u64` array for manual scaling
///
/// Related constants in: circuit_breaker.zig, backend_selector.zig,
/// worker_state.zig, and simple_connection_pool.zig
const std = @import("std");

/// Maximum supported backends. Limited by u64 bitmap.
/// See module doc for scaling options.
pub const MAX_BACKENDS: usize = 64;

/// Tracks health status of backends using a bitmap.
/// Each bit represents one backend: 1 = healthy, 0 = unhealthy.
pub const HealthState = struct {
    bitmap: u64 = 0,

    /// Mark a backend as healthy
    pub fn markHealthy(self: *HealthState, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.bitmap |= @as(u64, 1) << @intCast(idx);
    }

    /// Mark a backend as unhealthy
    pub fn markUnhealthy(self: *HealthState, idx: usize) void {
        if (idx >= MAX_BACKENDS) return;
        self.bitmap &= ~(@as(u64, 1) << @intCast(idx));
    }

    /// Check if a backend is healthy
    /// Hot path - inlined for performance
    pub inline fn isHealthy(self: *const HealthState, idx: usize) bool {
        if (idx >= MAX_BACKENDS) return false;
        return (self.bitmap & (@as(u64, 1) << @intCast(idx))) != 0;
    }

    /// Count total healthy backends
    /// Uses CPU popcount intrinsic - single instruction on modern CPUs
    pub inline fn countHealthy(self: *const HealthState) usize {
        return @popCount(self.bitmap);
    }

    /// Find the first healthy backend, optionally excluding one
    /// Uses CPU ctz intrinsic - single instruction on modern CPUs
    pub inline fn findFirstHealthy(self: *const HealthState, exclude_idx: ?usize) ?usize {
        var mask = self.bitmap;
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
    pub inline fn findNthHealthy(self: *const HealthState, n: usize) ?usize {
        var mask = self.bitmap;
        var remaining = n;
        while (mask != 0) {
            const idx = @ctz(mask);
            if (remaining == 0) return idx;
            remaining -= 1;
            mask &= mask - 1; // Clear lowest set bit
        }
        return null;
    }

    /// Get all healthy backend indices as an iterator
    pub fn healthyIterator(self: *const HealthState) HealthyIterator {
        return .{ .bitmap = self.bitmap };
    }

    /// Mark all backends in range as healthy
    pub fn markAllHealthy(self: *HealthState, count: usize) void {
        if (count == 0) return;
        const n = @min(count, MAX_BACKENDS);
        // Handle edge case where n == 64 (can't shift by 64 on u64)
        if (n >= 64) {
            self.bitmap = 0xFFFFFFFFFFFFFFFF;
        } else {
            self.bitmap = (@as(u64, 1) << @intCast(n)) - 1;
        }
    }

    /// Mark all backends as unhealthy
    pub fn markAllUnhealthy(self: *HealthState) void {
        self.bitmap = 0;
    }
};

/// Iterator over healthy backend indices
pub const HealthyIterator = struct {
    bitmap: u64,

    pub fn next(self: *HealthyIterator) ?usize {
        if (self.bitmap == 0) return null;
        const idx = @ctz(self.bitmap);
        self.bitmap &= self.bitmap - 1; // Clear lowest set bit
        return idx;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "HealthState: initial state is all unhealthy" {
    const state = HealthState{};
    try std.testing.expectEqual(@as(usize, 0), state.countHealthy());
    try std.testing.expect(!state.isHealthy(0));
    try std.testing.expect(!state.isHealthy(63));
}

test "HealthState: markHealthy sets bit correctly" {
    var state = HealthState{};

    state.markHealthy(0);
    try std.testing.expect(state.isHealthy(0));
    try std.testing.expectEqual(@as(usize, 1), state.countHealthy());

    state.markHealthy(5);
    try std.testing.expect(state.isHealthy(5));
    try std.testing.expectEqual(@as(usize, 2), state.countHealthy());

    // Marking same index again should be idempotent
    state.markHealthy(5);
    try std.testing.expectEqual(@as(usize, 2), state.countHealthy());
}

test "HealthState: markUnhealthy clears bit correctly" {
    var state = HealthState{};
    state.markHealthy(0);
    state.markHealthy(1);
    state.markHealthy(2);
    try std.testing.expectEqual(@as(usize, 3), state.countHealthy());

    state.markUnhealthy(1);
    try std.testing.expect(state.isHealthy(0));
    try std.testing.expect(!state.isHealthy(1));
    try std.testing.expect(state.isHealthy(2));
    try std.testing.expectEqual(@as(usize, 2), state.countHealthy());

    // Marking unhealthy again should be idempotent
    state.markUnhealthy(1);
    try std.testing.expectEqual(@as(usize, 2), state.countHealthy());
}

test "HealthState: boundary conditions at MAX_BACKENDS" {
    var state = HealthState{};

    // Last valid index
    state.markHealthy(63);
    try std.testing.expect(state.isHealthy(63));
    try std.testing.expectEqual(@as(usize, 1), state.countHealthy());

    // Out of bounds should be no-op and return false
    state.markHealthy(64);
    try std.testing.expect(!state.isHealthy(64));
    try std.testing.expectEqual(@as(usize, 1), state.countHealthy());

    state.markHealthy(100);
    try std.testing.expect(!state.isHealthy(100));
    try std.testing.expectEqual(@as(usize, 1), state.countHealthy());
}

test "HealthState: findFirstHealthy returns lowest index" {
    var state = HealthState{};

    // No healthy backends
    try std.testing.expectEqual(@as(?usize, null), state.findFirstHealthy(null));

    state.markHealthy(5);
    state.markHealthy(2);
    state.markHealthy(7);

    // Should return lowest healthy index
    try std.testing.expectEqual(@as(?usize, 2), state.findFirstHealthy(null));

    // With exclusion
    try std.testing.expectEqual(@as(?usize, 5), state.findFirstHealthy(2));
    try std.testing.expectEqual(@as(?usize, 2), state.findFirstHealthy(5));
    try std.testing.expectEqual(@as(?usize, 2), state.findFirstHealthy(7));

    // Exclude all by marking unhealthy
    state.markUnhealthy(2);
    try std.testing.expectEqual(@as(?usize, 5), state.findFirstHealthy(null));
}

test "HealthState: findFirstHealthy with single backend" {
    var state = HealthState{};
    state.markHealthy(0);

    try std.testing.expectEqual(@as(?usize, 0), state.findFirstHealthy(null));
    try std.testing.expectEqual(@as(?usize, null), state.findFirstHealthy(0));
}

test "HealthState: markAllHealthy initializes range" {
    var state = HealthState{};

    state.markAllHealthy(4);
    try std.testing.expect(state.isHealthy(0));
    try std.testing.expect(state.isHealthy(1));
    try std.testing.expect(state.isHealthy(2));
    try std.testing.expect(state.isHealthy(3));
    try std.testing.expect(!state.isHealthy(4));
    try std.testing.expectEqual(@as(usize, 4), state.countHealthy());
}

test "HealthState: markAllHealthy with zero count" {
    var state = HealthState{};
    state.markHealthy(5); // Pre-existing state
    state.markAllHealthy(0);
    // Should not change anything
    try std.testing.expect(state.isHealthy(5));
}

test "HealthState: markAllHealthy caps at MAX_BACKENDS" {
    var state = HealthState{};
    state.markAllHealthy(100);
    try std.testing.expectEqual(@as(usize, 64), state.countHealthy());
}

test "HealthState: markAllUnhealthy clears all" {
    var state = HealthState{};
    state.markAllHealthy(10);
    try std.testing.expectEqual(@as(usize, 10), state.countHealthy());

    state.markAllUnhealthy();
    try std.testing.expectEqual(@as(usize, 0), state.countHealthy());
}

test "HealthyIterator: iterates in ascending order" {
    var state = HealthState{};
    state.markHealthy(7);
    state.markHealthy(2);
    state.markHealthy(5);

    var iter = state.healthyIterator();
    try std.testing.expectEqual(@as(?usize, 2), iter.next());
    try std.testing.expectEqual(@as(?usize, 5), iter.next());
    try std.testing.expectEqual(@as(?usize, 7), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "HealthyIterator: empty state returns null immediately" {
    const state = HealthState{};
    var iter = state.healthyIterator();
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "HealthState: findNthHealthy returns correct indices" {
    var state = HealthState{};
    state.markHealthy(2);
    state.markHealthy(5);
    state.markHealthy(7);

    // 0th healthy = 2, 1st = 5, 2nd = 7
    try std.testing.expectEqual(@as(?usize, 2), state.findNthHealthy(0));
    try std.testing.expectEqual(@as(?usize, 5), state.findNthHealthy(1));
    try std.testing.expectEqual(@as(?usize, 7), state.findNthHealthy(2));
    try std.testing.expectEqual(@as(?usize, null), state.findNthHealthy(3));
}

test "HealthState: findNthHealthy with empty state" {
    const state = HealthState{};
    try std.testing.expectEqual(@as(?usize, null), state.findNthHealthy(0));
}

test "HealthState: findNthHealthy with single backend" {
    var state = HealthState{};
    state.markHealthy(42);

    try std.testing.expectEqual(@as(?usize, 42), state.findNthHealthy(0));
    try std.testing.expectEqual(@as(?usize, null), state.findNthHealthy(1));
}

test "HealthyIterator: all backends healthy" {
    var state = HealthState{};
    state.markAllHealthy(3);

    var iter = state.healthyIterator();
    try std.testing.expectEqual(@as(?usize, 0), iter.next());
    try std.testing.expectEqual(@as(?usize, 1), iter.next());
    try std.testing.expectEqual(@as(?usize, 2), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "HealthState: bitmap manipulation preserves other bits" {
    var state = HealthState{};
    state.bitmap = 0xFFFFFFFFFFFFFFFF; // All healthy

    state.markUnhealthy(32);
    try std.testing.expect(!state.isHealthy(32));
    try std.testing.expect(state.isHealthy(31));
    try std.testing.expect(state.isHealthy(33));
    try std.testing.expectEqual(@as(usize, 63), state.countHealthy());

    state.markHealthy(32);
    try std.testing.expectEqual(@as(usize, 64), state.countHealthy());
}
