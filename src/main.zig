const std = @import("std");
const induct = @import("induct");

const templates = struct {
    const basic =
        \\name: my spec
        \\description: Description of what this spec tests
        \\
        \\test:
        \\  command: echo "hello world"
        \\  expect_output: "hello world\n"
        \\  expect_exit_code: 0
        \\
    ;

    const setup =
        \\name: my spec
        \\description: Description of what this spec tests
        \\
        \\setup:
        \\  - run: echo "setting up"
        \\
        \\test:
        \\  command: echo "hello world"
        \\  expect_output: "hello world\n"
        \\  expect_exit_code: 0
        \\
        \\teardown:
        \\  - run: echo "cleaning up"
        \\
    ;

    const api =
        \\name: API endpoint test
        \\description: Verify API responds correctly
        \\
        \\test:
        \\  command: curl -s http://localhost:8080/health
        \\  expect_output_contains: '"status"'
        \\  expect_exit_code: 0
        \\  timeout_ms: 5000
        \\
    ;

    const cli_tool =
        \\name: CLI command test
        \\description: Verify CLI command output
        \\
        \\test:
        \\  command: ./my-tool --version
        \\  expect_output_contains: "v"
        \\  expect_exit_code: 0
        \\
    ;

    const project =
        \\name: my project
        \\description: Project test suite
        \\
        \\specs:
        \\  - name: sanity check
        \\    test:
        \\      command: echo "ok"
        \\      expect_output: "ok\n"
        \\
        \\include:
        \\  # - specs/feature.yaml
        \\
    ;

    fn get(template_type: induct.cli.args.TemplateType) []const u8 {
        return switch (template_type) {
            .basic => basic,
            .setup => setup,
            .api => api,
            .cli_tool => cli_tool,
            .project => project,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const command = induct.cli.args.parseArgs(args) catch |err| {
        switch (err) {
            error.MissingCommand => {
                induct.cli.reporter.printHelp(stdout);
                stdout.flush() catch {};
                return;
            },
            error.MissingArgument => {
                stderr.print("Error: Missing required argument\n\n", .{}) catch {};
                induct.cli.reporter.printHelp(stderr);
            },
            error.UnknownCommand => {
                stderr.print("Error: Unknown command\n\n", .{}) catch {};
                induct.cli.reporter.printHelp(stderr);
            },
            else => {
                stderr.print("Error: {}\n", .{err}) catch {};
            },
        }
        stderr.flush() catch {};
        std.process.exit(1);
    };

    try dispatchCommand(io, allocator, command, stdout, stderr);
}

fn dispatchCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: induct.cli.args.Command,
    stdout: anytype,
    stderr: anytype,
) !void {
    switch (command) {
        .run => |run_args| try handleRunCommand(io, allocator, run_args),
        .run_dir => |run_args| try handleRunDirCommand(io, allocator, run_args),
        .init_cmd => |init_args| handleInitCommand(io, init_args, stdout, stderr),
        .validate_cmd => |val_args| try handleValidateCommand(allocator, val_args, stdout, stderr),
        .list_cmd => |list_args| {
            try handleList(io, allocator, list_args.dir_path, list_args.markdown, stdout);
            stdout.flush() catch {};
        },
        .schema => {
            induct.cli.reporter.printSchema(stdout);
            stdout.flush() catch {};
        },
        .version => {
            induct.cli.reporter.printVersion(stdout);
            stdout.flush() catch {};
        },
        .help => {
            induct.cli.reporter.printHelp(stdout);
            stdout.flush() catch {};
        },
    }
}

fn outputFormat(run_json: bool, run_junit: bool) induct.cli.reporter.OutputFormat {
    return if (run_junit)
        .junit
    else if (run_json)
        .json
    else
        .text;
}

fn summarizeAndReport(
    reporter: *induct.cli.reporter.Reporter,
    format: induct.cli.reporter.OutputFormat,
    results: []const induct.core.result.SpecResult,
) void {
    var summary = induct.core.result.RunSummary.init();
    for (results) |r| {
        reporter.reportResult(r);
        summary.add(r);
    }

    if (format == .junit) {
        reporter.reportJunit(results, summary);
    } else {
        reporter.reportSummary(summary, results);
    }
    if (summary.failed > 0) std.process.exit(1);
}

fn deinitResults(allocator: std.mem.Allocator, results: []induct.core.result.SpecResult) void {
    for (results) |*r| {
        var result = @constCast(r);
        result.deinit(allocator);
    }
    allocator.free(results);
}

fn handleRunCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    run_args: induct.cli.args.RunArgs,
) !void {
    const format = outputFormat(run_args.json_output, run_args.junit_output);
    var reporter = induct.cli.reporter.Reporter.initWithFormat(io, run_args.verbose, format);
    const options = induct.core.executor.ExecuteOptions{
        .fail_fast = run_args.fail_fast,
        .filter = run_args.filter,
        .default_timeout_ms = run_args.timeout_ms,
        .max_jobs = run_args.max_jobs,
    };

    if (run_args.dry_run) return handleDryRun(io, allocator, run_args.spec_path, &reporter);

    const results = if (induct.core.executor.isProjectSpecFile(run_args.spec_path))
        try induct.core.executor.executeProjectSpecFromFileWithOptions(
            allocator,
            run_args.spec_path,
            options,
        )
    else
        try induct.core.executor.executeSpecFromFileWithTimeout(
            allocator,
            run_args.spec_path,
            options.default_timeout_ms,
        );
    defer deinitResults(allocator, results);
    summarizeAndReport(&reporter, format, results);
}

fn handleRunDirCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    run_args: induct.cli.args.RunDirArgs,
) !void {
    const format = outputFormat(run_args.json_output, run_args.junit_output);
    var reporter = induct.cli.reporter.Reporter.initWithFormat(io, run_args.verbose, format);
    if (run_args.dry_run) return handleDryRunDir(io, allocator, run_args.dir_path, &reporter);

    const options = induct.core.executor.ExecuteOptions{
        .fail_fast = run_args.fail_fast,
        .filter = run_args.filter,
        .max_jobs = run_args.max_jobs,
        .default_timeout_ms = run_args.timeout_ms,
    };
    const results = try induct.core.executor.executeSpecsFromDirWithOptions(
        allocator,
        run_args.dir_path,
        options,
    );
    defer deinitResults(allocator, results);
    summarizeAndReport(&reporter, format, results);
}

fn handleInitCommand(
    io: std.Io,
    init_args: induct.cli.args.InitArgs,
    stdout: anytype,
    stderr: anytype,
) void {
    const template = templates.get(init_args.template);
    if (init_args.output_path) |path| {
        const file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| {
            if (err == error.PathAlreadyExists) {
                stderr.print("Error: File '{s}' already exists\n", .{path}) catch {};
            } else {
                stderr.print("Error: Failed to create file '{s}': {}\n", .{ path, err }) catch {};
            }
            stderr.flush() catch {};
            std.process.exit(1);
        };
        defer file.close(io);
        file.writeStreamingAll(io, template) catch |write_err| {
            stderr.print("Error: Failed to write file: {}\n", .{write_err}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        stdout.print("Created spec template: {s}\n", .{path}) catch {};
        stdout.flush() catch {};
        return;
    }
    stdout.print("{s}", .{template}) catch {};
    stdout.flush() catch {};
}

fn handleValidateCommand(
    allocator: std.mem.Allocator,
    val_args: induct.cli.args.ValidateArgs,
    stdout: anytype,
    stderr: anytype,
) !void {
    const err_msg = try induct.core.executor.validateSpecFile(allocator, val_args.spec_path);
    if (err_msg) |msg| {
        defer allocator.free(msg);
        stderr.print("INVALID: {s}\n  {s}\n", .{ val_args.spec_path, msg }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }
    stdout.print("VALID: {s}\n", .{val_args.spec_path}) catch {};
    stdout.flush() catch {};
}

fn formatDryRunCommand(allocator: std.mem.Allocator, test_case: induct.core.TestCase) ![]const u8 {
    return test_case.formatCommand(allocator);
}

fn reportDryRunSpec(
    allocator: std.mem.Allocator,
    reporter: *induct.cli.reporter.Reporter,
    spec: induct.core.Spec,
) !void {
    if (spec.hasSteps()) {
        const steps = spec.steps.?;
        for (steps, 0..) |step, idx| {
            const step_name = try std.fmt.allocPrint(
                allocator,
                "{s} > {s}",
                .{ spec.name, step.name },
            );
            defer allocator.free(step_name);

            const formatted = try formatDryRunCommand(allocator, step.test_case);
            defer allocator.free(formatted);

            reporter.reportDryRun(
                step_name,
                formatted,
                idx == 0 and spec.setup != null,
                idx == steps.len - 1 and spec.teardown != null,
            );
        }
        return;
    }

    const formatted = try formatDryRunCommand(allocator, spec.test_case);
    defer allocator.free(formatted);
    reporter.reportDryRun(spec.name, formatted, spec.setup != null, spec.teardown != null);
}

fn handleDryRun(
    io: std.Io,
    allocator: std.mem.Allocator,
    spec_path: []const u8,
    reporter: *induct.cli.reporter.Reporter,
) !void {
    if (induct.core.executor.isProjectSpecFile(spec_path)) {
        var project = try induct.yaml.parser.parseProjectSpecFromFile(allocator, spec_path);
        defer project.deinit(allocator);

        for (project.specs) |spec| {
            try reportDryRunSpec(allocator, reporter, spec);
        }
        for (project.include) |include_path| {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
            const stdout = &stdout_writer.interface;
            stdout.print("[DRY-RUN] include: {s}\n", .{include_path}) catch {};
            stdout.flush() catch {};
        }
    } else {
        var spec = try induct.yaml.parser.parseSpecFromFile(allocator, spec_path);
        defer spec.deinit(allocator);
        try reportDryRunSpec(allocator, reporter, spec);
    }
}

fn handleDryRunDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    reporter: *induct.cli.reporter.Reporter,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isYamlFile(entry.name)) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);

        var spec = induct.yaml.parser.parseSpecFromFile(allocator, full_path) catch |err| {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
            const stdout = &stdout_writer.interface;
            stdout.print("[DRY-RUN] {s}: parse error: {}\n", .{ entry.name, err }) catch {};
            stdout.flush() catch {};
            continue;
        };
        defer spec.deinit(allocator);
        try reportDryRunSpec(allocator, reporter, spec);
    }
}

fn flattenOneLine(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    // Trim trailing whitespace/newlines, then replace internal newlines with spaces
    const trimmed = std.mem.trimRight(u8, s, " \t\n\r");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (trimmed) |c| {
        if (c == '\n') {
            // Skip if last char was already a space
            if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') continue;
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, c);
        }
    }
    return try out.toOwnedSlice(allocator);
}

const ListEntry = struct {
    name: []const u8,
    description: []const u8,
    file: []const u8,
};

fn handleList(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    markdown: bool,
    writer: anytype,
) !void {
    // Check if path is a file (ProjectSpec) or directory
    const is_file = blk: {
        std.Io.Dir.cwd().access(io, path, .{}) catch break :blk false;
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch break :blk true;
        dir.close(io);
        break :blk false;
    };

    var entries: std.ArrayListUnmanaged(ListEntry) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.name);
            if (e.description.len > 0) allocator.free(e.description);
            allocator.free(e.file);
        }
        entries.deinit(allocator);
    }

    if (is_file) {
        if (induct.core.executor.isProjectSpecFile(path)) {
            try collectProjectSpecEntries(allocator, path, &entries);
        } else {
            // Single spec file: show name and description directly
            var spec = induct.yaml.parser.parseSpecFromFile(allocator, path) catch |err| {
                writer.print("Error: Failed to parse {s}: {}\n", .{ path, err }) catch {};
                return;
            };
            defer spec.deinit(allocator);

            writer.print("{s}\n", .{spec.name}) catch {};
            if (spec.description) |desc| {
                // Print description with indentation
                var line_iter = std.mem.splitScalar(u8, desc, '\n');
                while (line_iter.next()) |line| {
                    if (line.len > 0) {
                        writer.print("  {s}\n", .{line}) catch {};
                    }
                }
            }
            return;
        }
    } else {
        try collectDirEntries(io, allocator, path, &entries);
    }

    // Sort by filename
    std.mem.sort(ListEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: ListEntry, b: ListEntry) bool {
            return std.mem.order(u8, a.file, b.file) == .lt;
        }
    }.lessThan);

    if (markdown) {
        writer.print("| Name | File | Description |\n", .{}) catch {};
        writer.print("|------|------|-------------|\n", .{}) catch {};
        for (entries.items) |e| {
            // Flatten description for markdown: replace newlines with spaces
            writer.print("| {s} | {s} | ", .{ e.name, e.file }) catch {};
            if (e.description.len > 0) {
                for (e.description) |c| {
                    if (c == '\n') {
                        writer.print(" ", .{}) catch {};
                    } else {
                        writer.print("{c}", .{c}) catch {};
                    }
                }
            }
            writer.print(" |\n", .{}) catch {};
        }
    } else {
        for (entries.items) |e| {
            writer.print("{s}\n", .{e.name}) catch {};
            if (e.description.len > 0) {
                // Print multi-line description with indentation
                var line_iter = std.mem.splitScalar(u8, e.description, '\n');
                while (line_iter.next()) |line| {
                    if (line.len > 0) {
                        writer.print("  {s}\n", .{line}) catch {};
                    }
                }
            }
            writer.print("\n", .{}) catch {};
        }
    }
}

fn collectDirEntries(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    entries: *std.ArrayListUnmanaged(ListEntry),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isYamlFile(entry.name)) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);

        var spec = induct.yaml.parser.parseSpecFromFile(allocator, full_path) catch continue;
        const name = try allocator.dupe(u8, spec.name);
        const desc = if (spec.description) |d|
            try allocator.dupe(u8, d)
        else
            try allocator.dupe(u8, "");
        const file = try allocator.dupe(u8, entry.name);
        spec.deinit(allocator);

        try entries.append(allocator, .{ .name = name, .description = desc, .file = file });
    }
}

fn collectProjectSpecEntries(
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: *std.ArrayListUnmanaged(ListEntry),
) !void {
    var project = try induct.yaml.parser.parseProjectSpecFromFile(allocator, path);
    defer project.deinit(allocator);

    const base_dir = std.fs.path.dirname(path);

    // Inline specs
    for (project.specs) |spec| {
        const name = try allocator.dupe(u8, spec.name);
        const desc = if (spec.description) |d|
            try allocator.dupe(u8, d)
        else
            try allocator.dupe(u8, "");
        const file = try allocator.dupe(u8, "(inline)");
        try entries.append(allocator, .{ .name = name, .description = desc, .file = file });
    }

    // Included spec files
    for (project.include) |include_path| {
        const full_path = if (base_dir) |base|
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, include_path })
        else
            try allocator.dupe(u8, include_path);
        defer allocator.free(full_path);

        // Recurse into nested ProjectSpecs (use full_path for content-based detection)
        if (induct.core.executor.isProjectSpecFile(full_path)) {
            collectProjectSpecEntries(allocator, full_path, entries) catch continue;
            continue;
        }

        var spec = induct.yaml.parser.parseSpecFromFile(allocator, full_path) catch continue;
        const name = try allocator.dupe(u8, spec.name);
        const desc = if (spec.description) |d|
            try allocator.dupe(u8, d)
        else
            try allocator.dupe(u8, "");
        const file = try allocator.dupe(u8, include_path);
        spec.deinit(allocator);

        try entries.append(allocator, .{ .name = name, .description = desc, .file = file });
    }
}

test "main module imports" {
    _ = induct;
}

fn isYamlFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".yaml") or std.mem.endsWith(u8, name, ".yml");
}
