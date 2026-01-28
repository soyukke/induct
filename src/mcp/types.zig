const std = @import("std");

pub const ServerInfo = struct {
    name: []const u8 = "induct",
    version: []const u8 = "0.1.0",
};

pub const ServerCapabilities = struct {
    tools: ToolsCapability = .{},
};

pub const ToolsCapability = struct {
    listChanged: bool = false,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: InputSchema,
};

pub const InputSchema = struct {
    type: []const u8 = "object",
    properties: std.json.Value,
    required: []const []const u8,
};

pub const ToolCall = struct {
    name: []const u8,
    arguments: std.json.Value,
};

pub const ToolResult = struct {
    content: []const Content,
    isError: bool = false,
};

pub const Content = struct {
    type: []const u8 = "text",
    text: []const u8,
};

pub fn getTools() []const Tool {
    return &[_]Tool{
        .{
            .name = "run_spec",
            .description = "Execute a spec file and return the results",
            .inputSchema = .{
                .properties = .{ .object = &.{} },
                .required = &[_][]const u8{"path"},
            },
        },
        .{
            .name = "get_result",
            .description = "Get the result of a previously executed spec by ID",
            .inputSchema = .{
                .properties = .{ .object = &.{} },
                .required = &[_][]const u8{"id"},
            },
        },
        .{
            .name = "list_specs",
            .description = "List all spec files in a directory",
            .inputSchema = .{
                .properties = .{ .object = &.{} },
                .required = &[_][]const u8{"dir"},
            },
        },
        .{
            .name = "read_spec",
            .description = "Read the contents of a spec file",
            .inputSchema = .{
                .properties = .{ .object = &.{} },
                .required = &[_][]const u8{"path"},
            },
        },
    };
}
