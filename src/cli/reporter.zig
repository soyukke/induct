const std = @import("std");
const result_mod = @import("../core/result.zig");
const SpecResult = result_mod.SpecResult;
const RunSummary = result_mod.RunSummary;

pub const Reporter = struct {
    stdout: std.fs.File,
    verbose: bool,
    json_output: bool,
    use_color: bool,
    buffer: [8192]u8 = undefined,

    const Self = @This();

    pub fn init(verbose: bool, json_output: bool) Self {
        const stdout = std.fs.File.stdout();
        return .{
            .stdout = stdout,
            .verbose = verbose,
            .json_output = json_output,
            .use_color = stdout.supportsAnsiEscapeCodes(),
        };
    }

    fn getWriter(self: *Self) std.fs.File.Writer {
        return self.stdout.writer(&self.buffer);
    }

    pub fn reportResult(self: *Self, result: SpecResult) void {
        if (self.json_output) {
            self.reportResultJson(result);
        } else {
            self.reportResultText(result);
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
            if (self.verbose and result.actual_output.len > 0) {
                w.print("  Output: {s}\n", .{result.actual_output}) catch {};
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

        if (result.error_message) |msg| {
            w.print(",\"error\":\"{s}\"", .{msg}) catch {};
        }

        w.print("}}\n", .{}) catch {};
        w.flush() catch {};
    }

    pub fn reportSummary(self: *Self, summary: RunSummary) void {
        if (self.json_output) {
            self.reportSummaryJson(summary);
        } else {
            self.reportSummaryText(summary);
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
        \\    mcp                  Start MCP server mode
        \\    version              Show version information
        \\    help                 Show this help message
        \\
        \\OPTIONS:
        \\    -v, --verbose        Enable verbose output
        \\    --json               Output results in JSON format
        \\
        \\EXAMPLES:
        \\    induct run specs/echo.yaml
        \\    induct run-dir specs/
        \\    induct run --json specs/test.yaml
        \\
    , .{}) catch {};
}

pub fn printVersion(writer: anytype) void {
    writer.print("induct v0.1.0\n", .{}) catch {};
}

test "Reporter initialization" {
    const reporter = Reporter.init(false, false);
    try std.testing.expect(!reporter.verbose);
    try std.testing.expect(!reporter.json_output);
}
