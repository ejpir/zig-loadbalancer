/// Shared Memory Region for Multi-Process Load Balancer
///
/// Provides a memory-mapped region that can be shared across forked worker
/// processes. Supports:
/// - Shared health state between workers
/// - Double-buffered backend configuration for atomic hot reload
/// - Cache-line aligned structures to minimize false sharing
///
/// Platform support:
/// - Linux: Uses memfd_create for anonymous file-backed memory
/// - macOS/BSD: Uses MAP_ANONYMOUS with file fallback for persistence
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.shared_region);

/// Maximum backends supported (fits in 64-bit bitmap)
pub const MAX_BACKENDS = 64;

/// Maximum hostname length (per RFC 1035)
pub const MAX_HOST_LEN = 253;

/// Page size for alignment
pub const PAGE_SIZE = std.heap.page_size_min;

/// Shared backend definition - self-contained, no pointers
/// Sized to fit nicely in cache lines
pub const SharedBackend = extern struct {
    /// Null-terminated hostname (inlined, no pointer)
    host: [MAX_HOST_LEN + 1]u8 = [_]u8{0} ** (MAX_HOST_LEN + 1),
    /// Port number
    port: u16 = 0,
    /// Weight for weighted round-robin (1-100)
    weight: u16 = 1,
    /// Use TLS for this backend
    use_tls: bool = false,
    /// Padding for alignment
    _padding: [1]u8 = undefined,

    /// Get host as slice
    pub fn getHost(self: *const SharedBackend) []const u8 {
        // Find null terminator
        var len: usize = 0;
        while (len < MAX_HOST_LEN and self.host[len] != 0) : (len += 1) {}
        return self.host[0..len];
    }

    /// Set host from slice
    pub fn setHost(self: *SharedBackend, host: []const u8) void {
        const copy_len = @min(host.len, MAX_HOST_LEN);
        @memcpy(self.host[0..copy_len], host[0..copy_len]);
        self.host[copy_len] = 0; // Null terminate
    }

    /// Check if backend is configured (non-empty)
    pub fn isConfigured(self: *const SharedBackend) bool {
        return self.host[0] != 0 and self.port != 0;
    }

    /// Check if backend uses HTTPS (for UltraSock compatibility)
    pub fn isHttps(self: *const SharedBackend) bool {
        return self.use_tls or self.port == 443;
    }

    /// Get full host (same as getHost for SharedBackend, for UltraSock compatibility)
    pub fn getFullHost(self: *const SharedBackend) []const u8 {
        return self.getHost();
    }
};

/// Array of backends (one buffer in double-buffering scheme)
pub const BackendArray = extern struct {
    backends: [MAX_BACKENDS]SharedBackend = [_]SharedBackend{.{}} ** MAX_BACKENDS,
};

/// Control block for atomic configuration management
/// Aligned to cache line to prevent false sharing
pub const ControlBlock = extern struct {
    /// Index of active backend array (0 or 1)
    /// Uses u64 for atomic operations, lower bit = array index
    active_index: std.atomic.Value(u64) align(64) = .{ .raw = 0 },

    /// Generation counter for ABA prevention
    generation: std.atomic.Value(u64) = .{ .raw = 0 },

    /// Number of configured backends
    backend_count: std.atomic.Value(u32) = .{ .raw = 0 },

    /// Padding to fill cache line (64 bytes total)
    _padding: [40]u8 = undefined,

    /// Get the index of the currently active backend array
    pub fn getActiveIndex(self: *const ControlBlock) usize {
        return @intCast(self.active_index.load(.acquire) & 1);
    }

    /// Get current generation
    pub fn getGeneration(self: *const ControlBlock) u64 {
        return self.generation.load(.acquire);
    }

    /// Get backend count
    pub fn getBackendCount(self: *const ControlBlock) u32 {
        return self.backend_count.load(.acquire);
    }

    /// Atomically switch to the other backend array
    /// Returns the new generation number
    pub fn switchActiveArray(self: *ControlBlock, new_count: u32) u64 {
        // Increment generation (also flips the active index bit)
        const new_gen = self.generation.fetchAdd(1, .acq_rel) + 1;
        // Update count
        self.backend_count.store(new_count, .release);
        // Flip active index
        _ = self.active_index.fetchXor(1, .release);
        return new_gen;
    }
};

/// Shared health state for all backends
/// Aligned to separate cache line from ControlBlock
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

/// The complete shared memory region
/// All fields are cache-line aligned to prevent false sharing
pub const SharedRegion = extern struct {
    /// Magic number for validation
    magic: u64 align(64) = MAGIC,

    /// Version for compatibility checking
    version: u32 = VERSION,

    /// Padding
    _header_padding: [52]u8 = undefined,

    /// Control block for backend array management
    control: ControlBlock align(64) = .{},

    /// Shared health state
    health: SharedHealthState align(64) = .{},

    /// Double-buffered backend arrays
    backend_arrays: [2]BackendArray = [_]BackendArray{.{}} ** 2,

    const MAGIC: u64 = 0x5A5A_4C42_5348_4152; // "ZZSHAR_LB" in hex-ish
    const VERSION: u32 = 1;

    /// Validate the region
    pub fn isValid(self: *const SharedRegion) bool {
        return self.magic == MAGIC and self.version == VERSION;
    }

    /// Get the currently active backend array
    pub fn getActiveBackends(self: *const SharedRegion) []const SharedBackend {
        const idx = self.control.getActiveIndex();
        const count = self.control.getBackendCount();
        return self.backend_arrays[idx].backends[0..count];
    }

    /// Get the inactive backend array for writing
    pub fn getInactiveBackends(self: *SharedRegion) []SharedBackend {
        const idx = 1 - self.control.getActiveIndex();
        return &self.backend_arrays[idx].backends;
    }

    /// Calculate the size needed for mmap
    pub fn requiredSize() usize {
        return std.mem.alignForward(usize, @sizeOf(SharedRegion), PAGE_SIZE);
    }
};

// Compile-time validations
comptime {
    // Ensure ControlBlock fits in one cache line
    std.debug.assert(@sizeOf(ControlBlock) == 64);
    // Ensure SharedHealthState starts on cache line
    std.debug.assert(@offsetOf(SharedRegion, "health") % 64 == 0);
    // Ensure control starts on cache line
    std.debug.assert(@offsetOf(SharedRegion, "control") % 64 == 0);
}

/// Allocator for shared memory regions
pub const SharedRegionAllocator = struct {
    /// File descriptor for the shared memory (for passing to child processes)
    fd: posix.fd_t = -1,

    /// Pointer to the mapped region
    region: ?*SharedRegion = null,

    /// Size of the mapping
    size: usize = 0,

    /// Path for file-backed mmap (if used)
    path: ?[]const u8 = null,

    /// Allocate and map a new shared region
    pub fn init(self: *SharedRegionAllocator) !*SharedRegion {
        const size = SharedRegion.requiredSize();

        // Try platform-specific anonymous shared memory first
        if (comptime builtin.os.tag == .linux) {
            // Linux: use memfd_create for anonymous file-backed memory
            const fd = try createMemfd();
            errdefer posix.close(fd);

            try posix.ftruncate(fd, @intCast(size));

            const ptr = try posix.mmap(
                null,
                size,
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                fd,
                0,
            );

            const region: *SharedRegion = @ptrCast(@alignCast(ptr));
            region.* = .{};

            self.fd = fd;
            self.region = region;
            self.size = size;

            // Prefault pages
            prefaultPages(ptr.ptr, size);

            log.info("Created shared region via memfd_create ({d} bytes)", .{size});
            return region;
        } else {
            // macOS/BSD: use MAP_ANONYMOUS | MAP_SHARED
            const ptr = try posix.mmap(
                null,
                size,
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED, .ANONYMOUS = true },
                -1,
                0,
            );

            const region: *SharedRegion = @ptrCast(@alignCast(ptr));
            region.* = .{};

            self.fd = -1; // No fd for anonymous mapping
            self.region = region;
            self.size = size;

            // Prefault pages
            prefaultPages(ptr.ptr, size);

            log.info("Created shared region via MAP_ANONYMOUS ({d} bytes)", .{size});
            return region;
        }
    }

    /// Attach to an existing shared region (for child processes on Linux)
    pub fn attach(self: *SharedRegionAllocator, fd: posix.fd_t) !*SharedRegion {
        const size = SharedRegion.requiredSize();

        const ptr = try posix.mmap(
            null,
            size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        const region: *SharedRegion = @ptrCast(@alignCast(ptr));

        if (!region.isValid()) {
            posix.munmap(ptr, size);
            return error.InvalidSharedRegion;
        }

        self.fd = fd;
        self.region = region;
        self.size = size;

        log.info("Attached to existing shared region", .{});
        return region;
    }

    /// Deinitialize and unmap the region
    pub fn deinit(self: *SharedRegionAllocator) void {
        if (self.region) |region| {
            const ptr: [*]align(PAGE_SIZE) u8 = @ptrCast(@alignCast(region));
            posix.munmap(ptr[0..self.size]);
            self.region = null;
        }

        if (self.fd >= 0) {
            posix.close(self.fd);
            self.fd = -1;
        }

        self.size = 0;
    }

    /// Get the file descriptor (for passing to child processes)
    pub fn getFd(self: *const SharedRegionAllocator) ?posix.fd_t {
        return if (self.fd >= 0) self.fd else null;
    }
};

/// Create an anonymous file via memfd_create (Linux only)
fn createMemfd() !posix.fd_t {
    if (comptime builtin.os.tag != .linux) {
        @compileError("memfd_create only available on Linux");
    }

    const name = "lb_shared";
    const rc = std.os.linux.memfd_create(name, std.os.linux.MFD.CLOEXEC);

    if (@as(isize, @bitCast(rc)) < 0) {
        return posix.unexpectedErrno(@enumFromInt(@as(u16, @truncate(@as(usize, @bitCast(-@as(isize, @bitCast(rc))))))));
    }

    return @intCast(rc);
}

/// Touch each page to trigger page faults during initialization
fn prefaultPages(ptr: [*]align(PAGE_SIZE) u8, size: usize) void {
    var offset: usize = 0;
    while (offset < size) : (offset += PAGE_SIZE) {
        // Volatile read to prevent optimization
        _ = @as(*volatile u8, @ptrCast(ptr + offset)).*;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "SharedBackend: host operations" {
    var backend = SharedBackend{};

    // Initially empty
    try std.testing.expectEqual(@as(usize, 0), backend.getHost().len);
    try std.testing.expect(!backend.isConfigured());

    // Set host
    backend.setHost("example.com");
    backend.port = 8080;

    try std.testing.expectEqualStrings("example.com", backend.getHost());
    try std.testing.expect(backend.isConfigured());

    // Set long host (should truncate)
    var long_host: [300]u8 = undefined;
    @memset(&long_host, 'x');
    backend.setHost(&long_host);

    try std.testing.expectEqual(MAX_HOST_LEN, backend.getHost().len);
}

test "SharedBackend: tls and weight fields" {
    var backend = SharedBackend{};

    // Defaults
    try std.testing.expectEqual(false, backend.use_tls);
    try std.testing.expectEqual(@as(u16, 1), backend.weight);

    // Set TLS backend
    backend.setHost("secure.example.com");
    backend.port = 443;
    backend.use_tls = true;
    backend.weight = 10;

    try std.testing.expect(backend.isConfigured());
    try std.testing.expectEqual(true, backend.use_tls);
    try std.testing.expectEqual(@as(u16, 10), backend.weight);
}

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

test "ControlBlock: atomic switch" {
    var control = ControlBlock{};

    try std.testing.expectEqual(@as(usize, 0), control.getActiveIndex());
    try std.testing.expectEqual(@as(u64, 0), control.getGeneration());

    // Switch to array 1
    const gen1 = control.switchActiveArray(3);
    try std.testing.expectEqual(@as(usize, 1), control.getActiveIndex());
    try std.testing.expectEqual(@as(u64, 1), gen1);
    try std.testing.expectEqual(@as(u32, 3), control.getBackendCount());

    // Switch back to array 0
    const gen2 = control.switchActiveArray(5);
    try std.testing.expectEqual(@as(usize, 0), control.getActiveIndex());
    try std.testing.expectEqual(@as(u64, 2), gen2);
    try std.testing.expectEqual(@as(u32, 5), control.getBackendCount());
}

test "SharedRegion: validation" {
    var region = SharedRegion{};

    try std.testing.expect(region.isValid());
    try std.testing.expectEqual(@as(u32, 1), region.version);
}

test "SharedRegion: double buffering" {
    var region = SharedRegion{};

    // Configure backends in inactive array (array 0 is initially active)
    var inactive = region.getInactiveBackends();
    inactive[0].setHost("backend1.local");
    inactive[0].port = 8001;
    inactive[1].setHost("backend2.local");
    inactive[1].port = 8002;

    // Switch to make them active
    _ = region.control.switchActiveArray(2);

    // Verify active backends
    const active = region.getActiveBackends();
    try std.testing.expectEqual(@as(usize, 2), active.len);
    try std.testing.expectEqualStrings("backend1.local", active[0].getHost());
    try std.testing.expectEqual(@as(u16, 8001), active[0].port);
}

test "SharedRegion: size and alignment" {
    // Verify cache line alignment
    try std.testing.expectEqual(@as(usize, 64), @alignOf(ControlBlock));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ControlBlock));

    // Verify region size is page-aligned
    const size = SharedRegion.requiredSize();
    try std.testing.expectEqual(@as(usize, 0), size % PAGE_SIZE);

    log.debug("SharedRegion size: {d} bytes ({d} pages)", .{
        @sizeOf(SharedRegion),
        @sizeOf(SharedRegion) / PAGE_SIZE + 1,
    });
}

test "SharedRegionAllocator: create and access" {
    var allocator = SharedRegionAllocator{};
    defer allocator.deinit();

    const region = try allocator.init();

    // Verify region is valid
    try std.testing.expect(region.isValid());

    // Write and read back
    var inactive = region.getInactiveBackends();
    inactive[0].setHost("test.example.com");
    inactive[0].port = 9000;
    inactive[0].weight = 5;

    _ = region.control.switchActiveArray(1);

    const active = region.getActiveBackends();
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqualStrings("test.example.com", active[0].getHost());
    try std.testing.expectEqual(@as(u16, 9000), active[0].port);
    try std.testing.expectEqual(@as(u16, 5), active[0].weight);
}

test "SharedRegion: fork inheritance" {
    // This test verifies that shared memory is visible across fork()
    var allocator = SharedRegionAllocator{};
    defer allocator.deinit();

    const region = try allocator.init();

    // Set initial state
    region.health.resetAll(3);
    try std.testing.expectEqual(@as(usize, 3), region.health.countHealthy());

    const pid = posix.fork() catch |err| {
        // Fork not supported (e.g., in some test environments)
        log.warn("Fork not available: {}", .{err});
        return;
    };

    if (pid == 0) {
        // Child process
        // Verify we can see parent's state
        if (region.health.countHealthy() != 3) {
            posix.exit(1);
        }

        // Modify shared state
        region.health.markUnhealthy(1);

        // Small delay to ensure write is visible
        posix.nanosleep(0, 10_000_000); // 10ms

        posix.exit(0);
    } else {
        // Parent process
        // Wait for child to complete
        const result = posix.waitpid(pid, 0);
        // Extract exit code: WEXITSTATUS(status) = (status >> 8) & 0xff
        const exit_code: u8 = @truncate(result.status >> 8);
        try std.testing.expectEqual(@as(u8, 0), exit_code);

        // Verify child's modification is visible
        // Note: On some systems, there might be a slight delay
        posix.nanosleep(0, 10_000_000); // 10ms
        try std.testing.expect(!region.health.isHealthy(1));
        try std.testing.expectEqual(@as(usize, 2), region.health.countHealthy());
    }
}
