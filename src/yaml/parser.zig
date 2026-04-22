const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const spec_mod = @import("../core/spec.zig");
const Spec = spec_mod.Spec;
const TestCase = spec_mod.TestCase;
const SetupCommand = spec_mod.SetupCommand;
const TeardownCommand = spec_mod.TeardownCommand;
const EnvVar = spec_mod.EnvVar;
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

    const LineIndent = struct {
        line_start: usize,
        indent: usize,
    };

    fn readLineIndent(self: *Parser) ?LineIndent {
        if (self.pos >= self.source.len) return null;
        const line_start = self.pos;
        var indent: usize = 0;
        while (self.pos < self.source.len and self.source[self.pos] == ' ') {
            indent += 1;
            self.pos += 1;
        }
        return .{ .line_start = line_start, .indent = indent };
    }

    fn parseMapKey(self: *Parser, line_start: usize) ParseError!?[]const u8 {
        const key_start = self.pos;
        while (self.pos < self.source.len and
            self.source[self.pos] != ':' and
            self.source[self.pos] != '\n')
        {
            self.pos += 1;
        }
        if (self.pos >= self.source.len or self.source[self.pos] != ':') {
            self.pos = line_start;
            return null;
        }
        const key = std.mem.trim(u8, self.source[key_start..self.pos], " \t");
        return self.allocator.dupe(u8, key) catch ParseError.OutOfMemory;
    }

    fn parseNestedValue(self: *Parser, parent_indent: usize) ParseError!YamlValue {
        self.skipToNextLine();
        self.skipEmptyLinesAndComments();
        if (self.pos >= self.source.len) return .null_value;

        const value_start = self.pos;
        var value_indent: usize = 0;
        while (self.pos < self.source.len and self.source[self.pos] == ' ') {
            value_indent += 1;
            self.pos += 1;
        }

        if (value_indent <= parent_indent or self.pos >= self.source.len) {
            self.pos = value_start;
            return .null_value;
        }

        self.pos = value_start;
        if (self.source[self.pos] == '-') return self.parseList(value_indent);
        return self.parseMap(value_indent);
    }

    fn parseMapValue(self: *Parser, indent: usize) ParseError!YamlValue {
        while (self.pos < self.source.len and self.source[self.pos] == ' ') {
            self.pos += 1;
        }
        if (self.pos >= self.source.len or self.source[self.pos] == '\n') {
            return self.parseNestedValue(indent);
        }
        if (self.source[self.pos] == '|') return self.parseMultilineString(indent);
        return self.parseScalar();
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
            const info = self.readLineIndent() orelse break;
            if (info.indent < min_indent and map.count() > 0) {
                self.pos = info.line_start;
                break;
            }
            if (self.pos >= self.source.len or self.source[self.pos] == '\n') continue;
            if (self.source[self.pos] == '-') {
                self.pos = info.line_start;
                break;
            }

            const key_duped = (try self.parseMapKey(info.line_start)) orelse break;
            errdefer self.allocator.free(key_duped);
            self.pos += 1; // skip ':'
            const value = try self.parseMapValue(info.indent);

            map.put(key_duped, value) catch {
                self.allocator.free(key_duped);
                return ParseError.OutOfMemory;
            };
        }

        return .{ .map = map };
    }

    fn listItemHasInlineMap(self: *Parser) bool {
        if (self.source[self.pos] == '"' or self.source[self.pos] == '\'') return false;
        var peek = self.pos;
        while (peek < self.source.len and self.source[peek] != '\n') : (peek += 1) {
            if (self.source[peek] == ':') return true;
        }
        return false;
    }

    fn parseListItemValue(self: *Parser, indent: usize) ParseError!YamlValue {
        if (self.pos >= self.source.len or self.source[self.pos] == '\n') {
            self.skipToNextLine();
            return self.parseMap(indent + 2);
        }
        if (self.listItemHasInlineMap()) return self.parseMap(indent + 2);
        return self.parseScalar();
    }

    fn parseList(self: *Parser, min_indent: usize) ParseError!YamlValue {
        var items: std.ArrayListUnmanaged(YamlValue) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        while (self.pos < self.source.len) {
            self.skipEmptyLinesAndComments();
            const info = self.readLineIndent() orelse break;
            if (info.indent < min_indent and items.items.len > 0) {
                self.pos = info.line_start;
                break;
            }
            if (self.pos >= self.source.len or self.source[self.pos] != '-') {
                self.pos = info.line_start;
                break;
            }

            self.pos += 1; // skip '-'
            while (self.pos < self.source.len and self.source[self.pos] == ' ') {
                self.pos += 1;
            }
            items.append(self.allocator, try self.parseListItemValue(info.indent)) catch
                return ParseError.OutOfMemory;
        }

        const result = items.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
        return .{ .list = result };
    }

    fn freeMultilineLines(self: *Parser, lines: *std.ArrayListUnmanaged([]const u8)) void {
        for (lines.items) |line| {
            if (line.len > 0) self.allocator.free(line);
        }
        lines.deinit(self.allocator);
    }

    fn appendMultilineLine(
        self: *Parser,
        lines: *std.ArrayListUnmanaged([]const u8),
    ) ParseError!void {
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
        if (self.pos < self.source.len) self.pos += 1;
    }

    fn joinMultilineLines(self: *Parser, lines: []const []const u8) ParseError![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        for (lines, 0..) |line, i| {
            result.appendSlice(self.allocator, line) catch return ParseError.OutOfMemory;
            if (i < lines.len - 1) {
                result.append(self.allocator, '\n') catch return ParseError.OutOfMemory;
            }
        }
        result.append(self.allocator, '\n') catch return ParseError.OutOfMemory;
        return result.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
    }

    fn parseMultilineString(self: *Parser, base_indent: usize) ParseError!YamlValue {
        self.pos += 1; // skip '|'
        self.skipToNextLine();

        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer self.freeMultilineLines(&lines);
        var content_indent: ?usize = null;

        while (self.pos < self.source.len) {
            const line_start = self.pos;
            const info = self.readLineIndent() orelse break;

            if (self.pos >= self.source.len or self.source[self.pos] == '\n') {
                lines.append(self.allocator, "") catch return ParseError.OutOfMemory;
                if (self.pos < self.source.len) self.pos += 1;
                continue;
            }
            if (content_indent == null) {
                if (info.indent <= base_indent) {
                    self.pos = line_start;
                    break;
                }
                content_indent = info.indent;
            }
            if (info.indent < content_indent.?) {
                self.pos = line_start;
                break;
            }
            try self.appendMultilineLine(&lines);
        }

        if (lines.items.len == 0) {
            return .{ .string = self.allocator.dupe(u8, "") catch return ParseError.OutOfMemory };
        }
        return .{ .string = try self.joinMultilineLines(lines.items) };
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
        while (self.pos < self.source.len and
            self.source[self.pos] != '\n' and
            self.source[self.pos] != '#')
        {
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
        if (std.mem.eql(u8, raw, "true") or
            std.mem.eql(u8, raw, "True") or
            std.mem.eql(u8, raw, "TRUE"))
        {
            return .{ .boolean = true };
        }
        if (std.mem.eql(u8, raw, "false") or
            std.mem.eql(u8, raw, "False") or
            std.mem.eql(u8, raw, "FALSE"))
        {
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
                result.append(self.allocator, self.source[self.pos]) catch
                    return ParseError.OutOfMemory;
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

fn parseEnvVars(
    allocator: Allocator,
    test_map: *std.StringHashMap(YamlValue),
) ParseError!?[]const EnvVar {
    const env_val_ptr = test_map.getPtr("env") orelse return null;
    const env_map = env_val_ptr.getMap() orelse return null;

    var env_vars = allocator.alloc(EnvVar, env_map.count()) catch return ParseError.OutOfMemory;
    var iter = env_map.iterator();
    var idx: usize = 0;
    while (iter.next()) |entry| {
        const val_owned: ?[]const u8 = if (entry.value_ptr.getInt()) |int_val|
            std.fmt.allocPrint(allocator, "{d}", .{int_val}) catch return ParseError.OutOfMemory
        else
            null;
        defer if (val_owned) |v| allocator.free(v);

        const val_str = val_owned orelse if (entry.value_ptr.getString()) |s|
            s
        else if (entry.value_ptr.getBool()) |b|
            (if (b) "true" else "false")
        else
            return ParseError.InvalidYaml;

        env_vars[idx] = .{
            .key = allocator.dupe(u8, entry.key_ptr.*) catch return ParseError.OutOfMemory,
            .value = allocator.dupe(u8, val_str) catch return ParseError.OutOfMemory,
        };
        idx += 1;
    }
    return env_vars;
}

fn parseScalarToOwnedString(allocator: Allocator, val: YamlValue) ParseError![]const u8 {
    if (val.getString()) |s| {
        return allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
    }
    if (val.getInt()) |int_val| {
        return std.fmt.allocPrint(allocator, "{d}", .{int_val}) catch return ParseError.OutOfMemory;
    }
    if (val.getBool()) |b| {
        return allocator.dupe(u8, if (b) "true" else "false") catch return ParseError.OutOfMemory;
    }
    return ParseError.InvalidYaml;
}

fn parseArgsList(allocator: Allocator, val: YamlValue) ParseError![]const []const u8 {
    const list = val.getList() orelse return ParseError.InvalidYaml;
    const items = allocator.alloc([]const u8, list.len) catch return ParseError.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| allocator.free(item);
        allocator.free(items);
    }
    for (list, 0..) |item, i| {
        items[i] = try parseScalarToOwnedString(allocator, item);
        initialized += 1;
    }
    return items;
}

fn deinitStringList(allocator: Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn expandStringList(
    allocator: Allocator,
    items: []const []const u8,
    vars_map: *std.StringHashMap(YamlValue),
) ParseError![]const []const u8 {
    const expanded = allocator.alloc([]const u8, items.len) catch return ParseError.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (expanded[0..initialized]) |item| allocator.free(item);
        allocator.free(expanded);
    }
    for (items, 0..) |item, i| {
        expanded[i] = try expandTemplate(allocator, item, vars_map);
        initialized += 1;
    }
    return expanded;
}

/// Parse a YAML value as either a single string or a list of strings.
fn parseStringOrList(allocator: Allocator, val: YamlValue) ParseError!?[]const []const u8 {
    // Single string
    if (val.getString()) |s| {
        const items = allocator.alloc([]const u8, 1) catch return ParseError.OutOfMemory;
        items[0] = allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
        return items;
    }
    // List of strings
    if (val.getList()) |list| {
        if (list.len == 0) return null;
        const items = allocator.alloc([]const u8, list.len) catch return ParseError.OutOfMemory;
        for (list, 0..) |item, i| {
            const s = item.getString() orelse return ParseError.InvalidYaml;
            items[i] = allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
        }
        return items;
    }
    return null;
}

fn parseInputLines(allocator: Allocator, val: YamlValue) ParseError!?spec_mod.InputLines {
    // Short form: input_lines is a list directly
    if (val.getList()) |list| {
        var lines = allocator.alloc([]const u8, list.len) catch return ParseError.OutOfMemory;
        for (list, 0..) |item, i| {
            const s = item.getString() orelse return ParseError.InvalidYaml;
            lines[i] = allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
        }
        return spec_mod.InputLines{
            .line_ending = .lf,
            .trailing = true,
            .lines = lines,
        };
    }

    // Map form: input_lines has line_ending, trailing, lines
    var val_copy = val;
    var map = val_copy.getMap() orelse return ParseError.InvalidYaml;

    // Parse line_ending
    var line_ending: spec_mod.LineEnding = .lf;
    if (map.get("line_ending")) |le_val| {
        const le_str = le_val.getString() orelse return ParseError.InvalidYaml;
        if (std.mem.eql(u8, le_str, "lf")) {
            line_ending = .lf;
        } else if (std.mem.eql(u8, le_str, "crlf")) {
            line_ending = .crlf;
        } else {
            return ParseError.InvalidYaml;
        }
    }

    // Parse trailing
    var trailing: bool = true;
    if (map.get("trailing")) |t_val| {
        trailing = t_val.getBool() orelse return ParseError.InvalidYaml;
    }

    // Parse lines
    const lines_val = map.get("lines") orelse return ParseError.InvalidYaml;
    const lines_list = lines_val.getList() orelse return ParseError.InvalidYaml;

    var lines = allocator.alloc([]const u8, lines_list.len) catch return ParseError.OutOfMemory;
    for (lines_list, 0..) |item, i| {
        const s = item.getString() orelse return ParseError.InvalidYaml;
        lines[i] = allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
    }

    return spec_mod.InputLines{
        .line_ending = line_ending,
        .trailing = trailing,
        .lines = lines,
    };
}

const InputFields = struct {
    input: ?[]const u8 = null,
    input_lines: ?spec_mod.InputLines = null,
};

const AssertionFields = struct {
    expect_output: ?[]const u8 = null,
    expect_output_contains: ?[]const []const u8 = null,
    expect_output_not_contains: ?[]const []const u8 = null,
    expect_output_regex: ?[]const u8 = null,
    expect_stderr: ?[]const u8 = null,
    expect_stderr_contains: ?[]const []const u8 = null,
    expect_stderr_not_contains: ?[]const []const u8 = null,
    expect_stderr_regex: ?[]const u8 = null,
    expect_exit_code: i32 = 0,
};

fn dupOptionalString(allocator: Allocator, value: ?[]const u8) ParseError!?[]const u8 {
    if (value) |s| {
        return allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
    }
    return null;
}

fn parseInputFields(
    allocator: Allocator,
    test_map: *std.StringHashMap(YamlValue),
) ParseError!InputFields {
    const input = if (test_map.get("input")) |v| v.getString() else null;
    const input_lines = if (test_map.get("input_lines")) |v|
        try parseInputLines(allocator, v)
    else
        null;

    if (input != null and input_lines != null) {
        if (input_lines) |il| il.deinit(allocator);
        return ParseError.InvalidYaml;
    }
    return .{ .input = input, .input_lines = input_lines };
}

fn parseAssertionFields(
    allocator: Allocator,
    map: *std.StringHashMap(YamlValue),
) ParseError!AssertionFields {
    return .{
        .expect_output = if (map.get("expect_output")) |v| v.getString() else null,
        .expect_output_contains = if (map.get("expect_output_contains")) |v|
            try parseStringOrList(allocator, v)
        else
            null,
        .expect_output_not_contains = if (map.get("expect_output_not_contains")) |v|
            try parseStringOrList(allocator, v)
        else
            null,
        .expect_output_regex = if (map.get("expect_output_regex")) |v| v.getString() else null,
        .expect_stderr = if (map.get("expect_stderr")) |v| v.getString() else null,
        .expect_stderr_contains = if (map.get("expect_stderr_contains")) |v|
            try parseStringOrList(allocator, v)
        else
            null,
        .expect_stderr_not_contains = if (map.get("expect_stderr_not_contains")) |v|
            try parseStringOrList(allocator, v)
        else
            null,
        .expect_stderr_regex = if (map.get("expect_stderr_regex")) |v| v.getString() else null,
        .expect_exit_code = if (map.get("expect_exit_code")) |v|
            @intCast(v.getInt() orelse 0)
        else
            0,
    };
}

fn parseTimeoutMs(map: *std.StringHashMap(YamlValue)) ?u64 {
    if (map.get("timeout_ms")) |v| {
        if (v.getInt()) |i| return @as(u64, @intCast(i));
    }
    return null;
}

fn buildOwnedTestCase(
    allocator: Allocator,
    command: []const u8,
    args: ?[]const []const u8,
    input_fields: InputFields,
    assertions: AssertionFields,
    generate: bool,
    target_path: ?[]const u8,
    env: ?[]const EnvVar,
    working_dir: ?[]const u8,
    timeout_ms: ?u64,
) ParseError!TestCase {
    return TestCase{
        .command = allocator.dupe(u8, command) catch return ParseError.OutOfMemory,
        .args = args,
        .input = try dupOptionalString(allocator, input_fields.input),
        .input_lines = input_fields.input_lines,
        .expect_output = try dupOptionalString(allocator, assertions.expect_output),
        .expect_output_contains = assertions.expect_output_contains,
        .expect_output_not_contains = assertions.expect_output_not_contains,
        .expect_output_regex = try dupOptionalString(allocator, assertions.expect_output_regex),
        .expect_stderr = try dupOptionalString(allocator, assertions.expect_stderr),
        .expect_stderr_contains = assertions.expect_stderr_contains,
        .expect_stderr_not_contains = assertions.expect_stderr_not_contains,
        .expect_stderr_regex = try dupOptionalString(allocator, assertions.expect_stderr_regex),
        .expect_exit_code = assertions.expect_exit_code,
        .generate = generate,
        .target_path = try dupOptionalString(allocator, target_path),
        .env = env,
        .working_dir = try dupOptionalString(allocator, working_dir),
        .timeout_ms = timeout_ms,
    };
}

fn parseTestCaseFromMap(
    allocator: Allocator,
    test_map: *std.StringHashMap(YamlValue),
) ParseError!TestCase {
    const command_val = test_map.get("command") orelse return ParseError.MissingRequiredField;
    const command = command_val.getString() orelse return ParseError.InvalidYaml;
    const args = if (test_map.get("args")) |v| try parseArgsList(allocator, v) else null;

    const input_fields = try parseInputFields(allocator, test_map);
    const assertions = try parseAssertionFields(allocator, test_map);
    const generate: bool = if (test_map.get("generate")) |v| v.getBool() orelse false else false;
    const target_path = if (test_map.get("target_path")) |v| v.getString() else null;
    const working_dir = if (test_map.get("working_dir")) |v| v.getString() else null;
    const timeout_ms = parseTimeoutMs(test_map);
    const env = try parseEnvVars(allocator, test_map);

    return buildOwnedTestCase(
        allocator,
        command,
        args,
        input_fields,
        assertions,
        generate,
        target_path,
        env,
        working_dir,
        timeout_ms,
    );
}

fn parseSetupCommands(
    allocator: Allocator,
    map: *std.StringHashMap(YamlValue),
) ParseError!?[]const SetupCommand {
    const setup_val = map.get("setup") orelse return null;
    const list = setup_val.getList() orelse return null;

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
    return setup_cmds;
}

fn parseTeardownCommands(
    allocator: Allocator,
    map: *std.StringHashMap(YamlValue),
) ParseError!?[]const TeardownCommand {
    const teardown_val = map.get("teardown") orelse return null;
    const list = teardown_val.getList() orelse return null;

    var teardown_cmds = allocator.alloc(TeardownCommand, list.len) catch
        return ParseError.OutOfMemory;
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
                    .kill_process = allocator.dupe(u8, kill_str) catch
                        return ParseError.OutOfMemory,
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
    return teardown_cmds;
}

fn parseSteps(
    allocator: Allocator,
    map: *std.StringHashMap(YamlValue),
) ParseError!?[]const spec_mod.Step {
    const steps_val = map.get("steps") orelse return null;
    const list = steps_val.getList() orelse return null;
    if (list.len == 0) return null;

    var steps = allocator.alloc(spec_mod.Step, list.len) catch return ParseError.OutOfMemory;
    errdefer allocator.free(steps);

    for (list, 0..) |item, i| {
        var item_copy = item;
        var item_map = item_copy.getMap() orelse return ParseError.InvalidYaml;

        const step_name_val = item_map.get("name") orelse return ParseError.MissingRequiredField;
        const step_name = step_name_val.getString() orelse return ParseError.InvalidYaml;

        // Steps have test case fields directly (not nested under test:)
        const test_case = try parseTestCaseFromMap(allocator, item_map);

        steps[i] = .{
            .name = allocator.dupe(u8, step_name) catch return ParseError.OutOfMemory,
            .test_case = test_case,
        };
    }
    return steps;
}

/// Known assertion/meta keys in test_table cases (not template variables)
const test_table_reserved_keys = [_][]const u8{
    "name",
    "args",
    "input",
    "input_lines",
    "expect_output",
    "expect_output_contains",
    "expect_output_not_contains",
    "expect_output_regex",
    "expect_stderr",
    "expect_stderr_contains",
    "expect_stderr_not_contains",
    "expect_stderr_regex",
    "expect_exit_code",
    "command",
};

fn isReservedKey(key: []const u8) bool {
    for (test_table_reserved_keys) |reserved| {
        if (std.mem.eql(u8, key, reserved)) return true;
    }
    return false;
}

fn builtinTemplateValue(var_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, var_name, "EXEEXT")) {
        return if (builtin.os.tag == .windows) ".exe" else "";
    }
    return null;
}

fn expandTemplateWithDepth(
    allocator: Allocator,
    template: []const u8,
    case_map: *std.StringHashMap(YamlValue),
    depth: usize,
) ParseError![]const u8 {
    if (depth > 8) return ParseError.InvalidYaml;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '$' and template[i + 1] == '{') {
            const var_start = i + 2;
            const var_end = std.mem.indexOfScalarPos(u8, template, var_start, '}') orelse
                return ParseError.InvalidYaml;
            const var_name = template[var_start..var_end];

            if (case_map.get(var_name)) |val| {
                if (val.getString()) |s| {
                    const expanded = try expandTemplateWithDepth(allocator, s, case_map, depth + 1);
                    defer allocator.free(expanded);
                    result.appendSlice(allocator, expanded) catch return ParseError.OutOfMemory;
                } else if (val.getInt()) |int_val| {
                    const s = std.fmt.allocPrint(allocator, "{d}", .{int_val}) catch
                        return ParseError.OutOfMemory;
                    result.appendSlice(allocator, s) catch return ParseError.OutOfMemory;
                    allocator.free(s);
                } else {
                    return ParseError.InvalidYaml;
                }
            } else if (builtinTemplateValue(var_name)) |value| {
                result.appendSlice(allocator, value) catch return ParseError.OutOfMemory;
            } else {
                // Variable not found — keep as-is
                result.appendSlice(allocator, template[i .. var_end + 1]) catch
                    return ParseError.OutOfMemory;
            }
            i = var_end + 1;
        } else {
            result.append(allocator, template[i]) catch return ParseError.OutOfMemory;
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
}

/// Replace all ${var} occurrences in template with values from the case map.
fn expandTemplate(
    allocator: Allocator,
    template: []const u8,
    case_map: *std.StringHashMap(YamlValue),
) ParseError![]const u8 {
    return expandTemplateWithDepth(allocator, template, case_map, 0);
}

fn expandInputLines(
    allocator: Allocator,
    input_lines: spec_mod.InputLines,
    case_map: *std.StringHashMap(YamlValue),
) ParseError!spec_mod.InputLines {
    defer input_lines.deinit(allocator);

    const expanded_lines = allocator.alloc([]const u8, input_lines.lines.len) catch
        return ParseError.OutOfMemory;
    errdefer allocator.free(expanded_lines);

    var expanded_count: usize = 0;
    errdefer {
        for (expanded_lines[0..expanded_count]) |line| allocator.free(line);
    }

    for (input_lines.lines, 0..) |line, i| {
        expanded_lines[i] = try expandTemplate(allocator, line, case_map);
        expanded_count += 1;
    }

    return .{
        .line_ending = input_lines.line_ending,
        .trailing = input_lines.trailing,
        .lines = expanded_lines,
    };
}

fn deinitAssertionLists(allocator: Allocator, assertions: AssertionFields) void {
    if (assertions.expect_output_contains) |items| deinitStringList(allocator, items);
    if (assertions.expect_output_not_contains) |items| deinitStringList(allocator, items);
    if (assertions.expect_stderr_contains) |items| deinitStringList(allocator, items);
    if (assertions.expect_stderr_not_contains) |items| deinitStringList(allocator, items);
}

const TestTableConfig = struct {
    command_template: []const u8,
    args_template: ?[]const []const u8,
    cases: []const YamlValue,
};

fn parseTestTableConfig(
    allocator: Allocator,
    map: *std.StringHashMap(YamlValue),
) ParseError!?TestTableConfig {
    const table_val_ptr = map.getPtr("test_table") orelse return null;
    var table_map = table_val_ptr.getMap() orelse return ParseError.InvalidYaml;

    const command_template_val = table_map.get("command") orelse
        return ParseError.MissingRequiredField;
    const command_template = command_template_val.getString() orelse return ParseError.InvalidYaml;
    const args_template = if (table_map.get("args")) |v| try parseArgsList(allocator, v) else null;
    const cases_val = table_map.get("cases") orelse return ParseError.MissingRequiredField;
    const cases = cases_val.getList() orelse return ParseError.InvalidYaml;
    if (cases.len == 0) {
        if (args_template) |args| deinitStringList(allocator, args);
        return null;
    }
    return .{
        .command_template = command_template,
        .args_template = args_template,
        .cases = cases,
    };
}

fn buildCaseName(
    allocator: Allocator,
    case_map: *std.StringHashMap(YamlValue),
    idx: usize,
) ParseError![]const u8 {
    if (case_map.get("name")) |n| {
        return allocator.dupe(u8, n.getString() orelse return ParseError.InvalidYaml) catch
            return ParseError.OutOfMemory;
    }

    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer name_buf.deinit(allocator);

    var case_iter = case_map.iterator();
    var found_var = false;
    while (case_iter.next()) |entry| {
        if (isReservedKey(entry.key_ptr.*)) continue;
        if (found_var) {
            name_buf.appendSlice(allocator, ", ") catch return ParseError.OutOfMemory;
        }
        if (entry.value_ptr.getString()) |s| {
            name_buf.appendSlice(allocator, s) catch return ParseError.OutOfMemory;
        } else if (entry.value_ptr.getInt()) |int_val| {
            const s = std.fmt.allocPrint(allocator, "{d}", .{int_val}) catch
                return ParseError.OutOfMemory;
            defer allocator.free(s);
            name_buf.appendSlice(allocator, s) catch return ParseError.OutOfMemory;
        }
        found_var = true;
    }
    if (name_buf.items.len == 0) {
        return std.fmt.allocPrint(allocator, "case {d}", .{idx + 1}) catch
            return ParseError.OutOfMemory;
    }
    return allocator.dupe(u8, name_buf.items) catch return ParseError.OutOfMemory;
}

fn parseCaseArgs(
    allocator: Allocator,
    case_map: *std.StringHashMap(YamlValue),
    args_template: ?[]const []const u8,
) ParseError!?[]const []const u8 {
    const case_args_raw = if (case_map.get("args")) |v|
        try parseArgsList(allocator, v)
    else
        null;
    defer if (case_args_raw) |args| deinitStringList(allocator, args);

    const raw_args = case_args_raw orelse args_template;
    if (raw_args) |args| return try expandStringList(allocator, args, case_map);
    return null;
}

fn parseExpandedInputFields(
    allocator: Allocator,
    case_map: *std.StringHashMap(YamlValue),
) ParseError!InputFields {
    const input = if (case_map.get("input")) |v| blk: {
        const raw = v.getString() orelse return ParseError.InvalidYaml;
        break :blk try expandTemplate(allocator, raw, case_map);
    } else null;

    const input_lines = if (case_map.get("input_lines")) |v|
        try expandInputLines(
            allocator,
            (try parseInputLines(allocator, v)) orelse return ParseError.InvalidYaml,
            case_map,
        )
    else
        null;

    if (input != null and input_lines != null) {
        if (input) |value| allocator.free(value);
        if (input_lines) |lines| lines.deinit(allocator);
        return ParseError.InvalidYaml;
    }
    return .{ .input = input, .input_lines = input_lines };
}

fn buildTestTableStep(
    allocator: Allocator,
    config: TestTableConfig,
    case_item: YamlValue,
    idx: usize,
) ParseError!spec_mod.Step {
    var case_copy = case_item;
    const case_map = case_copy.getMap() orelse return ParseError.InvalidYaml;

    const step_name = try buildCaseName(allocator, case_map, idx);
    errdefer allocator.free(step_name);
    const command = try expandTemplate(allocator, config.command_template, case_map);
    errdefer allocator.free(command);
    const args = try parseCaseArgs(allocator, case_map, config.args_template);
    errdefer if (args) |items| deinitStringList(allocator, items);
    const input_fields = try parseExpandedInputFields(allocator, case_map);
    errdefer {
        if (input_fields.input) |value| allocator.free(value);
        if (input_fields.input_lines) |lines| lines.deinit(allocator);
    }
    const assertions = try parseAssertionFields(allocator, case_map);
    errdefer deinitAssertionLists(allocator, assertions);

    return .{
        .name = step_name,
        .test_case = .{
            .command = command,
            .args = args,
            .input = input_fields.input,
            .input_lines = input_fields.input_lines,
            .expect_output = try dupOptionalString(allocator, assertions.expect_output),
            .expect_output_contains = assertions.expect_output_contains,
            .expect_output_not_contains = assertions.expect_output_not_contains,
            .expect_output_regex = try dupOptionalString(allocator, assertions.expect_output_regex),
            .expect_stderr = try dupOptionalString(allocator, assertions.expect_stderr),
            .expect_stderr_contains = assertions.expect_stderr_contains,
            .expect_stderr_not_contains = assertions.expect_stderr_not_contains,
            .expect_stderr_regex = try dupOptionalString(allocator, assertions.expect_stderr_regex),
            .expect_exit_code = assertions.expect_exit_code,
        },
    };
}

fn parseTestTable(
    allocator: Allocator,
    map: *std.StringHashMap(YamlValue),
) ParseError!?[]const spec_mod.Step {
    const config = (try parseTestTableConfig(allocator, map)) orelse return null;
    defer if (config.args_template) |args| deinitStringList(allocator, args);

    var steps = allocator.alloc(spec_mod.Step, config.cases.len) catch
        return ParseError.OutOfMemory;
    errdefer allocator.free(steps);

    for (config.cases, 0..) |case_item, idx| {
        steps[idx] = try buildTestTableStep(allocator, config, case_item, idx);
    }

    return steps;
}

fn parseVarsMapPtr(map: *std.StringHashMap(YamlValue)) ?*std.StringHashMap(YamlValue) {
    const vars_ptr = map.getPtr("vars") orelse return null;
    return vars_ptr.getMap();
}

fn expandSetupAndTeardown(
    allocator: Allocator,
    setup: ?[]const SetupCommand,
    teardown: ?[]const TeardownCommand,
    vars_map: *std.StringHashMap(YamlValue),
) ParseError!void {
    if (setup) |setup_cmds| {
        for (setup_cmds) |*cmd| {
            const expanded = try expandTemplate(allocator, cmd.run, vars_map);
            allocator.free(@constCast(cmd).run);
            @constCast(cmd).run = expanded;
        }
    }
    if (teardown) |teardown_cmds| {
        for (teardown_cmds) |*cmd| {
            switch (cmd.*) {
                .run => |run_cmd| {
                    const expanded = try expandTemplate(allocator, run_cmd, vars_map);
                    allocator.free(run_cmd);
                    @constCast(cmd).* = .{ .run = expanded };
                },
                .kill_process => {},
            }
        }
    }
}

fn expandStepsWithVars(
    allocator: Allocator,
    steps: []const spec_mod.Step,
    vars_map: *std.StringHashMap(YamlValue),
) ParseError!void {
    for (steps) |*step| {
        const expanded = try expandTemplate(allocator, step.test_case.command, vars_map);
        allocator.free(@constCast(step).test_case.command);
        @constCast(step).test_case.command = expanded;
        if (step.test_case.args) |args| {
            const expanded_args = try expandStringList(allocator, args, vars_map);
            deinitStringList(allocator, args);
            @constCast(step).test_case.args = expanded_args;
        }
    }
}

fn expandTestCaseWithVars(
    allocator: Allocator,
    test_case: *TestCase,
    vars_map: *std.StringHashMap(YamlValue),
) ParseError!void {
    const expanded = try expandTemplate(allocator, test_case.command, vars_map);
    allocator.free(test_case.command);
    test_case.command = expanded;
    if (test_case.args) |args| {
        const expanded_args = try expandStringList(allocator, args, vars_map);
        deinitStringList(allocator, args);
        test_case.args = expanded_args;
    }
}

fn buildSpecWithSteps(
    allocator: Allocator,
    name: []const u8,
    description: ?[]const u8,
    setup: ?[]const SetupCommand,
    steps: []const spec_mod.Step,
    teardown: ?[]const TeardownCommand,
) ParseError!Spec {
    return Spec{
        .name = allocator.dupe(u8, name) catch return ParseError.OutOfMemory,
        .description = try dupOptionalString(allocator, description),
        .setup = setup,
        .steps = steps,
        .teardown = teardown,
    };
}

fn buildSpecWithTestCase(
    allocator: Allocator,
    name: []const u8,
    description: ?[]const u8,
    setup: ?[]const SetupCommand,
    test_case: TestCase,
    teardown: ?[]const TeardownCommand,
) ParseError!Spec {
    return Spec{
        .name = allocator.dupe(u8, name) catch return ParseError.OutOfMemory,
        .description = try dupOptionalString(allocator, description),
        .setup = setup,
        .test_case = test_case,
        .teardown = teardown,
    };
}

fn parseRootTestCase(
    allocator: Allocator,
    map: *std.StringHashMap(YamlValue),
) ParseError!TestCase {
    const test_val = map.get("test_case") orelse
        map.get("test") orelse
        return ParseError.MissingRequiredField;
    const test_map = blk: {
        var tv = test_val;
        break :blk tv.getMap() orelse return ParseError.InvalidYaml;
    };
    return parseTestCaseFromMap(allocator, test_map);
}

pub fn parseSpec(allocator: Allocator, source: []const u8) ParseError!Spec {
    var yaml_parser = Parser.init(allocator, source);
    var yaml = try yaml_parser.parse();
    defer yaml.deinit(allocator);

    var map = yaml.getMap() orelse return ParseError.InvalidYaml;
    const name_val = map.get("name") orelse return ParseError.MissingRequiredField;
    const name = name_val.getString() orelse return ParseError.InvalidYaml;
    const description = if (map.get("description")) |desc_val| desc_val.getString() else null;
    const vars_map_ptr = parseVarsMapPtr(map);

    const setup = try parseSetupCommands(allocator, map);
    const teardown = try parseTeardownCommands(allocator, map);
    const steps = try parseSteps(allocator, map);

    if (vars_map_ptr) |vars_map| {
        try expandSetupAndTeardown(allocator, setup, teardown, vars_map);
    }

    if (steps) |steps_list| {
        if (vars_map_ptr) |vars_map| try expandStepsWithVars(allocator, steps_list, vars_map);
        return buildSpecWithSteps(allocator, name, description, setup, steps_list, teardown);
    }

    const table_steps = try parseTestTable(allocator, map);
    if (table_steps) |tbl_steps| {
        if (vars_map_ptr) |vars_map| try expandStepsWithVars(allocator, tbl_steps, vars_map);
        return buildSpecWithSteps(allocator, name, description, setup, tbl_steps, teardown);
    }

    var test_case = try parseRootTestCase(allocator, map);
    if (vars_map_ptr) |vars_map| try expandTestCaseWithVars(allocator, &test_case, vars_map);
    return buildSpecWithTestCase(allocator, name, description, setup, test_case, teardown);
}

pub fn parseSpecFromFile(allocator: Allocator, path: []const u8) !Spec {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
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
            var include_arr = allocator.alloc([]const u8, list.len) catch
                return ParseError.OutOfMemory;
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
        .description = if (description) |d|
            allocator.dupe(u8, d) catch return ParseError.OutOfMemory
        else
            null,
        .specs = specs,
        .include = include,
    };
}

fn parseSpecFromYamlValue(allocator: Allocator, yaml_val: YamlValue) ParseError!Spec {
    var val_copy = yaml_val;
    var map = val_copy.getMap() orelse return ParseError.InvalidYaml;

    const name_val = map.get("name") orelse return ParseError.MissingRequiredField;
    const name = name_val.getString() orelse return ParseError.InvalidYaml;
    const description = if (map.get("description")) |desc_val| desc_val.getString() else null;

    const setup = try parseSetupCommands(allocator, map);
    const teardown = try parseTeardownCommands(allocator, map);
    const steps = try parseSteps(allocator, map);

    if (steps != null) {
        return Spec{
            .name = allocator.dupe(u8, name) catch return ParseError.OutOfMemory,
            .description = if (description) |d|
                allocator.dupe(u8, d) catch return ParseError.OutOfMemory
            else
                null,
            .setup = setup,
            .steps = steps,
            .teardown = teardown,
        };
    }

    const table_steps = try parseTestTable(allocator, map);
    if (table_steps != null) {
        return Spec{
            .name = allocator.dupe(u8, name) catch return ParseError.OutOfMemory,
            .description = if (description) |d|
                allocator.dupe(u8, d) catch return ParseError.OutOfMemory
            else
                null,
            .setup = setup,
            .steps = table_steps,
            .teardown = teardown,
        };
    }

    const test_val = map.get("test_case") orelse
        map.get("test") orelse
        return ParseError.MissingRequiredField;
    const test_map = blk: {
        var tv = test_val;
        break :blk tv.getMap() orelse return ParseError.InvalidYaml;
    };

    const test_case = try parseTestCaseFromMap(allocator, test_map);

    return Spec{
        .name = allocator.dupe(u8, name) catch return ParseError.OutOfMemory,
        .description = if (description) |d|
            allocator.dupe(u8, d) catch return ParseError.OutOfMemory
        else
            null,
        .setup = setup,
        .test_case = test_case,
        .teardown = teardown,
    };
}

pub fn parseProjectSpecFromFile(allocator: Allocator, path: []const u8) !ProjectSpec {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
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
