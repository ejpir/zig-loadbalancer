//! Process manager for integration tests.
//!
//! Handles spawning and cleanup of backend/load balancer processes.

const std = @import("std");
const test_utils = @import("test_utils.zig");

pub const Process = struct {
    child: std.process.Child,
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn kill(self: *Process) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
    }

    pub fn deinit(self: *Process) void {
        self.allocator.free(self.name);
    }
};

pub const ProcessManager = struct {
    allocator: std.mem.Allocator,
    processes: std.ArrayList(Process),

    pub fn init(allocator: std.mem.Allocator) ProcessManager {
        return .{
            .allocator = allocator,
            .processes = std.ArrayList(Process).init(allocator),
        };
    }

    pub fn deinit(self: *ProcessManager) void {
        self.stopAll();
        self.processes.deinit();
    }

    pub fn startBackend(self: *ProcessManager, port: u16, server_id: []const u8) !void {
        var port_buf: [8]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

        var child = std.process.Child.init(
            &.{ "./zig-out/bin/test_backend_echo", "--port", port_str, "--id", server_id },
            self.allocator,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        try self.processes.append(.{
            .child = child,
            .name = try std.fmt.allocPrint(self.allocator, "backend_{s}", .{server_id}),
            .allocator = self.allocator,
        });

        // Wait for port to be ready
        try test_utils.waitForPort(port, 10000);
    }

    pub fn startLoadBalancer(self: *ProcessManager, backend_ports: []const u16) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        // Track strings we allocate so we can free them
        var allocated_strings = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (allocated_strings.items) |s| self.allocator.free(s);
            allocated_strings.deinit();
        }

        try args.append("./zig-out/bin/load_balancer");
        try args.append("--port");

        var lb_port_buf: [8]u8 = undefined;
        const lb_port_str = try std.fmt.bufPrint(&lb_port_buf, "{d}", .{test_utils.LB_PORT});
        const lb_port_dup = try self.allocator.dupe(u8, lb_port_str);
        try allocated_strings.append(lb_port_dup);
        try args.append(lb_port_dup);

        // Use single-process mode for easier testing
        try args.append("--mode");
        try args.append("sp");

        for (backend_ports) |port| {
            try args.append("--backend");
            var buf: [32]u8 = undefined;
            const backend_str = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port});
            const backend_dup = try self.allocator.dupe(u8, backend_str);
            try allocated_strings.append(backend_dup);
            try args.append(backend_dup);
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        try self.processes.append(.{
            .child = child,
            .name = try self.allocator.dupe(u8, "load_balancer"),
            .allocator = self.allocator,
        });

        // Wait for LB port
        try test_utils.waitForPort(test_utils.LB_PORT, 10000);

        // Wait for health checks (backends need to be marked healthy)
        std.time.sleep(2 * std.time.ns_per_s);
    }

    pub fn stopAll(self: *ProcessManager) void {
        // Stop in reverse order (LB first, then backends)
        while (self.processes.items.len > 0) {
            var proc = self.processes.pop();
            proc.kill();
            proc.deinit();
        }
    }
};
