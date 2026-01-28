const std = @import("std");

pub const Command = union(enum) {
    run: RunArgs,
    run_dir: RunDirArgs,
    mcp: void,
    version: void,
    help: void,
};

pub const RunArgs = struct {
    spec_path: []const u8,
    verbose: bool = false,
    json_output: bool = false,
};

pub const RunDirArgs = struct {
    dir_path: []const u8,
    verbose: bool = false,
    json_output: bool = false,
};

pub const ParseError = error{
    MissingCommand,
    MissingArgument,
    UnknownCommand,
    InvalidOption,
};

pub fn parseArgs(args: []const []const u8) ParseError!Command {
    if (args.len < 2) {
        return ParseError.MissingCommand;
    }

    const cmd = args[1];
    var verbose = false;
    var json_output = false;

    // Parse global options
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            break;
        }
    }

    if (std.mem.eql(u8, cmd, "run")) {
        if (i >= args.len) {
            return ParseError.MissingArgument;
        }
        return Command{
            .run = .{
                .spec_path = args[i],
                .verbose = verbose,
                .json_output = json_output,
            },
        };
    } else if (std.mem.eql(u8, cmd, "run-dir")) {
        if (i >= args.len) {
            return ParseError.MissingArgument;
        }
        return Command{
            .run_dir = .{
                .dir_path = args[i],
                .verbose = verbose,
                .json_output = json_output,
            },
        };
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        return Command.mcp;
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        return Command.version;
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return Command.help;
    }

    return ParseError.UnknownCommand;
}

test "parse run command" {
    const args = [_][]const u8{ "induct", "run", "test.yaml" };
    const result = try parseArgs(&args);

    switch (result) {
        .run => |run_args| {
            try std.testing.expectEqualStrings("test.yaml", run_args.spec_path);
            try std.testing.expect(!run_args.verbose);
        },
        else => try std.testing.expect(false),
    }
}

test "parse run command with verbose" {
    const args = [_][]const u8{ "induct", "run", "-v", "test.yaml" };
    const result = try parseArgs(&args);

    switch (result) {
        .run => |run_args| {
            try std.testing.expectEqualStrings("test.yaml", run_args.spec_path);
            try std.testing.expect(run_args.verbose);
        },
        else => try std.testing.expect(false),
    }
}

test "parse run-dir command" {
    const args = [_][]const u8{ "induct", "run-dir", "specs/" };
    const result = try parseArgs(&args);

    switch (result) {
        .run_dir => |run_args| {
            try std.testing.expectEqualStrings("specs/", run_args.dir_path);
        },
        else => try std.testing.expect(false),
    }
}

test "parse help command" {
    const args = [_][]const u8{ "induct", "help" };
    const result = try parseArgs(&args);

    try std.testing.expect(result == .help);
}

test "parse version command" {
    const args = [_][]const u8{ "induct", "version" };
    const result = try parseArgs(&args);

    try std.testing.expect(result == .version);
}
