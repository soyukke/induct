const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const spec_mod = @import("../core/spec.zig");

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

fn timeoutFromMilliseconds(timeout_ms: ?u64) std.Io.Timeout {
    return if (timeout_ms) |ms|
        .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
        } }
    else
        .none;
}

fn shellArgv(command: []const u8) [3][]const u8 {
    return switch (builtin.os.tag) {
        .windows => .{ "bash", "-lc", command },
        else => .{ "sh", "-c", command },
    };
}

fn termExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .stopped => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .unknown => -1,
    };
}

fn currentProcessEnviron() std.process.Environ {
    switch (builtin.os.tag) {
        .windows => return .{ .block = .global },
        .wasi, .emscripten => if (!builtin.link_libc) return .{ .block = .global },
        .freestanding, .other => return .{ .block = .global },
        else => {},
    }

    if (builtin.link_libc) {
        const c_environ = std.c.environ;
        var env_count: usize = 0;
        while (c_environ[env_count] != null) : (env_count += 1) {}
        return .{ .block = .{ .slice = c_environ[0..env_count :null] } };
    }

    return .empty;
}

fn buildEnvironmentMap(
    allocator: Allocator,
    env_vars: ?[]const spec_mod.EnvVar,
) !?std.process.Environ.Map {
    const vars = env_vars orelse return null;

    var env_map = try std.process.Environ.createMap(currentProcessEnviron(), allocator);
    errdefer env_map.deinit();

    for (vars) |ev| {
        try env_map.put(ev.key, ev.value);
    }

    return env_map;
}

fn collectChildResult(
    allocator: Allocator,
    io: std.Io,
    child: *std.process.Child,
    stdin_data: ?[]const u8,
    timeout_ms: ?u64,
) !ProcessResult {
    const start_time = std.Io.Clock.awake.now(io);
    defer if (child.id != null) child.kill(io);

    // Write stdin if provided
    if (stdin_data) |data| {
        if (child.stdin) |stdin| {
            stdin.writeStreamingAll(io, data) catch {};
            stdin.close(io);
            child.stdin = null;
        }
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const output_limit = std.Io.Limit.limited(10 * 1024 * 1024);
    const timeout = timeoutFromMilliseconds(timeout_ms);
    var timed_out = false;

    while (multi_reader.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > @intFromEnum(output_limit) or stderr_reader.buffered().len > @intFromEnum(output_limit)) {
            return RunError.CommandFailed;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => {
            timed_out = true;
            child.kill(io);
            multi_reader.fillRemaining(.none) catch {};
        },
        else => return RunError.CommandFailed,
    }

    if (!timed_out) {
        multi_reader.checkAnyError() catch |err| switch (err) {
            error.OutOfMemory => return RunError.OutOfMemory,
            else => return RunError.CommandFailed,
        };
    }

    const stdout = multi_reader.toOwnedSlice(0) catch return RunError.OutOfMemory;
    errdefer allocator.free(stdout);

    const stderr = multi_reader.toOwnedSlice(1) catch return RunError.OutOfMemory;
    errdefer allocator.free(stderr);

    const exit_code = if (timed_out)
        -1
    else
        termExitCode(child.wait(io) catch return RunError.CommandFailed);

    const end_time = std.Io.Clock.awake.now(io);

    return ProcessResult{
        .stdout = if (stdout.len > 0) stdout else allocator.dupe(u8, "") catch return RunError.OutOfMemory,
        .stderr = if (stderr.len > 0) stderr else allocator.dupe(u8, "") catch return RunError.OutOfMemory,
        .exit_code = exit_code,
        .duration_ns = @intCast(start_time.durationTo(end_time).toNanoseconds()),
        .timed_out = timed_out,
    };
}

pub fn runCommand(
    allocator: Allocator,
    command: []const u8,
    stdin_data: ?[]const u8,
    timeout_ms: ?u64,
) !ProcessResult {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{
        .environ = currentProcessEnviron(),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const argv = shellArgv(command);
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = if (stdin_data != null) .pipe else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        return RunError.SpawnFailed;
    };

    return collectChildResult(allocator, io, &child, stdin_data, timeout_ms);
}

pub fn runArgv(
    allocator: Allocator,
    program: []const u8,
    args: []const []const u8,
    stdin_data: ?[]const u8,
    working_dir: ?[]const u8,
    env_vars: ?[]const spec_mod.EnvVar,
    timeout_ms: ?u64,
) !ProcessResult {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{
        .environ = currentProcessEnviron(),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = program;
    @memcpy(argv[1..], args);

    var env_map = try buildEnvironmentMap(allocator, env_vars);
    defer if (env_map) |*map| map.deinit();

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (working_dir) |wd| .{ .path = wd } else .inherit,
        .environ_map = if (env_map) |*map| map else null,
        .stdin = if (stdin_data != null) .pipe else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        return RunError.SpawnFailed;
    };

    return collectChildResult(allocator, io, &child, stdin_data, timeout_ms);
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
    const result = try runCommand(std.testing.allocator, "exit 42", null, null);
    defer {
        var r = result;
        r.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(i32, 42), result.exit_code);
}
