const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    InvalidPattern,
};

const ClassRange = struct {
    start: u8,
    end: u8,
};

const ClassItem = union(enum) {
    literal: u8,
    range: ClassRange,
};

const CharClass = struct {
    negated: bool,
    items: []const ClassItem,

    fn matches(self: CharClass, c: u8) bool {
        var matched = false;
        for (self.items) |item| {
            switch (item) {
                .literal => |literal| {
                    if (literal == c) {
                        matched = true;
                        break;
                    }
                },
                .range => |range| {
                    if (range.start <= c and c <= range.end) {
                        matched = true;
                        break;
                    }
                },
            }
        }
        return if (self.negated) !matched else matched;
    }
};

const Repeat = struct {
    child: *const Node,
    min: usize,
    max: ?usize,
};

const Node = union(enum) {
    literal: u8,
    any,
    char_class: CharClass,
    seq: []const *const Node,
    alt: []const *const Node,
    repeat: Repeat,
    start_anchor,
    end_anchor,
};

const Positions = std.ArrayListUnmanaged(usize);

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    root: *const Node,

    pub fn init(gpa: Allocator, pattern: []const u8) Error!Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        var parser = Parser{
            .allocator = arena.allocator(),
            .pattern = pattern,
        };
        const root = try parser.parse();

        return .{
            .arena = arena,
            .root = root,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    pub fn matches(self: *const Regex, gpa: Allocator, text: []const u8) Error!bool {
        var cursor: usize = 0;
        while (nextLine(text, &cursor)) |line| {
            if (try matchesLine(gpa, self.root, line)) return true;
        }
        return false;
    }
};

pub fn matchesPattern(gpa: Allocator, pattern: []const u8, text: []const u8) Error!bool {
    var regex = try Regex.init(gpa, pattern);
    defer regex.deinit();
    return regex.matches(gpa, text);
}

const Parser = struct {
    allocator: Allocator,
    pattern: []const u8,
    index: usize = 0,

    fn parse(self: *Parser) Error!*const Node {
        const node = try self.parseAlternation();
        if (self.index != self.pattern.len) return error.InvalidPattern;
        return node;
    }

    fn parseAlternation(self: *Parser) Error!*const Node {
        var branches: std.ArrayListUnmanaged(*const Node) = .empty;
        defer branches.deinit(self.allocator);

        try branches.append(self.allocator, try self.parseSequence());
        while (self.peek() == '|') {
            _ = self.take();
            try branches.append(self.allocator, try self.parseSequence());
        }

        if (branches.items.len == 1) return branches.items[0];
        return self.allocNode(.{ .alt = try branches.toOwnedSlice(self.allocator) });
    }

    fn parseSequence(self: *Parser) Error!*const Node {
        var terms: std.ArrayListUnmanaged(*const Node) = .empty;
        defer terms.deinit(self.allocator);

        while (self.peek()) |c| {
            if (c == ')' or c == '|') break;
            try terms.append(self.allocator, try self.parseQuantified());
        }

        if (terms.items.len == 0) {
            return self.allocNode(.{ .seq = try self.allocator.alloc(*const Node, 0) });
        }
        if (terms.items.len == 1) return terms.items[0];
        return self.allocNode(.{ .seq = try terms.toOwnedSlice(self.allocator) });
    }

    fn parseQuantified(self: *Parser) Error!*const Node {
        var node = try self.parseAtom();

        while (self.peek()) |c| {
            node = switch (c) {
                '*' => blk: {
                    _ = self.take();
                    break :blk try self.allocNode(.{ .repeat = .{
                        .child = node,
                        .min = 0,
                        .max = null,
                    } });
                },
                '+' => blk: {
                    _ = self.take();
                    break :blk try self.allocNode(.{ .repeat = .{
                        .child = node,
                        .min = 1,
                        .max = null,
                    } });
                },
                '?' => blk: {
                    _ = self.take();
                    break :blk try self.allocNode(.{ .repeat = .{
                        .child = node,
                        .min = 0,
                        .max = 1,
                    } });
                },
                else => return node,
            };
        }

        return node;
    }

    fn parseAtom(self: *Parser) Error!*const Node {
        const c = self.take() orelse return error.InvalidPattern;

        return switch (c) {
            '.' => self.allocNode(.{ .any = {} }),
            '^' => self.allocNode(.{ .start_anchor = {} }),
            '$' => self.allocNode(.{ .end_anchor = {} }),
            '(' => blk: {
                const inner = try self.parseAlternation();
                if (self.take() != ')') return error.InvalidPattern;
                break :blk inner;
            },
            '[' => self.parseCharClass(),
            '\\' => blk: {
                const escaped = self.take() orelse return error.InvalidPattern;
                break :blk self.allocNode(.{ .literal = decodeEscape(escaped) });
            },
            else => self.allocNode(.{ .literal = c }),
        };
    }

    fn parseCharClass(self: *Parser) Error!*const Node {
        const negated = if (self.peek() == '^') blk: {
            _ = self.take();
            break :blk true;
        } else false;

        var items: std.ArrayListUnmanaged(ClassItem) = .empty;
        defer items.deinit(self.allocator);

        var saw_item = false;
        while (true) {
            const c = self.peek() orelse return error.InvalidPattern;
            if (c == ']' and saw_item) {
                _ = self.take();
                break;
            }

            const start = try self.parseClassChar();
            if (self.peek() == '-' and self.hasRangeEnd()) {
                _ = self.take();
                const end = try self.parseClassChar();
                if (end < start) return error.InvalidPattern;
                try items.append(self.allocator, .{ .range = .{
                    .start = start,
                    .end = end,
                } });
            } else {
                try items.append(self.allocator, .{ .literal = start });
            }
            saw_item = true;
        }

        if (!saw_item) return error.InvalidPattern;

        return self.allocNode(.{ .char_class = .{
            .negated = negated,
            .items = try items.toOwnedSlice(self.allocator),
        } });
    }

    fn parseClassChar(self: *Parser) Error!u8 {
        const c = self.take() orelse return error.InvalidPattern;
        if (c != '\\') return c;

        const escaped = self.take() orelse return error.InvalidPattern;
        return decodeEscape(escaped);
    }

    fn hasRangeEnd(self: *const Parser) bool {
        if (self.index + 1 >= self.pattern.len) return false;
        return self.pattern[self.index + 1] != ']';
    }

    fn allocNode(self: *Parser, node: Node) Error!*const Node {
        const ptr = try self.allocator.create(Node);
        ptr.* = node;
        return ptr;
    }

    fn peek(self: *const Parser) ?u8 {
        if (self.index >= self.pattern.len) return null;
        return self.pattern[self.index];
    }

    fn take(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.index += 1;
        return c;
    }
};

fn decodeEscape(c: u8) u8 {
    return switch (c) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => c,
    };
}

fn nextLine(text: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= text.len) return null;

    const start = cursor.*;
    const newline = std.mem.indexOfScalar(u8, text[start..], '\n');
    if (newline) |index| {
        cursor.* = start + index + 1;
        return text[start .. start + index];
    }

    cursor.* = text.len;
    return text[start..];
}

fn isAnchoredAtStart(node: *const Node) bool {
    return switch (node.*) {
        .start_anchor => true,
        .seq => |children| children.len > 0 and isAnchoredAtStart(children[0]),
        else => false,
    };
}

fn matchesLine(gpa: Allocator, root: *const Node, line: []const u8) Error!bool {
    const start_limit = if (isAnchoredAtStart(root)) 1 else line.len + 1;

    var start: usize = 0;
    while (start < start_limit) : (start += 1) {
        var positions = try collectMatchPositions(gpa, root, line, start);
        defer positions.deinit(gpa);
        if (positions.items.len != 0) return true;
    }

    return false;
}

fn collectMatchPositions(
    gpa: Allocator,
    node: *const Node,
    line: []const u8,
    start: usize,
) Error!Positions {
    switch (node.*) {
        .literal => |literal| return collectAtomicPositions(
            gpa,
            start < line.len and line[start] == literal,
            start + 1,
        ),
        .any => return collectAtomicPositions(gpa, start < line.len, start + 1),
        .char_class => |class| return collectAtomicPositions(
            gpa,
            start < line.len and class.matches(line[start]),
            start + 1,
        ),
        .start_anchor => return collectAtomicPositions(gpa, start == 0, start),
        .end_anchor => return collectAtomicPositions(gpa, start == line.len, start),
        .seq => |children| return collectSequencePositions(gpa, children, line, start),
        .alt => |branches| return collectAlternativePositions(gpa, branches, line, start),
        .repeat => |repeat| return collectRepeatPositions(gpa, repeat, line, start),
    }
}

fn collectAtomicPositions(gpa: Allocator, matches: bool, next_position: usize) Error!Positions {
    var positions: Positions = .empty;
    errdefer positions.deinit(gpa);
    if (matches) try positions.append(gpa, next_position);
    return positions;
}

fn collectSequencePositions(
    gpa: Allocator,
    children: []const *Node,
    line: []const u8,
    start: usize,
) Error!Positions {
    var current: Positions = .empty;
    errdefer current.deinit(gpa);
    try current.append(gpa, start);

    for (children) |child| {
        var next: Positions = .empty;
        errdefer next.deinit(gpa);

        for (current.items) |position| {
            var child_positions = try collectMatchPositions(gpa, child, line, position);
            defer child_positions.deinit(gpa);

            for (child_positions.items) |child_position| {
                try appendUnique(gpa, &next, child_position);
            }
        }

        current.deinit(gpa);
        current = next;
        if (current.items.len == 0) break;
    }
    return current;
}

fn collectAlternativePositions(
    gpa: Allocator,
    branches: []const *Node,
    line: []const u8,
    start: usize,
) Error!Positions {
    var positions: Positions = .empty;
    errdefer positions.deinit(gpa);

    for (branches) |branch| {
        var branch_positions = try collectMatchPositions(gpa, branch, line, start);
        defer branch_positions.deinit(gpa);

        for (branch_positions.items) |position| {
            try appendUnique(gpa, &positions, position);
        }
    }
    return positions;
}

fn collectRepeatPositions(
    gpa: Allocator,
    repeat: Repeat,
    line: []const u8,
    start: usize,
) Error!Positions {
    var positions: Positions = .empty;
    errdefer positions.deinit(gpa);

    try collectRepeatPositionsRecursive(gpa, repeat, line, start, 0, &positions);
    return positions;
}

fn collectRepeatPositionsRecursive(
    gpa: Allocator,
    repeat: Repeat,
    line: []const u8,
    position: usize,
    count: usize,
    positions: *Positions,
) Error!void {
    if (count >= repeat.min) {
        try appendUnique(gpa, positions, position);
    }

    if (repeat.max) |max| {
        if (count >= max) return;
    }

    var next_positions = try collectMatchPositions(gpa, repeat.child, line, position);
    defer next_positions.deinit(gpa);

    for (next_positions.items) |next_position| {
        if (next_position == position) continue;
        try collectRepeatPositionsRecursive(gpa, repeat, line, next_position, count + 1, positions);
    }
}

fn appendUnique(gpa: Allocator, positions: *Positions, position: usize) Error!void {
    for (positions.items) |existing| {
        if (existing == position) return;
    }
    try positions.append(gpa, position);
}

test "matches common regex constructs" {
    try std.testing.expect(try matchesPattern(
        std.testing.allocator,
        "version [0-9]+\\.[0-9]+\\.[0-9]+",
        "version 1.2.3\n",
    ));
    try std.testing.expect(try matchesPattern(
        std.testing.allocator,
        "error:.*line [0-9]+",
        "warn\nerror: file not found at line 42\n",
    ));
    try std.testing.expect(try matchesPattern(
        std.testing.allocator,
        "hello_(foo|[0-9]+)",
        "hello_123\n",
    ));
    try std.testing.expect(!(try matchesPattern(
        std.testing.allocator,
        "^beta$",
        "alpha\nbeta gamma\n",
    )));
}

test "anchors are line oriented" {
    try std.testing.expect(try matchesPattern(
        std.testing.allocator,
        "^beta$",
        "alpha\nbeta\nomega\n",
    ));
    try std.testing.expect(!(try matchesPattern(std.testing.allocator, "^beta$", "alphabeta\n")));
}

test "invalid patterns are rejected" {
    try std.testing.expectError(
        error.InvalidPattern,
        matchesPattern(std.testing.allocator, "[0-9", "42"),
    );
    try std.testing.expectError(
        error.InvalidPattern,
        matchesPattern(std.testing.allocator, "(abc", "abc"),
    );
}
