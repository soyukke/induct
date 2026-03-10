const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    duration_ns: u64,
    timed_out: bool = false,

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

fn timeoutWatcher(child: *std.process.Child, timeout_ms: u64, timed_out: *std.atomic.Value(bool), process_done: *std.atomic.Value(bool)) void {
    const check_interval_ns: u64 = 10 * std.time.ns_per_ms; // 10ms
    var elapsed_ns: u64 = 0;
    const timeout_ns: u64 = timeout_ms * std.time.ns_per_ms;

    while (elapsed_ns < timeout_ns) {
        if (process_done.load(.acquire)) return;
        std.Thread.sleep(check_interval_ns);
        elapsed_ns += check_interval_ns;
    }

    if (!process_done.load(.acquire)) {
        timed_out.store(true, .release);
        // Kill the child process
        std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
    }
}

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
    var timed_out = std.atomic.Value(bool).init(false);
    var process_done = std.atomic.Value(bool).init(false);
    var timeout_thread: ?std.Thread = null;

    if (timeout_ms) |ms| {
        timeout_thread = std.Thread.spawn(.{}, timeoutWatcher, .{
            &child, ms, &timed_out, &process_done,
        }) catch null;
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
        process_done.store(true, .release);
        if (timeout_thread) |t| t.join();
        return RunError.CommandFailed;
    };

    const end_time = std.time.nanoTimestamp();
    process_done.store(true, .release);
    if (timeout_thread) |t| t.join();

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
        .duration_ns = @intCast(end_time - start_time),
        .timed_out = timed_out.load(.acquire),
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
