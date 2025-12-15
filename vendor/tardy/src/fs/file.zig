const std = @import("std");
const assert = std.debug.assert;
const StdFile = std.fs.File;
const StdDir = std.fs.Dir;
const builtin = @import("builtin");

const Resulted = @import("../aio/completion.zig").Resulted;
const OpenFileResult = @import("../aio/completion.zig").OpenFileResult;
const OpenError = @import("../aio/completion.zig").OpenError;
const StatResult = @import("../aio/completion.zig").StatResult;
const StatError = @import("../aio/completion.zig").StatError;
const ReadResult = @import("../aio/completion.zig").ReadResult;
const ReadError = @import("../aio/completion.zig").ReadError;
const WriteResult = @import("../aio/completion.zig").WriteResult;
const WriteError = @import("../aio/completion.zig").WriteError;
const FileMode = @import("../aio/lib.zig").FileMode;
const AsyncOpenFlags = @import("../aio/lib.zig").AsyncOpenFlags;
const Cross = @import("../cross/lib.zig");
const Frame = @import("../frame/lib.zig").Frame;
const Runtime = @import("../runtime/lib.zig").Runtime;
const Path = @import("lib.zig").Path;
const Stat = @import("lib.zig").Stat;

const log = std.log.scoped(.@"tardy/fs/file");

pub const Writer = struct {
    file: File,
    err: ?anyerror = null,
    pos: u64 = 0,
    rt: *Runtime,
    interface: std.Io.Writer,

    pub fn init(file: File, rt: *Runtime, buffer: []u8) Writer {
        return .{
            .file = file,
            .rt = rt,
            .interface = initInterface(buffer),
        };
    }

    pub fn initInterface(buffer: []u8) std.Io.Writer {
        return .{
            .vtable = &.{
                .drain = drain,
                .sendFile = sendFile,
            },
            .buffer = buffer,
        };
    }

    pub fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        const buffered = io_w.buffered();
        if (buffered.len != 0) {
            const n = w.file.write(w.rt, buffered, w.pos) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            w.pos += n;
            return io_w.consume(n);
        }
        for (data[0 .. data.len - 1]) |buf| {
            if (buf.len == 0) continue;
            const n = w.file.write(w.rt, buf, w.pos) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            w.pos += n;
            return io_w.consume(n);
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 0 or splat == 0) return 0;
        const n = w.file.write(w.rt, pattern, w.pos) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        w.pos += n;
        return io_w.consume(n);
    }

    pub fn sendFile(
        io_w: *std.Io.Writer,
        file_reader: *std.fs.File.Reader,
        limit: std.Io.Limit,
    ) std.Io.Writer.FileError!usize {
        _ = io_w; // autofix
        _ = file_reader; // autofix
        _ = limit; // autofix
        return error.Unimplemented;
    }
};

pub const Reader = struct {
    file: File,
    err: ?anyerror = null,
    size: ?u64 = null,
    pos: u64 = 0,
    rt: *Runtime,
    interface: std.Io.Reader,

    pub fn init(file: File, rt: *Runtime, buffer: []u8) Reader {
        return .{
            .file = file,
            .rt = rt,
            .interface = initInterface(buffer),
        };
    }

    pub fn initInterface(buffer: []u8) std.Io.Reader {
        return .{
            .vtable = &.{
                .stream = stream,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        };
    }

    pub fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        const w_dest = limit.slice(try w.writableSliceGreedy(1));

        const n = r.file.read(r.rt, w_dest, r.pos) catch |err| switch (err) {
            error.EndOfFile => {
                r.size = r.pos;
                return error.EndOfStream;
            },
            else => {
                r.err = err;
                return error.ReadFailed;
            },
        };
        r.pos += n;
        w.advance(n);
        return n;
    }
};

pub const File = packed struct {
    handle: std.posix.fd_t,

    pub fn reader(file: File, rt: *Runtime, buffer: []u8) Reader {
        return .init(file, rt, buffer);
    }

    pub fn writer(file: File, rt: *Runtime, buffer: []u8) Writer {
        return .init(file, rt, buffer);
    }

    pub const CreateFlags = struct {
        mode: FileMode = .write,
        perms: isize = 0o644,
        truncate: bool = true,
        overwrite: bool = true,
    };

    pub const OpenFlags = struct {
        mode: FileMode = .read,
    };

    pub fn to_std(self: File) std.fs.File {
        return std.fs.File{ .handle = self.handle };
    }

    pub fn from_std(self: std.fs.File) File {
        return .{ .handle = self.handle };
    }

    /// Get `stdout` as a File.
    pub fn std_out() File {
        return .{ .handle = Cross.get_std_out() };
    }

    /// Get `stdin` as a File.
    pub fn std_in() File {
        return .{ .handle = Cross.get_std_in() };
    }

    /// Get `stderr` as a File.
    pub fn std_err() File {
        return .{ .handle = Cross.get_std_err() };
    }

    pub fn close(self: File, rt: *Runtime) !void {
        if (rt.aio.features.has_capability(.close))
            try rt.scheduler.io_await(.{ .close = self.handle })
        else
            std.posix.close(self.handle);
    }

    pub fn close_blocking(self: File) void {
        std.posix.close(self.handle);
    }

    pub fn create(rt: *Runtime, path: Path, flags: CreateFlags) !File {
        const aio_flags: AsyncOpenFlags = .{
            .mode = flags.mode,
            .perms = flags.perms,
            .create = true,
            .truncate = flags.truncate,
            .exclusive = !flags.overwrite,
            .directory = false,
        };

        if (rt.aio.features.has_capability(.open)) {
            try rt.scheduler.io_await(.{ .open = .{ .path = path, .flags = aio_flags } });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);

            const result: OpenFileResult = switch (task.result.open) {
                .actual => |actual| .{ .actual = actual.file },
                .err => |err| .{ .err = err },
            };

            return try result.unwrap();
        } else {
            const std_flags: StdFile.CreateFlags = .{
                .read = (aio_flags.mode == .read or aio_flags.mode == .read_write),
                .truncate = aio_flags.truncate,
                .exclusive = aio_flags.exclusive,
            };

            switch (path) {
                .rel => |inner| {
                    const dir: StdDir = .{ .fd = inner.dir };
                    const opened: StdFile = blk: while (true) {
                        break :blk dir.createFileZ(inner.path, std_flags) catch |e| return switch (e) {
                            StdFile.OpenError.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            StdFile.OpenError.AccessDenied => OpenError.AccessDenied,
                            StdFile.OpenError.BadPathName => OpenError.InvalidArguments,
                            StdFile.OpenError.DeviceBusy => OpenError.Busy,
                            StdFile.OpenError.SystemFdQuotaExceeded => OpenError.SystemFdQuotaExceeded,
                            StdFile.OpenError.ProcessFdQuotaExceeded => OpenError.ProcessFdQuotaExceeded,
                            StdFile.OpenError.FileNotFound => OpenError.NotFound,
                            StdFile.OpenError.PipeBusy => OpenError.Busy,
                            StdFile.OpenError.FileTooBig => OpenError.FileTooBig,
                            StdFile.OpenError.SharingViolation => OpenError.FileLocked,
                            StdFile.OpenError.IsDir => OpenError.IsDirectory,
                            StdFile.OpenError.NameTooLong => OpenError.NameTooLong,
                            StdFile.OpenError.NoDevice => OpenError.DeviceNotFound,
                            StdFile.OpenError.NoSpaceLeft => OpenError.NoSpace,
                            StdFile.OpenError.NotDir => OpenError.NotADirectory,
                            StdFile.OpenError.PathAlreadyExists => OpenError.AlreadyExists,
                            StdFile.OpenError.SymLinkLoop => OpenError.Loop,
                            StdFile.OpenError.SystemResources => OpenError.OutOfMemory,
                            else => OpenError.Unexpected,
                        };
                    };
                    try Cross.fd.to_nonblock(opened.handle);

                    return .{ .handle = opened.handle };
                },
                .abs => |inner| {
                    const opened: StdFile = blk: while (true) {
                        break :blk std.fs.createFileAbsoluteZ(inner, std_flags) catch |e| return switch (e) {
                            StdFile.OpenError.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            StdFile.OpenError.AccessDenied => OpenError.AccessDenied,
                            StdFile.OpenError.BadPathName => OpenError.InvalidArguments,
                            StdFile.OpenError.DeviceBusy, StdFile.OpenError.PipeBusy => OpenError.Busy,
                            StdFile.OpenError.SystemFdQuotaExceeded => OpenError.SystemFdQuotaExceeded,
                            StdFile.OpenError.ProcessFdQuotaExceeded => OpenError.ProcessFdQuotaExceeded,
                            StdFile.OpenError.FileNotFound => OpenError.NotFound,
                            StdFile.OpenError.FileTooBig => OpenError.FileTooBig,
                            StdFile.OpenError.SharingViolation => OpenError.FileLocked,
                            StdFile.OpenError.IsDir => OpenError.IsDirectory,
                            StdFile.OpenError.NameTooLong => OpenError.NameTooLong,
                            StdFile.OpenError.NoDevice => OpenError.DeviceNotFound,
                            StdFile.OpenError.NoSpaceLeft => OpenError.NoSpace,
                            StdFile.OpenError.NotDir => OpenError.NotADirectory,
                            StdFile.OpenError.PathAlreadyExists => OpenError.AlreadyExists,
                            StdFile.OpenError.SymLinkLoop => OpenError.Loop,
                            StdFile.OpenError.SystemResources => OpenError.OutOfMemory,
                            else => OpenError.Unexpected,
                        };
                    };
                    try Cross.fd.to_nonblock(opened.handle);

                    return .{ .handle = opened.handle };
                },
            }
        }
    }

    pub fn open(rt: *Runtime, path: Path, flags: OpenFlags) !File {
        if (rt.aio.features.has_capability(.open)) {
            const aio_flags: AsyncOpenFlags = .{
                .mode = flags.mode,
                .create = false,
                .directory = false,
            };

            try rt.scheduler.io_await(.{ .open = .{ .path = path, .flags = aio_flags } });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            const result: OpenFileResult = switch (task.result.open) {
                .actual => |actual| .{ .actual = actual.file },
                .err => |err| .{ .err = err },
            };

            return try result.unwrap();
        } else {
            const std_flags: StdFile.OpenFlags = .{
                .mode = switch (flags.mode) {
                    .read => .read_only,
                    .write => .write_only,
                    .read_write => .read_write,
                },
            };

            switch (path) {
                .rel => |inner| {
                    const dir: StdDir = .{ .fd = inner.dir };
                    const opened: StdFile = blk: while (true) {
                        break :blk dir.openFileZ(inner.path, std_flags) catch |e| return switch (e) {
                            StdFile.OpenError.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            StdFile.OpenError.AccessDenied => OpenError.AccessDenied,
                            StdFile.OpenError.BadPathName => OpenError.InvalidArguments,
                            StdFile.OpenError.DeviceBusy => OpenError.Busy,
                            StdFile.OpenError.SystemFdQuotaExceeded => OpenError.SystemFdQuotaExceeded,
                            StdFile.OpenError.ProcessFdQuotaExceeded => OpenError.ProcessFdQuotaExceeded,
                            StdFile.OpenError.FileNotFound => OpenError.NotFound,
                            StdFile.OpenError.PipeBusy => OpenError.Busy,
                            StdFile.OpenError.FileTooBig => OpenError.FileTooBig,
                            StdFile.OpenError.SharingViolation => OpenError.FileLocked,
                            StdFile.OpenError.IsDir => OpenError.IsDirectory,
                            StdFile.OpenError.NameTooLong => OpenError.NameTooLong,
                            StdFile.OpenError.NoDevice => OpenError.DeviceNotFound,
                            StdFile.OpenError.NoSpaceLeft => OpenError.NoSpace,
                            StdFile.OpenError.NotDir => OpenError.NotADirectory,
                            StdFile.OpenError.PathAlreadyExists => OpenError.AlreadyExists,
                            StdFile.OpenError.SymLinkLoop => OpenError.Loop,
                            StdFile.OpenError.SystemResources => OpenError.OutOfMemory,
                            else => OpenError.Unexpected,
                        };
                    };
                    try Cross.fd.to_nonblock(opened.handle);

                    return .{ .handle = opened.handle };
                },
                .abs => |inner| {
                    const opened: StdFile = blk: while (true) {
                        break :blk std.fs.openFileAbsoluteZ(inner, std_flags) catch |e| return switch (e) {
                            StdFile.OpenError.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            StdFile.OpenError.AccessDenied => OpenError.AccessDenied,
                            StdFile.OpenError.BadPathName => OpenError.InvalidArguments,
                            StdFile.OpenError.DeviceBusy, StdFile.OpenError.PipeBusy => OpenError.Busy,
                            StdFile.OpenError.SystemFdQuotaExceeded => OpenError.SystemFdQuotaExceeded,
                            StdFile.OpenError.ProcessFdQuotaExceeded => OpenError.ProcessFdQuotaExceeded,
                            StdFile.OpenError.FileNotFound => OpenError.NotFound,
                            StdFile.OpenError.FileTooBig => OpenError.FileTooBig,
                            StdFile.OpenError.SharingViolation => OpenError.FileLocked,
                            StdFile.OpenError.IsDir => OpenError.IsDirectory,
                            StdFile.OpenError.NameTooLong => OpenError.NameTooLong,
                            StdFile.OpenError.NoDevice => OpenError.DeviceNotFound,
                            StdFile.OpenError.NoSpaceLeft => OpenError.NoSpace,
                            StdFile.OpenError.NotDir => OpenError.NotADirectory,
                            StdFile.OpenError.PathAlreadyExists => OpenError.AlreadyExists,
                            StdFile.OpenError.SymLinkLoop => OpenError.Loop,
                            StdFile.OpenError.SystemResources => OpenError.OutOfMemory,
                            else => OpenError.Unexpected,
                        };
                    };
                    try Cross.fd.to_nonblock(opened.handle);

                    return .{ .handle = opened.handle };
                },
            }
        }
    }

    pub fn read(self: File, rt: *Runtime, buffer: []u8, offset: ?usize) !usize {
        if (rt.aio.features.has_capability(.read)) {
            try rt.scheduler.io_await(.{
                .read = .{
                    .fd = self.handle,
                    .buffer = buffer,
                    .offset = offset,
                },
            });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            return try task.result.read.unwrap();
        } else {
            const std_file = self.to_std();

            const count = blk: {
                if (offset) |o| {
                    while (true) {
                        break :blk std.fs.File.pread(std_file, buffer, o) catch |e| return switch (e) {
                            StdFile.PReadError.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            StdFile.PReadError.Unseekable => unreachable,
                            StdFile.PReadError.AccessDenied => ReadError.AccessDenied,
                            StdFile.PReadError.NotOpenForReading => ReadError.InvalidFd,
                            StdFile.PReadError.InputOutput => ReadError.IoError,
                            StdFile.PReadError.IsDir => ReadError.IsDirectory,
                            else => ReadError.Unexpected,
                        };
                    }
                } else {
                    while (true) {
                        break :blk std.fs.File.read(std_file, buffer) catch |e| return switch (e) {
                            StdFile.ReadError.WouldBlock => {
                                Frame.yield();
                                continue;
                            },
                            StdFile.ReadError.AccessDenied => ReadError.AccessDenied,
                            StdFile.ReadError.NotOpenForReading => ReadError.InvalidFd,
                            StdFile.ReadError.InputOutput => ReadError.IoError,
                            StdFile.ReadError.IsDir => ReadError.IsDirectory,
                            else => ReadError.Unexpected,
                        };
                    }
                }
            };

            if (count == 0) return ReadError.EndOfFile;
            return count;
        }
        return .{ .file = self, .buffer = buffer, .offset = offset };
    }

    pub fn read_all(self: File, rt: *Runtime, buffer: []u8, offset: ?usize) !usize {
        var length: usize = 0;

        while (length < buffer.len) {
            const real_offset: ?usize = if (offset) |o| o + length else null;

            const result = self.read(rt, buffer[length..], real_offset) catch |e| switch (e) {
                error.EndOfFile => return length,
                else => return e,
            };

            length += result;
        }

        return length;
    }

    pub fn write(self: File, rt: *Runtime, buffer: []const u8, offset: ?usize) !usize {
        if (rt.aio.features.has_capability(.write)) {
            try rt.scheduler.io_await(.{
                .write = .{ .fd = self.handle, .buffer = buffer, .offset = offset },
            });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            return try task.result.write.unwrap();
        } else {
            const std_file = self.to_std();

            // TODO: Proper error handling.
            if (offset) |o| {
                return blk: while (true) {
                    break :blk std.fs.File.pwrite(std_file, buffer, o) catch |e| switch (e) {
                        StdFile.PWriteError.WouldBlock => {
                            Frame.yield();
                            continue;
                        },
                        StdFile.PWriteError.Unseekable => unreachable,
                        StdFile.PWriteError.DiskQuota => WriteError.DiskQuotaExceeded,
                        StdFile.PWriteError.FileTooBig => WriteError.FileTooBig,
                        StdFile.PWriteError.InvalidArgument => WriteError.InvalidArguments,
                        StdFile.PWriteError.InputOutput => WriteError.IoError,
                        StdFile.PWriteError.NoSpaceLeft => WriteError.NoSpace,
                        StdFile.PWriteError.AccessDenied => WriteError.AccessDenied,
                        StdFile.PWriteError.NotOpenForWriting => WriteError.InvalidFd,
                        StdFile.PWriteError.BrokenPipe => WriteError.BrokenPipe,
                        else => WriteError.Unexpected,
                    };
                };
            } else {
                return blk: while (true) {
                    break :blk std.fs.File.write(std_file, buffer) catch |e| switch (e) {
                        StdFile.WriteError.WouldBlock => {
                            Frame.yield();
                            continue;
                        },
                        StdFile.WriteError.DiskQuota => WriteError.DiskQuotaExceeded,
                        StdFile.WriteError.FileTooBig => WriteError.FileTooBig,
                        StdFile.WriteError.InvalidArgument => WriteError.InvalidArguments,
                        StdFile.WriteError.InputOutput => WriteError.IoError,
                        StdFile.WriteError.NoSpaceLeft => WriteError.NoSpace,
                        StdFile.WriteError.AccessDenied => WriteError.AccessDenied,
                        StdFile.WriteError.NotOpenForWriting => WriteError.InvalidFd,
                        StdFile.WriteError.BrokenPipe => WriteError.BrokenPipe,
                        else => WriteError.Unexpected,
                    };
                };
            }
        }
    }

    pub fn write_all(self: File, rt: *Runtime, buffer: []const u8, offset: ?usize) !usize {
        var length: usize = 0;

        while (length < buffer.len) {
            const real_offset: ?usize = if (offset) |o| o + length else null;

            const result = self.write(rt, buffer[length..], real_offset) catch |e| switch (e) {
                error.NoSpace => return length,
                else => return e,
            };

            length += result;
        }

        return length;
    }

    pub fn stat(self: File, rt: *Runtime) !Stat {
        if (rt.aio.features.has_capability(.stat)) {
            try rt.scheduler.io_await(.{ .stat = self.handle });

            const index = rt.current_task.?;
            const task = rt.scheduler.tasks.get(index);
            return try task.result.stat.unwrap();
        } else {
            const std_file = self.to_std();

            const file_stat = std_file.stat() catch |e| {
                return switch (e) {
                    StdFile.StatError.AccessDenied => StatError.AccessDenied,
                    StdFile.StatError.SystemResources => StatError.OutOfMemory,
                    StdFile.StatError.Unexpected => StatError.Unexpected,
                    StdFile.StatError.PermissionDenied => StatError.PermissionDenied,
                };
            };

            return .{
                .size = file_stat.size,
                .mode = file_stat.mode,
                .changed = .{
                    .seconds = @intCast(@divTrunc(file_stat.ctime, std.time.ns_per_s)),
                    .nanos = @intCast(@mod(file_stat.ctime, std.time.ns_per_s)),
                },
                .modified = .{
                    .seconds = @intCast(@divTrunc(file_stat.mtime, std.time.ns_per_s)),
                    .nanos = @intCast(@mod(file_stat.mtime, std.time.ns_per_s)),
                },
                .accessed = .{
                    .seconds = @intCast(@divTrunc(file_stat.atime, std.time.ns_per_s)),
                    .nanos = @intCast(@mod(file_stat.atime, std.time.ns_per_s)),
                },
            };
        }
    }

    // TODO: sendFile like api is a more appropriate for this
    pub fn stream_to(from: File, to_w: *std.Io.Writer, rt: *Runtime) !void {
        std.debug.assert(to_w.buffer.len > 0);

        var file = from.reader(rt, &.{});
        const file_r = &file.interface;
        while (true) {
            _ = Reader.stream(file_r, to_w, .limited(to_w.buffer.len)) catch |e| switch (e) {
                error.EndOfStream => break,
                else => {
                    return e;
                },
            };
            _ = to_w.vtable.drain(to_w, &.{}, 0) catch break;
        }
    }
};
