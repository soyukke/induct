const std = @import("std");

pub const Command = union(enum) {
    run: RunArgs,
    run_dir: RunDirArgs,
    init_cmd: InitArgs,
    validate_cmd: ValidateArgs,
    mcp: void,
    version: void,
    help: void,
};

pub const RunArgs = struct {
    spec_path: []const u8,
    verbose: bool = false,
    json_output: bool = false,
    junit_output: bool = false,
    fail_fast: bool = false,
    dry_run: bool = false,
};

pub const RunDirArgs = struct {
    dir_path: []const u8,
    verbose: bool = false,
    json_output: bool = false,
    junit_output: bool = false,
    fail_fast: bool = false,
    dry_run: bool = false,
    filter: ?[]const u8 = null,
    max_jobs: usize = 1,
};

pub const InitArgs = struct {
    output_path: ?[]const u8 = null,
    with_setup: bool = false,
};

pub const ValidateArgs = struct {
    spec_path: []const u8,
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
    var junit_output = false;
    var fail_fast = false;
    var dry_run = false;
    var with_setup = false;
    var filter: ?[]const u8 = null;
    var max_jobs: usize = 1;
    var positional: ?[]const u8 = null;

    // Parse options and positional args
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--junit")) {
            junit_output = true;
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            fail_fast = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--with-setup")) {
            with_setup = true;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            filter = arg["--filter=".len..];
        } else if (std.mem.eql(u8, arg, "-j")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            max_jobs = std.fmt.parseInt(usize, args[i], 10) catch return ParseError.InvalidOption;
        } else if (std.mem.startsWith(u8, arg, "-j")) {
            max_jobs = std.fmt.parseInt(usize, arg[2..], 10) catch return ParseError.InvalidOption;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (positional == null) positional = arg;
        }
    }

    if (std.mem.eql(u8, cmd, "run")) {
        if (positional == null) {
            return ParseError.MissingArgument;
        }
        return Command{
            .run = .{
                .spec_path = positional.?,
                .verbose = verbose,
                .json_output = json_output,
                .junit_output = junit_output,
                .fail_fast = fail_fast,
                .dry_run = dry_run,
            },
        };
    } else if (std.mem.eql(u8, cmd, "run-dir")) {
        if (positional == null) {
            return ParseError.MissingArgument;
        }
        return Command{
            .run_dir = .{
                .dir_path = positional.?,
                .verbose = verbose,
                .json_output = json_output,
                .junit_output = junit_output,
                .fail_fast = fail_fast,
                .dry_run = dry_run,
                .filter = filter,
                .max_jobs = max_jobs,
            },
        };
    } else if (std.mem.eql(u8, cmd, "init")) {
        return Command{
            .init_cmd = .{
                .output_path = positional,
                .with_setup = with_setup,
            },
        };
    } else if (std.mem.eql(u8, cmd, "validate")) {
        if (positional == null) {
            return ParseError.MissingArgument;
        }
        return Command{
            .validate_cmd = .{
                .spec_path = positional.?,
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

test "parse init command" {
    const args = [_][]const u8{ "induct", "init" };
    const result = try parseArgs(&args);

    switch (result) {
        .init_cmd => |init_args| {
            try std.testing.expect(init_args.output_path == null);
            try std.testing.expect(!init_args.with_setup);
        },
        else => try std.testing.expect(false),
    }
}

test "parse init command with path and --with-setup" {
    const args = [_][]const u8{ "induct", "init", "--with-setup", "my-spec.yaml" };
    const result = try parseArgs(&args);

    switch (result) {
        .init_cmd => |init_args| {
            try std.testing.expectEqualStrings("my-spec.yaml", init_args.output_path.?);
            try std.testing.expect(init_args.with_setup);
        },
        else => try std.testing.expect(false),
    }
}

test "parse validate command" {
    const args = [_][]const u8{ "induct", "validate", "test.yaml" };
    const result = try parseArgs(&args);

    switch (result) {
        .validate_cmd => |val_args| {
            try std.testing.expectEqualStrings("test.yaml", val_args.spec_path);
        },
        else => try std.testing.expect(false),
    }
}

test "parse run-dir with filter and parallel" {
    const args = [_][]const u8{ "induct", "run-dir", "--filter", "echo", "-j", "4", "--fail-fast", "specs/" };
    const result = try parseArgs(&args);

    switch (result) {
        .run_dir => |run_args| {
            try std.testing.expectEqualStrings("specs/", run_args.dir_path);
            try std.testing.expectEqualStrings("echo", run_args.filter.?);
            try std.testing.expectEqual(@as(usize, 4), run_args.max_jobs);
            try std.testing.expect(run_args.fail_fast);
        },
        else => try std.testing.expect(false),
    }
}
