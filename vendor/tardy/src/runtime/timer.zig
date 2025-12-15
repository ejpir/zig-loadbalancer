const Frame = @import("../frame/lib.zig").Frame;
const Timespec = @import("../lib.zig").Timespec;
const Runtime = @import("lib.zig").Runtime;

pub const Timer = struct {
    pub fn delay(rt: *Runtime, timespec: Timespec) !void {
        try rt.scheduler.io_await(.{ .timer = timespec });
    }
};
