const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    duration_ns: u64,

    pub fn deinit(self: *ProcessResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const RunError = error{
    CommandFailed,
    Timeout,
    OutOfMemory,
    SpawnFailed,
};

pub fn runCommand(
    allocator: Allocator,
    command: []const u8,
    stdin_data: ?[]const u8,
    timeout_ms: ?u64,
) !ProcessResult {
    const start_time = std.time.nanoTimestamp();

    // Parse command into arguments using shell
    const argv = [_][]const u8{ "sh", "-c", command };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = if (stdin_data != null) .Pipe else .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        return RunError.SpawnFailed;
    };

    // Write stdin if provided
    if (stdin_data) |data| {
        if (child.stdin) |stdin| {
            stdin.writeAll(data) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    // Set up timeout if specified
    if (timeout_ms) |timeout| {
        _ = timeout;
        // TODO: Implement timeout handling with a separate thread
        // For now, we'll skip timeout support
    }

    // Read stdout
    const stdout = if (child.stdout) |stdout_file|
        stdout_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch &[_]u8{}
    else
        &[_]u8{};

    // Read stderr
    const stderr = if (child.stderr) |stderr_file|
        stderr_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch &[_]u8{}
    else
        &[_]u8{};

    // Wait for process to complete
    const term = child.wait() catch {
        return RunError.CommandFailed;
    };

    const end_time = std.time.nanoTimestamp();
    const duration_ns: u64 = @intCast(end_time - start_time);

    const exit_code: i32 = switch (term) {
        .Exited => |code| @as(i32, code),
        .Signal => |sig| -@as(i32, @intCast(sig)),
        .Stopped => |sig| -@as(i32, @intCast(sig)),
        .Unknown => -1,
    };

    return ProcessResult{
        .stdout = if (stdout.len > 0) stdout else allocator.dupe(u8, "") catch return RunError.OutOfMemory,
        .stderr = if (stderr.len > 0) stderr else allocator.dupe(u8, "") catch return RunError.OutOfMemory,
        .exit_code = exit_code,
        .duration_ns = duration_ns,
    };
}

pub fn runCommandSimple(allocator: Allocator, command: []const u8) !ProcessResult {
    return runCommand(allocator, command, null, null);
}

test "run echo command" {
    const result = try runCommand(std.testing.allocator, "echo hello", null, null);
    defer {
        var r = result;
        r.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
}

test "run command with stdin" {
    const result = try runCommand(std.testing.allocator, "cat", "hello world", null);
    defer {
        var r = result;
        r.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("hello world", result.stdout);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
}

test "run command with exit code" {
    const result = try runCommand(std.testing.allocator, "sh -c 'exit 42'", null, null);
    defer {
        var r = result;
        r.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(i32, 42), result.exit_code);
}
