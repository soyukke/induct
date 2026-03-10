const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ValidationResult = struct {
    passed: bool,
    error_message: ?[]const u8,
    /// true if error_message is heap-allocated and must be freed by caller
    allocated: bool = false,
};

const max_display_len = 200;

pub fn truncate(s: []const u8) []const u8 {
    if (s.len <= max_display_len) return s;
    return s[0..max_display_len];
}

fn escape(allocator: Allocator, s: []const u8) ![]const u8 {
    const truncated = truncate(s);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (truncated) |c| {
        switch (c) {
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    if (s.len > max_display_len) {
        try out.appendSlice(allocator, "...");
    }
    return try out.toOwnedSlice(allocator);
}

pub fn validateOutput(
    allocator: Allocator,
    actual: []const u8,
    expect_exact: ?[]const u8,
    expect_contains: ?[]const u8,
) ValidationResult {
    if (expect_exact) |expected| {
        if (!std.mem.eql(u8, actual, expected)) {
            const escaped_expected = escape(allocator, expected) catch return .{ .passed = false, .error_message = "Output mismatch (allocation failed)" };
            const escaped_actual = escape(allocator, actual) catch {
                allocator.free(escaped_expected);
                return .{ .passed = false, .error_message = "Output mismatch (allocation failed)" };
            };
            const msg = std.fmt.allocPrint(allocator, "Output mismatch\n  Expected: \"{s}\"\n  Actual:   \"{s}\"", .{ escaped_expected, escaped_actual }) catch {
                allocator.free(escaped_expected);
                allocator.free(escaped_actual);
                return .{ .passed = false, .error_message = "Output mismatch (allocation failed)" };
            };
            allocator.free(escaped_expected);
            allocator.free(escaped_actual);
            return .{ .passed = false, .error_message = msg, .allocated = true };
        }
    }

    if (expect_contains) |expected| {
        if (std.mem.indexOf(u8, actual, expected) == null) {
            const escaped_expected = escape(allocator, expected) catch return .{ .passed = false, .error_message = "Output missing substring (allocation failed)" };
            const escaped_actual = escape(allocator, actual) catch {
                allocator.free(escaped_expected);
                return .{ .passed = false, .error_message = "Output missing substring (allocation failed)" };
            };
            const msg = std.fmt.allocPrint(allocator, "Output missing expected substring\n  Expected to contain: \"{s}\"\n  Actual: \"{s}\"", .{ escaped_expected, escaped_actual }) catch {
                allocator.free(escaped_expected);
                allocator.free(escaped_actual);
                return .{ .passed = false, .error_message = "Output missing substring (allocation failed)" };
            };
            allocator.free(escaped_expected);
            allocator.free(escaped_actual);
            return .{ .passed = false, .error_message = msg, .allocated = true };
        }
    }

    return .{ .passed = true, .error_message = null };
}

pub fn validateOutputNotContains(
    allocator: Allocator,
    actual: []const u8,
    not_contains: ?[]const u8,
) ValidationResult {
    if (not_contains) |unexpected| {
        if (std.mem.indexOf(u8, actual, unexpected) != null) {
            const msg = std.fmt.allocPrint(allocator, "Output contains unwanted substring\n  Should not contain: \"{s}\"", .{truncate(unexpected)}) catch
                return .{ .passed = false, .error_message = "Output contains unwanted substring" };
            return .{ .passed = false, .error_message = msg, .allocated = true };
        }
    }
    return .{ .passed = true, .error_message = null };
}

pub fn validateStderr(
    allocator: Allocator,
    actual_stderr: []const u8,
    expect_stderr: ?[]const u8,
    expect_stderr_contains: ?[]const u8,
) ValidationResult {
    if (expect_stderr) |expected| {
        if (!std.mem.eql(u8, actual_stderr, expected)) {
            const escaped_expected = escape(allocator, expected) catch return .{ .passed = false, .error_message = "Stderr mismatch (allocation failed)" };
            const escaped_actual = escape(allocator, actual_stderr) catch {
                allocator.free(escaped_expected);
                return .{ .passed = false, .error_message = "Stderr mismatch (allocation failed)" };
            };
            const msg = std.fmt.allocPrint(allocator, "Stderr mismatch\n  Expected: \"{s}\"\n  Actual:   \"{s}\"", .{ escaped_expected, escaped_actual }) catch {
                allocator.free(escaped_expected);
                allocator.free(escaped_actual);
                return .{ .passed = false, .error_message = "Stderr mismatch (allocation failed)" };
            };
            allocator.free(escaped_expected);
            allocator.free(escaped_actual);
            return .{ .passed = false, .error_message = msg, .allocated = true };
        }
    }
    if (expect_stderr_contains) |expected| {
        if (std.mem.indexOf(u8, actual_stderr, expected) == null) {
            const escaped_actual = escape(allocator, actual_stderr) catch return .{ .passed = false, .error_message = "Stderr missing substring (allocation failed)" };
            const msg = std.fmt.allocPrint(allocator, "Stderr missing expected substring\n  Expected to contain: \"{s}\"\n  Actual: \"{s}\"", .{ truncate(expected), escaped_actual }) catch {
                allocator.free(escaped_actual);
                return .{ .passed = false, .error_message = "Stderr missing substring (allocation failed)" };
            };
            allocator.free(escaped_actual);
            return .{ .passed = false, .error_message = msg, .allocated = true };
        }
    }
    return .{ .passed = true, .error_message = null };
}

pub fn validateExitCode(allocator: Allocator, actual: i32, expected: i32) ValidationResult {
    if (actual != expected) {
        const msg = std.fmt.allocPrint(allocator, "Exit code mismatch\n  Expected: {d}\n  Actual:   {d}", .{ expected, actual }) catch
            return .{ .passed = false, .error_message = "Exit code mismatch" };
        return .{ .passed = false, .error_message = msg, .allocated = true };
    }
    return .{ .passed = true, .error_message = null };
}

pub fn validate(
    allocator: Allocator,
    actual_output: []const u8,
    actual_stderr: []const u8,
    actual_exit_code: i32,
    expect_output: ?[]const u8,
    expect_output_contains: ?[]const u8,
    expect_output_not_contains: ?[]const u8,
    expect_stderr: ?[]const u8,
    expect_stderr_contains: ?[]const u8,
    expect_exit_code: i32,
) ValidationResult {
    const exit_result = validateExitCode(allocator, actual_exit_code, expect_exit_code);
    if (!exit_result.passed) return exit_result;

    const output_result = validateOutput(allocator, actual_output, expect_output, expect_output_contains);
    if (!output_result.passed) return output_result;

    const not_contains_result = validateOutputNotContains(allocator, actual_output, expect_output_not_contains);
    if (!not_contains_result.passed) return not_contains_result;

    const stderr_result = validateStderr(allocator, actual_stderr, expect_stderr, expect_stderr_contains);
    if (!stderr_result.passed) return stderr_result;

    return .{ .passed = true, .error_message = null };
}

test "validate exact output match" {
    const result = validateOutput(std.testing.allocator, "hello\n", "hello\n", null);
    try std.testing.expect(result.passed);
}

test "validate exact output mismatch" {
    const result = validateOutput(std.testing.allocator, "hello\n", "world\n", null);
    defer if (result.allocated) std.testing.allocator.free(result.error_message.?);
    try std.testing.expect(!result.passed);
    try std.testing.expect(result.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "Expected:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "Actual:") != null);
}

test "validate contains match" {
    const result = validateOutput(std.testing.allocator, "hello world\n", null, "world");
    try std.testing.expect(result.passed);
}

test "validate contains mismatch" {
    const result = validateOutput(std.testing.allocator, "hello world\n", null, "foo");
    defer if (result.allocated) std.testing.allocator.free(result.error_message.?);
    try std.testing.expect(!result.passed);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "Expected to contain:") != null);
}

test "validate not contains" {
    const r1 = validateOutputNotContains(std.testing.allocator, "hello world", "foo");
    try std.testing.expect(r1.passed);

    const r2 = validateOutputNotContains(std.testing.allocator, "hello world", "world");
    defer if (r2.allocated) std.testing.allocator.free(r2.error_message.?);
    try std.testing.expect(!r2.passed);
    try std.testing.expect(std.mem.indexOf(u8, r2.error_message.?, "Should not contain:") != null);
}

test "validate stderr" {
    const r1 = validateStderr(std.testing.allocator, "error msg", "error msg", null);
    try std.testing.expect(r1.passed);

    const r2 = validateStderr(std.testing.allocator, "error msg", "other", null);
    defer if (r2.allocated) std.testing.allocator.free(r2.error_message.?);
    try std.testing.expect(!r2.passed);

    const r3 = validateStderr(std.testing.allocator, "error msg", null, "error");
    try std.testing.expect(r3.passed);

    const r4 = validateStderr(std.testing.allocator, "error msg", null, "warning");
    defer if (r4.allocated) std.testing.allocator.free(r4.error_message.?);
    try std.testing.expect(!r4.passed);
}

test "validate exit code" {
    const r1 = validateExitCode(std.testing.allocator, 0, 0);
    try std.testing.expect(r1.passed);

    const r2 = validateExitCode(std.testing.allocator, 1, 0);
    defer if (r2.allocated) std.testing.allocator.free(r2.error_message.?);
    try std.testing.expect(!r2.passed);
    try std.testing.expect(std.mem.indexOf(u8, r2.error_message.?, "Expected: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.error_message.?, "Actual:   1") != null);

    const r3 = validateExitCode(std.testing.allocator, 1, 1);
    try std.testing.expect(r3.passed);
}

test "validate all" {
    const r1 = validate(std.testing.allocator, "hello\n", "", 0, "hello\n", null, null, null, null, 0);
    try std.testing.expect(r1.passed);

    const r2 = validate(std.testing.allocator, "hello\n", "", 1, "hello\n", null, null, null, null, 0);
    defer if (r2.allocated) std.testing.allocator.free(r2.error_message.?);
    try std.testing.expect(!r2.passed);

    const r3 = validate(std.testing.allocator, "world\n", "", 0, "hello\n", null, null, null, null, 0);
    defer if (r3.allocated) std.testing.allocator.free(r3.error_message.?);
    try std.testing.expect(!r3.passed);

    const r4 = validate(std.testing.allocator, "hello\n", "", 0, null, null, "hello", null, null, 0);
    defer if (r4.allocated) std.testing.allocator.free(r4.error_message.?);
    try std.testing.expect(!r4.passed);
}
