const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("jsonrpc.zig");
const handlers = @import("handlers.zig");

pub const McpServer = struct {
    allocator: Allocator,
    initialized: bool,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .initialized = false,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn run(self: *Self) !void {
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();

        var line_buf: [64 * 1024]u8 = undefined;
        var stdout_buf: [64 * 1024]u8 = undefined;

        while (true) {
            // Read a line manually by reading byte by byte
            var line_len: usize = 0;
            while (line_len < line_buf.len) {
                var byte_buf: [1]u8 = undefined;
                const bytes_read = stdin.read(&byte_buf) catch break;
                if (bytes_read == 0) {
                    // EOF
                    return;
                }
                if (byte_buf[0] == '\n') {
                    break;
                }
                line_buf[line_len] = byte_buf[0];
                line_len += 1;
            }

            if (line_len == 0) continue;

            const line = line_buf[0..line_len];
            var stdout_writer = stdout.writer(&stdout_buf);
            const writer = &stdout_writer.interface;

            self.handleRequest(line, writer) catch |err| {
                const response = jsonrpc.makeErrorResponse(
                    null,
                    jsonrpc.ErrorCode.InternalError,
                    @errorName(err),
                );
                jsonrpc.writeResponse(self.allocator, writer, response) catch {};
            };
            writer.flush() catch {};
        }
    }

    fn handleRequest(self: *Self, json_str: []const u8, writer: anytype) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const request = jsonrpc.parseRequest(alloc, json_str) catch {
            const response = jsonrpc.makeErrorResponse(
                null,
                jsonrpc.ErrorCode.ParseError,
                "Failed to parse JSON-RPC request",
            );
            try jsonrpc.writeResponse(alloc, writer, response);
            return;
        };

        // Handle different methods
        if (std.mem.eql(u8, request.method, "initialize")) {
            const result = try handlers.handleInitialize(alloc, request.params);
            const response = jsonrpc.makeResponse(request.id, result);
            try jsonrpc.writeResponse(alloc, writer, response);
            self.initialized = true;
        } else if (std.mem.eql(u8, request.method, "initialized")) {
            // Notification, no response needed
        } else if (std.mem.eql(u8, request.method, "tools/list")) {
            const result = try handlers.handleToolsList(alloc, request.params);
            const response = jsonrpc.makeResponse(request.id, result);
            try jsonrpc.writeResponse(alloc, writer, response);
        } else if (std.mem.eql(u8, request.method, "tools/call")) {
            const result = try handlers.handleToolsCall(alloc, request.params);
            const response = jsonrpc.makeResponse(request.id, result);
            try jsonrpc.writeResponse(alloc, writer, response);
        } else if (std.mem.eql(u8, request.method, "ping")) {
            var result = std.json.ObjectMap.init(alloc);
            try result.put("pong", .{ .bool = true });
            const response = jsonrpc.makeResponse(request.id, .{ .object = result });
            try jsonrpc.writeResponse(alloc, writer, response);
        } else if (std.mem.eql(u8, request.method, "shutdown")) {
            var result = std.json.ObjectMap.init(alloc);
            try result.put("success", .{ .bool = true });
            const response = jsonrpc.makeResponse(request.id, .{ .object = result });
            try jsonrpc.writeResponse(alloc, writer, response);
            return;
        } else {
            const response = jsonrpc.makeErrorResponse(
                request.id,
                jsonrpc.ErrorCode.MethodNotFound,
                "Method not found",
            );
            try jsonrpc.writeResponse(alloc, writer, response);
        }
    }
};

test "MCP server initialization" {
    const allocator = std.testing.allocator;
    var server = McpServer.init(allocator);
    defer server.deinit();

    try std.testing.expect(!server.initialized);
}
