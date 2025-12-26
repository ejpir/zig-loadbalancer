//! Process manager for integration tests.
//!
//! Handles spawning and cleanup of backend/load balancer processes.
//! Supports both HTTP/1.1 (Zig) and HTTP/2 (Python/hypercorn) backends.

const std = @import("std");
const posix = std.posix;
const test_utils = @import("test_utils.zig");

pub const H2_BACKEND_PORT: u16 = 9443;

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
            .processes = .empty,
        };
    }

    pub fn deinit(self: *ProcessManager) void {
        self.stopAll();
        self.processes.deinit(self.allocator);
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

        try self.processes.append(self.allocator, .{
            .child = child,
            .name = try std.fmt.allocPrint(self.allocator, "backend_{s}", .{server_id}),
            .allocator = self.allocator,
        });

        // Wait for port to be ready
        try test_utils.waitForPort(port, 10000);
    }

    pub fn startLoadBalancer(self: *ProcessManager, backend_ports: []const u16) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        // Track strings we allocate so we can free them
        var allocated_strings: std.ArrayList([]const u8) = .empty;
        defer {
            for (allocated_strings.items) |s| self.allocator.free(s);
            allocated_strings.deinit(self.allocator);
        }

        try args.append(self.allocator, "./zig-out/bin/load_balancer");
        try args.append(self.allocator, "--port");

        var lb_port_buf: [8]u8 = undefined;
        const lb_port_str = try std.fmt.bufPrint(&lb_port_buf, "{d}", .{test_utils.LB_PORT});
        const lb_port_dup = try self.allocator.dupe(u8, lb_port_str);
        try allocated_strings.append(self.allocator, lb_port_dup);
        try args.append(self.allocator, lb_port_dup);

        // Use single-process mode for easier testing
        try args.append(self.allocator, "--mode");
        try args.append(self.allocator, "sp");

        for (backend_ports) |port| {
            try args.append(self.allocator, "--backend");
            var buf: [32]u8 = undefined;
            const backend_str = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port});
            const backend_dup = try self.allocator.dupe(u8, backend_str);
            try allocated_strings.append(self.allocator, backend_dup);
            try args.append(self.allocator, backend_dup);
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

        try self.processes.append(self.allocator, .{
            .child = child,
            .name = try self.allocator.dupe(u8, "load_balancer"),
            .allocator = self.allocator,
        });

        // Wait for LB port
        try test_utils.waitForPort(test_utils.LB_PORT, 10000);

        // Wait for health checks (backends need to be marked healthy)
        posix.nanosleep(2, 0);
    }

    /// Start HTTP/2 backend using Python hypercorn
    pub fn startH2Backend(self: *ProcessManager) !void {
        // Use bash to activate venv and run hypercorn
        var child = std.process.Child.init(
            &.{
                "/bin/bash", "-c",
                "cd tests && source .venv/bin/activate && " ++
                    "hypercorn h2_backend:app --bind 0.0.0.0:9443 " ++
                    "--certfile ../test_certs/cert.pem " ++
                    "--keyfile ../test_certs/key.pem " ++
                    "2>&1",
            },
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

        try self.processes.append(self.allocator, .{
            .child = child,
            .name = try self.allocator.dupe(u8, "h2_backend"),
            .allocator = self.allocator,
        });

        // Wait for port to be ready (HTTPS so need longer timeout)
        try test_utils.waitForTlsPort(H2_BACKEND_PORT, 15000);
    }

    /// Start load balancer configured for HTTP/2 TLS backend
    pub fn startLoadBalancerH2(self: *ProcessManager) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        // Track strings we allocate so we can free them
        var allocated_strings: std.ArrayList([]const u8) = .empty;
        defer {
            for (allocated_strings.items) |s| self.allocator.free(s);
            allocated_strings.deinit(self.allocator);
        }

        try args.append(self.allocator, "./zig-out/bin/load_balancer");
        try args.append(self.allocator, "--port");

        var lb_port_buf: [8]u8 = undefined;
        const lb_port_str = try std.fmt.bufPrint(&lb_port_buf, "{d}", .{test_utils.LB_H2_PORT});
        const lb_port_dup = try self.allocator.dupe(u8, lb_port_str);
        try allocated_strings.append(self.allocator, lb_port_dup);
        try args.append(self.allocator, lb_port_dup);

        // Use single-process mode for easier testing
        try args.append(self.allocator, "--mode");
        try args.append(self.allocator, "sp");

        // Use HTTPS backend
        try args.append(self.allocator, "--backend");
        var buf: [64]u8 = undefined;
        const backend_str = try std.fmt.bufPrint(&buf, "https://127.0.0.1:{d}", .{H2_BACKEND_PORT});
        const backend_dup = try self.allocator.dupe(u8, backend_str);
        try allocated_strings.append(self.allocator, backend_dup);
        try args.append(self.allocator, backend_dup);

        // Skip TLS verification for self-signed test certs
        try args.append(self.allocator, "--insecure");

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        try self.processes.append(self.allocator, .{
            .child = child,
            .name = try self.allocator.dupe(u8, "load_balancer_h2"),
            .allocator = self.allocator,
        });

        // Wait for LB port
        try test_utils.waitForPort(test_utils.LB_H2_PORT, 10000);

        // Wait for health checks and HTTP/2 connection establishment
        posix.nanosleep(3, 0);
    }

    pub fn stopAll(self: *ProcessManager) void {
        // Stop in reverse order (LB first, then backends)
        while (self.processes.pop()) |*proc| {
            var p = proc.*;
            p.kill();
            p.deinit();
        }
    }
};
