const std = @import("std");

pub const ValidationResult = struct {
    passed: bool,
    error_message: ?[]const u8,
};

pub fn validateOutput(
    actual: []const u8,
    expect_exact: ?[]const u8,
    expect_contains: ?[]const u8,
) ValidationResult {
    // Check exact match if specified
    if (expect_exact) |expected| {
        if (!std.mem.eql(u8, actual, expected)) {
            return .{
                .passed = false,
                .error_message = "Output does not match expected value",
            };
        }
    }

    // Check contains if specified
    if (expect_contains) |expected| {
        if (std.mem.indexOf(u8, actual, expected) == null) {
            return .{
                .passed = false,
                .error_message = "Output does not contain expected substring",
            };
        }
    }

    return .{
        .passed = true,
        .error_message = null,
    };
}

pub fn validateExitCode(actual: i32, expected: i32) ValidationResult {
    if (actual != expected) {
        return .{
            .passed = false,
            .error_message = "Exit code does not match expected value",
        };
    }
    return .{
        .passed = true,
        .error_message = null,
    };
}

pub fn validate(
    actual_output: []const u8,
    actual_exit_code: i32,
    expect_output: ?[]const u8,
    expect_output_contains: ?[]const u8,
    expect_exit_code: i32,
) ValidationResult {
    // Validate exit code first
    const exit_result = validateExitCode(actual_exit_code, expect_exit_code);
    if (!exit_result.passed) {
        return exit_result;
    }

    // Validate output
    return validateOutput(actual_output, expect_output, expect_output_contains);
}

test "validate exact output match" {
    const result = validateOutput("hello\n", "hello\n", null);
    try std.testing.expect(result.passed);
}

test "validate exact output mismatch" {
    const result = validateOutput("hello\n", "world\n", null);
    try std.testing.expect(!result.passed);
    try std.testing.expect(result.error_message != null);
}

test "validate contains match" {
    const result = validateOutput("hello world\n", null, "world");
    try std.testing.expect(result.passed);
}

test "validate contains mismatch" {
    const result = validateOutput("hello world\n", null, "foo");
    try std.testing.expect(!result.passed);
}

test "validate exit code" {
    try std.testing.expect(validateExitCode(0, 0).passed);
    try std.testing.expect(!validateExitCode(1, 0).passed);
    try std.testing.expect(validateExitCode(1, 1).passed);
}

test "validate all" {
    const result = validate("hello\n", 0, "hello\n", null, 0);
    try std.testing.expect(result.passed);

    const failed_exit = validate("hello\n", 1, "hello\n", null, 0);
    try std.testing.expect(!failed_exit.passed);

    const failed_output = validate("world\n", 0, "hello\n", null, 0);
    try std.testing.expect(!failed_output.passed);
}
