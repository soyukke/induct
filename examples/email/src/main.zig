const std = @import("std");
const Allocator = std.mem.Allocator;

// ═══════════════════════════════════════════════════════════
// RFC 5322 Section 2.2.3: Header Unfolding
// ═══════════════════════════════════════════════════════════

fn unfold(allocator: Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 2 < input.len and input[i] == '\r' and input[i + 1] == '\n' and
            (input[i + 2] == ' ' or input[i + 2] == '\t'))
        {
            try result.append(allocator, ' ');
            i += 2;
            while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════
// RFC 5322 Section 3.2.2: Comment Handling
// ═══════════════════════════════════════════════════════════

fn stripComments(allocator: Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    var depth: usize = 0;

    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len and depth > 0) {
            // quoted-pair inside comment: skip both
            i += 2;
        } else if (input[i] == '(') {
            depth += 1;
            i += 1;
        } else if (input[i] == ')' and depth > 0) {
            depth -= 1;
            i += 1;
            // Replace comment with single space if not at start/end
            if (depth == 0 and result.items.len > 0 and i < input.len) {
                // Avoid double spaces
                if (result.items[result.items.len - 1] != ' ') {
                    try result.append(allocator, ' ');
                }
            }
        } else if (depth > 0) {
            i += 1; // inside comment, skip
        } else if (input[i] == '"') {
            // Quoted string: copy verbatim (comments don't nest inside quotes)
            try result.append(allocator, input[i]);
            i += 1;
            while (i < input.len and input[i] != '"') {
                if (input[i] == '\\' and i + 1 < input.len) {
                    try result.append(allocator, input[i]);
                    try result.append(allocator, input[i + 1]);
                    i += 2;
                } else {
                    try result.append(allocator, input[i]);
                    i += 1;
                }
            }
            if (i < input.len) {
                try result.append(allocator, input[i]); // closing quote
                i += 1;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    // Trim trailing whitespace that might remain from comment removal
    var slice = result.items;
    while (slice.len > 0 and (slice[slice.len - 1] == ' ' or slice[slice.len - 1] == '\t')) {
        slice.len -= 1;
    }
    return try allocator.dupe(u8, slice);
}

// ═══════════════════════════════════════════════════════════
// RFC 5322 Section 3.2.4: Quoted String unescaping
// ═══════════════════════════════════════════════════════════

fn unescapeQuotedString(allocator: Allocator, input: []const u8) ![]const u8 {
    // Input should be the content between quotes (without the surrounding quotes)
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            try result.append(allocator, input[i + 1]);
            i += 2;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════
// RFC 5322 Section 3.4: Address Parsing (full)
// ═══════════════════════════════════════════════════════════

const Address = struct {
    display_name: ?[]const u8,
    local_part: []const u8,
    domain: []const u8,
};

fn skipWS(input: []const u8, pos: usize) usize {
    var i = pos;
    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
    return i;
}

fn parseAddrSpec(input: []const u8, start: usize) ?struct { local: []const u8, domain: []const u8, end: usize } {
    var i = start;
    i = skipWS(input, i);

    const local_start = i;
    if (i < input.len and input[i] == '"') {
        i += 1;
        while (i < input.len and input[i] != '"') {
            if (input[i] == '\\' and i + 1 < input.len) i += 2 else i += 1;
        }
        if (i < input.len) i += 1; // skip closing "
    } else {
        while (i < input.len and input[i] != '@' and input[i] != '>' and
            input[i] != ',' and input[i] != ';' and input[i] != ' ' and input[i] != '\t')
        {
            i += 1;
        }
    }
    const local_end = i;
    if (local_end == local_start) return null;

    if (i >= input.len or input[i] != '@') return null;
    i += 1;

    const domain_start = i;
    if (i < input.len and input[i] == '[') {
        // domain-literal: [...]
        while (i < input.len and input[i] != ']') i += 1;
        if (i < input.len) i += 1; // include ]
    } else {
        while (i < input.len and input[i] != '>' and input[i] != ',' and
            input[i] != ';' and input[i] != ' ' and input[i] != '\t' and
            input[i] != '\r' and input[i] != '\n')
        {
            i += 1;
        }
    }
    const domain_end = i;
    if (domain_end == domain_start) return null;

    return .{ .local = input[local_start..local_end], .domain = input[domain_start..domain_end], .end = i };
}

fn parseSingleAddress(input: []const u8) ?Address {
    var i: usize = 0;
    i = skipWS(input, i);
    if (i >= input.len) return null;

    // Look for '<' (name-addr) outside quotes
    var angle_pos: ?usize = null;
    {
        var j = i;
        var in_q = false;
        while (j < input.len) {
            if (input[j] == '"') in_q = !in_q;
            if (!in_q and input[j] == '<') { angle_pos = j; break; }
            j += 1;
        }
    }

    if (angle_pos) |ap| {
        const display_raw = std.mem.trim(u8, input[i..ap], " \t");
        var display_name: ?[]const u8 = null;
        if (display_raw.len > 0) {
            if (display_raw.len >= 2 and display_raw[0] == '"' and display_raw[display_raw.len - 1] == '"') {
                display_name = display_raw[1 .. display_raw.len - 1];
            } else {
                display_name = display_raw;
            }
        }
        const addr = parseAddrSpec(input, ap + 1) orelse return null;
        return .{ .display_name = display_name, .local_part = addr.local, .domain = addr.domain };
    } else {
        const addr = parseAddrSpec(input, i) orelse return null;
        return .{ .display_name = null, .local_part = addr.local, .domain = addr.domain };
    }
}

const AddressListResult = struct {
    addresses: []Address,
    groups: []GroupResult,
};

const GroupResult = struct {
    name: []const u8,
    members: []Address,
};

fn parseAddressList(allocator: Allocator, input: []const u8) !AddressListResult {
    var addresses: std.ArrayListUnmanaged(Address) = .empty;
    defer addresses.deinit(allocator);
    var groups: std.ArrayListUnmanaged(GroupResult) = .empty;
    defer groups.deinit(allocator);

    // Split on ',' but respect quotes and angle brackets and groups
    var i: usize = 0;
    while (i < input.len) {
        i = skipWS(input, i);
        if (i >= input.len) break;

        // Find extent of this address/group
        const item_start = i;
        var in_quotes = false;
        var angle_depth: usize = 0;
        var colon_pos: ?usize = null;
        var semicolon_pos: ?usize = null;

        while (i < input.len) {
            if (input[i] == '"') in_quotes = !in_quotes;
            if (!in_quotes) {
                if (input[i] == '<') angle_depth += 1;
                if (input[i] == '>' and angle_depth > 0) angle_depth -= 1;
                if (angle_depth == 0) {
                    if (input[i] == ':' and colon_pos == null) colon_pos = i;
                    if (input[i] == ';') { semicolon_pos = i; i += 1; break; }
                    if (input[i] == ',' and colon_pos == null) break;
                }
            }
            i += 1;
        }

        const item = std.mem.trim(u8, input[item_start..i], " \t,");
        if (item.len == 0) { if (i < input.len) i += 1; continue; }

        if (colon_pos != null and semicolon_pos != null) {
            // Group
            const cp = colon_pos.? - item_start;
            const sp = if (semicolon_pos.? > item_start) semicolon_pos.? - item_start else item.len;
            const group_name = std.mem.trim(u8, item[0..cp], " \t");
            const member_str = if (cp + 1 < sp) item[cp + 1 .. sp] else "";

            // Parse members
            var members: std.ArrayListUnmanaged(Address) = .empty;
            defer members.deinit(allocator);
            var parts_iter = std.mem.splitScalar(u8, member_str, ',');
            while (parts_iter.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len == 0) continue;
                if (parseSingleAddress(trimmed)) |addr| {
                    try members.append(allocator, addr);
                }
            }

            try groups.append(allocator, .{
                .name = group_name,
                .members = try members.toOwnedSlice(allocator),
            });
        } else {
            if (parseSingleAddress(item)) |addr| {
                try addresses.append(allocator, addr);
            }
        }

        // Skip comma
        if (i < input.len and input[i] == ',') i += 1;
    }

    return .{
        .addresses = try addresses.toOwnedSlice(allocator),
        .groups = try groups.toOwnedSlice(allocator),
    };
}

// ═══════════════════════════════════════════════════════════
// RFC 5322 Section 3.3: Date-Time Parsing
// ═══════════════════════════════════════════════════════════

const DateTime = struct {
    day_of_week: ?[]const u8,
    day: u8,
    month: []const u8,
    year: u16,
    hour: u8,
    minute: u8,
    second: ?u8,
    zone: []const u8,
};

fn parseDateTime(input: []const u8) ?DateTime {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    var pos: usize = 0;

    var day_of_week: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, trimmed, ',')) |ci| {
        day_of_week = std.mem.trim(u8, trimmed[0..ci], " \t");
        pos = ci + 1;
    }

    while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) pos += 1;

    const day_start = pos;
    while (pos < trimmed.len and trimmed[pos] >= '0' and trimmed[pos] <= '9') pos += 1;
    if (pos == day_start) return null;
    const day = std.fmt.parseInt(u8, trimmed[day_start..pos], 10) catch return null;

    while (pos < trimmed.len and trimmed[pos] == ' ') pos += 1;

    if (pos + 3 > trimmed.len) return null;
    const month = trimmed[pos .. pos + 3];
    pos += 3;

    while (pos < trimmed.len and trimmed[pos] == ' ') pos += 1;

    const year_start = pos;
    while (pos < trimmed.len and trimmed[pos] >= '0' and trimmed[pos] <= '9') pos += 1;
    if (pos == year_start) return null;
    var year = std.fmt.parseInt(u16, trimmed[year_start..pos], 10) catch return null;
    if (pos - year_start == 2) {
        year += if (year <= 49) @as(u16, 2000) else @as(u16, 1900);
    }

    while (pos < trimmed.len and trimmed[pos] == ' ') pos += 1;

    const hour_start = pos;
    while (pos < trimmed.len and trimmed[pos] >= '0' and trimmed[pos] <= '9') pos += 1;
    const hour = std.fmt.parseInt(u8, trimmed[hour_start..pos], 10) catch return null;

    if (pos >= trimmed.len or trimmed[pos] != ':') return null;
    pos += 1;

    const min_start = pos;
    while (pos < trimmed.len and trimmed[pos] >= '0' and trimmed[pos] <= '9') pos += 1;
    const minute = std.fmt.parseInt(u8, trimmed[min_start..pos], 10) catch return null;

    var second: ?u8 = null;
    if (pos < trimmed.len and trimmed[pos] == ':') {
        pos += 1;
        const sec_start = pos;
        while (pos < trimmed.len and trimmed[pos] >= '0' and trimmed[pos] <= '9') pos += 1;
        second = std.fmt.parseInt(u8, trimmed[sec_start..pos], 10) catch return null;
    }

    while (pos < trimmed.len and trimmed[pos] == ' ') pos += 1;

    return .{
        .day_of_week = day_of_week,
        .day = day,
        .month = month,
        .year = year,
        .hour = hour,
        .minute = minute,
        .second = second,
        .zone = std.mem.trim(u8, trimmed[pos..], " \t"),
    };
}

// ═══════════════════════════════════════════════════════════
// RFC 5322 Section 3.5/3.6: Message Parsing
// ═══════════════════════════════════════════════════════════

const Header = struct { name: []const u8, value: []const u8 };

fn parseMessage(allocator: Allocator, input: []const u8) !struct { headers: []Header, body: []const u8 } {
    var headers: std.ArrayListUnmanaged(Header) = .empty;
    defer headers.deinit(allocator);

    var i: usize = 0;

    // Parse headers: terminated by empty line (CRLF CRLF)
    while (i < input.len) {
        // Check for end of headers (empty line)
        if (i + 1 < input.len and input[i] == '\r' and input[i + 1] == '\n') {
            i += 2;
            break;
        }
        if (input[i] == '\n') {
            i += 1;
            break;
        }

        // Parse header name
        const name_start = i;
        while (i < input.len and input[i] != ':' and input[i] != '\r' and input[i] != '\n') i += 1;
        if (i >= input.len or input[i] != ':') break;
        const name = input[name_start..i];
        i += 1; // skip ':'

        // Parse header value (including folded lines)
        var value: std.ArrayListUnmanaged(u8) = .empty;
        defer value.deinit(allocator);

        // Skip leading SP after ':'
        if (i < input.len and input[i] == ' ') i += 1;

        while (i < input.len) {
            if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') {
                if (i + 2 < input.len and (input[i + 2] == ' ' or input[i + 2] == '\t')) {
                    // Folded line: CRLF + WSP → SP
                    try value.append(allocator, ' ');
                    i += 2;
                    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
                } else {
                    i += 2;
                    break;
                }
            } else if (input[i] == '\n') {
                if (i + 1 < input.len and (input[i + 1] == ' ' or input[i + 1] == '\t')) {
                    try value.append(allocator, ' ');
                    i += 1;
                    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
                } else {
                    i += 1;
                    break;
                }
            } else {
                try value.append(allocator, input[i]);
                i += 1;
            }
        }

        try headers.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .value = try value.toOwnedSlice(allocator),
        });
    }

    const body = if (i < input.len) input[i..] else "";

    return .{
        .headers = try headers.toOwnedSlice(allocator),
        .body = body,
    };
}

// ═══════════════════════════════════════════════════════════
// CLI
// ═══════════════════════════════════════════════════════════

fn writeStderr(io: std.Io, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    writer.interface.writeAll(msg) catch {};
    writer.interface.flush() catch {};
}

fn readStdin(io: std.Io, allocator: Allocator) ![]const u8 {
    var reader = std.Io.File.stdin().reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

fn joinArgs(allocator: Allocator, args: []const []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (args) |arg| {
        if (buf.items.len > 0) try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, arg);
    }
    return try buf.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

    if (args.len < 2) {
        writeStderr(io, "Usage: email <unfold|strip-comments|unescape|parse-address|parse-addresses|parse-date|parse-message> [input]\n");
        std.process.exit(1);
    }

    var stdout_buf: [65536]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "unfold")) {
        const input = try readStdin(io, allocator);
        defer allocator.free(input);
        const result = try unfold(allocator, input);
        defer allocator.free(result);
        stdout.writeAll(result) catch {};
        stdout.flush() catch {};
    } else if (std.mem.eql(u8, cmd, "strip-comments")) {
        const input = if (args.len >= 3)
            try joinArgs(allocator, args[2..])
        else
            try readStdin(io, allocator);
        defer allocator.free(input);
        const trimmed = std.mem.trim(u8, input, "\r\n");
        const result = try stripComments(allocator, trimmed);
        defer allocator.free(result);
        stdout.writeAll(result) catch {};
        stdout.writeAll("\n") catch {};
        stdout.flush() catch {};
    } else if (std.mem.eql(u8, cmd, "unescape")) {
        const input = if (args.len >= 3)
            try joinArgs(allocator, args[2..])
        else blk: {
            const data = try readStdin(io, allocator);
            break :blk std.mem.trim(u8, data, "\r\n \t");
        };
        const result = try unescapeQuotedString(allocator, input);
        defer allocator.free(result);
        stdout.writeAll(result) catch {};
        stdout.writeAll("\n") catch {};
        stdout.flush() catch {};
    } else if (std.mem.eql(u8, cmd, "parse-address")) {
        const addr_input = if (args.len >= 3) blk: {
            break :blk try joinArgs(allocator, args[2..]);
        } else blk: {
            const data = try readStdin(io, allocator);
            break :blk std.mem.trim(u8, data, "\r\n \t");
        };

        if (parseSingleAddress(addr_input)) |addr| {
            if (addr.display_name) |dn| stdout.print("display-name: {s}\n", .{dn}) catch {};
            stdout.print("local-part: {s}\n", .{addr.local_part}) catch {};
            stdout.print("domain: {s}\n", .{addr.domain}) catch {};
        } else {
            writeStderr(io, "error: invalid address\n");
            std.process.exit(1);
        }
        stdout.flush() catch {};
    } else if (std.mem.eql(u8, cmd, "parse-addresses")) {
        const input = if (args.len >= 3)
            try joinArgs(allocator, args[2..])
        else blk: {
            const data = try readStdin(io, allocator);
            break :blk std.mem.trim(u8, data, "\r\n \t");
        };

        const result = try parseAddressList(allocator, input);
        for (result.addresses) |addr| {
            if (addr.display_name) |dn| stdout.print("display-name: {s}\n", .{dn}) catch {};
            stdout.print("local-part: {s}\n", .{addr.local_part}) catch {};
            stdout.print("domain: {s}\n", .{addr.domain}) catch {};
            stdout.writeAll("---\n") catch {};
        }
        for (result.groups) |grp| {
            stdout.print("group: {s}\n", .{grp.name}) catch {};
            for (grp.members) |m| {
                if (m.display_name) |dn| stdout.print("  display-name: {s}\n", .{dn}) catch {};
                stdout.print("  local-part: {s}\n", .{m.local_part}) catch {};
                stdout.print("  domain: {s}\n", .{m.domain}) catch {};
                stdout.writeAll("  ---\n") catch {};
            }
        }
        stdout.flush() catch {};
    } else if (std.mem.eql(u8, cmd, "parse-date")) {
        if (args.len < 3) {
            writeStderr(io, "Usage: email parse-date <date-time>\n");
            std.process.exit(1);
        }
        const date_input = try joinArgs(allocator, args[2..]);
        defer allocator.free(date_input);

        if (parseDateTime(date_input)) |dt| {
            if (dt.day_of_week) |dow| stdout.print("day-of-week: {s}\n", .{dow}) catch {};
            stdout.print("day: {d}\n", .{dt.day}) catch {};
            stdout.print("month: {s}\n", .{dt.month}) catch {};
            stdout.print("year: {d}\n", .{dt.year}) catch {};
            stdout.print("hour: {d:0>2}\n", .{dt.hour}) catch {};
            stdout.print("minute: {d:0>2}\n", .{dt.minute}) catch {};
            if (dt.second) |s| stdout.print("second: {d:0>2}\n", .{s}) catch {};
            stdout.print("zone: {s}\n", .{dt.zone}) catch {};
        } else {
            writeStderr(io, "error: invalid date-time\n");
            std.process.exit(1);
        }
        stdout.flush() catch {};
    } else if (std.mem.eql(u8, cmd, "parse-message")) {
        const input = try readStdin(io, allocator);
        defer allocator.free(input);

        const msg = try parseMessage(allocator, input);
        for (msg.headers) |h| {
            stdout.print("{s}: {s}\n", .{ h.name, h.value }) catch {};
        }
        stdout.writeAll("\n") catch {};
        if (msg.body.len > 0) {
            stdout.writeAll(msg.body) catch {};
        }
        stdout.flush() catch {};
    } else {
        writeStderr(io, "Unknown command\n");
        std.process.exit(1);
    }
}
