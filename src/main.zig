const std = @import("std");
const induct = @import("induct");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
                // 引数なしの場合はヘルプを表示して正常終了
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
            var reporter = induct.cli.reporter.Reporter.init(run_args.verbose, run_args.json_output);

            // Check if this is a project spec file (inductspec.yaml)
            if (induct.core.executor.isProjectSpecFile(run_args.spec_path)) {
                const results = try induct.core.executor.executeProjectSpecFromFile(allocator, run_args.spec_path);
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
                reporter.reportSummary(summary);

                if (summary.failed > 0) {
                    std.process.exit(1);
                }
            } else {
                var result = try induct.core.executor.executeSpecFromFile(allocator, run_args.spec_path);
                defer result.deinit(allocator);

                reporter.reportResult(result);

                var summary = induct.core.result.RunSummary.init();
                summary.add(result);
                reporter.reportSummary(summary);

                if (!result.passed) {
                    std.process.exit(1);
                }
            }
        },
        .run_dir => |run_args| {
            var reporter = induct.cli.reporter.Reporter.init(run_args.verbose, run_args.json_output);
            const results = try induct.core.executor.executeSpecsFromDir(allocator, run_args.dir_path);
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
            reporter.reportSummary(summary);

            if (summary.failed > 0) {
                std.process.exit(1);
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

test "main module imports" {
    _ = induct;
}
