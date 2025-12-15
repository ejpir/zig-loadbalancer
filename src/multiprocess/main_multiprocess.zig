/// Multi-Process Load Balancer Entry Point (nginx-style)
///
/// Usage:
///   zig build -Doptimize=ReleaseFast
///   ./zig-out/bin/load_balancer_mp --workers 4 --port 8080
///
/// Architecture:
///   Master Process
///     └── Worker 0 (CPU 0) ─┐
///     └── Worker 1 (CPU 1) ─┼── SO_REUSEPORT ── Port 8080
///     └── Worker 2 (CPU 2) ─┤
///     └── Worker 3 (CPU 3) ─┘
///
/// Each worker:
///   - Has its own event loop (no thread contention)
///   - Has its own connection pool (no locks!)
///   - Is pinned to a specific CPU core
///   - Can crash without affecting others
const std = @import("std");
const log = std.log.scoped(.@"load_balancer_mp");
const WorkerPool = @import("worker_pool.zig").WorkerPool;

// Zzz imports
const zzz = @import("zzz");
const tardy = zzz.tardy;
const http = zzz.HTTP;

// Local imports
const types = @import("../core/types.zig");
const connection_pool_mod = @import("../memory/connection_pool.zig");
const proxy = @import("../core/proxy.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Parse arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var worker_count: usize = try std.Thread.getCpuCount();
    var port: u16 = 8080;
    var host: []const u8 = "0.0.0.0";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--workers") and i + 1 < args.len) {
            worker_count = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            host = args[i + 1];
            i += 1;
        }
    }

    log.info("Starting multi-process load balancer", .{});
    log.info("  Workers: {d}", .{worker_count});
    log.info("  Listen: {s}:{d}", .{host, port});

    // Initialize worker pool
    var pool = try WorkerPool.init(allocator, worker_count);
    defer pool.deinit();

    // Create listening socket with SO_REUSEPORT
    try pool.createListenSocket(host, port);

    // Spawn worker processes
    const config = WorkerPool.WorkerConfig{
        .listen_fd = undefined, // Set by spawnWorkers
        .worker_id = undefined, // Set by spawnWorkers
        .backends = &[_]WorkerPool.BackendConfig{
            .{ .host = "127.0.0.1", .port = 3000, .weight = 1 },
            .{ .host = "127.0.0.1", .port = 3001, .weight = 1 },
        },
        .strategy = "round-robin",
    };

    try pool.spawnWorkers(workerMain, config);

    // Master loop - monitor and restart crashed workers
    try pool.masterLoop(workerMain, config);
}

/// Worker process main function
/// Each worker is completely independent - no shared state!
fn workerMain(config: WorkerPool.WorkerConfig) void {
    // Each worker gets its own allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    log.info("Worker {d}: Initializing...", .{config.worker_id});

    // Each worker creates its own Tardy runtime
    // SINGLE THREADED - no locks needed within worker!
    const Tardy = tardy.Tardy(.auto);
    var t = Tardy.init(allocator, .{
        .threading = .single,  // Key difference: single-threaded per worker
        .pooling = .grow,
        .size_tasks_initial = 1024,
        .size_aio_reap_max = 1024,
    }) catch |err| {
        log.err("Worker {d}: Failed to init Tardy: {s}", .{config.worker_id, @errorName(err)});
        return;
    };
    defer t.deinit();

    // Each worker gets its own connection pool (no sharing = no locks!)
    var connection_pool = connection_pool_mod.LockFreeConnectionPool{
        .pools = undefined,
        .allocator = undefined,
        .initialized = false,
    };
    connection_pool.init(allocator) catch |err| {
        log.err("Worker {d}: Failed to init connection pool: {s}", .{config.worker_id, @errorName(err)});
        return;
    };
    defer connection_pool.deinit();

    // Initialize backends
    var backends = types.BackendsList.init(allocator);
    defer backends.deinit();

    for (config.backends) |backend_config| {
        backends.append(types.BackendServer.init(
            backend_config.host,
            backend_config.port,
            backend_config.weight,
        )) catch continue;
    }

    connection_pool.addBackends(backends.items.len) catch |err| {
        log.err("Worker {d}: Failed to add backends: {s}", .{config.worker_id, @errorName(err)});
        return;
    };

    log.info("Worker {d}: Ready, accepting connections on fd {d}", .{
        config.worker_id, config.listen_fd
    });

    // Create HTTP server using the shared listen socket
    // Each worker accepts independently via SO_REUSEPORT
    // Kernel distributes connections across workers

    // Note: zzz would need modification to accept an existing socket
    // This is a sketch showing the architecture pattern

    // Simplified event loop
    while (true) {
        // In real implementation:
        // 1. t.entry() with socket from config.listen_fd
        // 2. Handle requests independently
        // 3. No coordination with other workers needed!

        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

// ============================================================================
// Performance Comparison
// ============================================================================
//
// Multi-Threaded (current):
// ┌────────────────────────────────────────┐
// │           Single Process               │
// │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐  │
// │  │Thread│ │Thread│ │Thread│ │Thread│  │
// │  └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘  │
// │     │        │        │        │       │
// │     └────────┴────┬───┴────────┘       │
// │                   │                    │
// │         Shared Connection Pool         │
// │         (atomic operations)            │
// │         Shared Backends List           │
// │         (atomic health flags)          │
// └────────────────────────────────────────┘
//
// Issues:
// - False sharing in CPU caches
// - Lock contention on pool operations
// - One crash kills all connections
//
// Multi-Process (nginx-style):
// ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
// │ Worker 0 │ │ Worker 1 │ │ Worker 2 │ │ Worker 3 │
// │ ┌──────┐ │ │ ┌──────┐ │ │ ┌──────┐ │ │ ┌──────┐ │
// │ │ Pool │ │ │ │ Pool │ │ │ │ Pool │ │ │ │ Pool │ │
// │ └──────┘ │ │ └──────┘ │ │ └──────┘ │ │ └──────┘ │
// │ ┌──────┐ │ │ ┌──────┐ │ │ ┌──────┐ │ │ ┌──────┐ │
// │ │Tardy │ │ │ │Tardy │ │ │ │Tardy │ │ │ │Tardy │ │
// │ └──────┘ │ │ └──────┘ │ │ └──────┘ │ │ └──────┘ │
// └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘
//      │            │            │            │
//      └────────────┴─────┬──────┴────────────┘
//                         │
//                   SO_REUSEPORT
//                   (kernel LB)
//
// Benefits:
// - Zero contention (nothing shared)
// - Perfect CPU cache utilization
// - Crash isolation
// - Simpler code (no atomics needed)
//
// Trade-offs:
// - Higher memory (N copies of pool)
// - Need IPC for shared state (metrics, config)
// - Slower config reload
