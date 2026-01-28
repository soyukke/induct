const std = @import("std");
const Allocator = std.mem.Allocator;

/// Extracts the test file path from a command string.
/// Supports common test runners: npm test, pytest, go test, cargo test, etc.
///
/// Returns the extracted path or null if no path could be determined.
pub fn extractTestPath(allocator: Allocator, command: []const u8) !?[]const u8 {
    // Skip leading whitespace
    var cmd = std.mem.trim(u8, command, " \t");

    // Try various patterns

    // npm test -- <path>
    if (std.mem.indexOf(u8, cmd, "npm test")) |_| {
        if (std.mem.indexOf(u8, cmd, "-- ")) |idx| {
            const after_dashes = std.mem.trim(u8, cmd[idx + 3 ..], " \t");
            if (after_dashes.len > 0) {
                return try extractPathFromArg(allocator, after_dashes);
            }
        }
    }

    // npx jest <path>
    if (std.mem.indexOf(u8, cmd, "npx jest")) |idx| {
        const after_jest = std.mem.trim(u8, cmd[idx + 8 ..], " \t");
        if (after_jest.len > 0) {
            return try extractPathFromArg(allocator, after_jest);
        }
    }

    // jest <path>
    if (std.mem.startsWith(u8, cmd, "jest ")) {
        const after_jest = std.mem.trim(u8, cmd[5..], " \t");
        if (after_jest.len > 0) {
            return try extractPathFromArg(allocator, after_jest);
        }
    }

    // pytest <path>
    if (std.mem.indexOf(u8, cmd, "pytest")) |idx| {
        const after_pytest = std.mem.trim(u8, cmd[idx + 6 ..], " \t");
        if (after_pytest.len > 0) {
            return try extractPathFromArg(allocator, after_pytest);
        }
    }

    // python -m pytest <path>
    if (std.mem.indexOf(u8, cmd, "python -m pytest")) |idx| {
        const after_pytest = std.mem.trim(u8, cmd[idx + 16 ..], " \t");
        if (after_pytest.len > 0) {
            return try extractPathFromArg(allocator, after_pytest);
        }
    }

    // go test <path>
    if (std.mem.indexOf(u8, cmd, "go test")) |idx| {
        const after_gotest = std.mem.trim(u8, cmd[idx + 7 ..], " \t");
        if (after_gotest.len > 0) {
            return try extractPathFromArg(allocator, after_gotest);
        }
    }

    // cargo test <path>
    if (std.mem.indexOf(u8, cmd, "cargo test")) |idx| {
        const after_cargo = std.mem.trim(u8, cmd[idx + 10 ..], " \t");
        if (after_cargo.len > 0) {
            return try extractPathFromArg(allocator, after_cargo);
        }
    }

    // zig test <path>
    if (std.mem.indexOf(u8, cmd, "zig test")) |idx| {
        const after_zig = std.mem.trim(u8, cmd[idx + 8 ..], " \t");
        if (after_zig.len > 0) {
            return try extractPathFromArg(allocator, after_zig);
        }
    }

    // Look for common test file extensions
    return try findTestFilePath(allocator, cmd);
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
    try std.testing.expectEqualStrings("jest", detectFramework("npm test -- tests/login.test.ts").?);
    try std.testing.expectEqualStrings("pytest", detectFramework("pytest tests/test_login.py").?);
    try std.testing.expectEqualStrings("go-test", detectFramework("go test ./pkg/auth").?);
    try std.testing.expectEqualStrings("zig-test", detectFramework("zig test src/main.zig").?);
}
