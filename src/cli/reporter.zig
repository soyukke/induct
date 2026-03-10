const std = @import("std");
const result_mod = @import("../core/result.zig");
const SpecResult = result_mod.SpecResult;
const RunSummary = result_mod.RunSummary;

pub const OutputFormat = enum {
    text,
    json,
    junit,
};

pub const Reporter = struct {
    stdout: std.fs.File,
    verbose: bool,
    format: OutputFormat,
    use_color: bool,
    buffer: [8192]u8 = undefined,

    const Self = @This();

    pub fn init(verbose: bool, json_output: bool) Self {
        return initWithFormat(verbose, if (json_output) .json else .text);
    }

    pub fn initWithFormat(verbose: bool, format: OutputFormat) Self {
        const stdout = std.fs.File.stdout();
        return .{
            .stdout = stdout,
            .verbose = verbose,
            .format = format,
            .use_color = stdout.supportsAnsiEscapeCodes(),
        };
    }

    fn getWriter(self: *Self) std.fs.File.Writer {
        return self.stdout.writer(&self.buffer);
    }

    pub fn reportResult(self: *Self, result: SpecResult) void {
        switch (self.format) {
            .json => self.reportResultJson(result),
            .junit => {},
            .text => self.reportResultText(result),
        }
    }

    fn reportResultText(self: *Self, result: SpecResult) void {
        var writer = self.getWriter();
        const w = &writer.interface;

        const status_str = if (result.passed) "[PASS]" else "[FAIL]";

        w.print("{s} {s} ({d}ms)\n", .{
            status_str,
            result.spec_name,
            result.duration_ms,
        }) catch {};

        if (self.verbose or !result.passed) {
            if (result.error_message) |msg| {
                w.print("  Error: {s}\n", .{msg}) catch {};
            }
            if (result.timed_out) {
                w.print("  (timed out)\n", .{}) catch {};
            }
            if (self.verbose and result.actual_output.len > 0) {
                w.print("  Output: {s}\n", .{result.actual_output}) catch {};
            }
            if (self.verbose and result.actual_stderr.len > 0) {
                w.print("  Stderr: {s}\n", .{result.actual_stderr}) catch {};
            }
        }

        w.flush() catch {};
    }

    fn reportResultJson(self: *Self, result: SpecResult) void {
        var writer = self.getWriter();
        const w = &writer.interface;

        w.print(
            \\{{"id":"{s}","spec_name":"{s}","passed":{s},"exit_code":{d},"duration_ms":{d}
        , .{
            result.id,
            result.spec_name,
            if (result.passed) "true" else "false",
            result.actual_exit_code,
            result.duration_ms,
        }) catch {};

        if (result.timed_out) {
            w.print(",\"timed_out\":true", .{}) catch {};
        }

        if (result.error_message) |msg| {
            w.print(",\"error\":\"{s}\"", .{msg}) catch {};
        }

        w.print("}}\n", .{}) catch {};
        w.flush() catch {};
    }

    pub fn reportSummary(self: *Self, summary: RunSummary) void {
        switch (self.format) {
            .json => self.reportSummaryJson(summary),
            .junit => {},
            .text => self.reportSummaryText(summary),
        }
    }

    fn reportSummaryText(self: *Self, summary: RunSummary) void {
        var writer = self.getWriter();
        const w = &writer.interface;

        w.print("\n", .{}) catch {};
        w.print("----------------------------------------\n", .{}) catch {};

        w.print("Total: {d} | passed: {d} | failed: {d} | Duration: {d}ms\n", .{
            summary.total,
            summary.passed,
            summary.failed,
            summary.total_duration_ms,
        }) catch {};

        if (summary.failed == 0) {
            w.print("\nAll specs passed!\n", .{}) catch {};
        } else {
            w.print("\nSome specs failed.\n", .{}) catch {};
        }

        w.flush() catch {};
    }

    fn reportSummaryJson(self: *Self, summary: RunSummary) void {
        var writer = self.getWriter();
        const w = &writer.interface;

        w.print(
            \\{{"summary":{{"total":{d},"passed":{d},"failed":{d},"duration_ms":{d}}}}}
        ++ "\n", .{
            summary.total,
            summary.passed,
            summary.failed,
            summary.total_duration_ms,
        }) catch {};

        w.flush() catch {};
    }

    pub fn reportJunit(self: *Self, results: []const SpecResult, summary: RunSummary) void {
        var writer = self.getWriter();
        const w = &writer.interface;

        const duration_s = @as(f64, @floatFromInt(summary.total_duration_ms)) / 1000.0;

        w.print(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<testsuites>
            \\<testsuite name="induct" tests="{d}" failures="{d}" time="{d:.3}">
            \\
        , .{
            summary.total,
            summary.failed,
            duration_s,
        }) catch {};

        for (results) |result| {
            const test_duration_s = @as(f64, @floatFromInt(result.duration_ms)) / 1000.0;
            w.print("<testcase name=\"{s}\" time=\"{d:.3}\"", .{
                result.spec_name,
                test_duration_s,
            }) catch {};

            if (!result.passed) {
                if (result.error_message) |msg| {
                    w.print(">\n<failure message=\"{s}\">", .{msg}) catch {};
                    if (result.actual_output.len > 0) {
                        w.print("{s}", .{result.actual_output}) catch {};
                    }
                    w.print("</failure>\n</testcase>\n", .{}) catch {};
                } else {
                    w.print(">\n<failure message=\"Test failed\"/>\n</testcase>\n", .{}) catch {};
                }
            } else {
                w.print("/>\n", .{}) catch {};
            }
        }

        w.print("</testsuite>\n</testsuites>\n", .{}) catch {};
        w.flush() catch {};
    }

    pub fn reportDryRun(self: *Self, spec_name: []const u8, command: []const u8, has_setup: bool, has_teardown: bool) void {
        var writer = self.getWriter();
        const w = &writer.interface;

        w.print("[DRY-RUN] {s}\n", .{spec_name}) catch {};
        w.print("  Command: {s}\n", .{command}) catch {};
        if (has_setup) {
            w.print("  Setup: yes\n", .{}) catch {};
        }
        if (has_teardown) {
            w.print("  Teardown: yes\n", .{}) catch {};
        }
        w.flush() catch {};
    }
};

pub fn printHelp(writer: anytype) void {
    writer.print(
        \\induct - Executable Specification Engine for AI-era TDD
        \\
        \\USAGE:
        \\    induct <COMMAND> [OPTIONS] [ARGS]
        \\
        \\COMMANDS:
        \\    run <spec.yaml>      Run a single spec file
        \\    run-dir <dir>        Run all specs in a directory
        \\    init [file.yaml]     Generate a template spec file
        \\    validate <spec.yaml> Validate spec syntax without executing
        \\    mcp                  Start MCP server mode
        \\    version              Show version information
        \\    help                 Show this help message
        \\
        \\OPTIONS:
        \\    -v, --verbose        Enable verbose output
        \\    --json               Output results in JSON format
        \\    --junit              Output results in JUnit XML format
        \\    --fail-fast          Stop on first failure
        \\    --dry-run            Show what would be executed without running
        \\    --filter <pattern>   Filter specs by name substring (run-dir)
        \\    -j <N>               Run up to N specs in parallel (run-dir)
        \\    --with-setup         Include setup/teardown in template (init)
        \\
        \\EXAMPLES:
        \\    induct run specs/echo.yaml
        \\    induct run-dir specs/
        \\    induct run --json --fail-fast specs/test.yaml
        \\    induct run-dir --filter echo -j4 specs/
        \\    induct init my-spec.yaml --with-setup
        \\    induct validate specs/test.yaml
        \\
    , .{}) catch {};
}

pub fn printVersion(writer: anytype) void {
    writer.print("induct v0.1.0\n", .{}) catch {};
}

test "Reporter initialization" {
    const reporter = Reporter.init(false, false);
    try std.testing.expect(!reporter.verbose);
    try std.testing.expect(reporter.format == .text);
}
