//! zig-tools/check_style.zig — project-agnostic Zig style checker.
//!
//! Enforces a small set of TigerBeetle-inspired rules via a ratcheting
//! baseline. The baseline records the current per-file violation counts;
//! the checker fails only when a file's count increases. Existing debt
//! does not block development, but new violations do.
//!
//! Pinned to Zig 0.16 (uses `std.Io.Dir`, `std.process.Init`).
//!
//! Usage (typical project justfile):
//!
//!     style_checker := env("ZIG_STYLE_CHECKER", "scripts/check_style.zig")
//!
//!     lint:
//!         zig run {{style_checker}} -- --root src
//!     lint-strict:
//!         zig run {{style_checker}} -- --root src --strict
//!     lint-update-baseline:
//!         zig run {{style_checker}} -- --root src --update-baseline
//!
//! CLI:
//!     --root <dir>         Directory to scan (default: src).
//!     --baseline <path>    Baseline file (default: scripts/style_baseline.txt).
//!     --line-limit <n>     Column limit for line_too_long (default: 100).
//!     --function-line-limit <n>
//!                          Line limit for function_too_long (default: 70).
//!     --disable <rule>     Disable a rule by name. Repeatable. See rule list below.
//!     --update-baseline    Regenerate the baseline from current violations.
//!     --strict             Report every violation and fail on any. Ignores baseline.
//!     -h, --help           Print help.
//!
//! Rules:
//!     line_too_long         Line exceeds --line-limit columns.
//!     tab_character         Tab character in source.
//!     trailing_whitespace   Line ends with space or tab.
//!     missing_final_newline File does not end with '\n'.
//!     debug_print           `std.debug.print` committed in source.
//!     function_too_long     Function body exceeds --function-line-limit lines.
//!
//! Extending: add a value to `Rule` and a matching entry in `rule_names`,
//! then implement detection in `checkLine` / `checkFile`.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Ast = std.zig.Ast;

const Rule = enum {
    line_too_long,
    tab_character,
    trailing_whitespace,
    missing_final_newline,
    debug_print,
    function_too_long,
};

const rule_names = [_][]const u8{
    "line_too_long",
    "tab_character",
    "trailing_whitespace",
    "missing_final_newline",
    "debug_print",
    "function_too_long",
};

const rule_count: usize = rule_names.len;
const line_limit_default: usize = 100;
const function_line_limit_default: usize = 70;
const baseline_path_default: []const u8 = "scripts/style_baseline.txt";
const root_default: []const u8 = "src";
const max_file_bytes: usize = 16 * 1024 * 1024;

const Counts = [rule_count]u32;
const RuleMask = [rule_count]bool;

fn ruleName(r: Rule) []const u8 {
    return rule_names[@intFromEnum(r)];
}

fn parseRule(name: []const u8) ?Rule {
    for (rule_names, 0..) |n, i| {
        if (mem.eql(u8, n, name)) return @enumFromInt(i);
    }
    return null;
}

// -------- Config: rule toggles + tunables --------

const Config = struct {
    line_limit: usize = line_limit_default,
    function_line_limit: usize = function_line_limit_default,
    enabled: RuleMask = [_]bool{true} ** rule_count,

    fn isEnabled(self: *const Config, r: Rule) bool {
        return self.enabled[@intFromEnum(r)];
    }

    fn disable(self: *Config, r: Rule) void {
        self.enabled[@intFromEnum(r)] = false;
    }
};

// -------- Counter: path -> per-rule counts --------

const Counter = struct {
    allocator: mem.Allocator,
    map: std.StringArrayHashMapUnmanaged(Counts) = .empty,

    fn init(allocator: mem.Allocator) Counter {
        return .{ .allocator = allocator };
    }

    fn getOrInsert(self: *Counter, path: []const u8) !*Counts {
        const gop = try self.map.getOrPut(self.allocator, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, path);
            gop.value_ptr.* = [_]u32{0} ** rule_count;
        }
        return gop.value_ptr;
    }

    fn bump(self: *Counter, path: []const u8, rule: Rule) !void {
        const counts = try self.getOrInsert(path);
        counts[@intFromEnum(rule)] += 1;
    }

    fn get(self: *const Counter, path: []const u8) Counts {
        return self.map.get(path) orelse [_]u32{0} ** rule_count;
    }
};

// -------- Line / file checks --------

fn checkLine(
    cfg: *const Config,
    counter: *Counter,
    path: []const u8,
    raw: []const u8,
) !void {
    // Strip optional trailing CR so CRLF files report sensibly.
    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

    if (cfg.isEnabled(.tab_character) and mem.indexOfScalar(u8, line, '\t') != null) {
        try counter.bump(path, .tab_character);
    }
    if (cfg.isEnabled(.trailing_whitespace) and line.len > 0) {
        const last = line[line.len - 1];
        if (last == ' ' or last == '\t') try counter.bump(path, .trailing_whitespace);
    }
    if (cfg.isEnabled(.line_too_long) and lineTooLong(cfg, line)) {
        try counter.bump(path, .line_too_long);
    }
    if (cfg.isEnabled(.debug_print) and mem.indexOf(u8, line, "std.debug.print") != null) {
        try counter.bump(path, .debug_print);
    }
}

fn lineTooLong(cfg: *const Config, line: []const u8) bool {
    const line_length = std.unicode.utf8CountCodepoints(line) catch line.len;
    if (line_length <= cfg.line_limit) return false;
    if (mem.indexOf(u8, line, "https://") != null) return false;

    if (rawStringLiteralValue(line)) |string_value| {
        const value_length = std.unicode.utf8CountCodepoints(string_value) catch string_value.len;
        if (value_length <= cfg.line_limit) return false;
    }

    return true;
}

fn rawStringLiteralValue(line: []const u8) ?[]const u8 {
    const split = mem.indexOf(u8, line, "\\\\") orelse return null;
    const indent = line[0..split];
    for (indent) |c| {
        if (c != ' ') return null;
    }
    return line[split + 2 ..];
}

fn checkFunctionLength(
    allocator: mem.Allocator,
    cfg: *const Config,
    counter: *Counter,
    path: []const u8,
    content: []const u8,
) !void {
    if (!cfg.isEnabled(.function_too_long)) return;

    const content_z = try allocator.dupeZ(u8, content);
    defer allocator.free(content_z);

    var tree = try Ast.parse(allocator, content_z, .zig);
    defer tree.deinit(allocator);

    const FnRange = struct {
        line_opening: usize,
        line_closing: usize,
    };
    var functions: std.ArrayListUnmanaged(FnRange) = .empty;
    defer functions.deinit(allocator);

    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    for (tags, datas, 0..) |tag, data, node_usize| {
        if (tag != .fn_decl) continue;

        const node: Ast.Node.Index = @enumFromInt(node_usize);
        const body_node = data.node_and_node[1];
        const token_opening = tree.firstToken(node);
        const token_closing = tree.lastToken(body_node);
        const line_opening = tree.tokenLocation(0, token_opening).line;
        const line_closing = tree.tokenLocation(0, token_closing).line;
        try functions.append(allocator, .{
            .line_opening = line_opening,
            .line_closing = line_closing,
        });
    }

    const Ctx = struct {
        fn lessThan(_: void, a: FnRange, b: FnRange) bool {
            if (a.line_opening != b.line_opening) return a.line_opening < b.line_opening;
            return a.line_closing < b.line_closing;
        }
    };
    std.mem.sort(FnRange, functions.items, {}, Ctx.lessThan);

    for (functions.items, 0..) |fn_range, i| {
        // Match TigerBeetle's behavior: skip outer function when nested fn exists inside.
        if (i + 1 < functions.items.len and functions.items[i + 1].line_opening <= fn_range.line_closing) {
            continue;
        }

        const function_length = fn_range.line_closing - fn_range.line_opening + 1;
        if (function_length > cfg.function_line_limit) {
            try counter.bump(path, .function_too_long);
        }
    }
}

fn checkFile(
    allocator: mem.Allocator,
    cfg: *const Config,
    counter: *Counter,
    path: []const u8,
    content: []const u8,
) !void {
    _ = try counter.getOrInsert(path);
    if (content.len == 0) return;

    if (cfg.isEnabled(.missing_final_newline) and content[content.len - 1] != '\n') {
        try counter.bump(path, .missing_final_newline);
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            try checkLine(cfg, counter, path, content[start..i]);
            start = i + 1;
        }
    }
    if (start < content.len) {
        try checkLine(cfg, counter, path, content[start..]);
    }

    try checkFunctionLength(allocator, cfg, counter, path, content);
}

// -------- Walk .zig files under a root --------

fn walkRoot(
    allocator: mem.Allocator,
    io: Io,
    cfg: *const Config,
    counter: *Counter,
    root: []const u8,
) !void {
    const cwd = Dir.cwd();
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch |err| {
        std.debug.print("error: cannot open --root {s}: {s}\n", .{ root, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".zig")) continue;

        const joined = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(joined);

        const content = try cwd.readFileAlloc(io, joined, allocator, .limited(max_file_bytes));
        defer allocator.free(content);

        try checkFile(allocator, cfg, counter, joined, content);
    }
}

// -------- Baseline I/O --------

fn loadBaseline(allocator: mem.Allocator, io: Io, path: []const u8) !Counter {
    var counter = Counter.init(allocator);
    const cwd = Dir.cwd();
    const content = cwd.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return counter,
        else => return err,
    };
    defer allocator.free(content);

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var parts = mem.splitScalar(u8, line, '\t');
        const p = parts.next() orelse continue;
        const r = parts.next() orelse continue;
        const c = parts.next() orelse continue;

        const rule = parseRule(r) orelse continue;
        const n = std.fmt.parseInt(u32, c, 10) catch continue;

        const counts = try counter.getOrInsert(p);
        counts[@intFromEnum(rule)] = n;
    }
    return counter;
}

fn writeBaseline(counter: *const Counter, io: Io, path: []const u8) !void {
    const allocator = counter.allocator;

    const Entry = struct { path: []const u8, rule: Rule, count: u32 };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer entries.deinit(allocator);

    var it = counter.map.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.*, 0..) |n, i| {
            if (n == 0) continue;
            try entries.append(allocator, .{
                .path = e.key_ptr.*,
                .rule = @enumFromInt(i),
                .count = n,
            });
        }
    }

    const Ctx = struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            const cmp = mem.order(u8, a.path, b.path);
            if (cmp != .eq) return cmp == .lt;
            return @intFromEnum(a.rule) < @intFromEnum(b.rule);
        }
    };
    std.mem.sort(Entry, entries.items, {}, Ctx.lessThan);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\# Zig style baseline (auto-generated by scripts/check_style.zig).
        \\#
        \\# Ratcheting baseline: each entry records the current number of
        \\# violations for (path, rule). The checker fails only when a count
        \\# exceeds its baseline. Drain it by fixing existing violations and
        \\# running: just lint-update-baseline
        \\#
        \\# Format: <path>\t<rule>\t<count>
        \\
    );

    var line_buf: [1024]u8 = undefined;
    for (entries.items) |e| {
        const line = try std.fmt.bufPrint(&line_buf, "{s}\t{s}\t{d}\n", .{
            e.path, ruleName(e.rule), e.count,
        });
        try buf.appendSlice(allocator, line);
    }

    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

// -------- Reporting --------

const Mode = enum { check, update, strict };

const Regression = struct {
    path: []const u8,
    rule: Rule,
    baseline: u32,
    current: u32,
};

fn collectRegressions(
    allocator: mem.Allocator,
    current: *const Counter,
    baseline: *const Counter,
) !std.ArrayListUnmanaged(Regression) {
    var out: std.ArrayListUnmanaged(Regression) = .empty;
    var it = current.map.iterator();
    while (it.next()) |e| {
        const base = baseline.get(e.key_ptr.*);
        for (e.value_ptr.*, 0..) |n, i| {
            if (n > base[i]) {
                try out.append(allocator, .{
                    .path = e.key_ptr.*,
                    .rule = @enumFromInt(i),
                    .baseline = base[i],
                    .current = n,
                });
            }
        }
    }
    return out;
}

fn writeAllTo(io: Io, out: File, bytes: []const u8) !void {
    try out.writeStreamingAll(io, bytes);
}

fn printLine(io: Io, out: File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try out.writeStreamingAll(io, s);
}

fn printTotals(io: Io, out: File, counter: *const Counter) !void {
    var totals = [_]u64{0} ** rule_count;
    var it = counter.map.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.*, 0..) |n, i| totals[i] += n;
    }
    try writeAllTo(io, out, "violation totals:\n");
    for (totals, 0..) |n, i| {
        try printLine(io, out, "  {s:<24} {d}\n", .{ rule_names[i], n });
    }
}

// -------- CLI --------

const Args = struct {
    root: []const u8 = root_default,
    baseline: []const u8 = baseline_path_default,
    cfg: Config = .{},
    mode: Mode = .check,
};

fn parseArgs(allocator: mem.Allocator, process_args: std.process.Args) !Args {
    var out: Args = .{};
    var it = process_args.iterate();
    defer it.deinit();
    _ = it.next(); // program name

    while (it.next()) |arg| {
        if (mem.eql(u8, arg, "--root")) {
            const v = it.next() orelse return error.MissingValue;
            out.root = try allocator.dupe(u8, v);
        } else if (mem.eql(u8, arg, "--baseline")) {
            const v = it.next() orelse return error.MissingValue;
            out.baseline = try allocator.dupe(u8, v);
        } else if (mem.eql(u8, arg, "--line-limit")) {
            const v = it.next() orelse return error.MissingValue;
            out.cfg.line_limit = std.fmt.parseInt(usize, v, 10) catch {
                std.debug.print("error: --line-limit expects a non-negative integer, got {s}\n", .{v});
                std.process.exit(2);
            };
        } else if (mem.eql(u8, arg, "--function-line-limit")) {
            const v = it.next() orelse return error.MissingValue;
            out.cfg.function_line_limit = std.fmt.parseInt(usize, v, 10) catch {
                std.debug.print("error: --function-line-limit expects a non-negative integer, got {s}\n", .{v});
                std.process.exit(2);
            };
        } else if (mem.eql(u8, arg, "--disable")) {
            const v = it.next() orelse return error.MissingValue;
            const rule = parseRule(v) orelse {
                std.debug.print("error: unknown rule {s}. Known rules:\n", .{v});
                for (rule_names) |n| std.debug.print("  {s}\n", .{n});
                std.process.exit(2);
            };
            out.cfg.disable(rule);
        } else if (mem.eql(u8, arg, "--update-baseline")) {
            out.mode = .update;
        } else if (mem.eql(u8, arg, "--strict")) {
            out.mode = .strict;
        } else if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            try printHelp();
            std.process.exit(2);
        }
    }
    return out;
}

fn printHelp() !void {
    const msg =
        \\zig-tools/check_style — Zig style checker (ratcheting baseline).
        \\
        \\Usage:
        \\  zig run scripts/check_style.zig -- [options]
        \\
        \\Options:
        \\  --root <dir>         Directory to scan (default: src).
        \\  --baseline <path>    Baseline file (default: scripts/style_baseline.txt).
        \\  --line-limit <n>     Column limit for line_too_long (default: 100).
        \\  --function-line-limit <n>
        \\                       Line limit for function_too_long (default: 70).
        \\  --disable <rule>     Disable a rule. Repeatable.
        \\  --update-baseline    Regenerate the baseline from current violations.
        \\  --strict             Report every violation; ignore baseline. Fails on any.
        \\  -h, --help           Print this help.
        \\
        \\Rules:
        \\  line_too_long         Line exceeds --line-limit columns.
        \\  tab_character         Tab character in source.
        \\  trailing_whitespace   Line ends with space or tab.
        \\  missing_final_newline File does not end with '\n'.
        \\  debug_print           `std.debug.print` committed in source.
        \\  function_too_long     Function exceeds --function-line-limit lines.
        \\
    ;
    std.debug.print("{s}", .{msg});
}

// -------- main --------

pub fn main(init: std.process.Init) !void {
    // Short-lived CLI: funnel all allocations through the process arena so
    // the DebugAllocator in the Zig entry point has nothing to report.
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try parseArgs(allocator, init.minimal.args);

    var current = Counter.init(allocator);
    try walkRoot(allocator, io, &args.cfg, &current, args.root);

    const stdout = File.stdout();

    switch (args.mode) {
        .update => {
            try writeBaseline(&current, io, args.baseline);
            try printLine(io, stdout, "wrote baseline: {s}\n", .{args.baseline});
            try printTotals(io, stdout, &current);
        },
        .strict => {
            try printTotals(io, stdout, &current);
            var any = false;
            var it = current.map.iterator();
            while (it.next()) |e| {
                for (e.value_ptr.*, 0..) |n, i| {
                    if (n == 0) continue;
                    any = true;
                    try printLine(io, stdout, "  {s}: {s} x{d}\n", .{ e.key_ptr.*, rule_names[i], n });
                }
            }
            if (any) std.process.exit(1);
        },
        .check => {
            var baseline = try loadBaseline(allocator, io, args.baseline);
            _ = &baseline;

            var regressions = try collectRegressions(allocator, &current, &baseline);
            defer regressions.deinit(allocator);

            if (regressions.items.len == 0) {
                try writeAllTo(io, stdout, "style: OK (no new violations above baseline)\n");
                return;
            }

            try printLine(io, stdout, "style: {d} new violation(s) above baseline:\n", .{regressions.items.len});
            const Ctx = struct {
                fn lessThan(_: void, a: Regression, b: Regression) bool {
                    const cmp = mem.order(u8, a.path, b.path);
                    if (cmp != .eq) return cmp == .lt;
                    return @intFromEnum(a.rule) < @intFromEnum(b.rule);
                }
            };
            std.mem.sort(Regression, regressions.items, {}, Ctx.lessThan);
            for (regressions.items) |r| {
                try printLine(
                    io,
                    stdout,
                    "  {s}: {s}  baseline={d} current={d} (+{d})\n",
                    .{ r.path, ruleName(r.rule), r.baseline, r.current, r.current - r.baseline },
                );
            }
            try writeAllTo(
                io,
                stdout,
                \\
                \\To accept current state as the new baseline, run:
                \\  just lint-update-baseline
                \\
                ,
            );
            std.process.exit(1);
        },
    }
}
