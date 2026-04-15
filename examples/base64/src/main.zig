const std = @import("std");

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn encode(input: []const u8, writer: anytype) !void {
    var i: usize = 0;
    while (i < input.len) {
        const remaining = input.len - i;

        const b0: u32 = input[i];
        const b1: u32 = if (remaining > 1) input[i + 1] else 0;
        const b2: u32 = if (remaining > 2) input[i + 2] else 0;

        const triple = (b0 << 16) | (b1 << 8) | b2;

        try writer.writeByte(base64_alphabet[(triple >> 18) & 0x3F]);
        try writer.writeByte(base64_alphabet[(triple >> 12) & 0x3F]);

        if (remaining > 1) {
            try writer.writeByte(base64_alphabet[(triple >> 6) & 0x3F]);
        } else {
            try writer.writeByte('=');
        }

        if (remaining > 2) {
            try writer.writeByte(base64_alphabet[triple & 0x3F]);
        } else {
            try writer.writeByte('=');
        }

        i += 3;
    }
}

fn decodeChar(c: u8) !u6 {
    if (c >= 'A' and c <= 'Z') return @intCast(c - 'A');
    if (c >= 'a' and c <= 'z') return @intCast(c - 'a' + 26);
    if (c >= '0' and c <= '9') return @intCast(c - '0' + 52);
    if (c == '+') return 62;
    if (c == '/') return 63;
    return error.InvalidCharacter;
}

fn decode(input: []const u8, writer: anytype) !void {
    if (input.len == 0) return;
    if (input.len % 4 != 0) {
        return error.InvalidLength;
    }

    var i: usize = 0;
    while (i < input.len) {
        const c0 = decodeChar(input[i]) catch return error.InvalidCharacter;
        const c1 = decodeChar(input[i + 1]) catch return error.InvalidCharacter;

        const triple: u32 = (@as(u32, c0) << 18) | (@as(u32, c1) << 12);
        writer.writeByte(@intCast((triple >> 16) & 0xFF)) catch return error.WriteError;

        if (input[i + 2] != '=') {
            const c2 = decodeChar(input[i + 2]) catch return error.InvalidCharacter;
            const triple2 = triple | (@as(u32, c2) << 6);
            writer.writeByte(@intCast((triple2 >> 8) & 0xFF)) catch return error.WriteError;

            if (input[i + 3] != '=') {
                const c3 = decodeChar(input[i + 3]) catch return error.InvalidCharacter;
                const triple3 = triple2 | @as(u32, c3);
                writer.writeByte(@intCast(triple3 & 0xFF)) catch return error.WriteError;
            }
        } else if (input[i + 3] != '=') {
            return error.InvalidPadding;
        }

        i += 4;
    }
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 2) {
        var buf: [256]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buf);
        writer.interface.writeAll("Usage: base64 <encode|decode>\n") catch {};
        writer.interface.flush() catch {};
        std.process.exit(1);
    }

    const stdin = std.fs.File.stdin();
    const input = try stdin.readToEndAlloc(std.heap.page_allocator, 10 * 1024 * 1024);
    defer std.heap.page_allocator.free(input);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, args[1], "encode")) {
        encode(input, stdout) catch {
            std.process.exit(1);
        };
        stdout.flush() catch {};
    } else if (std.mem.eql(u8, args[1], "decode")) {
        decode(input, stdout) catch |err| {
            var stderr_buf: [256]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
            const stderr = &stderr_writer.interface;
            switch (err) {
                error.InvalidCharacter => stderr.writeAll("error: invalid base64 character\n") catch {},
                error.InvalidLength => stderr.writeAll("error: invalid base64 length\n") catch {},
                error.InvalidPadding => stderr.writeAll("error: invalid base64 padding\n") catch {},
                else => stderr.writeAll("error: decode failed\n") catch {},
            }
            stderr.flush() catch {};
            std.process.exit(1);
        };
        stdout.flush() catch {};
    } else {
        var buf: [256]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buf);
        writer.interface.writeAll("Usage: base64 <encode|decode>\n") catch {};
        writer.interface.flush() catch {};
        std.process.exit(1);
    }
}
