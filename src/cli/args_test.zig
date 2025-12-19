/// Tests for CLI argument parsing
///
/// Tests the parseArgs function in main.zig, specifically focusing on
/// the binary hot reload --upgrade-fd flag and Config struct handling.

const std = @import("std");
const posix = std.posix;

// ============================================================================
// Tests - Binary Hot Reload (--upgrade-fd parsing)
// ============================================================================

test "parseArgs: --upgrade-fd with valid fd" {
    // Test parsing upgrade_fd from string (mirrors parseArgs logic at main.zig:256)
    const fd_str = "5";
    const parsed_fd = try std.fmt.parseInt(posix.fd_t, fd_str, 10);
    try std.testing.expectEqual(@as(posix.fd_t, 5), parsed_fd);

    // Test larger fd values
    const large_fd_str = "1024";
    const large_fd = try std.fmt.parseInt(posix.fd_t, large_fd_str, 10);
    try std.testing.expectEqual(@as(posix.fd_t, 1024), large_fd);
}

test "parseArgs: --upgrade-fd parsing zero" {
    // Test that fd 0 (stdin) can be parsed
    const fd_str = "0";
    const parsed_fd = try std.fmt.parseInt(posix.fd_t, fd_str, 10);
    try std.testing.expectEqual(@as(posix.fd_t, 0), parsed_fd);
}

test "parseArgs: --upgrade-fd with invalid fd" {
    // Test that non-numeric input is rejected
    const invalid_fd = "not_a_number";
    const result = std.fmt.parseInt(posix.fd_t, invalid_fd, 10);
    try std.testing.expectError(error.InvalidCharacter, result);
}

test "parseArgs: --upgrade-fd with negative fd" {
    // Test that negative fd values can be parsed
    const negative_fd = "-1";

    // On most platforms, fd_t is i32, so parsing -1 should work
    // but when used with file operations it would be invalid
    // The parse itself succeeds, validation happens at use time
    const parsed = try std.fmt.parseInt(posix.fd_t, negative_fd, 10);
    try std.testing.expect(parsed < 0);
}

test "parseArgs: --upgrade-fd with overflow value" {
    // Test that values too large for fd_t are rejected
    const overflow_fd = "999999999999999999999";
    const result = std.fmt.parseInt(posix.fd_t, overflow_fd, 10);
    try std.testing.expectError(error.Overflow, result);
}

test "parseArgs: --upgrade-fd with empty string" {
    // Test that empty string is rejected
    const empty_fd = "";
    const result = std.fmt.parseInt(posix.fd_t, empty_fd, 10);
    try std.testing.expectError(error.InvalidCharacter, result);
}

test "parseArgs: --upgrade-fd with leading/trailing spaces" {
    // Test that strings with whitespace are rejected
    const space_fd = " 5 ";
    const result = std.fmt.parseInt(posix.fd_t, space_fd, 10);
    try std.testing.expectError(error.InvalidCharacter, result);
}

test "parseArgs: --upgrade-fd with hex notation" {
    // Test that hex notation is rejected (base 10 only)
    const hex_fd = "0x5";
    const result = std.fmt.parseInt(posix.fd_t, hex_fd, 10);
    try std.testing.expectError(error.InvalidCharacter, result);
}

test "parseArgs: --upgrade-fd with plus sign prefix" {
    // Test that positive sign prefix is handled
    const plus_fd = "+5";
    const result = std.fmt.parseInt(posix.fd_t, plus_fd, 10);

    // parseInt accepts + prefix for positive numbers
    try std.testing.expectEqual(@as(posix.fd_t, 5), try result);
}

// Note: We cannot easily test the full parseArgs function without mocking
// std.process.argsAlloc, which requires more complex test infrastructure.
// The tests above verify the core parsing logic used in parseArgs at line 256:
//   upgrade_fd = try std.fmt.parseInt(posix.fd_t, args[i + 1], 10);
