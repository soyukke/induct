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

var result_counter: u64 = 0;

fn generateId(allocator: Allocator) ![]const u8 {
    result_counter += 1;
    const timestamp = @as(u64, @intCast(std.time.milliTimestamp()));
    return std.fmt.allocPrint(allocator, "{d}-{d}", .{ timestamp, result_counter });
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
                    // Other errors - assume file exists to be safe
                    break :blk true;
                };
                break :blk true;
            };

            if (!file_exists) {
                // File doesn't exist - return GENERATE_REQUIRED status
                const end_time = std.time.milliTimestamp();
                const framework_hint = path_extractor.detectFramework(spec.test_case.command);
                return SpecResult{
                    .id = try generateId(allocator),
                    .spec_name = try allocator.dupe(u8, spec.name),
                    .passed = false,
                    .status = .generate_required,
                    .actual_output = try allocator.dupe(u8, ""),
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
            // File exists - free the path and continue with normal execution
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

    var actual_output: []const u8 = "";
    var actual_exit_code: i32 = 0;
    var passed = false;

    if (!setup_failed) {
        // Run the test command
        var proc_result = runner.runCommand(
            allocator,
            spec.test_case.command,
            spec.test_case.input,
            null,
        ) catch |err| {
            const end_time = std.time.milliTimestamp();
            return SpecResult{
                .id = try generateId(allocator),
                .spec_name = try allocator.dupe(u8, spec.name),
                .passed = false,
                .actual_output = try allocator.dupe(u8, ""),
                .actual_exit_code = -1,
                .error_message = try std.fmt.allocPrint(allocator, "Failed to run command: {}", .{err}),
                .duration_ms = @intCast(end_time - start_time),
            };
        };
        defer proc_result.deinit(allocator);

        actual_output = try allocator.dupe(u8, proc_result.stdout);
        actual_exit_code = proc_result.exit_code;

        // Validate results
        const validation = validator.validate(
            proc_result.stdout,
            proc_result.exit_code,
            spec.test_case.expect_output,
            spec.test_case.expect_output_contains,
            spec.test_case.expect_exit_code,
        );

        passed = validation.passed;
        if (!passed and validation.error_message != null) {
            error_message = try allocator.dupe(u8, validation.error_message.?);
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
                .kill_process => |_| {
                    // TODO: Implement process killing by name
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
        .actual_exit_code = actual_exit_code,
        .error_message = error_message,
        .duration_ms = @intCast(end_time - start_time),
    };
}

pub fn executeSpecFromFile(allocator: Allocator, path: []const u8) !SpecResult {
    var spec = parser.parseSpecFromFile(allocator, path) catch |err| {
        return SpecResult{
            .id = try generateId(allocator),
            .spec_name = try allocator.dupe(u8, path),
            .passed = false,
            .actual_output = try allocator.dupe(u8, ""),
            .actual_exit_code = -1,
            .error_message = try std.fmt.allocPrint(allocator, "Failed to parse spec: {}", .{err}),
            .duration_ms = 0,
        };
    };
    defer spec.deinit(allocator);

    return executeSpec(allocator, spec);
}

pub fn executeSpecsFromDir(allocator: Allocator, dir_path: []const u8) ![]SpecResult {
    var results: std.ArrayListUnmanaged(SpecResult) = .empty;
    errdefer {
        for (results.items) |*r| {
            r.deinit(allocator);
        }
        results.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        const result = SpecResult{
            .id = try generateId(allocator),
            .spec_name = try allocator.dupe(u8, dir_path),
            .passed = false,
            .actual_output = try allocator.dupe(u8, ""),
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

        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".yaml") and !std.mem.endsWith(u8, name, ".yml")) {
            continue;
        }

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
        defer allocator.free(full_path);

        const result = try executeSpecFromFile(allocator, full_path);
        try results.append(allocator, result);
    }

    return try results.toOwnedSlice(allocator);
}

pub fn executeProjectSpec(allocator: Allocator, project: ProjectSpec, base_dir: ?[]const u8) ![]SpecResult {
    var results: std.ArrayListUnmanaged(SpecResult) = .empty;
    errdefer {
        for (results.items) |*r| {
            r.deinit(allocator);
        }
        results.deinit(allocator);
    }

    // Execute inline specs
    for (project.specs) |spec| {
        const result = try executeSpec(allocator, spec);
        try results.append(allocator, result);
    }

    // Execute specs from include files
    for (project.include) |include_path| {
        const full_path = if (base_dir) |base|
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, include_path })
        else
            try allocator.dupe(u8, include_path);
        defer allocator.free(full_path);

        // Check if include_path is a project spec (inductspec.yaml) or regular spec
        if (std.mem.endsWith(u8, include_path, "inductspec.yaml")) {
            // Recursively execute project spec
            var nested_project = parser.parseProjectSpecFromFile(allocator, full_path) catch |err| {
                const error_result = SpecResult{
                    .id = try generateId(allocator),
                    .spec_name = try allocator.dupe(u8, include_path),
                    .passed = false,
                    .actual_output = try allocator.dupe(u8, ""),
                    .actual_exit_code = -1,
                    .error_message = try std.fmt.allocPrint(allocator, "Failed to parse project spec: {}", .{err}),
                    .duration_ms = 0,
                };
                try results.append(allocator, error_result);
                continue;
            };
            defer nested_project.deinit(allocator);

            // Get directory of the nested project spec
            const nested_base_dir = std.fs.path.dirname(full_path);
            const nested_results = try executeProjectSpec(allocator, nested_project, nested_base_dir);
            defer allocator.free(nested_results);

            for (nested_results) |nested_result| {
                try results.append(allocator, nested_result);
            }
        } else {
            // Execute as regular spec file
            const result = try executeSpecFromFile(allocator, full_path);
            try results.append(allocator, result);
        }
    }

    return try results.toOwnedSlice(allocator);
}

pub fn executeProjectSpecFromFile(allocator: Allocator, path: []const u8) ![]SpecResult {
    var project = parser.parseProjectSpecFromFile(allocator, path) catch |err| {
        var results: std.ArrayListUnmanaged(SpecResult) = .empty;
        const error_result = SpecResult{
            .id = try generateId(allocator),
            .spec_name = try allocator.dupe(u8, path),
            .passed = false,
            .actual_output = try allocator.dupe(u8, ""),
            .actual_exit_code = -1,
            .error_message = try std.fmt.allocPrint(allocator, "Failed to parse project spec: {}", .{err}),
            .duration_ms = 0,
        };
        try results.append(allocator, error_result);
        return try results.toOwnedSlice(allocator);
    };
    defer project.deinit(allocator);

    // Get directory of the project spec file
    const base_dir = std.fs.path.dirname(path);

    return executeProjectSpec(allocator, project, base_dir);
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
