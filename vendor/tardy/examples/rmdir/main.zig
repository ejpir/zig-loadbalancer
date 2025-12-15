const std = @import("std");

const Cross = @import("tardy").Cross;
const Dir = @import("tardy").Dir;
const Runtime = @import("tardy").Runtime;
const Task = @import("tardy").Task;

const Tardy = @import("tardy").Tardy(.auto);
const log = std.log.scoped(.@"tardy/example/rmdir");

fn main_frame(rt: *Runtime, name: [:0]const u8) !void {
    try Dir.cwd().delete_tree(rt, name);
    log.debug("deleted tree :)", .{});
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var tardy: Tardy = try .init(allocator, .{
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = 1,
        .size_aio_reap_max = 1,
    });
    defer tardy.deinit();

    var i: usize = 0;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const tree_name: [:0]const u8 = blk: {
        while (args.next()) |arg| : (i += 1) {
            if (i == 1) break :blk arg;
        }

        try std.fs.File.stdout().writeAll("tree name not passed in: ./rmdir [tree name]");
        return;
    };

    try tardy.entry(
        tree_name,
        struct {
            fn start(rt: *Runtime, name: [:0]const u8) !void {
                try rt.spawn(.{ rt, name }, main_frame, 1024 * 1024 * 2);
            }
        }.start,
    );
}
