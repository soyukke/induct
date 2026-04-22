const std = @import("std");
const Allocator = std.mem.Allocator;
const spec_mod = @import("spec.zig");
const TestCase = spec_mod.TestCase;

fn appendFmt(
    list: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var writer = std.Io.Writer.Allocating.fromArrayListAligned(allocator, .of(u8), list);
    defer list.* = writer.toArrayListAligned(.of(u8));
    try writer.writer.print(fmt, args);
}

pub const ValidationResult = struct {
    passed: bool,
    error_message: ?[]const u8,
    /// true if error_message is heap-allocated and must be freed by caller
    allocated: bool = false,
};

const max_display_len = 200;
const max_diff_lines = 20;
const err_output_mismatch_alloc = "Output mismatch (allocation failed)";
const err_output_missing_substring_alloc = "Output missing substring (allocation failed)";
const err_stderr_mismatch_alloc = "Stderr mismatch (allocation failed)";
const err_stderr_missing_substring_alloc = "Stderr missing substring (allocation failed)";
const err_contains_unwanted_substring = "contains unwanted substring";
const err_exit_code_mismatch = "Exit code mismatch";

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

/// Returns true if the string contains multiple lines (ignoring a single trailing newline).
fn isMultiline(s: []const u8) bool {
    const trimmed = if (s.len > 0 and s[s.len - 1] == '\n') s[0 .. s.len - 1] else s;
    return std.mem.indexOf(u8, trimmed, "\n") != null;
}

/// Split a string into lines, preserving the content without terminators.
fn splitLines(s: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, s, '\n');
}

/// Generate a line-by-line diff between expected and actual output.
/// Note: This is a simple line-by-line comparison, not LCS-based.
/// Insertions/deletions at the beginning will cause all subsequent lines to show as changed.
/// Only context lines around differences are shown (similar to unified diff).
fn generateDiff(allocator: Allocator, expected: []const u8, actual: []const u8) ![]const u8 {
    return generateDiffWithHeader(allocator, expected, actual, "Output mismatch (diff):\n");
}

fn generateStderrDiff(allocator: Allocator, expected: []const u8, actual: []const u8) ![]const u8 {
    return generateDiffWithHeader(allocator, expected, actual, "Stderr mismatch (diff):\n");
}

fn generateDiffWithHeader(
    allocator: Allocator,
    expected: []const u8,
    actual: []const u8,
    header: []const u8,
) ![]const u8 {
    const context_lines = 3;

    // First pass: collect all lines and find which are different
    var exp_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exp_lines.deinit(allocator);
    var act_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer act_lines.deinit(allocator);

    var exp_iter = splitLines(expected);
    while (exp_iter.next()) |line| try exp_lines.append(allocator, line);
    var act_iter = splitLines(actual);
    while (act_iter.next()) |line| try act_lines.append(allocator, line);

    const max_len = @max(exp_lines.items.len, act_lines.items.len);

    // Mark which lines should be displayed (different lines + context)
    var show = try allocator.alloc(bool, max_len);
    defer allocator.free(show);
    @memset(show, false);

    for (0..max_len) |i| {
        const is_diff = if (i < exp_lines.items.len and i < act_lines.items.len)
            !std.mem.eql(u8, exp_lines.items[i], act_lines.items[i])
        else
            true;
        if (is_diff) {
            const start = if (i >= context_lines) i - context_lines else 0;
            const end = @min(i + context_lines + 1, max_len);
            for (start..end) |j| show[j] = true;
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, header);
    try appendDiffRows(allocator, &out, show, exp_lines.items, act_lines.items, max_len);

    return try out.toOwnedSlice(allocator);
}

fn appendDiffRows(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    show: []const bool,
    exp_lines: []const []const u8,
    act_lines: []const []const u8,
    max_len: usize,
) !void {
    var diff_count: usize = 0;
    var in_gap = false;

    for (0..max_len) |i| {
        if (diff_count >= max_diff_lines) {
            try out.appendSlice(allocator, "  ... (diff truncated)\n");
            break;
        }
        if (!show[i]) {
            if (!in_gap) {
                try out.appendSlice(allocator, "  ...\n");
                in_gap = true;
            }
            continue;
        }
        in_gap = false;
        const line_num = i + 1;

        if (i < exp_lines.len and i < act_lines.len) {
            if (std.mem.eql(u8, exp_lines[i], act_lines[i])) {
                try appendFmt(out, allocator, "  {d: >3}   {s}\n", .{ line_num, exp_lines[i] });
            } else {
                try appendFmt(out, allocator, "  {d: >3} - {s}\n", .{ line_num, exp_lines[i] });
                try appendFmt(out, allocator, "      + {s}\n", .{act_lines[i]});
                diff_count += 1;
            }
        } else if (i < exp_lines.len) {
            try appendFmt(out, allocator, "  {d: >3} - {s}\n", .{ line_num, exp_lines[i] });
            diff_count += 1;
        } else if (i < act_lines.len) {
            try appendFmt(out, allocator, "  {d: >3} + {s}\n", .{ line_num, act_lines[i] });
            diff_count += 1;
        }
    }
}

pub fn validateOutput(
    allocator: Allocator,
    actual: []const u8,
    expect_exact: ?[]const u8,
    expect_contains: ?[]const []const u8,
) ValidationResult {
    const exact_result = validateExactOutput(allocator, actual, expect_exact);
    if (!exact_result.passed) return exact_result;

    return validateOutputContains(allocator, actual, expect_contains);
}

fn validateExactOutput(
    allocator: Allocator,
    actual: []const u8,
    expect_exact: ?[]const u8,
) ValidationResult {
    if (expect_exact) |expected| {
        if (!std.mem.eql(u8, actual, expected)) {
            if (isMultiline(expected) or isMultiline(actual)) {
                const msg = generateDiff(allocator, expected, actual) catch
                    return .{ .passed = false, .error_message = err_output_mismatch_alloc };
                return .{ .passed = false, .error_message = msg, .allocated = true };
            }

            const escaped_expected = escape(allocator, expected) catch
                return .{ .passed = false, .error_message = err_output_mismatch_alloc };
            const escaped_actual = escape(allocator, actual) catch {
                allocator.free(escaped_expected);
                return .{ .passed = false, .error_message = err_output_mismatch_alloc };
            };
            const msg = std.fmt.allocPrint(
                allocator,
                "Output mismatch\n  Expected: \"{s}\"\n  Actual:   \"{s}\"",
                .{ escaped_expected, escaped_actual },
            ) catch {
                allocator.free(escaped_expected);
                allocator.free(escaped_actual);
                return .{ .passed = false, .error_message = err_output_mismatch_alloc };
            };
            allocator.free(escaped_expected);
            allocator.free(escaped_actual);
            return .{ .passed = false, .error_message = msg, .allocated = true };
        }
    }
    return .{ .passed = true, .error_message = null };
}

fn validateOutputContains(
    allocator: Allocator,
    actual: []const u8,
    expect_contains: ?[]const []const u8,
) ValidationResult {
    if (expect_contains) |items| {
        for (items) |expected| {
            if (std.mem.indexOf(u8, actual, expected) == null) {
                const escaped_expected = escape(allocator, expected) catch
                    return .{
                        .passed = false,
                        .error_message = err_output_missing_substring_alloc,
                    };
                const escaped_actual = escape(allocator, actual) catch {
                    allocator.free(escaped_expected);
                    return .{
                        .passed = false,
                        .error_message = err_output_missing_substring_alloc,
                    };
                };
                const msg_format =
                    \\Output missing expected substring
                    \\  Expected to contain: "{s}"
                    \\  Actual: "{s}"
                ;
                const msg = std.fmt.allocPrint(
                    allocator,
                    msg_format,
                    .{ escaped_expected, escaped_actual },
                ) catch {
                    allocator.free(escaped_expected);
                    allocator.free(escaped_actual);
                    return .{
                        .passed = false,
                        .error_message = err_output_missing_substring_alloc,
                    };
                };
                allocator.free(escaped_expected);
                allocator.free(escaped_actual);
                return .{ .passed = false, .error_message = msg, .allocated = true };
            }
        }
    }
    return .{ .passed = true, .error_message = null };
}

fn validateNotContains(
    allocator: Allocator,
    actual: []const u8,
    not_contains: ?[]const []const u8,
    label: []const u8,
) ValidationResult {
    if (not_contains) |items| {
        for (items) |unexpected| {
            if (std.mem.indexOf(u8, actual, unexpected) != null) {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "{s} contains unwanted substring\n  Should not contain: \"{s}\"",
                    .{ label, truncate(unexpected) },
                ) catch return .{
                    .passed = false,
                    .error_message = err_contains_unwanted_substring,
                };
                return .{ .passed = false, .error_message = msg, .allocated = true };
            }
        }
    }
    return .{ .passed = true, .error_message = null };
}

pub fn validateOutputNotContains(
    allocator: Allocator,
    actual: []const u8,
    not_contains: ?[]const []const u8,
) ValidationResult {
    return validateNotContains(allocator, actual, not_contains, "Output");
}

pub fn validateStderrNotContains(
    allocator: Allocator,
    actual_stderr: []const u8,
    not_contains: ?[]const []const u8,
) ValidationResult {
    return validateNotContains(allocator, actual_stderr, not_contains, "Stderr");
}

pub fn validateStderr(
    allocator: Allocator,
    actual_stderr: []const u8,
    expect_stderr: ?[]const u8,
    expect_stderr_contains: ?[]const []const u8,
) ValidationResult {
    if (expect_stderr) |expected| {
        if (!std.mem.eql(u8, actual_stderr, expected)) {
            if (isMultiline(expected) or isMultiline(actual_stderr)) {
                const msg = generateStderrDiff(allocator, expected, actual_stderr) catch
                    return .{ .passed = false, .error_message = err_stderr_mismatch_alloc };
                return .{ .passed = false, .error_message = msg, .allocated = true };
            }

            const escaped_expected = escape(allocator, expected) catch
                return .{ .passed = false, .error_message = err_stderr_mismatch_alloc };
            const escaped_actual = escape(allocator, actual_stderr) catch {
                allocator.free(escaped_expected);
                return .{ .passed = false, .error_message = err_stderr_mismatch_alloc };
            };
            const msg = std.fmt.allocPrint(
                allocator,
                "Stderr mismatch\n  Expected: \"{s}\"\n  Actual:   \"{s}\"",
                .{ escaped_expected, escaped_actual },
            ) catch {
                allocator.free(escaped_expected);
                allocator.free(escaped_actual);
                return .{ .passed = false, .error_message = err_stderr_mismatch_alloc };
            };
            allocator.free(escaped_expected);
            allocator.free(escaped_actual);
            return .{ .passed = false, .error_message = msg, .allocated = true };
        }
    }
    if (expect_stderr_contains) |items| {
        for (items) |expected| {
            if (std.mem.indexOf(u8, actual_stderr, expected) == null) {
                const escaped_actual = escape(allocator, actual_stderr) catch
                    return .{
                        .passed = false,
                        .error_message = err_stderr_missing_substring_alloc,
                    };
                const msg_format =
                    \\Stderr missing expected substring
                    \\  Expected to contain: "{s}"
                    \\  Actual: "{s}"
                ;
                const msg = std.fmt.allocPrint(
                    allocator,
                    msg_format,
                    .{ truncate(expected), escaped_actual },
                ) catch {
                    allocator.free(escaped_actual);
                    return .{
                        .passed = false,
                        .error_message = err_stderr_missing_substring_alloc,
                    };
                };
                allocator.free(escaped_actual);
                return .{ .passed = false, .error_message = msg, .allocated = true };
            }
        }
    }
    return .{ .passed = true, .error_message = null };
}

pub fn validateExitCode(allocator: Allocator, actual: i32, expected: i32) ValidationResult {
    if (actual != expected) {
        const msg = std.fmt.allocPrint(
            allocator,
            "Exit code mismatch\n  Expected: {d}\n  Actual:   {d}",
            .{ expected, actual },
        ) catch return .{ .passed = false, .error_message = err_exit_code_mismatch };
        return .{ .passed = false, .error_message = msg, .allocated = true };
    }
    return .{ .passed = true, .error_message = null };
}

pub fn validateTestCase(
    allocator: Allocator,
    actual_output: []const u8,
    actual_stderr: []const u8,
    actual_exit_code: i32,
    tc: TestCase,
) ValidationResult {
    const exit_result = validateExitCode(allocator, actual_exit_code, tc.expect_exit_code);
    if (!exit_result.passed) return exit_result;

    const output_result = validateOutput(
        allocator,
        actual_output,
        tc.expect_output,
        tc.expect_output_contains,
    );
    if (!output_result.passed) return output_result;

    const not_contains_result = validateOutputNotContains(
        allocator,
        actual_output,
        tc.expect_output_not_contains,
    );
    if (!not_contains_result.passed) return not_contains_result;

    const stderr_result = validateStderr(
        allocator,
        actual_stderr,
        tc.expect_stderr,
        tc.expect_stderr_contains,
    );
    if (!stderr_result.passed) return stderr_result;

    const stderr_not_contains_result = validateStderrNotContains(
        allocator,
        actual_stderr,
        tc.expect_stderr_not_contains,
    );
    if (!stderr_not_contains_result.passed) return stderr_not_contains_result;

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
    const result = validateOutput(std.testing.allocator, "hello world\n", null, &.{"world"});
    try std.testing.expect(result.passed);
}

test "validate contains mismatch" {
    const result = validateOutput(std.testing.allocator, "hello world\n", null, &.{"foo"});
    defer if (result.allocated) std.testing.allocator.free(result.error_message.?);
    try std.testing.expect(!result.passed);
    try std.testing.expect(
        std.mem.indexOf(u8, result.error_message.?, "Expected to contain:") != null,
    );
}

test "validate not contains" {
    const r1 = validateOutputNotContains(std.testing.allocator, "hello world", &.{"foo"});
    try std.testing.expect(r1.passed);

    const r2 = validateOutputNotContains(std.testing.allocator, "hello world", &.{"world"});
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

    const r3 = validateStderr(std.testing.allocator, "error msg", null, &.{"error"});
    try std.testing.expect(r3.passed);

    const r4 = validateStderr(std.testing.allocator, "error msg", null, &.{"warning"});
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

test "validate stderr not contains" {
    const r1 = validateStderrNotContains(std.testing.allocator, "warning: minor", &.{"FATAL"});
    try std.testing.expect(r1.passed);

    const r2 = validateStderrNotContains(std.testing.allocator, "FATAL error", &.{"FATAL"});
    defer if (r2.allocated) std.testing.allocator.free(r2.error_message.?);
    try std.testing.expect(!r2.passed);
    try std.testing.expect(std.mem.indexOf(u8, r2.error_message.?, "Should not contain:") != null);
}

test "validateTestCase" {
    const r1 = validateTestCase(
        std.testing.allocator,
        "hello\n",
        "",
        0,
        .{ .command = "x", .expect_output = "hello\n" },
    );
    try std.testing.expect(r1.passed);

    const r2 = validateTestCase(
        std.testing.allocator,
        "hello\n",
        "",
        1,
        .{ .command = "x", .expect_output = "hello\n" },
    );
    defer if (r2.allocated) std.testing.allocator.free(r2.error_message.?);
    try std.testing.expect(!r2.passed);

    const r3 = validateTestCase(
        std.testing.allocator,
        "world\n",
        "",
        0,
        .{ .command = "x", .expect_output = "hello\n" },
    );
    defer if (r3.allocated) std.testing.allocator.free(r3.error_message.?);
    try std.testing.expect(!r3.passed);

    const r4 = validateTestCase(
        std.testing.allocator,
        "hello\n",
        "",
        0,
        .{ .command = "x", .expect_output_not_contains = &.{"hello"} },
    );
    defer if (r4.allocated) std.testing.allocator.free(r4.error_message.?);
    try std.testing.expect(!r4.passed);

    const r5 = validateTestCase(
        std.testing.allocator,
        "",
        "warning only",
        0,
        .{ .command = "x", .expect_stderr_not_contains = &.{"FATAL"} },
    );
    try std.testing.expect(r5.passed);

    const r6 = validateTestCase(
        std.testing.allocator,
        "",
        "FATAL crash",
        0,
        .{ .command = "x", .expect_stderr_not_contains = &.{"FATAL"} },
    );
    defer if (r6.allocated) std.testing.allocator.free(r6.error_message.?);
    try std.testing.expect(!r6.passed);
}
