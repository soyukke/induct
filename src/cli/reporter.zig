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

        const status_str = if (result.status == .skipped) "[SKIP]" else if (result.passed) "[PASS]" else "[FAIL]";

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

    fn writeJsonEscaped(w: anytype, s: []const u8) void {
        var start: usize = 0;
        for (s, 0..) |c, i| {
            const esc: ?[]const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => null,
            };
            if (esc) |seq| {
                if (i > start) w.writeAll(s[start..i]) catch {};
                w.writeAll(seq) catch {};
                start = i + 1;
            }
        }
        if (start < s.len) w.writeAll(s[start..]) catch {};
    }

    fn reportResultJson(self: *Self, result: SpecResult) void {
        var writer = self.getWriter();
        const w = &writer.interface;

        w.print("{{\"id\":\"", .{}) catch {};
        writeJsonEscaped(w, result.id);
        w.print("\",\"spec_name\":\"", .{}) catch {};
        writeJsonEscaped(w, result.spec_name);
        w.print("\",\"passed\":{s},\"exit_code\":{d},\"duration_ms\":{d}", .{
            if (result.passed) "true" else "false",
            result.actual_exit_code,
            result.duration_ms,
        }) catch {};

        if (result.timed_out) {
            w.print(",\"timed_out\":true", .{}) catch {};
        }

        if (result.error_message) |msg| {
            w.print(",\"error\":\"", .{}) catch {};
            writeJsonEscaped(w, msg);
            w.print("\"", .{}) catch {};
        }

        w.print("}}\n", .{}) catch {};
        w.flush() catch {};
    }

    pub fn reportSummary(self: *Self, summary: RunSummary, results: ?[]const SpecResult) void {
        switch (self.format) {
            .json => self.reportSummaryJson(summary),
            .junit => {},
            .text => self.reportSummaryText(summary, results),
        }
    }

    fn reportSummaryText(self: *Self, summary: RunSummary, results: ?[]const SpecResult) void {
        var writer = self.getWriter();
        const w = &writer.interface;

        w.print("\n", .{}) catch {};
        w.print("----------------------------------------\n", .{}) catch {};

        if (summary.skipped > 0) {
            w.print("Total: {d} | passed: {d} | failed: {d} | skipped: {d} | Duration: {d}ms\n", .{
                summary.total,
                summary.passed,
                summary.failed,
                summary.skipped,
                summary.total_duration_ms,
            }) catch {};
        } else {
            w.print("Total: {d} | passed: {d} | failed: {d} | Duration: {d}ms\n", .{
                summary.total,
                summary.passed,
                summary.failed,
                summary.total_duration_ms,
            }) catch {};
        }

        if (summary.failed == 0) {
            w.print("\nAll specs passed!\n", .{}) catch {};
        } else {
            w.print("\nFailed:\n", .{}) catch {};
            if (results) |res| {
                for (res) |r| {
                    if (!r.passed and r.status != .skipped) {
                        w.print("  - {s}", .{r.spec_name}) catch {};
                        if (r.error_message) |msg| {
                            // Show first line of error only
                            const first_line = if (std.mem.indexOf(u8, msg, "\n")) |nl| msg[0..nl] else msg;
                            w.print(": {s}", .{first_line}) catch {};
                        }
                        w.print("\n", .{}) catch {};
                    }
                }
            }
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
        \\induct - Executable specification engine for AI-driven development
        \\
        \\USAGE:
        \\    induct <COMMAND> [OPTIONS] [ARGS]
        \\
        \\COMMANDS:
        \\    run <spec.yaml>      Run a spec and verify results
        \\    run-dir <dir>        Run all specs in a directory
        \\    list <dir>           List specs in a directory (name, description)
        \\    validate <spec.yaml> Validate spec syntax without executing
        \\    schema               Show YAML spec schema reference
        \\    init [file.yaml]     Generate a template spec file
        \\    version              Show version information
        \\    help                 Show this help message
        \\
        \\OPTIONS:
        \\    -v, --verbose        Enable verbose output
        \\    --json               Output results in JSON format
        \\    --junit              Output results in JUnit XML format
        \\    --fail-fast          Stop on first failure
        \\    --dry-run            Show what would be executed without running
        \\    --filter <pattern>   Filter specs by name substring (run, run-dir)
        \\    --timeout-ms <ms>   Default timeout for commands without timeout_ms
        \\    -j <N>               Run up to N specs in parallel (run, run-dir)
        \\    --markdown            Output as markdown table (list)
        \\    --with-setup         Include setup/teardown in template (init)
        \\    --template <type>    Template type: basic, setup, api, cli, project (init)
        \\
        \\EXAMPLES:
        \\    induct schema
        \\    induct run specs/echo.yaml
        \\    induct run-dir specs/ -j4
        \\    induct validate specs/test.yaml
        \\    induct init my-spec.yaml --template api
        \\
    , .{}) catch {};
}

pub fn printSchema(writer: anytype) void {
    writer.print(
        \\# Induct Spec Schema
        \\
        \\## Single Spec (*.yaml)
        \\
        \\```yaml
        \\name: string                            # Required: spec name (title)
        \\description: |                          # Recommended: the specification itself
        \\  Describe WHAT the system should do.   #   This is the human-readable spec.
        \\  name is the title, description is     #   Shown by `induct list`.
        \\  the body. test: section verifies it.
        \\
        \\setup:                                  # Optional: pre-test commands
        \\  - run: echo "setup"
        \\
        \\test:                                   # Required: test definition
        \\  command: echo hello                    # Required: command to execute
        \\  input: "stdin data"                    # Optional: stdin input
        \\  expect_output: "hello\n"               # Optional: exact stdout match
        \\  expect_output_contains: "llo"          # Optional: stdout substring match
        \\  expect_output_not_contains: "err"      # Optional: stdout negative match
        \\  expect_output_regex: "hel+"            # Optional: stdout regex (POSIX ERE)
        \\  expect_stderr: "warn\n"                # Optional: exact stderr match
        \\  expect_stderr_contains: "warn"         # Optional: stderr substring match
        \\  expect_stderr_not_contains: "FATAL"    # Optional: stderr negative match
        \\  expect_stderr_regex: "warn.*"           # Optional: stderr regex (POSIX ERE)
        \\  expect_exit_code: 0                    # Optional: exit code (default: 0)
        \\  env:                                   # Optional: environment variables
        \\    KEY: value
        \\  working_dir: /path/to/dir              # Optional: working directory
        \\  timeout_ms: 5000                       # Optional: timeout in milliseconds
        \\
        \\teardown:                                # Optional: cleanup commands
        \\  - run: rm -f /tmp/test.txt
        \\  - kill_process: server
        \\```
        \\
        \\## Multi-Step Spec
        \\
        \\```yaml
        \\name: string                            # Required: spec name
        \\description: string                     # Recommended: specification
        \\
        \\setup:                                  # Optional: pre-test commands (run once)
        \\  - run: echo "setup"
        \\
        \\steps:                                  # Sequential steps (replaces test:)
        \\  - name: step one                      # Required: step name
        \\    command: echo hello                  # Required: command
        \\    expect_output: "hello\n"             # Same fields as test:
        \\
        \\  - name: step two
        \\    command: echo world
        \\    expect_output_contains: "world"
        \\
        \\teardown:                               # Optional: cleanup (run once, always)
        \\  - run: echo "cleanup"
        \\```
        \\
        \\- Steps execute sequentially
        \\- If a step fails, remaining steps are skipped
        \\- setup runs once before all steps, teardown runs once after
        \\- `steps:` and `test:` are mutually exclusive
        \\
        \\## Project Spec (inductspec.yaml)
        \\
        \\```yaml
        \\name: project name                      # Required: project name
        \\description: string                     # Optional: description
        \\
        \\specs:                                  # Optional: inline spec definitions
        \\  - name: test1
        \\    test:
        \\      command: echo hello
        \\      expect_output_contains: "hello"
        \\
        \\include:                                # Optional: external spec files
        \\  - specs/auth.yaml
        \\  - specs/api.yaml
        \\```
        \\
        \\## Validation Rules
        \\
        \\- `name` and `test.command` are required fields
        \\- `expect_exit_code` defaults to 0 if not specified
        \\- Multiple expect_* fields can be combined (all must pass)
        \\- `expect_output_regex` uses POSIX Extended Regular Expressions
        \\- `timeout_ms` kills the process if exceeded
        \\- `setup` commands run before the test (fail = test skipped)
        \\- `teardown` commands always run (even on test failure)
        \\
        \\## Writing Good Specs
        \\
        \\A spec has two parts: the specification (name + description)
        \\and the verification (test/steps). Write description as if
        \\explaining the requirement to a colleague:
        \\
        \\```yaml
        \\name: User creation API
        \\description: |
        \\  POST /users with a name returns a new user with an assigned ID.
        \\  The response must contain an "id" field.
        \\
        \\test:
        \\  command: curl -s -X POST localhost:8080/users -d '{{"name":"alice"}}'
        \\  expect_output_contains: '"id":'
        \\```
        \\
        \\Use `induct list <dir>` to view all specs as a specification index.
        \\
        \\## Workflow
        \\
        \\1. Run `induct schema` to learn the spec format (this output)
        \\2. Write a spec: name = what, description = why, test = verification
        \\3. Run `induct validate <spec.yaml>` to check syntax
        \\4. Run `induct run <spec.yaml>` to verify (expect FAIL)
        \\5. Implement until the spec passes
        \\6. Run `induct run <spec.yaml>` again (expect PASS)
        \\7. Run `induct list <dir>` to review the spec index
        \\
        \\Example:
        \\```bash
        \\cat > specs/hello.yaml << 'EOF'
        \\name: hello command
        \\description: |
        \\  ./hello prints "Hello, World!" to stdout and exits successfully.
        \\test:
        \\  command: ./hello
        \\  expect_output: "Hello, World!\n"
        \\EOF
        \\
        \\induct validate specs/hello.yaml
        \\induct run specs/hello.yaml          # FAIL - not yet implemented
        \\# ... implement ./hello ...
        \\induct run specs/hello.yaml          # PASS
        \\induct list specs/                   # review spec index
        \\```
        \\
    , .{}) catch {};
}

pub const version = std.mem.trimRight(u8, @embedFile("../VERSION"), &.{ '\n', '\r', ' ' });

pub fn printVersion(writer: anytype) void {
    writer.print("induct v{s}\n", .{version}) catch {};
}

test "Reporter initialization" {
    const reporter = Reporter.init(false, false);
    try std.testing.expect(!reporter.verbose);
    try std.testing.expect(reporter.format == .text);
}
