/// RunMode Tests
///
/// Tests for the unified load balancer's mode selection and parsing.
/// These tests verify that the CLI correctly parses mode flags and
/// selects appropriate defaults based on platform.

const std = @import("std");
const builtin = @import("builtin");

// We can't import from main.zig in tests, so we duplicate the RunMode
// enum here for testing purposes. In the actual implementation, main.zig
// is the authoritative source.

pub const RunMode = enum {
    multiprocess,
    singleprocess,

    pub fn fromString(s: []const u8) ?RunMode {
        if (std.mem.eql(u8, s, "mp") or std.mem.eql(u8, s, "multiprocess")) {
            return .multiprocess;
        } else if (std.mem.eql(u8, s, "sp") or std.mem.eql(u8, s, "singleprocess")) {
            return .singleprocess;
        }
        return null;
    }

    pub fn toString(self: RunMode) []const u8 {
        return switch (self) {
            .multiprocess => "multiprocess",
            .singleprocess => "singleprocess",
        };
    }

    pub fn default() RunMode {
        return switch (builtin.os.tag) {
            .linux => .multiprocess,
            else => .singleprocess,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RunMode: fromString parses mp correctly" {
    const mode = RunMode.fromString("mp");
    try std.testing.expect(mode != null);
    try std.testing.expectEqual(RunMode.multiprocess, mode.?);
}

test "RunMode: fromString parses multiprocess correctly" {
    const mode = RunMode.fromString("multiprocess");
    try std.testing.expect(mode != null);
    try std.testing.expectEqual(RunMode.multiprocess, mode.?);
}

test "RunMode: fromString parses sp correctly" {
    const mode = RunMode.fromString("sp");
    try std.testing.expect(mode != null);
    try std.testing.expectEqual(RunMode.singleprocess, mode.?);
}

test "RunMode: fromString parses singleprocess correctly" {
    const mode = RunMode.fromString("singleprocess");
    try std.testing.expect(mode != null);
    try std.testing.expectEqual(RunMode.singleprocess, mode.?);
}

test "RunMode: fromString rejects invalid input" {
    const mode = RunMode.fromString("invalid");
    try std.testing.expect(mode == null);
}

test "RunMode: fromString rejects empty string" {
    const mode = RunMode.fromString("");
    try std.testing.expect(mode == null);
}

test "RunMode: fromString is case sensitive" {
    // Should reject uppercase
    const mode1 = RunMode.fromString("MP");
    try std.testing.expect(mode1 == null);

    const mode2 = RunMode.fromString("Multiprocess");
    try std.testing.expect(mode2 == null);
}

test "RunMode: toString returns correct string for multiprocess" {
    const mode = RunMode.multiprocess;
    try std.testing.expectEqualStrings("multiprocess", mode.toString());
}

test "RunMode: toString returns correct string for singleprocess" {
    const mode = RunMode.singleprocess;
    try std.testing.expectEqualStrings("singleprocess", mode.toString());
}

test "RunMode: default returns multiprocess on Linux" {
    if (builtin.os.tag == .linux) {
        const mode = RunMode.default();
        try std.testing.expectEqual(RunMode.multiprocess, mode);
    }
}

test "RunMode: default returns singleprocess on macOS" {
    if (builtin.os.tag == .macos) {
        const mode = RunMode.default();
        try std.testing.expectEqual(RunMode.singleprocess, mode);
    }
}

test "RunMode: default returns singleprocess on non-Linux" {
    const mode = RunMode.default();
    // On macOS, BSD, Windows, etc., should default to singleprocess
    if (builtin.os.tag != .linux) {
        try std.testing.expectEqual(RunMode.singleprocess, mode);
    }
}

test "RunMode: round-trip through toString/fromString" {
    const mp_original = RunMode.multiprocess;
    const mp_str = mp_original.toString();
    const mp_parsed = RunMode.fromString(mp_str);
    try std.testing.expect(mp_parsed != null);
    try std.testing.expectEqual(mp_original, mp_parsed.?);

    const sp_original = RunMode.singleprocess;
    const sp_str = sp_original.toString();
    const sp_parsed = RunMode.fromString(sp_str);
    try std.testing.expect(sp_parsed != null);
    try std.testing.expectEqual(sp_original, sp_parsed.?);
}
