const std = @import("std");

const ParseError = error{
    UnexpectedQuote,
    UnclosedQuote,
};

fn parseAndPrintRecord(line: []const u8, stdout: anytype) ParseError!void {
    var i: usize = 0;
    var field_start: usize = 0;
    var in_quotes = false;
    var has_quotes = false;
    var first_field = true;

    // Buffer for unescaped quoted field content
    var unescaped_buf: [65536]u8 = undefined;
    var unescaped_len: usize = 0;

    while (i < line.len) {
        const c = line[i];
        if (in_quotes) {
            if (c == '"') {
                if (i + 1 < line.len and line[i + 1] == '"') {
                    // Escaped quote ""
                    if (unescaped_len < unescaped_buf.len) {
                        unescaped_buf[unescaped_len] = '"';
                        unescaped_len += 1;
                    }
                    i += 2;
                } else {
                    in_quotes = false;
                    i += 1;
                }
            } else {
                if (unescaped_len < unescaped_buf.len) {
                    unescaped_buf[unescaped_len] = c;
                    unescaped_len += 1;
                }
                i += 1;
            }
        } else {
            if (c == ',') {
                if (!first_field) {
                    // nothing before bracket
                }
                if (has_quotes) {
                    stdout.print("[{s}]", .{unescaped_buf[0..unescaped_len]}) catch {};
                    unescaped_len = 0;
                    has_quotes = false;
                } else {
                    stdout.print("[{s}]", .{line[field_start..i]}) catch {};
                }
                first_field = false;
                i += 1;
                field_start = i;
            } else if (c == '"') {
                if (i == field_start) {
                    in_quotes = true;
                    has_quotes = true;
                    unescaped_len = 0;
                    i += 1;
                } else {
                    return ParseError.UnexpectedQuote;
                }
            } else {
                i += 1;
            }
        }
    }

    if (in_quotes) {
        return ParseError.UnclosedQuote;
    }

    // Last field
    if (has_quotes) {
        stdout.print("[{s}]", .{unescaped_buf[0..unescaped_len]}) catch {};
    } else {
        stdout.print("[{s}]", .{line[field_start..]}) catch {};
    }

    stdout.writeAll("\n") catch {};
}

const RecordIterator = struct {
    input: []const u8,
    pos: usize,

    fn next(self: *RecordIterator) ?[]const u8 {
        if (self.pos >= self.input.len) return null;

        var i = self.pos;
        var in_quotes = false;

        while (i < self.input.len) {
            const c = self.input[i];
            if (c == '"') {
                in_quotes = !in_quotes;
                i += 1;
            } else if (!in_quotes and i + 1 < self.input.len and c == '\r' and self.input[i + 1] == '\n') {
                const record = self.input[self.pos..i];
                self.pos = i + 2;
                return record;
            } else if (!in_quotes and c == '\n') {
                const record = self.input[self.pos..i];
                self.pos = i + 1;
                return record;
            } else {
                i += 1;
            }
        }

        // Last record without trailing newline (Rule 2)
        const record = self.input[self.pos..];
        self.pos = self.input.len;
        return record;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args: []const []const u8 = @ptrCast(raw_args);

    if (args.len < 2) {
        var buf: [256]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buf);
        writer.interface.writeAll("Usage: csv parse\n") catch {};
        writer.interface.flush() catch {};
        std.process.exit(1);
    }

    if (!std.mem.eql(u8, args[1], "parse")) {
        var buf: [256]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buf);
        writer.interface.print("Unknown command: {s}\n", .{args[1]}) catch {};
        writer.interface.flush() catch {};
        std.process.exit(1);
    }

    var stdin_reader = std.Io.File.stdin().reader(io, &.{});
    const input = stdin_reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return stdin_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
    defer allocator.free(input);

    var stdout_buf: [65536]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var iter = RecordIterator{ .input = input, .pos = 0 };
    while (iter.next()) |record| {
        parseAndPrintRecord(record, stdout) catch |err| {
            stdout.flush() catch {};
            var stderr_buf: [256]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
            const stderr = &stderr_writer.interface;
            switch (err) {
                ParseError.UnexpectedQuote => stderr.writeAll("error: unexpected quote in unquoted field\n") catch {},
                ParseError.UnclosedQuote => stderr.writeAll("error: unclosed quote\n") catch {},
            }
            stderr.flush() catch {};
            std.process.exit(1);
        };
    }

    stdout.flush() catch {};
}
