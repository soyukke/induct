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
                    reporter.reportSummary(summary, results);
                }

                if (summary.failed > 0) std.process.exit(1);
            } else {
                const results = try induct.core.executor.executeSpecFromFile(allocator, run_args.spec_path);
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
                    reporter.reportSummary(summary, results);
                }

                if (summary.failed > 0) std.process.exit(1);
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
                reporter.reportSummary(summary, results);
            }

            if (summary.failed > 0) std.process.exit(1);
        },
        .init_cmd => |init_args| {
            const template = templates.get(init_args.template);

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
