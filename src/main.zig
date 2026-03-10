const std = @import("std");
const induct = @import("induct");

const init_template_basic =
    \\name: my spec
    \\description: Description of what this spec tests
    \\
    \\test:
    \\  command: echo "hello world"
    \\  expect_output: "hello world\n"
    \\  expect_exit_code: 0
    \\  # input: "stdin input"
    \\  # expect_output_contains: "hello"
    \\  # expect_output_not_contains: "error"
    \\  # expect_output_regex: "hello.*world"
    \\  # expect_stderr: ""
    \\  # expect_stderr_contains: ""
    \\  # env:
    \\  #   KEY: value
    \\  # working_dir: /path/to/dir
    \\  # timeout_ms: 5000
    \\
;

const init_template_with_setup =
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
    \\  # input: "stdin input"
    \\  # expect_output_contains: "hello"
    \\  # expect_output_not_contains: "error"
    \\  # expect_output_regex: "hello.*world"
    \\  # expect_stderr: ""
    \\  # expect_stderr_contains: ""
    \\  # env:
    \\  #   KEY: value
    \\  # working_dir: /path/to/dir
    \\  # timeout_ms: 5000
    \\
    \\teardown:
    \\  - run: echo "cleaning up"
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
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

    switch (command) {
        .run => |run_args| {
            const format: induct.cli.reporter.OutputFormat = if (run_args.junit_output)
                .junit
            else if (run_args.json_output)
                .json
            else
                .text;
            var reporter = induct.cli.reporter.Reporter.initWithFormat(run_args.verbose, format);

            const options = induct.core.executor.ExecuteOptions{
                .fail_fast = run_args.fail_fast,
            };

            if (run_args.dry_run) {
                // Dry-run mode: parse and display without executing
                try handleDryRun(allocator, run_args.spec_path, &reporter);
                return;
            }

            if (induct.core.executor.isProjectSpecFile(run_args.spec_path)) {
                const results = try induct.core.executor.executeProjectSpecFromFileWithOptions(allocator, run_args.spec_path, options);
                defer {
                    for (results) |*r| {
                        var result = @constCast(r);
                        result.deinit(allocator);
                    }
                    allocator.free(results);
                }

                var summary = induct.core.result.RunSummary.init();
                for (results) |r| {
                    reporter.reportResult(r);
                    summary.add(r);
                }

                if (format == .junit) {
                    reporter.reportJunit(results, summary);
                } else {
                    reporter.reportSummary(summary);
                }

                if (summary.failed > 0) std.process.exit(1);
            } else {
                var result = try induct.core.executor.executeSpecFromFile(allocator, run_args.spec_path);
                defer result.deinit(allocator);

                var summary = induct.core.result.RunSummary.init();
                summary.add(result);

                if (format == .junit) {
                    const results_slice = @as([]const induct.core.result.SpecResult, &[_]induct.core.result.SpecResult{result});
                    reporter.reportJunit(results_slice, summary);
                } else {
                    reporter.reportResult(result);
                    reporter.reportSummary(summary);
                }

                if (!result.passed) std.process.exit(1);
            }
        },
        .run_dir => |run_args| {
            const format: induct.cli.reporter.OutputFormat = if (run_args.junit_output)
                .junit
            else if (run_args.json_output)
                .json
            else
                .text;
            var reporter = induct.cli.reporter.Reporter.initWithFormat(run_args.verbose, format);

            if (run_args.dry_run) {
                try handleDryRunDir(allocator, run_args.dir_path, &reporter);
                return;
            }

            const options = induct.core.executor.ExecuteOptions{
                .fail_fast = run_args.fail_fast,
                .filter = run_args.filter,
                .max_jobs = run_args.max_jobs,
            };

            const results = try induct.core.executor.executeSpecsFromDirWithOptions(allocator, run_args.dir_path, options);
            defer {
                for (results) |*r| {
                    var result = r.*;
                    result.deinit(allocator);
                }
                allocator.free(results);
            }

            var summary = induct.core.result.RunSummary.init();
            for (results) |r| {
                reporter.reportResult(r);
                summary.add(r);
            }

            if (format == .junit) {
                reporter.reportJunit(results, summary);
            } else {
                reporter.reportSummary(summary);
            }

            if (summary.failed > 0) std.process.exit(1);
        },
        .init_cmd => |init_args| {
            const template = if (init_args.with_setup) init_template_with_setup else init_template_basic;

            if (init_args.output_path) |path| {
                const file = std.fs.cwd().createFile(path, .{ .exclusive = true }) catch |err| {
                    if (err == error.PathAlreadyExists) {
                        stderr.print("Error: File '{s}' already exists\n", .{path}) catch {};
                    } else {
                        stderr.print("Error: Failed to create file '{s}': {}\n", .{ path, err }) catch {};
                    }
                    stderr.flush() catch {};
                    std.process.exit(1);
                };
                defer file.close();
                file.writeAll(template) catch |write_err| {
                    stderr.print("Error: Failed to write file: {}\n", .{write_err}) catch {};
                    stderr.flush() catch {};
                    std.process.exit(1);
                };
                stdout.print("Created spec template: {s}\n", .{path}) catch {};
                stdout.flush() catch {};
                return;
            } else {
                // Write to stdout
                stdout.print("{s}", .{template}) catch {};
                stdout.flush() catch {};
            }
        },
        .validate_cmd => |val_args| {
            const err_msg = try induct.core.executor.validateSpecFile(allocator, val_args.spec_path);
            if (err_msg) |msg| {
                defer allocator.free(msg);
                stderr.print("INVALID: {s}\n  {s}\n", .{ val_args.spec_path, msg }) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            } else {
                stdout.print("VALID: {s}\n", .{val_args.spec_path}) catch {};
                stdout.flush() catch {};
            }
        },
        .mcp => {
            var server = induct.mcp.server.McpServer.init(allocator);
            defer server.deinit();
            try server.run();
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

fn handleDryRun(allocator: std.mem.Allocator, spec_path: []const u8, reporter: *induct.cli.reporter.Reporter) !void {
    if (induct.core.executor.isProjectSpecFile(spec_path)) {
        var project = try induct.yaml.parser.parseProjectSpecFromFile(allocator, spec_path);
        defer project.deinit(allocator);

        for (project.specs) |spec| {
            reporter.reportDryRun(spec.name, spec.test_case.command, spec.setup != null, spec.teardown != null);
        }
        for (project.include) |include_path| {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_writer.interface;
            stdout.print("[DRY-RUN] include: {s}\n", .{include_path}) catch {};
            stdout.flush() catch {};
        }
    } else {
        var spec = try induct.yaml.parser.parseSpecFromFile(allocator, spec_path);
        defer spec.deinit(allocator);
        reporter.reportDryRun(spec.name, spec.test_case.command, spec.setup != null, spec.teardown != null);
    }
}

fn handleDryRunDir(allocator: std.mem.Allocator, dir_path: []const u8, reporter: *induct.cli.reporter.Reporter) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);

        var spec = induct.yaml.parser.parseSpecFromFile(allocator, full_path) catch |err| {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_writer.interface;
            stdout.print("[DRY-RUN] {s}: parse error: {}\n", .{ entry.name, err }) catch {};
            stdout.flush() catch {};
            continue;
        };
        defer spec.deinit(allocator);
        reporter.reportDryRun(spec.name, spec.test_case.command, spec.setup != null, spec.teardown != null);
    }
}

test "main module imports" {
    _ = induct;
}
