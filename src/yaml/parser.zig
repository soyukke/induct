const std = @import("std");
const Allocator = std.mem.Allocator;
const spec_mod = @import("../core/spec.zig");
const Spec = spec_mod.Spec;
const TestCase = spec_mod.TestCase;
const SetupCommand = spec_mod.SetupCommand;
const TeardownCommand = spec_mod.TeardownCommand;
const ProjectSpec = spec_mod.ProjectSpec;

pub const ParseError = error{
    InvalidYaml,
    MissingRequiredField,
    UnexpectedToken,
    OutOfMemory,
    InvalidCharacter,
};

pub const YamlValue = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    list: []const YamlValue,
    map: std.StringHashMap(YamlValue),
    null_value,

    pub fn deinit(self: *YamlValue, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .list => |list| {
                for (list) |*item| {
                    var mutable_item = item.*;
                    mutable_item.deinit(allocator);
                }
                allocator.free(list);
            },
            .map => |*map| {
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    var val = entry.value_ptr.*;
                    val.deinit(allocator);
                }
                map.deinit();
            },
            .integer, .boolean, .null_value => {},
        }
    }

    pub fn getString(self: YamlValue) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getInt(self: YamlValue) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    pub fn getBool(self: YamlValue) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn getMap(self: *YamlValue) ?*std.StringHashMap(YamlValue) {
        return switch (self.*) {
            .map => |*m| m,
            else => null,
        };
    }

    pub fn getList(self: YamlValue) ?[]const YamlValue {
        return switch (self) {
            .list => |l| l,
            else => null,
        };
    }
};

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .pos = 0,
        };
    }

    pub fn parse(self: *Parser) ParseError!YamlValue {
        return self.parseMap(0);
    }

    fn getCurrentIndent(self: *Parser) usize {
        // Find the start of the current line
        var line_start = self.pos;
        while (line_start > 0 and self.source[line_start - 1] != '\n') {
            line_start -= 1;
        }
        // Count spaces from line start to first non-space
        var indent: usize = 0;
        var i = line_start;
        while (i < self.source.len and self.source[i] == ' ') {
            indent += 1;
            i += 1;
        }
        return indent;
    }

    fn skipToNextLine(self: *Parser) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) {
            self.pos += 1; // skip newline
        }
    }

    fn skipEmptyLinesAndComments(self: *Parser) void {
        while (self.pos < self.source.len) {
            // Skip spaces at start of line
            while (self.pos < self.source.len and self.source[self.pos] == ' ') {
                self.pos += 1;
            }
            // Check if line is empty or comment
            if (self.pos >= self.source.len) break;
            if (self.source[self.pos] == '\n') {
                self.pos += 1;
                continue;
            }
            if (self.source[self.pos] == '#') {
                self.skipToNextLine();
                continue;
            }
            // Line has content - go back to start of indent
            while (self.pos > 0 and self.source[self.pos - 1] == ' ') {
                self.pos -= 1;
            }
            break;
        }
    }

    fn parseMap(self: *Parser, min_indent: usize) ParseError!YamlValue {
        var map = std.StringHashMap(YamlValue).init(self.allocator);
        errdefer {
            var iter = map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                var val = entry.value_ptr.*;
                val.deinit(self.allocator);
            }
            map.deinit();
        }

        while (self.pos < self.source.len) {
            self.skipEmptyLinesAndComments();
            if (self.pos >= self.source.len) break;

            // Count indent of this line
            const line_start = self.pos;
            var indent: usize = 0;
            while (self.pos < self.source.len and self.source[self.pos] == ' ') {
                indent += 1;
                self.pos += 1;
            }

            // Check if we've dedented past our level
            if (indent < min_indent and map.count() > 0) {
                self.pos = line_start;
                break;
            }

            if (self.pos >= self.source.len or self.source[self.pos] == '\n') {
                continue;
            }

            // Check for list
            if (self.source[self.pos] == '-') {
                self.pos = line_start;
                break;
            }

            // Parse key
            const key_start = self.pos;
            while (self.pos < self.source.len and self.source[self.pos] != ':' and self.source[self.pos] != '\n') {
                self.pos += 1;
            }

            if (self.pos >= self.source.len or self.source[self.pos] != ':') {
                self.pos = line_start;
                break;
            }

            const key = std.mem.trim(u8, self.source[key_start..self.pos], " \t");
            const key_duped = self.allocator.dupe(u8, key) catch return ParseError.OutOfMemory;

            self.pos += 1; // skip ':'

            // Skip spaces after colon
            while (self.pos < self.source.len and self.source[self.pos] == ' ') {
                self.pos += 1;
            }

            // Parse value
            var value: YamlValue = undefined;
            if (self.pos >= self.source.len or self.source[self.pos] == '\n') {
                // Value is on next lines - could be map or list
                self.skipToNextLine();
                self.skipEmptyLinesAndComments();

                if (self.pos >= self.source.len) {
                    value = .null_value;
                } else {
                    // Count indent of value
                    var value_indent: usize = 0;
                    const value_start = self.pos;
                    while (self.pos < self.source.len and self.source[self.pos] == ' ') {
                        value_indent += 1;
                        self.pos += 1;
                    }

                    if (value_indent <= indent) {
                        self.pos = value_start;
                        value = .null_value;
                    } else if (self.pos < self.source.len and self.source[self.pos] == '-') {
                        self.pos = value_start;
                        value = try self.parseList(value_indent);
                    } else {
                        self.pos = value_start;
                        value = try self.parseMap(value_indent);
                    }
                }
            } else if (self.source[self.pos] == '|') {
                value = try self.parseMultilineString(indent);
            } else {
                value = try self.parseScalar();
            }

            map.put(key_duped, value) catch {
                self.allocator.free(key_duped);
                return ParseError.OutOfMemory;
            };
        }

        return .{ .map = map };
    }

    fn parseList(self: *Parser, min_indent: usize) ParseError!YamlValue {
        var items: std.ArrayListUnmanaged(YamlValue) = .empty;
        errdefer {
            for (items.items) |*item| {
                item.deinit(self.allocator);
            }
            items.deinit(self.allocator);
        }

        while (self.pos < self.source.len) {
            self.skipEmptyLinesAndComments();
            if (self.pos >= self.source.len) break;

            // Count indent
            const line_start = self.pos;
            var indent: usize = 0;
            while (self.pos < self.source.len and self.source[self.pos] == ' ') {
                indent += 1;
                self.pos += 1;
            }

            if (indent < min_indent and items.items.len > 0) {
                self.pos = line_start;
                break;
            }

            if (self.pos >= self.source.len or self.source[self.pos] != '-') {
                self.pos = line_start;
                break;
            }

            self.pos += 1; // skip '-'

            // Skip space after dash
            while (self.pos < self.source.len and self.source[self.pos] == ' ') {
                self.pos += 1;
            }

            // Parse the list item value
            if (self.pos >= self.source.len or self.source[self.pos] == '\n') {
                // Value on next line
                self.skipToNextLine();
                items.append(self.allocator, try self.parseMap(indent + 2)) catch return ParseError.OutOfMemory;
            } else {
                // Check if it's a map on the same line (key: value)
                var has_colon = false;
                var peek = self.pos;
                while (peek < self.source.len and self.source[peek] != '\n') {
                    if (self.source[peek] == ':') {
                        has_colon = true;
                        break;
                    }
                    peek += 1;
                }

                if (has_colon) {
                    items.append(self.allocator, try self.parseMap(indent + 2)) catch return ParseError.OutOfMemory;
                } else {
                    items.append(self.allocator, try self.parseScalar()) catch return ParseError.OutOfMemory;
                }
            }
        }

        const result = items.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
        return .{ .list = result };
    }

    fn parseMultilineString(self: *Parser, base_indent: usize) ParseError!YamlValue {
        self.pos += 1; // skip '|'
        self.skipToNextLine();

        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer lines.deinit(self.allocator);

        var content_indent: ?usize = null;

        while (self.pos < self.source.len) {
            const line_start = self.pos;

            // Count indent
            var indent: usize = 0;
            while (self.pos < self.source.len and self.source[self.pos] == ' ') {
                indent += 1;
                self.pos += 1;
            }

            // Empty line
            if (self.pos >= self.source.len or self.source[self.pos] == '\n') {
                lines.append(self.allocator, "") catch return ParseError.OutOfMemory;
                if (self.pos < self.source.len) self.pos += 1;
                continue;
            }

            // Determine content indent from first non-empty line
            if (content_indent == null) {
                if (indent <= base_indent) {
                    self.pos = line_start;
                    break;
                }
                content_indent = indent;
            }

            // Check if we've dedented
            if (indent < content_indent.?) {
                self.pos = line_start;
                break;
            }

            // Read line content
            const content_start = self.pos;
            while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                self.pos += 1;
            }

            const line_content = self.source[content_start..self.pos];
            const duped = self.allocator.dupe(u8, line_content) catch return ParseError.OutOfMemory;
            lines.append(self.allocator, duped) catch {
                self.allocator.free(duped);
                return ParseError.OutOfMemory;
            };

            if (self.pos < self.source.len) self.pos += 1; // skip newline
        }

        // Join lines with newlines
        if (lines.items.len == 0) {
            return .{ .string = self.allocator.dupe(u8, "") catch return ParseError.OutOfMemory };
        }

        var total_len: usize = 0;
        for (lines.items) |line| {
            total_len += line.len + 1;
        }

        var result = self.allocator.alloc(u8, total_len) catch return ParseError.OutOfMemory;
        var offset: usize = 0;
        for (lines.items, 0..) |line, i| {
            @memcpy(result[offset .. offset + line.len], line);
            offset += line.len;
            if (i < lines.items.len - 1) {
                result[offset] = '\n';
                offset += 1;
            }
        }

        // Free individual line copies
        for (lines.items) |line| {
            if (line.len > 0) {
                self.allocator.free(line);
            }
        }

        // Add final newline
        const final_result = self.allocator.realloc(result, offset + 1) catch return ParseError.OutOfMemory;
        final_result[offset] = '\n';

        return .{ .string = final_result };
    }

    fn parseScalar(self: *Parser) ParseError!YamlValue {
        // Skip leading spaces
        while (self.pos < self.source.len and self.source[self.pos] == ' ') {
            self.pos += 1;
        }

        if (self.pos >= self.source.len or self.source[self.pos] == '\n') {
            return .null_value;
        }

        const c = self.source[self.pos];

        // Quoted string
        if (c == '"' or c == '\'') {
            return self.parseQuotedString(c);
        }

        // Unquoted value
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '#') {
            self.pos += 1;
        }

        const raw = std.mem.trim(u8, self.source[start..self.pos], " \t");

        // Skip to end of line
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1;

        if (raw.len == 0) {
            return .null_value;
        }

        // Try to parse as boolean
        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "True") or std.mem.eql(u8, raw, "TRUE")) {
            return .{ .boolean = true };
        }
        if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "False") or std.mem.eql(u8, raw, "FALSE")) {
            return .{ .boolean = false };
        }

        // Try to parse as integer
        if (std.fmt.parseInt(i64, raw, 10)) |int_val| {
            return .{ .integer = int_val };
        } else |_| {}

        // Return as string
        const duped = self.allocator.dupe(u8, raw) catch return ParseError.OutOfMemory;
        return .{ .string = duped };
    }

    fn parseQuotedString(self: *Parser, quote: u8) ParseError!YamlValue {
        self.pos += 1; // skip opening quote

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        while (self.pos < self.source.len and self.source[self.pos] != quote) {
            if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) {
                self.pos += 1;
                const escaped = switch (self.source[self.pos]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    else => self.source[self.pos],
                };
                result.append(self.allocator, escaped) catch return ParseError.OutOfMemory;
            } else {
                result.append(self.allocator, self.source[self.pos]) catch return ParseError.OutOfMemory;
            }
            self.pos += 1;
        }

        if (self.pos < self.source.len) {
            self.pos += 1; // skip closing quote
        }

        // Skip to end of line
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1;

        const str = result.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
        return .{ .string = str };
    }
};

pub fn parseSpec(allocator: Allocator, source: []const u8) ParseError!Spec {
    var parser = Parser.init(allocator, source);
    var yaml = try parser.parse();
    defer yaml.deinit(allocator);

    var map = yaml.getMap() orelse return ParseError.InvalidYaml;

    // Get required name field
    const name_val = map.get("name") orelse return ParseError.MissingRequiredField;
    const name = name_val.getString() orelse return ParseError.InvalidYaml;

    // Get optional description
    const description = if (map.get("description")) |desc_val|
        desc_val.getString()
    else
        null;

    // Get required test_case (or test)
    const test_val = map.get("test_case") orelse map.get("test") orelse return ParseError.MissingRequiredField;
    var test_map = blk: {
        var tv = test_val;
        break :blk tv.getMap() orelse return ParseError.InvalidYaml;
    };

    const command_val = test_map.get("command") orelse return ParseError.MissingRequiredField;
    const command = command_val.getString() orelse return ParseError.InvalidYaml;

    const input = if (test_map.get("input")) |v| v.getString() else null;
    const expect_output = if (test_map.get("expect_output")) |v| v.getString() else null;
    const expect_output_contains = if (test_map.get("expect_output_contains")) |v| v.getString() else null;
    const expect_exit_code: i32 = if (test_map.get("expect_exit_code")) |v|
        @intCast(v.getInt() orelse 0)
    else
        0;
    const generate: bool = if (test_map.get("generate")) |v| v.getBool() orelse false else false;
    const target_path = if (test_map.get("target_path")) |v| v.getString() else null;

    // Parse setup commands
    var setup: ?[]const SetupCommand = null;
    if (map.get("setup")) |setup_val| {
        if (setup_val.getList()) |list| {
            var setup_cmds = allocator.alloc(SetupCommand, list.len) catch return ParseError.OutOfMemory;
            for (list, 0..) |item, i| {
                var item_copy = item;
                if (item_copy.getMap()) |item_map| {
                    if (item_map.get("run")) |run_val| {
                        const run_str = run_val.getString() orelse return ParseError.InvalidYaml;
                        setup_cmds[i] = .{
                            .run = allocator.dupe(u8, run_str) catch return ParseError.OutOfMemory,
                        };
                    } else {
                        allocator.free(setup_cmds);
                        return ParseError.InvalidYaml;
                    }
                } else if (item.getString()) |run_str| {
                    setup_cmds[i] = .{
                        .run = allocator.dupe(u8, run_str) catch return ParseError.OutOfMemory,
                    };
                } else {
                    allocator.free(setup_cmds);
                    return ParseError.InvalidYaml;
                }
            }
            setup = setup_cmds;
        }
    }

    // Parse teardown commands
    var teardown: ?[]const TeardownCommand = null;
    if (map.get("teardown")) |teardown_val| {
        if (teardown_val.getList()) |list| {
            var teardown_cmds = allocator.alloc(TeardownCommand, list.len) catch return ParseError.OutOfMemory;
            for (list, 0..) |item, i| {
                var item_copy = item;
                if (item_copy.getMap()) |item_map| {
                    if (item_map.get("run")) |run_val| {
                        const run_str = run_val.getString() orelse return ParseError.InvalidYaml;
                        teardown_cmds[i] = .{
                            .run = allocator.dupe(u8, run_str) catch return ParseError.OutOfMemory,
                        };
                    } else if (item_map.get("kill_process")) |kill_val| {
                        const kill_str = kill_val.getString() orelse return ParseError.InvalidYaml;
                        teardown_cmds[i] = .{
                            .kill_process = allocator.dupe(u8, kill_str) catch return ParseError.OutOfMemory,
                        };
                    } else {
                        allocator.free(teardown_cmds);
                        return ParseError.InvalidYaml;
                    }
                } else {
                    allocator.free(teardown_cmds);
                    return ParseError.InvalidYaml;
                }
            }
            teardown = teardown_cmds;
        }
    }

    return Spec{
        .name = allocator.dupe(u8, name) catch return ParseError.OutOfMemory,
        .description = if (description) |d| allocator.dupe(u8, d) catch return ParseError.OutOfMemory else null,
        .setup = setup,
        .test_case = .{
            .command = allocator.dupe(u8, command) catch return ParseError.OutOfMemory,
            .input = if (input) |i| allocator.dupe(u8, i) catch return ParseError.OutOfMemory else null,
            .expect_output = if (expect_output) |o| allocator.dupe(u8, o) catch return ParseError.OutOfMemory else null,
            .expect_output_contains = if (expect_output_contains) |o| allocator.dupe(u8, o) catch return ParseError.OutOfMemory else null,
            .expect_exit_code = expect_exit_code,
            .generate = generate,
            .target_path = if (target_path) |tp| allocator.dupe(u8, tp) catch return ParseError.OutOfMemory else null,
        },
        .teardown = teardown,
    };
}

pub fn parseSpecFromFile(allocator: Allocator, path: []const u8) !Spec {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return parseSpec(allocator, content);
}

pub fn parseProjectSpec(allocator: Allocator, source: []const u8) ParseError!ProjectSpec {
    var parser_instance = Parser.init(allocator, source);
    var yaml = try parser_instance.parse();
    defer yaml.deinit(allocator);

    var map = yaml.getMap() orelse return ParseError.InvalidYaml;

    // Get required name field
    const name_val = map.get("name") orelse return ParseError.MissingRequiredField;
    const name = name_val.getString() orelse return ParseError.InvalidYaml;

    // Get optional description
    const description = if (map.get("description")) |desc_val|
        desc_val.getString()
    else
        null;

    // Parse inline specs
    var specs: []const Spec = &.{};
    if (map.get("specs")) |specs_val| {
        if (specs_val.getList()) |list| {
            var specs_arr = allocator.alloc(Spec, list.len) catch return ParseError.OutOfMemory;
            errdefer allocator.free(specs_arr);

            for (list, 0..) |item, i| {
                var item_copy = item;
                if (item_copy.getMap()) |_| {
                    specs_arr[i] = try parseSpecFromYamlValue(allocator, item);
                } else {
                    allocator.free(specs_arr);
                    return ParseError.InvalidYaml;
                }
            }
            specs = specs_arr;
        }
    }

    // Parse include paths
    var include: []const []const u8 = &.{};
    if (map.get("include")) |include_val| {
        if (include_val.getList()) |list| {
            var include_arr = allocator.alloc([]const u8, list.len) catch return ParseError.OutOfMemory;
            errdefer allocator.free(include_arr);

            for (list, 0..) |item, i| {
                const path_str = item.getString() orelse {
                    allocator.free(include_arr);
                    return ParseError.InvalidYaml;
                };
                include_arr[i] = allocator.dupe(u8, path_str) catch return ParseError.OutOfMemory;
            }
            include = include_arr;
        }
    }

    return ProjectSpec{
        .name = allocator.dupe(u8, name) catch return ParseError.OutOfMemory,
        .description = if (description) |d| allocator.dupe(u8, d) catch return ParseError.OutOfMemory else null,
        .specs = specs,
        .include = include,
    };
}

fn parseSpecFromYamlValue(allocator: Allocator, yaml_val: YamlValue) ParseError!Spec {
    var val_copy = yaml_val;
    var map = val_copy.getMap() orelse return ParseError.InvalidYaml;

    // Get required name field
    const name_val = map.get("name") orelse return ParseError.MissingRequiredField;
    const name = name_val.getString() orelse return ParseError.InvalidYaml;

    // Get optional description
    const description = if (map.get("description")) |desc_val|
        desc_val.getString()
    else
        null;

    // Get required test_case (or test)
    const test_val = map.get("test_case") orelse map.get("test") orelse return ParseError.MissingRequiredField;
    var test_map = blk: {
        var tv = test_val;
        break :blk tv.getMap() orelse return ParseError.InvalidYaml;
    };

    const command_val = test_map.get("command") orelse return ParseError.MissingRequiredField;
    const command = command_val.getString() orelse return ParseError.InvalidYaml;

    const input = if (test_map.get("input")) |v| v.getString() else null;
    const expect_output = if (test_map.get("expect_output")) |v| v.getString() else null;
    const expect_output_contains = if (test_map.get("expect_output_contains")) |v| v.getString() else null;
    const expect_exit_code: i32 = if (test_map.get("expect_exit_code")) |v|
        @intCast(v.getInt() orelse 0)
    else
        0;
    const generate: bool = if (test_map.get("generate")) |v| v.getBool() orelse false else false;
    const target_path = if (test_map.get("target_path")) |v| v.getString() else null;

    // Parse setup commands
    var setup: ?[]const SetupCommand = null;
    if (map.get("setup")) |setup_val| {
        if (setup_val.getList()) |list| {
            var setup_cmds = allocator.alloc(SetupCommand, list.len) catch return ParseError.OutOfMemory;
            for (list, 0..) |item, i| {
                var item_copy = item;
                if (item_copy.getMap()) |item_map| {
                    if (item_map.get("run")) |run_val| {
                        const run_str = run_val.getString() orelse return ParseError.InvalidYaml;
                        setup_cmds[i] = .{
                            .run = allocator.dupe(u8, run_str) catch return ParseError.OutOfMemory,
                        };
                    } else {
                        allocator.free(setup_cmds);
                        return ParseError.InvalidYaml;
                    }
                } else if (item.getString()) |run_str| {
                    setup_cmds[i] = .{
                        .run = allocator.dupe(u8, run_str) catch return ParseError.OutOfMemory,
                    };
                } else {
                    allocator.free(setup_cmds);
                    return ParseError.InvalidYaml;
                }
            }
            setup = setup_cmds;
        }
    }

    // Parse teardown commands
    var teardown: ?[]const TeardownCommand = null;
    if (map.get("teardown")) |teardown_val| {
        if (teardown_val.getList()) |list| {
            var teardown_cmds = allocator.alloc(TeardownCommand, list.len) catch return ParseError.OutOfMemory;
            for (list, 0..) |item, i| {
                var item_copy = item;
                if (item_copy.getMap()) |item_map| {
                    if (item_map.get("run")) |run_val| {
                        const run_str = run_val.getString() orelse return ParseError.InvalidYaml;
                        teardown_cmds[i] = .{
                            .run = allocator.dupe(u8, run_str) catch return ParseError.OutOfMemory,
                        };
                    } else if (item_map.get("kill_process")) |kill_val| {
                        const kill_str = kill_val.getString() orelse return ParseError.InvalidYaml;
                        teardown_cmds[i] = .{
                            .kill_process = allocator.dupe(u8, kill_str) catch return ParseError.OutOfMemory,
                        };
                    } else {
                        allocator.free(teardown_cmds);
                        return ParseError.InvalidYaml;
                    }
                } else {
                    allocator.free(teardown_cmds);
                    return ParseError.InvalidYaml;
                }
            }
            teardown = teardown_cmds;
        }
    }

    return Spec{
        .name = allocator.dupe(u8, name) catch return ParseError.OutOfMemory,
        .description = if (description) |d| allocator.dupe(u8, d) catch return ParseError.OutOfMemory else null,
        .setup = setup,
        .test_case = .{
            .command = allocator.dupe(u8, command) catch return ParseError.OutOfMemory,
            .input = if (input) |inp| allocator.dupe(u8, inp) catch return ParseError.OutOfMemory else null,
            .expect_output = if (expect_output) |o| allocator.dupe(u8, o) catch return ParseError.OutOfMemory else null,
            .expect_output_contains = if (expect_output_contains) |o| allocator.dupe(u8, o) catch return ParseError.OutOfMemory else null,
            .expect_exit_code = expect_exit_code,
            .generate = generate,
            .target_path = if (target_path) |tp| allocator.dupe(u8, tp) catch return ParseError.OutOfMemory else null,
        },
        .teardown = teardown,
    };
}

pub fn parseProjectSpecFromFile(allocator: Allocator, path: []const u8) !ProjectSpec {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return parseProjectSpec(allocator, content);
}

test "parse simple spec" {
    const yaml =
        \\name: echo test
        \\description: Tests the echo command
        \\test:
        \\  command: echo hello
        \\  expect_output: hello
        \\  expect_exit_code: 0
    ;

    var spec = try parseSpec(std.testing.allocator, yaml);
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("echo test", spec.name);
    try std.testing.expectEqualStrings("Tests the echo command", spec.description.?);
    try std.testing.expectEqualStrings("echo hello", spec.test_case.command);
    try std.testing.expectEqualStrings("hello", spec.test_case.expect_output.?);
    try std.testing.expectEqual(@as(i32, 0), spec.test_case.expect_exit_code);
}

test "parse spec with setup and teardown" {
    const yaml =
        \\name: file test
        \\setup:
        \\  - run: touch /tmp/test.txt
        \\test:
        \\  command: cat /tmp/test.txt
        \\  expect_exit_code: 0
        \\teardown:
        \\  - run: rm /tmp/test.txt
    ;

    var spec = try parseSpec(std.testing.allocator, yaml);
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("file test", spec.name);
    try std.testing.expect(spec.setup != null);
    try std.testing.expectEqual(@as(usize, 1), spec.setup.?.len);
    try std.testing.expectEqualStrings("touch /tmp/test.txt", spec.setup.?[0].run);
    try std.testing.expect(spec.teardown != null);
    try std.testing.expectEqual(@as(usize, 1), spec.teardown.?.len);
}

test "parse project spec with inline specs" {
    const yaml =
        \\name: my project
        \\description: Test project
        \\specs:
        \\  - name: echo test
        \\    test:
        \\      command: echo hello
        \\      expect_output: hello
        \\  - name: cat test
        \\    test:
        \\      command: cat
        \\      input: world
        \\      expect_output: world
    ;

    var project = try parseProjectSpec(std.testing.allocator, yaml);
    defer project.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("my project", project.name);
    try std.testing.expectEqualStrings("Test project", project.description.?);
    try std.testing.expectEqual(@as(usize, 2), project.specs.len);
    try std.testing.expectEqualStrings("echo test", project.specs[0].name);
    try std.testing.expectEqualStrings("cat test", project.specs[1].name);
}

test "parse project spec with include" {
    const yaml =
        \\name: my project
        \\include:
        \\  - specs/cli.yaml
        \\  - specs/mcp.yaml
    ;

    var project = try parseProjectSpec(std.testing.allocator, yaml);
    defer project.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("my project", project.name);
    try std.testing.expectEqual(@as(usize, 0), project.specs.len);
    try std.testing.expectEqual(@as(usize, 2), project.include.len);
    try std.testing.expectEqualStrings("specs/cli.yaml", project.include[0]);
    try std.testing.expectEqualStrings("specs/mcp.yaml", project.include[1]);
}
