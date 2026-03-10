const std = @import("std");
const Allocator = std.mem.Allocator;
const spec_mod = @import("spec.zig");
const Spec = spec_mod.Spec;
const ProjectSpec = spec_mod.ProjectSpec;
const result_mod = @import("result.zig");
const SpecResult = result_mod.SpecResult;
const SpecStatus = result_mod.SpecStatus;
const GenerateInfo = result_mod.GenerateInfo;
const validator = @import("validator.zig");
const runner = @import("../process/runner.zig");
const parser = @import("../yaml/parser.zig");
const path_extractor = @import("path_extractor.zig");

pub const ExecuteError = error{
    SetupFailed,
    TestFailed,
    TeardownFailed,
    ParseError,
    OutOfMemory,
    FileNotFound,
    InvalidPath,
};

var result_counter = std.atomic.Value(u64).init(0);

fn generateId(allocator: Allocator) ![]const u8 {
    const count = result_counter.fetchAdd(1, .monotonic) + 1;
    const timestamp = @as(u64, @intCast(std.time.milliTimestamp()));
    return std.fmt.allocPrint(allocator, "{d}-{d}", .{ timestamp, count });
}

/// Append a shell single-quoted-escaped version of input to the list
fn appendShellEscaped(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), input: []const u8) !void {
    for (input) |c| {
        if (c == '\'') {
            try list.appendSlice(allocator, "'\"'\"'");
        } else {
            try list.append(allocator, c);
        }
    }
}

/// Build a full command string with env vars and working_dir prefix.
/// Returns null if no modifications are needed (caller should use original command).
fn buildFullCommand(allocator: Allocator, command: []const u8, test_case: spec_mod.TestCase) !?[]const u8 {
    if (test_case.env == null and test_case.working_dir == null) return null;

    var parts: std.ArrayListUnmanaged(u8) = .empty;
    errdefer parts.deinit(allocator);

    if (test_case.env) |env_vars| {
        for (env_vars) |ev| {
            try parts.appendSlice(allocator, "export ");
            try parts.appendSlice(allocator, ev.key);
            try parts.appendSlice(allocator, "='");
            try appendShellEscaped(allocator, &parts, ev.value);
            try parts.appendSlice(allocator, "'; ");
        }
    }

    if (test_case.working_dir) |wd| {
        try parts.appendSlice(allocator, "cd '");
        try appendShellEscaped(allocator, &parts, wd);
        try parts.appendSlice(allocator, "' && ");
    }

    try parts.appendSlice(allocator, command);
    return try parts.toOwnedSlice(allocator);
}

/// Validate output against a regex pattern using grep -qE
fn matchRegex(allocator: Allocator, text: []const u8, pattern: []const u8) !bool {
    var escaped: std.ArrayListUnmanaged(u8) = .empty;
    defer escaped.deinit(allocator);
    try appendShellEscaped(allocator, &escaped, pattern);

    const cmd = try std.fmt.allocPrint(allocator, "grep -qE '{s}'", .{escaped.items});
    defer allocator.free(cmd);

    var result = runner.runCommand(allocator, cmd, text, null) catch return false;
    defer result.deinit(allocator);
    return result.exit_code == 0;
}

pub fn executeSpec(allocator: Allocator, spec: Spec) !SpecResult {
    const start_time = std.time.milliTimestamp();
    var setup_failed = false;
    var error_message: ?[]const u8 = null;

    // Check if this is a generate spec
    if (spec.test_case.generate) {
        // Determine target path
        const target_path = if (spec.test_case.target_path) |tp|
            try allocator.dupe(u8, tp)
        else if (try path_extractor.extractTestPath(allocator, spec.test_case.command)) |extracted|
            extracted
        else
            null;

        if (target_path) |tp| {
            // Check if file exists
            const file_exists = blk: {
                std.fs.cwd().access(tp, .{}) catch |err| {
                    if (err == error.FileNotFound) {
                        break :blk false;
                    }
                    break :blk true;
                };
                break :blk true;
            };

            if (!file_exists) {
                const end_time = std.time.milliTimestamp();
                const framework_hint = path_extractor.detectFramework(spec.test_case.command);
                return SpecResult{
                    .id = try generateId(allocator),
                    .spec_name = try allocator.dupe(u8, spec.name),
                    .passed = false,
                    .status = .generate_required,
                    .actual_output = try allocator.dupe(u8, ""),
                    .actual_stderr = try allocator.dupe(u8, ""),
                    .actual_exit_code = -1,
                    .error_message = try allocator.dupe(u8, "Test file not found. Generation required."),
                    .duration_ms = @intCast(end_time - start_time),
                    .generate_info = .{
                        .target_path = tp,
                        .description = if (spec.description) |d| try allocator.dupe(u8, d) else null,
                        .framework_hint = if (framework_hint) |f| try allocator.dupe(u8, f) else null,
                        .command = try allocator.dupe(u8, spec.test_case.command),
                    },
                };
            }
            allocator.free(tp);
        }
    }

    // Run setup commands
    if (spec.setup) |setup_cmds| {
        for (setup_cmds) |cmd| {
            var result = runner.runCommandSimple(allocator, cmd.run) catch {
                setup_failed = true;
                error_message = try allocator.dupe(u8, "Setup command failed to execute");
                break;
            };
            defer result.deinit(allocator);

            if (result.exit_code != 0) {
                setup_failed = true;
                error_message = try std.fmt.allocPrint(
                    allocator,
                    "Setup command failed with exit code {d}: {s}",
                    .{ result.exit_code, cmd.run },
                );
                break;
            }
        }
    }

    var actual_output: []const u8 = try allocator.dupe(u8, "");
    var actual_stderr: []const u8 = try allocator.dupe(u8, "");
    var actual_exit_code: i32 = 0;
    var passed = false;
    var timed_out = false;

    if (!setup_failed) {
        // Build full command with env vars and working_dir
        const full_cmd_owned = try buildFullCommand(allocator, spec.test_case.command, spec.test_case);
        defer if (full_cmd_owned) |fc| allocator.free(fc);
        const full_cmd = full_cmd_owned orelse spec.test_case.command;

        // Run the test command
        var proc_result = runner.runCommand(
            allocator,
            full_cmd,
            spec.test_case.input,
            spec.test_case.timeout_ms,
        ) catch |err| {
            const end_time = std.time.milliTimestamp();
            return SpecResult{
                .id = try generateId(allocator),
                .spec_name = try allocator.dupe(u8, spec.name),
                .passed = false,
                .actual_output = try allocator.dupe(u8, ""),
                .actual_stderr = try allocator.dupe(u8, ""),
                .actual_exit_code = -1,
                .error_message = try std.fmt.allocPrint(allocator, "Failed to run command: {}", .{err}),
                .duration_ms = @intCast(end_time - start_time),
            };
        };
        defer proc_result.deinit(allocator);

        allocator.free(actual_output);
        actual_output = try allocator.dupe(u8, proc_result.stdout);
        allocator.free(actual_stderr);
        actual_stderr = try allocator.dupe(u8, proc_result.stderr);
        actual_exit_code = proc_result.exit_code;
        timed_out = proc_result.timed_out;

        if (timed_out) {
            passed = false;
            error_message = try std.fmt.allocPrint(
                allocator,
                "Command timed out after {d}ms",
                .{spec.test_case.timeout_ms.?},
            );
        } else {
            // Validate results
            const validation = validator.validate(
                proc_result.stdout,
                proc_result.stderr,
                proc_result.exit_code,
                spec.test_case.expect_output,
                spec.test_case.expect_output_contains,
                spec.test_case.expect_output_not_contains,
                spec.test_case.expect_stderr,
                spec.test_case.expect_stderr_contains,
                spec.test_case.expect_exit_code,
            );

            passed = validation.passed;
            if (!passed and validation.error_message != null) {
                error_message = try allocator.dupe(u8, validation.error_message.?);
            }

            // Regex validation (requires shelling out to grep)
            if (passed) {
                if (spec.test_case.expect_output_regex) |pattern| {
                    const regex_match = try matchRegex(allocator, proc_result.stdout, pattern);
                    if (!regex_match) {
                        passed = false;
                        error_message = try allocator.dupe(u8, "Output does not match regex pattern");
                    }
                }
            }
        }
    }

    // Run teardown commands (always, even if test failed)
    if (spec.teardown) |teardown_cmds| {
        for (teardown_cmds) |cmd| {
            switch (cmd) {
                .run => |run_cmd| {
                    var result = runner.runCommandSimple(allocator, run_cmd) catch continue;
                    result.deinit(allocator);
                },
                .kill_process => |process_name| {
                    // Kill process by name using pkill
                    const kill_cmd = std.fmt.allocPrint(allocator, "pkill -f '{s}'", .{process_name}) catch continue;
                    defer allocator.free(kill_cmd);
                    var result = runner.runCommandSimple(allocator, kill_cmd) catch continue;
                    result.deinit(allocator);
                },
            }
        }
    }

    const end_time = std.time.milliTimestamp();

    return SpecResult{
        .id = try generateId(allocator),
        .spec_name = try allocator.dupe(u8, spec.name),
        .passed = passed and !setup_failed,
        .actual_output = actual_output,
        .actual_stderr = actual_stderr,
        .actual_exit_code = actual_exit_code,
        .error_message = error_message,
        .duration_ms = @intCast(end_time - start_time),
        .timed_out = timed_out,
    };
}

pub fn executeSpecFromFile(allocator: Allocator, path: []const u8) !SpecResult {
    var spec = parser.parseSpecFromFile(allocator, path) catch |err| {
        return SpecResult{
            .id = try generateId(allocator),
            .spec_name = try allocator.dupe(u8, path),
            .passed = false,
            .actual_output = try allocator.dupe(u8, ""),
            .actual_stderr = try allocator.dupe(u8, ""),
            .actual_exit_code = -1,
            .error_message = try std.fmt.allocPrint(allocator, "Failed to parse spec: {}", .{err}),
            .duration_ms = 0,
        };
    };
    defer spec.deinit(allocator);

    return executeSpec(allocator, spec);
}

/// Validate a spec file without executing it. Returns null if valid, error message if invalid.
pub fn validateSpecFile(allocator: Allocator, path: []const u8) !?[]const u8 {
    // Try to parse as project spec first
    if (isProjectSpecFile(path)) {
        var project = parser.parseProjectSpecFromFile(allocator, path) catch |err| {
            return try std.fmt.allocPrint(allocator, "Invalid project spec: {}", .{err});
        };
        project.deinit(allocator);
        return null;
    }

    var spec = parser.parseSpecFromFile(allocator, path) catch |err| {
        return try std.fmt.allocPrint(allocator, "Invalid spec: {}", .{err});
    };
    spec.deinit(allocator);
    return null;
}

pub const ExecuteOptions = struct {
    fail_fast: bool = false,
    filter: ?[]const u8 = null,
    max_jobs: usize = 1,
};

pub fn executeSpecsFromDir(allocator: Allocator, dir_path: []const u8) ![]SpecResult {
    return executeSpecsFromDirWithOptions(allocator, dir_path, .{});
}

pub fn executeSpecsFromDirWithOptions(allocator: Allocator, dir_path: []const u8, options: ExecuteOptions) ![]SpecResult {
    // Collect spec file paths
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        var results: std.ArrayListUnmanaged(SpecResult) = .empty;
        const result = SpecResult{
            .id = try generateId(allocator),
            .spec_name = try allocator.dupe(u8, dir_path),
            .passed = false,
            .actual_output = try allocator.dupe(u8, ""),
            .actual_stderr = try allocator.dupe(u8, ""),
            .actual_exit_code = -1,
            .error_message = try std.fmt.allocPrint(allocator, "Failed to open directory: {}", .{err}),
            .duration_ms = 0,
        };
        try results.append(allocator, result);
        return try results.toOwnedSlice(allocator);
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;

        // Apply filter if specified
        if (options.filter) |filter| {
            // Read spec to check name matches filter
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(full_path);

            var spec = parser.parseSpecFromFile(allocator, full_path) catch {
                // Can't parse - include it anyway to show the error
                const path_copy = try allocator.dupe(u8, full_path);
                try paths.append(allocator, path_copy);
                continue;
            };
            defer spec.deinit(allocator);

            if (std.mem.indexOf(u8, spec.name, filter) == null) {
                continue; // Filter out
            }

            const path_copy = try allocator.dupe(u8, full_path);
            try paths.append(allocator, path_copy);
        } else {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            try paths.append(allocator, full_path);
        }
    }

    if (paths.items.len == 0) {
        return try allocator.alloc(SpecResult, 0);
    }

    // Execute specs
    var results: std.ArrayListUnmanaged(SpecResult) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    if (options.max_jobs > 1) {
        // Parallel execution
        return try executeSpecsParallel(allocator, paths.items, options);
    }

    // Sequential execution
    for (paths.items) |path| {
        const result = try executeSpecFromFile(allocator, path);
        try results.append(allocator, result);

        if (options.fail_fast and !result.passed) {
            break;
        }
    }

    return try results.toOwnedSlice(allocator);
}

fn executeSpecsParallel(allocator: Allocator, paths: []const []const u8, options: ExecuteOptions) ![]SpecResult {
    const n = paths.len;
    const results = try allocator.alloc(SpecResult, n);
    // Initialize results to prevent undefined memory
    for (results) |*r| {
        r.* = SpecResult{
            .id = try allocator.dupe(u8, ""),
            .spec_name = try allocator.dupe(u8, ""),
            .passed = false,
            .actual_output = try allocator.dupe(u8, ""),
            .actual_stderr = try allocator.dupe(u8, ""),
            .actual_exit_code = -1,
            .error_message = null,
            .duration_ms = 0,
        };
    }

    const effective_jobs = @min(options.max_jobs, n);

    const ThreadContext = struct {
        alloc: Allocator,
        path: []const u8,
        result_slot: *SpecResult,

        fn work(ctx: @This()) void {
            const result = executeSpecFromFile(ctx.alloc, ctx.path) catch {
                ctx.result_slot.* = SpecResult{
                    .id = ctx.alloc.dupe(u8, "error") catch return,
                    .spec_name = ctx.alloc.dupe(u8, ctx.path) catch return,
                    .passed = false,
                    .actual_output = ctx.alloc.dupe(u8, "") catch return,
                    .actual_stderr = ctx.alloc.dupe(u8, "") catch return,
                    .actual_exit_code = -1,
                    .error_message = ctx.alloc.dupe(u8, "Thread execution failed") catch null,
                    .duration_ms = 0,
                };
                return;
            };
            ctx.result_slot.* = result;
        }
    };

    var threads = try allocator.alloc(?std.Thread, n);
    defer allocator.free(threads);
    for (threads) |*t| t.* = null;

    var launched: usize = 0;

    for (paths, 0..) |path, i| {
        // If we've hit the job limit, wait for one to finish
        while (launched >= effective_jobs) {
            var found = false;
            for (threads[0..launched]) |*t| {
                if (t.*) |thread| {
                    thread.join();
                    t.* = null;
                    launched -= 1;
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }

        threads[i] = std.Thread.spawn(.{}, ThreadContext.work, .{ThreadContext{
            .alloc = allocator,
            .path = path,
            .result_slot = &results[i],
        }}) catch null;

        if (threads[i] != null) {
            launched += 1;
        } else {
            // Thread spawn failed, run sequentially
            results[i] = try executeSpecFromFile(allocator, path);
        }
    }

    // Wait for all remaining threads
    for (threads) |t| {
        if (t) |thread| thread.join();
    }

    return results;
}

pub fn executeProjectSpec(allocator: Allocator, project: ProjectSpec, base_dir: ?[]const u8) ![]SpecResult {
    return executeProjectSpecWithOptions(allocator, project, base_dir, .{});
}

pub fn executeProjectSpecWithOptions(allocator: Allocator, project: ProjectSpec, base_dir: ?[]const u8, options: ExecuteOptions) ![]SpecResult {
    var results: std.ArrayListUnmanaged(SpecResult) = .empty;
    errdefer {
        for (results.items) |*r| {
            r.deinit(allocator);
        }
        results.deinit(allocator);
    }

    // Execute inline specs
    for (project.specs) |spec| {
        // Apply filter
        if (options.filter) |filter| {
            if (std.mem.indexOf(u8, spec.name, filter) == null) continue;
        }

        const result = try executeSpec(allocator, spec);
        try results.append(allocator, result);

        if (options.fail_fast and !result.passed) {
            return try results.toOwnedSlice(allocator);
        }
    }

    // Execute specs from include files
    for (project.include) |include_path| {
        const full_path = if (base_dir) |base|
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, include_path })
        else
            try allocator.dupe(u8, include_path);
        defer allocator.free(full_path);

        if (std.mem.endsWith(u8, include_path, "inductspec.yaml")) {
            var nested_project = parser.parseProjectSpecFromFile(allocator, full_path) catch |err| {
                const error_result = SpecResult{
                    .id = try generateId(allocator),
                    .spec_name = try allocator.dupe(u8, include_path),
                    .passed = false,
                    .actual_output = try allocator.dupe(u8, ""),
                    .actual_stderr = try allocator.dupe(u8, ""),
                    .actual_exit_code = -1,
                    .error_message = try std.fmt.allocPrint(allocator, "Failed to parse project spec: {}", .{err}),
                    .duration_ms = 0,
                };
                try results.append(allocator, error_result);
                continue;
            };
            defer nested_project.deinit(allocator);

            const nested_base_dir = std.fs.path.dirname(full_path);
            const nested_results = try executeProjectSpecWithOptions(allocator, nested_project, nested_base_dir, options);
            defer allocator.free(nested_results);

            var should_stop = false;
            for (nested_results) |nested_result| {
                try results.append(allocator, nested_result);
                if (options.fail_fast and !nested_result.passed) {
                    should_stop = true;
                }
            }
            if (should_stop) return try results.toOwnedSlice(allocator);
        } else {
            const result = try executeSpecFromFile(allocator, full_path);
            try results.append(allocator, result);

            if (options.fail_fast and !result.passed) {
                return try results.toOwnedSlice(allocator);
            }
        }
    }

    return try results.toOwnedSlice(allocator);
}

pub fn executeProjectSpecFromFile(allocator: Allocator, path: []const u8) ![]SpecResult {
    return executeProjectSpecFromFileWithOptions(allocator, path, .{});
}

pub fn executeProjectSpecFromFileWithOptions(allocator: Allocator, path: []const u8, options: ExecuteOptions) ![]SpecResult {
    var project = parser.parseProjectSpecFromFile(allocator, path) catch |err| {
        var results: std.ArrayListUnmanaged(SpecResult) = .empty;
        const error_result = SpecResult{
            .id = try generateId(allocator),
            .spec_name = try allocator.dupe(u8, path),
            .passed = false,
            .actual_output = try allocator.dupe(u8, ""),
            .actual_stderr = try allocator.dupe(u8, ""),
            .actual_exit_code = -1,
            .error_message = try std.fmt.allocPrint(allocator, "Failed to parse project spec: {}", .{err}),
            .duration_ms = 0,
        };
        try results.append(allocator, error_result);
        return try results.toOwnedSlice(allocator);
    };
    defer project.deinit(allocator);

    const base_dir = std.fs.path.dirname(path);
    return executeProjectSpecWithOptions(allocator, project, base_dir, options);
}

pub fn isProjectSpecFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "inductspec.yaml");
}

test "execute simple spec" {
    const spec = Spec{
        .name = "echo test",
        .test_case = .{
            .command = "echo hello",
            .expect_output = "hello\n",
            .expect_exit_code = 0,
        },
    };

    var result = try executeSpec(std.testing.allocator, spec);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.passed);
    try std.testing.expectEqualStrings("hello\n", result.actual_output);
    try std.testing.expectEqual(@as(i32, 0), result.actual_exit_code);
}

test "execute spec with stdin" {
    const spec = Spec{
        .name = "cat test",
        .test_case = .{
            .command = "cat",
            .input = "hello world",
            .expect_output = "hello world",
            .expect_exit_code = 0,
        },
    };

    var result = try executeSpec(std.testing.allocator, spec);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.passed);
}

test "execute failing spec" {
    const spec = Spec{
        .name = "failing test",
        .test_case = .{
            .command = "echo wrong",
            .expect_output = "hello\n",
            .expect_exit_code = 0,
        },
    };

    var result = try executeSpec(std.testing.allocator, spec);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.passed);
}

test "execute project spec with inline specs" {
    const project = ProjectSpec{
        .name = "test project",
        .specs = &[_]Spec{
            .{
                .name = "echo test",
                .test_case = .{
                    .command = "echo hello",
                    .expect_output = "hello\n",
                    .expect_exit_code = 0,
                },
            },
            .{
                .name = "true test",
                .test_case = .{
                    .command = "true",
                    .expect_exit_code = 0,
                },
            },
        },
    };

    const results = try executeProjectSpec(std.testing.allocator, project, null);
    defer {
        for (results) |*r| {
            var mutable_r = @constCast(r);
            mutable_r.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(results[0].passed);
    try std.testing.expect(results[1].passed);
}

test "isProjectSpecFile" {
    try std.testing.expect(isProjectSpecFile("inductspec.yaml"));
    try std.testing.expect(isProjectSpecFile("path/to/inductspec.yaml"));
    try std.testing.expect(!isProjectSpecFile("test.yaml"));
    try std.testing.expect(!isProjectSpecFile("inductspec.yml"));
}
