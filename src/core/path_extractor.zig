const std = @import("std");
const Allocator = std.mem.Allocator;

/// Extracts the test file path from a command string.
/// Supports common test runners: npm test, pytest, go test, cargo test, etc.
///
/// Returns the extracted path or null if no path could be determined.
pub fn extractTestPath(allocator: Allocator, command: []const u8) !?[]const u8 {
    // Skip leading whitespace
    const cmd = std.mem.trim(u8, command, " \t");

    if (std.mem.indexOf(u8, cmd, "npm test") != null) {
        if (std.mem.indexOf(u8, cmd, "-- ")) |idx| {
            if (try extractPathFromSuffix(allocator, cmd[idx + 3 ..])) |path| return path;
        }
    }
    if (try extractAfterContains(allocator, cmd, "npx jest", 8)) |path| return path;
    if (std.mem.startsWith(u8, cmd, "jest ")) {
        if (try extractPathFromSuffix(allocator, cmd[5..])) |path| return path;
    }
    if (try extractAfterContains(allocator, cmd, "pytest", 6)) |path| return path;
    if (try extractAfterContains(allocator, cmd, "python -m pytest", 16)) |path| return path;
    if (try extractAfterContains(allocator, cmd, "go test", 7)) |path| return path;
    if (try extractAfterContains(allocator, cmd, "cargo test", 10)) |path| return path;
    if (try extractAfterContains(allocator, cmd, "zig test", 8)) |path| return path;

    // Look for common test file extensions
    return try findTestFilePath(allocator, cmd);
}

fn extractAfterContains(
    allocator: Allocator,
    cmd: []const u8,
    marker: []const u8,
    offset: usize,
) !?[]const u8 {
    if (std.mem.indexOf(u8, cmd, marker)) |idx| {
        return try extractPathFromSuffix(allocator, cmd[idx + offset ..]);
    }
    return null;
}

fn extractPathFromSuffix(allocator: Allocator, suffix: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, suffix, " \t");
    if (trimmed.len == 0) return null;
    return try extractPathFromArg(allocator, trimmed);
}

/// Extracts the first path-like argument from a string.
fn extractPathFromArg(allocator: Allocator, args: []const u8) !?[]const u8 {
    // Find the first space-separated token that looks like a path
    var iter = std.mem.splitScalar(u8, args, ' ');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len == 0) continue;

        // Skip flags (start with -)
        if (std.mem.startsWith(u8, trimmed, "-")) continue;

        // Check if it looks like a file path
        if (looksLikeTestPath(trimmed)) {
            return try allocator.dupe(u8, trimmed);
        }
    }
    return null;
}

/// Finds a test file path by looking for common test file patterns.
fn findTestFilePath(allocator: Allocator, cmd: []const u8) !?[]const u8 {
    const test_patterns = [_][]const u8{
        ".test.ts",
        ".test.js",
        ".test.tsx",
        ".test.jsx",
        ".spec.ts",
        ".spec.js",
        "_test.py",
        "_test.go",
        ".test.zig",
    };

    var iter = std.mem.splitScalar(u8, cmd, ' ');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len == 0) continue;

        for (test_patterns) |pattern| {
            if (std.mem.endsWith(u8, trimmed, pattern)) {
                return try allocator.dupe(u8, trimmed);
            }
        }
    }
    return null;
}

/// Checks if a string looks like a test file path.
fn looksLikeTestPath(s: []const u8) bool {
    // Check for common test file extensions
    const test_extensions = [_][]const u8{
        ".test.ts",
        ".test.js",
        ".test.tsx",
        ".test.jsx",
        ".spec.ts",
        ".spec.js",
        "_test.py",
        "_test.go",
        ".test.zig",
        ".py",
        ".ts",
        ".js",
        ".go",
        ".zig",
    };

    for (test_extensions) |ext| {
        if (std.mem.endsWith(u8, s, ext)) {
            return true;
        }
    }

    // Check if it contains path separator
    if (std.mem.indexOf(u8, s, "/") != null) {
        return true;
    }

    return false;
}

/// Detects the testing framework from a command string.
pub fn detectFramework(command: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, command, "jest") != null or
        std.mem.indexOf(u8, command, "npm test") != null)
    {
        return "jest";
    }
    if (std.mem.indexOf(u8, command, "pytest") != null) {
        return "pytest";
    }
    if (std.mem.indexOf(u8, command, "go test") != null) {
        return "go-test";
    }
    if (std.mem.indexOf(u8, command, "cargo test") != null) {
        return "cargo-test";
    }
    if (std.mem.indexOf(u8, command, "zig test") != null) {
        return "zig-test";
    }
    if (std.mem.indexOf(u8, command, "vitest") != null) {
        return "vitest";
    }
    if (std.mem.indexOf(u8, command, "mocha") != null) {
        return "mocha";
    }
    return null;
}

test "extractTestPath - npm test" {
    const allocator = std.testing.allocator;
    const path = try extractTestPath(allocator, "npm test -- tests/login.test.ts");
    defer if (path) |p| allocator.free(p);
    try std.testing.expectEqualStrings("tests/login.test.ts", path.?);
}

test "extractTestPath - pytest" {
    const allocator = std.testing.allocator;
    const path = try extractTestPath(allocator, "pytest tests/test_login.py");
    defer if (path) |p| allocator.free(p);
    try std.testing.expectEqualStrings("tests/test_login.py", path.?);
}

test "extractTestPath - jest" {
    const allocator = std.testing.allocator;
    const path = try extractTestPath(allocator, "jest src/components/Button.test.tsx");
    defer if (path) |p| allocator.free(p);
    try std.testing.expectEqualStrings("src/components/Button.test.tsx", path.?);
}

test "extractTestPath - go test" {
    const allocator = std.testing.allocator;
    const path = try extractTestPath(allocator, "go test ./pkg/auth/login_test.go");
    defer if (path) |p| allocator.free(p);
    try std.testing.expectEqualStrings("./pkg/auth/login_test.go", path.?);
}

test "extractTestPath - zig test" {
    const allocator = std.testing.allocator;
    const path = try extractTestPath(allocator, "zig test src/core/spec.test.zig");
    defer if (path) |p| allocator.free(p);
    try std.testing.expectEqualStrings("src/core/spec.test.zig", path.?);
}

test "detectFramework" {
    try std.testing.expectEqualStrings(
        "jest",
        detectFramework("npm test -- tests/login.test.ts").?,
    );
    try std.testing.expectEqualStrings("pytest", detectFramework("pytest tests/test_login.py").?);
    try std.testing.expectEqualStrings("go-test", detectFramework("go test ./pkg/auth").?);
    try std.testing.expectEqualStrings("zig-test", detectFramework("zig test src/main.zig").?);
}
