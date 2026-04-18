const std = @import("std");
const Allocator = std.mem.Allocator;

fn appendShellQuoted(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), input: []const u8) !void {
    try list.append(allocator, '\'');
    for (input) |c| {
        if (c == '\'') {
            try list.appendSlice(allocator, "'\"'\"'");
        } else {
            try list.append(allocator, c);
        }
    }
    try list.append(allocator, '\'');
}

pub const Spec = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    setup: ?[]const SetupCommand = null,
    test_case: TestCase = .{},
    steps: ?[]const Step = null,
    teardown: ?[]const TeardownCommand = null,

    pub fn hasSteps(self: Spec) bool {
        return self.steps != null and self.steps.?.len > 0;
    }

    pub fn deinit(self: *Spec, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| {
            allocator.free(desc);
        }
        if (self.setup) |setup_cmds| {
            for (setup_cmds) |cmd| {
                cmd.deinit(allocator);
            }
            allocator.free(setup_cmds);
        }
        self.test_case.deinit(allocator);
        if (self.steps) |steps_list| {
            for (steps_list) |*step| {
                var mutable_step = @constCast(step);
                mutable_step.deinit(allocator);
            }
            allocator.free(steps_list);
        }
        if (self.teardown) |teardown_cmds| {
            for (teardown_cmds) |cmd| {
                cmd.deinit(allocator);
            }
            allocator.free(teardown_cmds);
        }
    }
};

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: EnvVar, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const LineEnding = enum {
    lf,
    crlf,

    pub fn bytes(self: LineEnding) []const u8 {
        return switch (self) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    }
};

pub const InputLines = struct {
    line_ending: LineEnding = .lf,
    trailing: bool = true,
    lines: []const []const u8 = &.{},

    pub fn deinit(self: InputLines, allocator: Allocator) void {
        for (self.lines) |line| allocator.free(line);
        if (self.lines.len > 0) allocator.free(self.lines);
    }

    /// Convert to a single byte slice suitable for stdin
    pub fn toBytes(self: InputLines, allocator: Allocator) ![]const u8 {
        if (self.lines.len == 0) return try allocator.dupe(u8, "");

        var total_len: usize = 0;
        const ending = self.line_ending.bytes();
        for (self.lines) |line| {
            total_len += line.len;
        }
        // Add line endings: all lines if trailing, all but last if not
        const endings_count = if (self.trailing) self.lines.len else self.lines.len -| 1;
        total_len += endings_count * ending.len;

        var result = try allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (self.lines, 0..) |line, i| {
            @memcpy(result[offset .. offset + line.len], line);
            offset += line.len;
            if (i < self.lines.len - 1 or self.trailing) {
                @memcpy(result[offset .. offset + ending.len], ending);
                offset += ending.len;
            }
        }
        return result;
    }
};

pub const TestCase = struct {
    command: []const u8 = "",
    args: ?[]const []const u8 = null,
    input: ?[]const u8 = null,
    input_lines: ?InputLines = null,
    expect_output: ?[]const u8 = null,
    expect_output_contains: ?[]const []const u8 = null,
    expect_output_not_contains: ?[]const []const u8 = null,
    expect_output_regex: ?[]const u8 = null,
    expect_stderr: ?[]const u8 = null,
    expect_stderr_contains: ?[]const []const u8 = null,
    expect_stderr_not_contains: ?[]const []const u8 = null,
    expect_stderr_regex: ?[]const u8 = null,
    expect_exit_code: i32 = 0,
    generate: bool = false,
    target_path: ?[]const u8 = null,
    env: ?[]const EnvVar = null,
    working_dir: ?[]const u8 = null,
    timeout_ms: ?u64 = null,

    pub fn deinit(self: *TestCase, allocator: Allocator) void {
        allocator.free(self.command);
        if (self.args) |args| {
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
        }
        if (self.input) |inp| allocator.free(inp);
        if (self.input_lines) |il| il.deinit(allocator);
        if (self.expect_output) |out| allocator.free(out);
        if (self.expect_output_contains) |items| {
            for (items) |s| allocator.free(s);
            allocator.free(items);
        }
        if (self.expect_output_not_contains) |items| {
            for (items) |s| allocator.free(s);
            allocator.free(items);
        }
        if (self.expect_output_regex) |out| allocator.free(out);
        if (self.expect_stderr) |out| allocator.free(out);
        if (self.expect_stderr_contains) |items| {
            for (items) |s| allocator.free(s);
            allocator.free(items);
        }
        if (self.expect_stderr_not_contains) |items| {
            for (items) |s| allocator.free(s);
            allocator.free(items);
        }
        if (self.expect_stderr_regex) |out| allocator.free(out);
        if (self.target_path) |path| allocator.free(path);
        if (self.env) |env_vars| {
            for (env_vars) |ev| ev.deinit(allocator);
            allocator.free(env_vars);
        }
        if (self.working_dir) |wd| allocator.free(wd);
    }

    pub fn appendRenderedCommand(self: TestCase, allocator: Allocator, list: *std.ArrayListUnmanaged(u8)) !void {
        if (self.args) |args| {
            try appendShellQuoted(allocator, list, self.command);
            for (args) |arg| {
                try list.append(allocator, ' ');
                try appendShellQuoted(allocator, list, arg);
            }
            return;
        }
        try list.appendSlice(allocator, self.command);
    }

    pub fn formatCommand(self: TestCase, allocator: Allocator) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        defer result.deinit(allocator);
        try self.appendRenderedCommand(allocator, &result);
        return try result.toOwnedSlice(allocator);
    }
};

pub const Step = struct {
    name: []const u8,
    test_case: TestCase,

    pub fn deinit(self: *Step, allocator: Allocator) void {
        allocator.free(self.name);
        self.test_case.deinit(allocator);
    }
};

pub const SetupCommand = struct {
    run: []const u8,

    pub fn deinit(self: SetupCommand, allocator: Allocator) void {
        allocator.free(self.run);
    }
};

pub const TeardownCommand = union(enum) {
    run: []const u8,
    kill_process: []const u8,

    pub fn deinit(self: TeardownCommand, allocator: Allocator) void {
        switch (self) {
            .run => |cmd| allocator.free(cmd),
            .kill_process => |name| allocator.free(name),
        }
    }
};

test "Spec creation" {
    const spec = Spec{
        .name = "test spec",
        .description = "A test specification",
        .test_case = .{
            .command = "echo hello",
            .expect_output = "hello\n",
            .expect_exit_code = 0,
        },
    };

    try std.testing.expectEqualStrings("test spec", spec.name);
    try std.testing.expectEqualStrings("A test specification", spec.description.?);
    try std.testing.expectEqualStrings("echo hello", spec.test_case.command);
    try std.testing.expectEqual(@as(i32, 0), spec.test_case.expect_exit_code);
}

pub const ProjectSpec = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    specs: []const Spec = &.{},
    include: []const []const u8 = &.{},

    pub fn deinit(self: *ProjectSpec, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| {
            allocator.free(desc);
        }
        for (self.specs) |*spec_item| {
            var mutable_spec = @constCast(spec_item);
            mutable_spec.deinit(allocator);
        }
        if (self.specs.len > 0) {
            allocator.free(self.specs);
        }
        for (self.include) |path| {
            allocator.free(path);
        }
        if (self.include.len > 0) {
            allocator.free(self.include);
        }
    }
};

test "TestCase defaults" {
    const tc = TestCase{
        .command = "ls",
    };

    try std.testing.expectEqual(@as(i32, 0), tc.expect_exit_code);
    try std.testing.expect(tc.args == null);
    try std.testing.expect(tc.input == null);
    try std.testing.expect(tc.expect_output == null);
    try std.testing.expect(tc.expect_output_contains == null);
}

test "ProjectSpec creation" {
    const project = ProjectSpec{
        .name = "test project",
        .description = "A test project",
    };

    try std.testing.expectEqualStrings("test project", project.name);
    try std.testing.expectEqualStrings("A test project", project.description.?);
    try std.testing.expectEqual(@as(usize, 0), project.specs.len);
    try std.testing.expectEqual(@as(usize, 0), project.include.len);
}
