const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Spec = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    setup: ?[]const SetupCommand = null,
    test_case: TestCase,
    teardown: ?[]const TeardownCommand = null,

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
        if (self.teardown) |teardown_cmds| {
            for (teardown_cmds) |cmd| {
                cmd.deinit(allocator);
            }
            allocator.free(teardown_cmds);
        }
    }
};

pub const TestCase = struct {
    command: []const u8,
    input: ?[]const u8 = null,
    expect_output: ?[]const u8 = null,
    expect_output_contains: ?[]const u8 = null,
    expect_exit_code: i32 = 0,
    generate: bool = false,
    target_path: ?[]const u8 = null,

    pub fn deinit(self: *TestCase, allocator: Allocator) void {
        allocator.free(self.command);
        if (self.input) |inp| {
            allocator.free(inp);
        }
        if (self.expect_output) |out| {
            allocator.free(out);
        }
        if (self.expect_output_contains) |out| {
            allocator.free(out);
        }
        if (self.target_path) |path| {
            allocator.free(path);
        }
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
