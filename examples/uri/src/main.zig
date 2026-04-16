const std = @import("std");

const Uri = struct {
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

/// RFC 3986 Appendix B regex-based decomposition:
/// ^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?
fn parseUri(input: []const u8) Uri {
    var uri = Uri{};
    var pos: usize = 0;

    // Scheme: everything before first ':'
    // But only if it looks like a scheme (no / ? # before the colon)
    if (findSchemeEnd(input)) |colon_pos| {
        uri.scheme = input[0..colon_pos];
        pos = colon_pos + 1;
    }

    // Authority: starts with //
    if (pos + 1 < input.len and input[pos] == '/' and input[pos + 1] == '/') {
        pos += 2;
        const auth_start = pos;
        while (pos < input.len and input[pos] != '/' and input[pos] != '?' and input[pos] != '#') {
            pos += 1;
        }
        uri.authority = input[auth_start..pos];
    }

    // Path: up to ? or #
    const path_start = pos;
    while (pos < input.len and input[pos] != '?' and input[pos] != '#') {
        pos += 1;
    }
    uri.path = input[path_start..pos];

    // Query: after ?
    if (pos < input.len and input[pos] == '?') {
        pos += 1;
        const query_start = pos;
        while (pos < input.len and input[pos] != '#') {
            pos += 1;
        }
        uri.query = input[query_start..pos];
    }

    // Fragment: after #
    if (pos < input.len and input[pos] == '#') {
        pos += 1;
        uri.fragment = input[pos..];
    }

    return uri;
}

fn findSchemeEnd(input: []const u8) ?usize {
    // scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    if (input.len == 0) return null;
    if (!std.ascii.isAlphabetic(input[0])) return null;

    var i: usize = 1;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == ':') return i;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    return null;
}

fn printUri(uri: Uri, writer: anytype) !void {
    if (uri.scheme) |s| try writer.print("scheme: {s}\n", .{s});
    if (uri.authority) |a| try writer.print("authority: {s}\n", .{a});
    if (uri.path.len > 0) try writer.print("path: {s}\n", .{uri.path});
    if (uri.query) |q| try writer.print("query: {s}\n", .{q});
    if (uri.fragment) |f| try writer.print("fragment: {s}\n", .{f});
}

/// RFC 3986 Section 5.2.4: Remove Dot Segments
fn removeDotSegments(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    var input = path;

    while (input.len > 0) {
        // A: ../  or ./
        if (std.mem.startsWith(u8, input, "../")) {
            input = input[3..];
        } else if (std.mem.startsWith(u8, input, "./")) {
            input = input[2..];
        }
        // B: /./  or /.
        else if (std.mem.startsWith(u8, input, "/./")) {
            input = input[2..];
        } else if (std.mem.eql(u8, input, "/.")) {
            input = "/";
        }
        // C: /../ or /..
        else if (std.mem.startsWith(u8, input, "/../")) {
            input = input[3..];
            removeLastSegment(&output);
        } else if (std.mem.eql(u8, input, "/..")) {
            input = "/";
            removeLastSegment(&output);
        }
        // D: . or ..
        else if (std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..")) {
            input = "";
        }
        // E: move first path segment to output
        else {
            if (input[0] == '/') {
                try output.append(allocator, '/');
                input = input[1..];
            }
            // Find next /
            var end: usize = 0;
            while (end < input.len and input[end] != '/') {
                end += 1;
            }
            try output.appendSlice(allocator, input[0..end]);
            input = input[end..];
        }
    }

    return try allocator.dupe(u8, output.items);
}

fn removeLastSegment(output: *std.ArrayListUnmanaged(u8)) void {
    // Remove everything after last /
    while (output.items.len > 0 and output.items[output.items.len - 1] != '/') {
        _ = output.pop();
    }
    // Remove the trailing / too
    if (output.items.len > 0) {
        _ = output.pop();
    }
}

/// RFC 3986 Section 5.3: Recompose URI from components
fn recomposeUri(allocator: std.mem.Allocator, uri: Uri) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    if (uri.scheme) |s| {
        try result.appendSlice(allocator, s);
        try result.append(allocator, ':');
    }
    if (uri.authority) |a| {
        try result.appendSlice(allocator, "//");
        try result.appendSlice(allocator, a);
    }
    try result.appendSlice(allocator, uri.path);
    if (uri.query) |q| {
        try result.append(allocator, '?');
        try result.appendSlice(allocator, q);
    }
    if (uri.fragment) |f| {
        try result.append(allocator, '#');
        try result.appendSlice(allocator, f);
    }

    return try allocator.dupe(u8, result.items);
}

/// RFC 3986 Section 5.2.2: Reference Resolution
fn resolveReference(allocator: std.mem.Allocator, base: Uri, ref_uri: Uri) !Uri {
    var target = Uri{};

    if (ref_uri.scheme != null) {
        target.scheme = ref_uri.scheme;
        target.authority = ref_uri.authority;
        const cleaned = try removeDotSegments(allocator, ref_uri.path);
        target.path = cleaned;
        target.query = ref_uri.query;
    } else {
        if (ref_uri.authority != null) {
            target.authority = ref_uri.authority;
            const cleaned = try removeDotSegments(allocator, ref_uri.path);
            target.path = cleaned;
            target.query = ref_uri.query;
        } else {
            if (ref_uri.path.len == 0) {
                target.path = base.path;
                target.query = ref_uri.query orelse base.query;
            } else {
                if (ref_uri.path[0] == '/') {
                    const cleaned = try removeDotSegments(allocator, ref_uri.path);
                    target.path = cleaned;
                } else {
                    // Merge
                    const merged = try mergePaths(allocator, base, ref_uri.path);
                    const cleaned = try removeDotSegments(allocator, merged);
                    allocator.free(merged);
                    target.path = cleaned;
                }
                target.query = ref_uri.query;
            }
            target.authority = base.authority;
        }
        target.scheme = base.scheme;
    }

    target.fragment = ref_uri.fragment;
    return target;
}

fn mergePaths(allocator: std.mem.Allocator, base: Uri, ref_path: []const u8) ![]const u8 {
    if (base.authority != null and base.path.len == 0) {
        // Append / before ref_path
        return try std.fmt.allocPrint(allocator, "/{s}", .{ref_path});
    }
    // Find last / in base path
    if (std.mem.lastIndexOfScalar(u8, base.path, '/')) |last_slash| {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        try result.appendSlice(allocator, base.path[0 .. last_slash + 1]);
        try result.appendSlice(allocator, ref_path);
        return try result.toOwnedSlice(allocator);
    }
    return try allocator.dupe(u8, ref_path);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        var buf: [256]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buf);
        writer.interface.writeAll("Usage: uri <parse|resolve> <uri> [ref]\n") catch {};
        writer.interface.flush() catch {};
        std.process.exit(1);
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, args[1], "parse")) {
        const uri = parseUri(args[2]);
        printUri(uri, stdout) catch {};
    } else if (std.mem.eql(u8, args[1], "resolve")) {
        if (args.len < 4) {
            var buf: [256]u8 = undefined;
            var writer = std.fs.File.stderr().writer(&buf);
            writer.interface.writeAll("Usage: uri resolve <base> <ref>\n") catch {};
            writer.interface.flush() catch {};
            std.process.exit(1);
        }
        const base = parseUri(args[2]);
        const ref_uri = parseUri(args[3]);
        const target = try resolveReference(allocator, base, ref_uri);
        const result = try recomposeUri(allocator, target);
        defer allocator.free(result);
        stdout.print("{s}\n", .{result}) catch {};
    }

    stdout.flush() catch {};
}
