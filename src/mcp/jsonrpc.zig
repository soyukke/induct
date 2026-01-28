const std = @import("std");
const Allocator = std.mem.Allocator;

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    id: ?std.json.Value,
    method: []const u8,
    params: ?std.json.Value,
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value,
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const ErrorCode = struct {
    pub const ParseError: i32 = -32700;
    pub const InvalidRequest: i32 = -32600;
    pub const MethodNotFound: i32 = -32601;
    pub const InvalidParams: i32 = -32602;
    pub const InternalError: i32 = -32603;
};

pub fn parseRequest(allocator: Allocator, json_str: []const u8) !JsonRpcRequest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    const jsonrpc = obj.get("jsonrpc").?.string;
    const method = obj.get("method").?.string;
    const id = obj.get("id");
    const params = obj.get("params");

    return JsonRpcRequest{
        .jsonrpc = try allocator.dupe(u8, jsonrpc),
        .id = if (id) |i| try cloneJsonValue(allocator, i) else null,
        .method = try allocator.dupe(u8, method),
        .params = if (params) |p| try cloneJsonValue(allocator, p) else null,
    };
}

pub fn cloneJsonValue(allocator: Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = std.json.Array.init(allocator);
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = std.json.ObjectMap.init(allocator);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(key, val);
            }
            return .{ .object = new_obj };
        },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
    };
}

pub fn makeResponse(id: ?std.json.Value, result: std.json.Value) JsonRpcResponse {
    return .{
        .id = id,
        .result = result,
    };
}

pub fn makeErrorResponse(id: ?std.json.Value, code: i32, message: []const u8) JsonRpcResponse {
    return .{
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    };
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.print("null", .{}),
        .bool => |b| try writer.print("{s}", .{if (b) "true" else "false"}),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| {
            try writer.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try writer.print("\\\"", .{}),
                    '\\' => try writer.print("\\\\", .{}),
                    '\n' => try writer.print("\\n", .{}),
                    '\r' => try writer.print("\\r", .{}),
                    '\t' => try writer.print("\\t", .{}),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.writeByte('"');
                try writer.print("{s}", .{entry.key_ptr.*});
                try writer.print("\":", .{});
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .number_string => |s| try writer.print("{s}", .{s}),
    }
}

pub fn writeResponse(allocator: Allocator, writer: anytype, response: JsonRpcResponse) !void {
    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("jsonrpc", .{ .string = "2.0" });

    if (response.id) |id| {
        try obj.put("id", id);
    } else {
        try obj.put("id", .null);
    }

    if (response.result) |result| {
        try obj.put("result", result);
    }

    if (response.@"error") |err| {
        var err_obj = std.json.ObjectMap.init(allocator);
        try err_obj.put("code", .{ .integer = err.code });
        try err_obj.put("message", .{ .string = err.message });
        if (err.data) |data| {
            try err_obj.put("data", data);
        }
        try obj.put("error", .{ .object = err_obj });
    }

    try writeJsonValue(writer, .{ .object = obj });
    try writer.writeByte('\n');
}

test "parse JSON-RPC request" {
    const json =
        \\{"jsonrpc":"2.0","id":1,"method":"test","params":{}}
    ;

    const allocator = std.testing.allocator;
    const request = try parseRequest(allocator, json);

    defer {
        allocator.free(request.jsonrpc);
        allocator.free(request.method);
        if (request.params) |p| {
            var params = p;
            params.object.deinit();
        }
    }

    try std.testing.expectEqualStrings("2.0", request.jsonrpc);
    try std.testing.expectEqualStrings("test", request.method);
}
