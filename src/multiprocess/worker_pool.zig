/// Multi-Process Worker Pool (nginx-style architecture)
///
/// Each worker is a separate process with its own:
/// - Event loop (Tardy runtime)
/// - Connection pool
/// - Memory allocator
///
/// Benefits over multi-threaded:
/// - No lock contention (each process isolated)
/// - Better CPU cache utilization (no false sharing)
/// - Crash isolation (one worker dies, others continue)
/// - Simpler memory model (no atomics needed within worker)
///
/// Trade-offs:
/// - Higher memory usage (no shared connection pool)
/// - More complex IPC for shared state
/// - Longer startup time (fork overhead)
const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.worker_pool);

pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    worker_count: usize,
    worker_pids: []posix.pid_t,
    listen_fd: posix.socket_t,

    /// Configuration passed to each worker
    pub const WorkerConfig = struct {
        listen_fd: posix.socket_t,
        worker_id: usize,
        backends: []const BackendConfig,
        strategy: []const u8,
    };

    pub const BackendConfig = struct {
        host: []const u8,
        port: u16,
        weight: u16,
    };

    pub fn init(allocator: std.mem.Allocator, worker_count: usize) !*WorkerPool {
        const pool = try allocator.create(WorkerPool);
        pool.* = .{
            .allocator = allocator,
            .worker_count = worker_count,
            .worker_pids = try allocator.alloc(posix.pid_t, worker_count),
            .listen_fd = undefined,
        };
        @memset(pool.worker_pids, 0);
        return pool;
    }

    pub fn deinit(self: *WorkerPool) void {
        self.allocator.free(self.worker_pids);
        self.allocator.destroy(self);
    }

    /// Create listening socket with SO_REUSEPORT
    /// This allows multiple processes to accept on the same port
    /// Kernel load-balances incoming connections across workers
    pub fn createListenSocket(self: *WorkerPool, host: []const u8, port: u16) !void {
        const addr = try std.net.Address.parseIp4(host, port);

        self.listen_fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            0
        );
        errdefer posix.close(self.listen_fd);

        // SO_REUSEPORT: Allow multiple processes to bind to same port
        // Kernel distributes connections using consistent hashing
        try posix.setsockopt(self.listen_fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

        // SO_REUSEADDR: Allow quick restart after crash
        try posix.setsockopt(self.listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        try posix.bind(self.listen_fd, &addr.any, addr.getOsSockLen());
        try posix.listen(self.listen_fd, 4096);

        log.info("Listening on {s}:{d} with SO_REUSEPORT", .{host, port});
    }

    /// Fork worker processes
    pub fn spawnWorkers(self: *WorkerPool, worker_main: *const fn(WorkerConfig) void, config_template: WorkerConfig) !void {
        for (0..self.worker_count) |i| {
            const pid = try posix.fork();

            if (pid == 0) {
                // Child process - become a worker
                var worker_config = config_template;
                worker_config.worker_id = i;
                worker_config.listen_fd = self.listen_fd;

                // Set CPU affinity (pin worker to specific core)
                setCpuAffinity(i) catch |err| {
                    log.warn("Failed to set CPU affinity for worker {d}: {s}", .{i, @errorName(err)});
                };

                log.info("Worker {d} started (PID: {d})", .{i, std.os.linux.getpid()});

                // Run worker main loop (never returns)
                worker_main(worker_config);

                // If worker_main returns, exit
                posix.exit(0);
            } else {
                // Parent process - record child PID
                self.worker_pids[i] = pid;
                log.info("Spawned worker {d} with PID {d}", .{i, pid});
            }
        }
    }

    /// Master process main loop - monitor workers and restart on crash
    pub fn masterLoop(self: *WorkerPool, worker_main: *const fn(WorkerConfig) void, config_template: WorkerConfig) !void {
        log.info("Master process running, monitoring {d} workers", .{self.worker_count});

        // Set up signal handlers
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        try posix.sigaction(posix.SIG.CHLD, &sa, null);
        try posix.sigaction(posix.SIG.HUP, &sa, null);
        try posix.sigaction(posix.SIG.TERM, &sa, null);

        while (true) {
            // Wait for any child to exit
            const result = posix.waitpid(-1, 0);

            if (result.pid > 0) {
                // Find which worker died
                for (self.worker_pids, 0..) |pid, i| {
                    if (pid == result.pid) {
                        const status = result.status;
                        if (posix.W.IFEXITED(status)) {
                            log.warn("Worker {d} exited with code {d}", .{i, posix.W.EXITSTATUS(status)});
                        } else if (posix.W.IFSIGNALED(status)) {
                            log.err("Worker {d} killed by signal {d}", .{i, posix.W.TERMSIG(status)});
                        }

                        // Restart the worker
                        log.info("Restarting worker {d}...", .{i});
                        self.restartWorker(i, worker_main, config_template) catch |err| {
                            log.err("Failed to restart worker {d}: {s}", .{i, @errorName(err)});
                        };
                        break;
                    }
                }
            }
        }
    }

    fn restartWorker(self: *WorkerPool, worker_id: usize, worker_main: *const fn(WorkerConfig) void, config_template: WorkerConfig) !void {
        const pid = try posix.fork();

        if (pid == 0) {
            var worker_config = config_template;
            worker_config.worker_id = worker_id;
            worker_config.listen_fd = self.listen_fd;

            setCpuAffinity(worker_id) catch {};
            worker_main(worker_config);
            posix.exit(0);
        } else {
            self.worker_pids[worker_id] = pid;
        }
    }

    /// Graceful shutdown - send SIGTERM to all workers
    pub fn shutdown(self: *WorkerPool) void {
        log.info("Shutting down all workers...", .{});
        for (self.worker_pids) |pid| {
            if (pid > 0) {
                _ = posix.kill(pid, posix.SIG.TERM) catch {};
            }
        }
    }

    /// Graceful reload - spawn new workers, then kill old ones
    pub fn reload(self: *WorkerPool, worker_main: *const fn(WorkerConfig) void, config_template: WorkerConfig) !void {
        log.info("Reloading configuration (graceful restart)...", .{});

        const old_pids = try self.allocator.dupe(posix.pid_t, self.worker_pids);
        defer self.allocator.free(old_pids);

        // Spawn new workers with new config
        try self.spawnWorkers(worker_main, config_template);

        // Give new workers time to start accepting
        std.time.sleep(100 * std.time.ns_per_ms);

        // Gracefully stop old workers
        for (old_pids) |pid| {
            if (pid > 0) {
                _ = posix.kill(pid, posix.SIG.TERM) catch {};
            }
        }
    }
};

/// Set CPU affinity to pin worker to specific core
fn setCpuAffinity(worker_id: usize) !void {
    if (@hasDecl(std.os.linux, "sched_setaffinity")) {
        var cpu_set = std.os.linux.cpu_set_t{ .bits = [_]usize{0} ** 16 };
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const target_cpu = worker_id % cpu_count;

        cpu_set.bits[target_cpu / 64] |= @as(usize, 1) << @intCast(target_cpu % 64);

        try std.os.linux.sched_setaffinity(0, &cpu_set);
    }
}

var should_reload: bool = false;
var should_shutdown: bool = false;

fn handleSignal(sig: c_int) callconv(.C) void {
    switch (sig) {
        posix.SIG.HUP => should_reload = true,
        posix.SIG.TERM, posix.SIG.INT => should_shutdown = true,
        else => {},
    }
}

// ============================================================================
// Example Worker Implementation
// ============================================================================

/// Example worker main function
pub fn exampleWorkerMain(config: WorkerPool.WorkerConfig) void {
    // Each worker gets its own allocator (no sharing!)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    log.info("Worker {d} initializing...", .{config.worker_id});

    // Each worker creates its own:
    // 1. Tardy runtime (event loop)
    // 2. Connection pool (no sharing = no locks!)
    // 3. Backend connections

    // const tardy = @import("zzz").tardy;
    // var t = tardy.Tardy(.auto).init(allocator, .{
    //     .threading = .single,  // Single-threaded per worker!
    //     .pooling = .grow,
    // }) catch return;
    // defer t.deinit();

    // ... set up routes, start accepting on config.listen_fd ...

    // Worker event loop (simplified)
    while (true) {
        // Accept connections from shared listen_fd
        // Process requests
        // Each worker is completely independent!
        _ = allocator;
        std.time.sleep(1 * std.time.ns_per_s);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "WorkerPool initialization" {
    const allocator = std.testing.allocator;
    const pool = try WorkerPool.init(allocator, 4);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 4), pool.worker_count);
}
