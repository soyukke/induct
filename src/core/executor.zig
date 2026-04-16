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
    return std.fmt.allocPrint(allocator, "{d}", .{count});
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

pub fn executeSpec(allocator: Allocator, spec: Spec, default_timeout_ms: ?u64) !SpecResult {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const start_time = std.Io.Clock.awake.now(io);
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
                std.Io.Dir.cwd().access(io, tp, .{}) catch |err| {
                    if (err == error.FileNotFound) {
                        break :blk false;
                    }
                    break :blk true;
                };
                break :blk true;
            };

            if (!file_exists) {
                const end_time = std.Io.Clock.awake.now(io);
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
                    .duration_ms = @intCast(start_time.durationTo(end_time).toMilliseconds()),
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

    // Effective timeout: spec-level takes precedence, then global default
    const effective_timeout = spec.test_case.timeout_ms orelse default_timeout_ms;

    // Run setup commands
    if (spec.setup) |setup_cmds| {
        for (setup_cmds) |cmd| {
            var result = runner.runCommand(allocator, cmd.run, null, default_timeout_ms) catch {
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

        // Resolve stdin data: input_lines takes priority conversion, then input
        const resolved_input = if (spec.test_case.input_lines) |il|
            il.toBytes(allocator) catch null
        else
            null;
        defer if (resolved_input) |ri| allocator.free(ri);

        const stdin_data = resolved_input orelse spec.test_case.input;

        // Run the test command
        var proc_result = runner.runCommand(
            allocator,
            full_cmd,
            stdin_data,
            effective_timeout,
        ) catch |err| {
            const end_time = std.Io.Clock.awake.now(io);
            return SpecResult{
                .id = try generateId(allocator),
                .spec_name = try allocator.dupe(u8, spec.name),
                .passed = false,
                .actual_output = try allocator.dupe(u8, ""),
                .actual_stderr = try allocator.dupe(u8, ""),
                .actual_exit_code = -1,
                .error_message = try std.fmt.allocPrint(allocator, "Failed to run command: {}", .{err}),
                .duration_ms = @intCast(start_time.durationTo(end_time).toMilliseconds()),
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
                .{effective_timeout.?},
            );
        } else {
            // Validate results
            const validation = validator.validateTestCase(
                allocator,
                proc_result.stdout,
                proc_result.stderr,
                proc_result.exit_code,
                spec.test_case,
            );

            passed = validation.passed;
            if (!passed and validation.error_message != null) {
                if (validation.allocated) {
                    error_message = validation.error_message;
                } else {
                    error_message = try allocator.dupe(u8, validation.error_message.?);
                }
            }

            // Regex validation (requires shelling out to grep)
            if (passed) {
                if (spec.test_case.expect_output_regex) |pattern| {
                    const regex_match = try matchRegex(allocator, proc_result.stdout, pattern);
                    if (!regex_match) {
                        passed = false;
                        error_message = try std.fmt.allocPrint(
                            allocator,
                            "Output does not match regex\n  Pattern: \"{s}\"\n  Actual:  \"{s}\"",
                            .{ pattern, validator.truncate(proc_result.stdout) },
                        );
                    }
                }
            }

            // Stderr regex validation
            if (passed) {
                if (spec.test_case.expect_stderr_regex) |pattern| {
                    const regex_match = try matchRegex(allocator, proc_result.stderr, pattern);
                    if (!regex_match) {
                        passed = false;
                        error_message = try std.fmt.allocPrint(
                            allocator,
                            "Stderr does not match regex\n  Pattern: \"{s}\"\n  Actual:  \"{s}\"",
                            .{ pattern, validator.truncate(proc_result.stderr) },
                        );
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

    const end_time = std.Io.Clock.awake.now(io);

    return SpecResult{
        .id = try generateId(allocator),
        .spec_name = try allocator.dupe(u8, spec.name),
        .passed = passed and !setup_failed,
        .actual_output = actual_output,
        .actual_stderr = actual_stderr,
        .actual_exit_code = actual_exit_code,
        .error_message = error_message,
        .duration_ms = @intCast(start_time.durationTo(end_time).toMilliseconds()),
        .timed_out = timed_out,
    };
}

pub fn executeSpecFromFile(allocator: Allocator, path: []const u8) ![]SpecResult {
    return executeSpecFromFileWithTimeout(allocator, path, null);
}

pub fn executeSpecFromFileWithTimeout(allocator: Allocator, path: []const u8, default_timeout_ms: ?u64) ![]SpecResult {
    var spec = parser.parseSpecFromFile(allocator, path) catch |err| {
        var results: std.ArrayListUnmanaged(SpecResult) = .empty;
        try results.append(allocator, SpecResult{
            .id = try generateId(allocator),
            .spec_name = try allocator.dupe(u8, path),
            .passed = false,
            .actual_output = try allocator.dupe(u8, ""),
            .actual_stderr = try allocator.dupe(u8, ""),
            .actual_exit_code = -1,
            .error_message = try std.fmt.allocPrint(allocator, "Failed to parse spec: {}", .{err}),
            .duration_ms = 0,
        });
        return try results.toOwnedSlice(allocator);
    };
    defer spec.deinit(allocator);

    if (spec.hasSteps()) {
        return executeSpecSteps(allocator, spec, default_timeout_ms);
    }

    var results: std.ArrayListUnmanaged(SpecResult) = .empty;
    try results.append(allocator, try executeSpec(allocator, spec, default_timeout_ms));
    return try results.toOwnedSlice(allocator);
}

fn executeSpecSteps(allocator: Allocator, spec: spec_mod.Spec, default_timeout_ms: ?u64) ![]SpecResult {
    const steps = spec.steps.?;
    var results: std.ArrayListUnmanaged(SpecResult) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    var setup_failed = false;

    // Run setup once
    if (spec.setup) |setup_cmds| {
        for (setup_cmds) |cmd| {
            var proc_result = runner.runCommand(allocator, cmd.run, null, default_timeout_ms) catch {
                setup_failed = true;
                break;
            };
            defer proc_result.deinit(allocator);
            if (proc_result.exit_code != 0) {
                setup_failed = true;
                break;
            }
        }
    }

    var skip_remaining = setup_failed;

    for (steps) |step| {
        const step_name = try std.fmt.allocPrint(allocator, "{s} > {s}", .{ spec.name, step.name });

        if (skip_remaining) {
            try results.append(allocator, SpecResult{
                .id = try generateId(allocator),
                .spec_name = step_name,
                .passed = false,
                .status = .skipped,
                .actual_output = try allocator.dupe(u8, ""),
                .actual_stderr = try allocator.dupe(u8, ""),
                .actual_exit_code = -1,
                .error_message = try allocator.dupe(u8, "Skipped due to previous failure"),
                .duration_ms = 0,
            });
            continue;
        }

        // Create a temporary single-step spec to reuse executeSpec
        const step_spec = spec_mod.Spec{
            .name = step_name,
            .test_case = step.test_case,
        };

        var result = try executeSpec(allocator, step_spec, default_timeout_ms);
        // Replace the name since executeSpec dupes spec.name
        allocator.free(result.spec_name);
        result.spec_name = step_name;

        if (!result.passed) {
            skip_remaining = true;
        }

        try results.append(allocator, result);
    }

    // Run teardown once (always)
    if (spec.teardown) |teardown_cmds| {
        for (teardown_cmds) |cmd| {
            switch (cmd) {
                .run => |run_cmd| {
                    var proc_result = runner.runCommandSimple(allocator, run_cmd) catch continue;
                    proc_result.deinit(allocator);
                },
                .kill_process => |process_name| {
                    const kill_cmd = std.fmt.allocPrint(allocator, "pkill -f '{s}'", .{process_name}) catch continue;
                    defer allocator.free(kill_cmd);
                    var proc_result = runner.runCommandSimple(allocator, kill_cmd) catch continue;
                    proc_result.deinit(allocator);
                },
            }
        }
    }

    return try results.toOwnedSlice(allocator);
}

/// Validate a spec file without executing it. Returns null if valid, error message if invalid.
pub fn validateSpecFile(allocator: Allocator, path: []const u8) !?[]const u8 {
    // Try to parse as project spec first
    if (isProjectSpecFile(path)) {
        var project = parser.parseProjectSpecFromFile(allocator, path) catch |err| {
            return try formatValidationError(allocator, err, "project spec");
        };
        project.deinit(allocator);
        return null;
    }

    var spec = parser.parseSpecFromFile(allocator, path) catch |err| {
        return try formatValidationError(allocator, err, "spec");
    };
    spec.deinit(allocator);
    return null;
}

fn formatValidationError(allocator: Allocator, err: anyerror, spec_type: []const u8) ![]const u8 {
    const detail = switch (err) {
        error.MissingRequiredField => "Missing required field. A spec must have 'name' and 'test.command'. Run 'induct schema' for the full format.",
        error.InvalidYaml => "YAML syntax error. Check indentation and formatting.",
        error.UnexpectedToken => "Unexpected token in YAML. Check for invalid characters or incorrect nesting.",
        error.InvalidCharacter => "Invalid character found. Check for encoding issues.",
        error.FileNotFound => "File not found. Check that the path exists.",
        error.IsDir => "Path is a directory, not a file. Use 'run-dir' for directories.",
        else => return try std.fmt.allocPrint(allocator, "Invalid {s}: {}", .{ spec_type, err }),
    };
    return try allocator.dupe(u8, detail);
}

pub const ExecuteOptions = struct {
    fail_fast: bool = false,
    filter: ?[]const u8 = null,
    max_jobs: usize = 1,
    default_timeout_ms: ?u64 = null,
};

pub fn executeSpecsFromDir(allocator: Allocator, dir_path: []const u8) ![]SpecResult {
    return executeSpecsFromDirWithOptions(allocator, dir_path, .{});
}

pub fn executeSpecsFromDirWithOptions(allocator: Allocator, dir_path: []const u8, options: ExecuteOptions) ![]SpecResult {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Collect spec file paths
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
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
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
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
        const file_results = try executeSpecFromFileWithTimeout(allocator, path, options.default_timeout_ms);
        defer allocator.free(file_results);

        var should_stop = false;
        for (file_results) |r| {
            try results.append(allocator, r);
            if (options.fail_fast and !r.passed and r.status != .skipped) {
                should_stop = true;
            }
        }
        if (should_stop) break;
    }

    return try results.toOwnedSlice(allocator);
}

fn executeSpecsParallel(allocator: Allocator, paths: []const []const u8, options: ExecuteOptions) ![]SpecResult {
    const n = paths.len;
    const effective_jobs = @min(options.max_jobs, n);

    // Each file can produce multiple results (steps), so store slices
    const file_results = try allocator.alloc([]SpecResult, n);
    defer allocator.free(file_results);
    for (file_results) |*r| r.* = &.{};

    const default_timeout = options.default_timeout_ms;

    const ThreadContext = struct {
        alloc: Allocator,
        path: []const u8,
        result_slot: *[]SpecResult,
        timeout_ms: ?u64,

        fn work(ctx: @This()) void {
            ctx.result_slot.* = executeSpecFromFileWithTimeout(ctx.alloc, ctx.path, ctx.timeout_ms) catch {
                // Create error result on failure
                var err_results: std.ArrayListUnmanaged(SpecResult) = .empty;
                err_results.append(ctx.alloc, SpecResult{
                    .id = ctx.alloc.dupe(u8, "error") catch return,
                    .spec_name = ctx.alloc.dupe(u8, ctx.path) catch return,
                    .passed = false,
                    .actual_output = ctx.alloc.dupe(u8, "") catch return,
                    .actual_stderr = ctx.alloc.dupe(u8, "") catch return,
                    .actual_exit_code = -1,
                    .error_message = ctx.alloc.dupe(u8, "Thread execution failed") catch null,
                    .duration_ms = 0,
                }) catch return;
                ctx.result_slot.* = err_results.toOwnedSlice(ctx.alloc) catch return;
                return;
            };
        }
    };

    var threads = try allocator.alloc(?std.Thread, n);
    defer allocator.free(threads);
    for (threads) |*t| t.* = null;

    var launched: usize = 0;

    for (paths, 0..) |path, i| {
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
            .result_slot = &file_results[i],
            .timeout_ms = default_timeout,
        }}) catch null;

        if (threads[i] != null) {
            launched += 1;
        } else {
            file_results[i] = try executeSpecFromFileWithTimeout(allocator, path, default_timeout);
        }
    }

    for (threads) |t| {
        if (t) |thread| thread.join();
    }

    // Flatten results
    var all_results: std.ArrayListUnmanaged(SpecResult) = .empty;
    for (file_results) |fr| {
        for (fr) |r| {
            try all_results.append(allocator, r);
        }
        allocator.free(fr);
    }

    return try all_results.toOwnedSlice(allocator);
}

pub fn executeProjectSpec(allocator: Allocator, project: ProjectSpec, base_dir: ?[]const u8) ![]SpecResult {
    return executeProjectSpecWithOptions(allocator, project, base_dir, .{});
}

pub fn executeProjectSpecWithOptions(allocator: Allocator, project: ProjectSpec, base_dir: ?[]const u8, options: ExecuteOptions) ![]SpecResult {
    // Collect work items: resolve include paths and apply filter
    const WorkItem = union(enum) {
        inline_spec_idx: usize, // index into project.specs
        include_file: []const u8, // owned full path
    };

    var work_items: std.ArrayListUnmanaged(WorkItem) = .empty;
    defer {
        for (work_items.items) |item| {
            switch (item) {
                .include_file => |p| allocator.free(p),
                .inline_spec_idx => {},
            }
        }
        work_items.deinit(allocator);
    }

    // Collect inline specs
    for (project.specs, 0..) |spec, idx| {
        if (options.filter) |filter| {
            if (std.mem.indexOf(u8, spec.name, filter) == null) continue;
        }
        try work_items.append(allocator, .{ .inline_spec_idx = idx });
    }

    // Collect include files
    for (project.include) |include_path| {
        const full_path = if (base_dir) |base|
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, include_path })
        else
            try allocator.dupe(u8, include_path);

        // Apply filter for non-projectspec includes
        if (!isProjectSpecFile(include_path)) {
            if (options.filter) |filter| {
                var spec = parser.parseSpecFromFile(allocator, full_path) catch {
                    try work_items.append(allocator, .{ .include_file = full_path });
                    continue;
                };
                const matches = std.mem.indexOf(u8, spec.name, filter) != null;
                spec.deinit(allocator);
                if (!matches) {
                    allocator.free(full_path);
                    continue;
                }
            }
        }
        try work_items.append(allocator, .{ .include_file = full_path });
    }

    if (work_items.items.len == 0) {
        return try allocator.alloc(SpecResult, 0);
    }

    // Sequential execution
    if (options.max_jobs <= 1) {
        var results: std.ArrayListUnmanaged(SpecResult) = .empty;
        errdefer {
            for (results.items) |*r| r.deinit(allocator);
            results.deinit(allocator);
        }

        for (work_items.items) |item| {
            switch (item) {
                .inline_spec_idx => |idx| {
                    const result = try executeSpec(allocator, project.specs[idx], options.default_timeout_ms);
                    try results.append(allocator, result);
                    if (options.fail_fast and !result.passed) {
                        return try results.toOwnedSlice(allocator);
                    }
                },
                .include_file => |full_path| {
                    if (isProjectSpecFile(full_path)) {
                        var nested_project = parser.parseProjectSpecFromFile(allocator, full_path) catch |err| {
                            try results.append(allocator, SpecResult{
                                .id = try generateId(allocator),
                                .spec_name = try allocator.dupe(u8, full_path),
                                .passed = false,
                                .actual_output = try allocator.dupe(u8, ""),
                                .actual_stderr = try allocator.dupe(u8, ""),
                                .actual_exit_code = -1,
                                .error_message = try std.fmt.allocPrint(allocator, "Failed to parse project spec: {}", .{err}),
                                .duration_ms = 0,
                            });
                            continue;
                        };
                        defer nested_project.deinit(allocator);
                        const nested_base_dir = std.fs.path.dirname(full_path);
                        const nested_results = try executeProjectSpecWithOptions(allocator, nested_project, nested_base_dir, options);
                        defer allocator.free(nested_results);
                        for (nested_results) |r| try results.append(allocator, r);
                    } else {
                        const file_results = try executeSpecFromFileWithTimeout(allocator, full_path, options.default_timeout_ms);
                        defer allocator.free(file_results);
                        var should_stop = false;
                        for (file_results) |r| {
                            try results.append(allocator, r);
                            if (options.fail_fast and !r.passed and r.status != .skipped) should_stop = true;
                        }
                        if (should_stop) return try results.toOwnedSlice(allocator);
                    }
                },
            }
        }
        return try results.toOwnedSlice(allocator);
    }

    // Parallel execution
    const n = work_items.items.len;
    const effective_jobs = @min(options.max_jobs, n);

    const slot_results = try allocator.alloc([]SpecResult, n);
    defer allocator.free(slot_results);
    for (slot_results) |*r| r.* = &.{};

    const ParallelCtx = struct {
        alloc: Allocator,
        item: WorkItem,
        project_specs: []const spec_mod.Spec,
        opts: ExecuteOptions,
        result_slot: *[]SpecResult,

        fn work(ctx: @This()) void {
            switch (ctx.item) {
                .inline_spec_idx => |idx| {
                    const result = executeSpec(ctx.alloc, ctx.project_specs[idx], ctx.opts.default_timeout_ms) catch return;
                    var res: std.ArrayListUnmanaged(SpecResult) = .empty;
                    res.append(ctx.alloc, result) catch return;
                    ctx.result_slot.* = res.toOwnedSlice(ctx.alloc) catch return;
                },
                .include_file => |full_path| {
                    if (isProjectSpecFile(full_path)) {
                        var nested_project = parser.parseProjectSpecFromFile(ctx.alloc, full_path) catch return;
                        defer nested_project.deinit(ctx.alloc);
                        const nested_base_dir = std.fs.path.dirname(full_path);
                        ctx.result_slot.* = executeProjectSpecWithOptions(ctx.alloc, nested_project, nested_base_dir, ctx.opts) catch return;
                    } else {
                        ctx.result_slot.* = executeSpecFromFileWithTimeout(ctx.alloc, full_path, ctx.opts.default_timeout_ms) catch return;
                    }
                },
            }
        }
    };

    var threads = try allocator.alloc(?std.Thread, n);
    defer allocator.free(threads);
    for (threads) |*t| t.* = null;

    var launched: usize = 0;

    for (work_items.items, 0..) |item, i| {
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

        threads[i] = std.Thread.spawn(.{}, ParallelCtx.work, .{ParallelCtx{
            .alloc = allocator,
            .item = item,
            .project_specs = project.specs,
            .opts = options,
            .result_slot = &slot_results[i],
        }}) catch null;

        if (threads[i] != null) {
            launched += 1;
        } else {
            // Fallback to sequential if thread spawn fails
            switch (item) {
                .inline_spec_idx => |idx| {
                    var res: std.ArrayListUnmanaged(SpecResult) = .empty;
                    res.append(allocator, try executeSpec(allocator, project.specs[idx], options.default_timeout_ms)) catch {};
                    slot_results[i] = res.toOwnedSlice(allocator) catch &.{};
                },
                .include_file => |full_path| {
                    slot_results[i] = executeSpecFromFileWithTimeout(allocator, full_path, options.default_timeout_ms) catch &.{};
                },
            }
        }
    }

    for (threads) |t| {
        if (t) |thread| thread.join();
    }

    // Flatten results
    var all_results: std.ArrayListUnmanaged(SpecResult) = .empty;
    for (slot_results) |sr| {
        for (sr) |r| try all_results.append(allocator, r);
        if (sr.len > 0) allocator.free(sr);
    }

    return try all_results.toOwnedSlice(allocator);
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
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Check by filename convention first
    if (std.mem.endsWith(u8, path, "inductspec.yaml")) return true;

    // Check by content: if file has include: or specs: top-level keys, it's a ProjectSpec
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(1024 * 1024)) catch return false;
    defer std.heap.page_allocator.free(content);

    return hasProjectSpecKeys(content);
}

fn hasProjectSpecKeys(content: []const u8) bool {
    // Look for top-level include: or specs: keys (not indented)
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "include:")) return true;
        if (std.mem.startsWith(u8, line, "specs:")) return true;
    }
    return false;
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

    var result = try executeSpec(std.testing.allocator, spec, null);
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

    var result = try executeSpec(std.testing.allocator, spec, null);
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

    var result = try executeSpec(std.testing.allocator, spec, null);
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

test "isProjectSpecFile by name" {
    try std.testing.expect(isProjectSpecFile("inductspec.yaml"));
    try std.testing.expect(isProjectSpecFile("path/to/inductspec.yaml"));
}

test "hasProjectSpecKeys" {
    try std.testing.expect(hasProjectSpecKeys("name: test\ninclude:\n  - foo.yaml\n"));
    try std.testing.expect(hasProjectSpecKeys("name: test\nspecs:\n  - name: foo\n"));
    try std.testing.expect(!hasProjectSpecKeys("name: test\ntest:\n  command: echo\n"));
    try std.testing.expect(!hasProjectSpecKeys("name: test\n  include: nested\n"));
}
