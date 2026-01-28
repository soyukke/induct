const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("jsonrpc.zig");
const types = @import("types.zig");
const executor = @import("../core/executor.zig");
const result_mod = @import("../core/result.zig");
const SpecResult = result_mod.SpecResult;
const parser = @import("../yaml/parser.zig");


pub fn handleInitialize(allocator: Allocator, _: ?std.json.Value) !std.json.Value {
    var result = std.json.ObjectMap.init(allocator);

    // Protocol version
    try result.put("protocolVersion", .{ .string = "2024-11-05" });

    // Server info
    var server_info = std.json.ObjectMap.init(allocator);
    try server_info.put("name", .{ .string = "induct" });
    try server_info.put("version", .{ .string = "0.1.0" });
    try result.put("serverInfo", .{ .object = server_info });

    // Capabilities
    var capabilities = std.json.ObjectMap.init(allocator);
    var tools_cap = std.json.ObjectMap.init(allocator);
    try tools_cap.put("listChanged", .{ .bool = false });
    try capabilities.put("tools", .{ .object = tools_cap });
    try result.put("capabilities", .{ .object = capabilities });

    return .{ .object = result };
}

pub fn handleToolsList(allocator: Allocator, _: ?std.json.Value) !std.json.Value {
    var result = std.json.ObjectMap.init(allocator);
    var tools_array = std.json.Array.init(allocator);

    // run_spec tool
    {
        var tool = std.json.ObjectMap.init(allocator);
        try tool.put("name", .{ .string = "run_spec" });
        try tool.put("description", .{ .string = "Execute a spec file and return the results" });

        var schema = std.json.ObjectMap.init(allocator);
        try schema.put("type", .{ .string = "object" });

        var props = std.json.ObjectMap.init(allocator);
        var path_prop = std.json.ObjectMap.init(allocator);
        try path_prop.put("type", .{ .string = "string" });
        try path_prop.put("description", .{ .string = "Path to the spec file" });
        try props.put("path", .{ .object = path_prop });
        try schema.put("properties", .{ .object = props });

        var required = std.json.Array.init(allocator);
        try required.append(.{ .string = "path" });
        try schema.put("required", .{ .array = required });

        try tool.put("inputSchema", .{ .object = schema });
        try tools_array.append(.{ .object = tool });
    }

    // list_specs tool
    {
        var tool = std.json.ObjectMap.init(allocator);
        try tool.put("name", .{ .string = "list_specs" });
        try tool.put("description", .{ .string = "List all spec files in a directory" });

        var schema = std.json.ObjectMap.init(allocator);
        try schema.put("type", .{ .string = "object" });

        var props = std.json.ObjectMap.init(allocator);
        var dir_prop = std.json.ObjectMap.init(allocator);
        try dir_prop.put("type", .{ .string = "string" });
        try dir_prop.put("description", .{ .string = "Directory path to list specs from" });
        try props.put("dir", .{ .object = dir_prop });
        try schema.put("properties", .{ .object = props });

        // dir is now optional - if not specified, look for inductspec.yaml in current directory
        const required = std.json.Array.init(allocator);
        try schema.put("required", .{ .array = required });

        try tool.put("inputSchema", .{ .object = schema });
        try tools_array.append(.{ .object = tool });
    }

    // get_schema tool
    {
        var tool = std.json.ObjectMap.init(allocator);
        try tool.put("name", .{ .string = "get_schema" });
        try tool.put("description", .{ .string = "Get the YAML schema for induct spec files" });

        var schema = std.json.ObjectMap.init(allocator);
        try schema.put("type", .{ .string = "object" });
        const props = std.json.ObjectMap.init(allocator);
        try schema.put("properties", .{ .object = props });
        const required = std.json.Array.init(allocator);
        try schema.put("required", .{ .array = required });

        try tool.put("inputSchema", .{ .object = schema });
        try tools_array.append(.{ .object = tool });
    }

    // read_spec tool
    {
        var tool = std.json.ObjectMap.init(allocator);
        try tool.put("name", .{ .string = "read_spec" });
        try tool.put("description", .{ .string = "Read the contents of a spec file" });

        var schema = std.json.ObjectMap.init(allocator);
        try schema.put("type", .{ .string = "object" });

        var props = std.json.ObjectMap.init(allocator);
        var path_prop = std.json.ObjectMap.init(allocator);
        try path_prop.put("type", .{ .string = "string" });
        try path_prop.put("description", .{ .string = "Path to the spec file" });
        try props.put("path", .{ .object = path_prop });
        try schema.put("properties", .{ .object = props });

        var required = std.json.Array.init(allocator);
        try required.append(.{ .string = "path" });
        try schema.put("required", .{ .array = required });

        try tool.put("inputSchema", .{ .object = schema });
        try tools_array.append(.{ .object = tool });
    }

    try result.put("tools", .{ .array = tools_array });
    return .{ .object = result };
}

pub fn handleToolsCall(
    allocator: Allocator,
    params: ?std.json.Value,
) !std.json.Value {
    const p = params orelse return error.InvalidParams;
    const obj = p.object;

    const tool_name = obj.get("name").?.string;
    const arguments = obj.get("arguments").?.object;

    var result = std.json.ObjectMap.init(allocator);
    var content_array = std.json.Array.init(allocator);

    if (std.mem.eql(u8, tool_name, "run_spec")) {
        const path = arguments.get("path").?.string;

        var content = std.json.ObjectMap.init(allocator);
        try content.put("type", .{ .string = "text" });

        // Check if this is a project spec file (inductspec.yaml)
        if (executor.isProjectSpecFile(path)) {
            const results = try executor.executeProjectSpecFromFile(allocator, path);
            defer {
                for (results) |*r| {
                    var mutable_r = @constCast(r);
                    mutable_r.deinit(allocator);
                }
                allocator.free(results);
            }

            var output: std.ArrayListUnmanaged(u8) = .empty;
            var passed_count: usize = 0;
            var failed_count: usize = 0;

            for (results) |spec_result| {
                if (spec_result.passed) {
                    passed_count += 1;
                } else {
                    failed_count += 1;
                }

                const line = try std.fmt.allocPrint(
                    allocator,
                    "Spec: {s}\n  Passed: {}\n  Exit Code: {d}\n  Duration: {d}ms\n\n",
                    .{
                        spec_result.spec_name,
                        spec_result.passed,
                        spec_result.actual_exit_code,
                        spec_result.duration_ms,
                    },
                );
                try output.appendSlice(allocator, line);
            }

            const summary = try std.fmt.allocPrint(
                allocator,
                "Summary: {d} passed, {d} failed, {d} total\n\n",
                .{ passed_count, failed_count, results.len },
            );
            var final_output: std.ArrayListUnmanaged(u8) = .empty;
            try final_output.appendSlice(allocator, summary);
            try final_output.appendSlice(allocator, try output.toOwnedSlice(allocator));

            try content.put("text", .{ .string = try final_output.toOwnedSlice(allocator) });
        } else {
            var spec_result = try executor.executeSpecFromFile(allocator, path);
            defer spec_result.deinit(allocator);

            // Check if this is a GENERATE_REQUIRED status
            if (spec_result.status == .generate_required) {
                if (spec_result.generate_info) |info| {
                    const text = try std.fmt.allocPrint(
                        allocator,
                        \\Spec: {s}
                        \\Status: GENERATE_REQUIRED
                        \\
                        \\Target Path: {s}
                        \\Command: {s}
                        \\Framework: {s}
                        \\
                        \\Description:
                        \\{s}
                        \\
                        \\Action: Create the test file at the target path, then run this spec again.
                    ,
                        .{
                            spec_result.spec_name,
                            info.target_path,
                            info.command,
                            if (info.framework_hint) |f| f else "unknown",
                            if (info.description) |d| d else "(no description)",
                        },
                    );
                    try content.put("text", .{ .string = text });
                } else {
                    const text = try std.fmt.allocPrint(
                        allocator,
                        "Spec: {s}\nStatus: GENERATE_REQUIRED\nError: {s}",
                        .{
                            spec_result.spec_name,
                            if (spec_result.error_message) |e| e else "Test file not found",
                        },
                    );
                    try content.put("text", .{ .string = text });
                }
            } else {
                const text = try std.fmt.allocPrint(
                    allocator,
                    "Spec: {s}\nPassed: {}\nExit Code: {d}\nOutput: {s}\nDuration: {d}ms",
                    .{
                        spec_result.spec_name,
                        spec_result.passed,
                        spec_result.actual_exit_code,
                        spec_result.actual_output,
                        spec_result.duration_ms,
                    },
                );
                try content.put("text", .{ .string = text });
            }
        }

        try content_array.append(.{ .object = content });
    } else if (std.mem.eql(u8, tool_name, "list_specs")) {
        var content = std.json.ObjectMap.init(allocator);
        try content.put("type", .{ .string = "text" });

        var specs_list: std.ArrayListUnmanaged(u8) = .empty;

        // Check if dir is provided
        const dir_arg = arguments.get("dir");
        if (dir_arg) |dir_val| {
            // Use provided directory
            const dir_path = dir_val.string;

            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
                const error_text = try std.fmt.allocPrint(allocator, "Failed to open directory: {}", .{err});
                try content.put("text", .{ .string = error_text });
                try content_array.append(.{ .object = content });
                try result.put("content", .{ .array = content_array });
                return .{ .object = result };
            };
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) {
                    continue;
                }
                const line = try std.fmt.allocPrint(allocator, "{s}/{s}\n", .{ dir_path, entry.name });
                try specs_list.appendSlice(allocator, line);
            }
        } else {
            // No dir provided - look for inductspec.yaml in current directory
            var project = parser.parseProjectSpecFromFile(allocator, "inductspec.yaml") catch |err| {
                const error_text = try std.fmt.allocPrint(allocator, "No inductspec.yaml found in current directory: {}", .{err});
                try content.put("text", .{ .string = error_text });
                try content_array.append(.{ .object = content });
                try result.put("content", .{ .array = content_array });
                return .{ .object = result };
            };
            defer project.deinit(allocator);

            // List inline specs
            for (project.specs, 0..) |spec, i| {
                const line = try std.fmt.allocPrint(allocator, "[inline #{d}] {s}\n", .{ i + 1, spec.name });
                try specs_list.appendSlice(allocator, line);
            }

            // List include files
            for (project.include) |include_path| {
                const line = try std.fmt.allocPrint(allocator, "[include] {s}\n", .{include_path});
                try specs_list.appendSlice(allocator, line);
            }
        }

        const text = try specs_list.toOwnedSlice(allocator);
        try content.put("text", .{ .string = if (text.len > 0) text else "No spec files found" });
        try content_array.append(.{ .object = content });
    } else if (std.mem.eql(u8, tool_name, "get_schema")) {
        var content = std.json.ObjectMap.init(allocator);
        try content.put("type", .{ .string = "text" });

        const schema_text =
            \\# Induct Spec Schema
            \\
            \\## Single Spec (*.yaml)
            \\```yaml
            \\name: spec name              # Required: name of the spec
            \\description: optional desc   # Optional: description
            \\
            \\setup:                       # Optional: pre-test commands
            \\  - run: echo "setup"
            \\
            \\test:                        # Required: test definition
            \\  command: echo hello        # Required: command to execute
            \\  input: "stdin data"        # Optional: stdin input
            \\  expect_output: "hello\n"   # Optional: exact output match
            \\  expect_output_contains: x  # Optional: substring match
            \\  expect_exit_code: 0        # Optional: expected exit code (default: 0)
            \\
            \\teardown:                    # Optional: cleanup commands
            \\  - run: rm -f /tmp/test.txt
            \\  - kill_process: server
            \\```
            \\
            \\## Project Spec (inductspec.yaml)
            \\```yaml
            \\name: project name           # Required: project name
            \\description: optional desc   # Optional: description
            \\
            \\specs:                       # Optional: inline spec definitions
            \\  - name: test1
            \\    test:
            \\      command: echo hello
            \\      expect_output_contains: "hello"
            \\
            \\  - name: test2
            \\    test:
            \\      command: ./my-app --version
            \\      expect_exit_code: 0
            \\
            \\include:                     # Optional: external spec files
            \\  - tests/auth.yaml
            \\  - tests/api.yaml
            \\```
        ;

        try content.put("text", .{ .string = schema_text });
        try content_array.append(.{ .object = content });
    } else if (std.mem.eql(u8, tool_name, "read_spec")) {
        const path = arguments.get("path").?.string;

        var content = std.json.ObjectMap.init(allocator);
        try content.put("type", .{ .string = "text" });

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            const error_text = try std.fmt.allocPrint(allocator, "Failed to open file: {}", .{err});
            try content.put("text", .{ .string = error_text });
            try content_array.append(.{ .object = content });
            try result.put("content", .{ .array = content_array });
            return .{ .object = result };
        };
        defer file.close();

        const file_content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            const error_text = try std.fmt.allocPrint(allocator, "Failed to read file: {}", .{err});
            try content.put("text", .{ .string = error_text });
            try content_array.append(.{ .object = content });
            try result.put("content", .{ .array = content_array });
            return .{ .object = result };
        };

        try content.put("text", .{ .string = file_content });
        try content_array.append(.{ .object = content });
    } else {
        var content = std.json.ObjectMap.init(allocator);
        try content.put("type", .{ .string = "text" });
        try content.put("text", .{ .string = "Unknown tool" });
        try content_array.append(.{ .object = content });
        try result.put("isError", .{ .bool = true });
    }

    try result.put("content", .{ .array = content_array });
    return .{ .object = result };
}
