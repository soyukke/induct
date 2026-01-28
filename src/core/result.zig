const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GenerateInfo = struct {
    target_path: []const u8,
    description: ?[]const u8,
    framework_hint: ?[]const u8,
    command: []const u8,

    pub fn deinit(self: *GenerateInfo, allocator: Allocator) void {
        allocator.free(self.target_path);
        if (self.description) |desc| {
            allocator.free(desc);
        }
        if (self.framework_hint) |hint| {
            allocator.free(hint);
        }
        allocator.free(self.command);
    }
};

pub const SpecStatus = enum {
    passed,
    failed,
    generate_required,
};

pub const SpecResult = struct {
    id: []const u8,
    spec_name: []const u8,
    passed: bool,
    status: SpecStatus = .passed,
    actual_output: []const u8,
    actual_exit_code: i32,
    error_message: ?[]const u8,
    duration_ms: u64,
    generate_info: ?GenerateInfo = null,

    pub fn deinit(self: *SpecResult, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.spec_name);
        allocator.free(self.actual_output);
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        if (self.generate_info) |*info| {
            var mutable_info = info.*;
            mutable_info.deinit(allocator);
        }
    }

    pub fn format(
        self: SpecResult,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const status = if (self.passed) "PASS" else "FAIL";
        try writer.print("[{s}] {s} ({d}ms)", .{ status, self.spec_name, self.duration_ms });
        if (self.error_message) |msg| {
            try writer.print("\n  Error: {s}", .{msg});
        }
    }
};

pub const RunSummary = struct {
    total: usize,
    passed: usize,
    failed: usize,
    total_duration_ms: u64,

    pub fn init() RunSummary {
        return .{
            .total = 0,
            .passed = 0,
            .failed = 0,
            .total_duration_ms = 0,
        };
    }

    pub fn add(self: *RunSummary, result: SpecResult) void {
        self.total += 1;
        if (result.passed) {
            self.passed += 1;
        } else {
            self.failed += 1;
        }
        self.total_duration_ms += result.duration_ms;
    }
};

test "SpecResult format" {
    const result = SpecResult{
        .id = "test-1",
        .spec_name = "echo test",
        .passed = true,
        .actual_output = "hello",
        .actual_exit_code = 0,
        .error_message = null,
        .duration_ms = 42,
    };

    var buf: [256]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{}", .{result}) catch unreachable;
    try std.testing.expectEqualStrings("[PASS] echo test (42ms)", formatted);
}

test "RunSummary tracking" {
    var summary = RunSummary.init();

    summary.add(.{
        .id = "1",
        .spec_name = "test1",
        .passed = true,
        .actual_output = "",
        .actual_exit_code = 0,
        .error_message = null,
        .duration_ms = 10,
    });

    summary.add(.{
        .id = "2",
        .spec_name = "test2",
        .passed = false,
        .actual_output = "",
        .actual_exit_code = 1,
        .error_message = "failed",
        .duration_ms = 20,
    });

    try std.testing.expectEqual(@as(usize, 2), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(u64, 30), summary.total_duration_ms);
}
