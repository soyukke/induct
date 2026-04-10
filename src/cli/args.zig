const std = @import("std");

pub const Command = union(enum) {
    run: RunArgs,
    run_dir: RunDirArgs,
    init_cmd: InitArgs,
    validate_cmd: ValidateArgs,
    list_cmd: ListArgs,
    schema: void,
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
    filter: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    max_jobs: usize = 1,
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
    timeout_ms: ?u64 = null,
};

pub const TemplateType = enum {
    basic,
    setup,
    api,
    cli_tool,
    project,
};

pub const InitArgs = struct {
    output_path: ?[]const u8 = null,
    with_setup: bool = false,
    template: TemplateType = .basic,
};

pub const ValidateArgs = struct {
    spec_path: []const u8,
};

pub const ListArgs = struct {
    dir_path: []const u8,
    markdown: bool = false,
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
    var markdown = false;
    var template: TemplateType = .basic;
    var filter: ?[]const u8 = null;
    var max_jobs: usize = 1;
    var timeout_ms: ?u64 = null;
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
        } else if (std.mem.eql(u8, arg, "--markdown")) {
            markdown = true;
        } else if (std.mem.eql(u8, arg, "--template")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            template = parseTemplateType(args[i]) orelse return ParseError.InvalidOption;
        } else if (std.mem.startsWith(u8, arg, "--template=")) {
            template = parseTemplateType(arg["--template=".len..]) orelse return ParseError.InvalidOption;
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
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            timeout_ms = std.fmt.parseInt(u64, args[i], 10) catch return ParseError.InvalidOption;
        } else if (std.mem.startsWith(u8, arg, "--timeout-ms=")) {
            timeout_ms = std.fmt.parseInt(u64, arg["--timeout-ms=".len..], 10) catch return ParseError.InvalidOption;
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
                .filter = filter,
                .timeout_ms = timeout_ms,
                .max_jobs = max_jobs,
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
                .timeout_ms = timeout_ms,
            },
        };
    } else if (std.mem.eql(u8, cmd, "init")) {
        const effective_template = if (with_setup and template == .basic) TemplateType.setup else template;
        return Command{
            .init_cmd = .{
                .output_path = positional,
                .with_setup = with_setup,
                .template = effective_template,
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
    } else if (std.mem.eql(u8, cmd, "list")) {
        if (positional == null) {
            return ParseError.MissingArgument;
        }
        return Command{
            .list_cmd = .{
                .dir_path = positional.?,
                .markdown = markdown,
            },
        };
    } else if (std.mem.eql(u8, cmd, "schema")) {
        return Command.schema;
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        return Command.version;
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return Command.help;
    }

    return ParseError.UnknownCommand;
}

fn parseTemplateType(s: []const u8) ?TemplateType {
    if (std.mem.eql(u8, s, "basic")) return .basic;
    if (std.mem.eql(u8, s, "setup")) return .setup;
    if (std.mem.eql(u8, s, "api")) return .api;
    if (std.mem.eql(u8, s, "cli")) return .cli_tool;
    if (std.mem.eql(u8, s, "project")) return .project;
    return null;
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

test "parse run command with filter" {
    const args = [_][]const u8{ "induct", "run", "--filter", "echo", "test.yaml" };
    const result = try parseArgs(&args);

    switch (result) {
        .run => |run_args| {
            try std.testing.expectEqualStrings("test.yaml", run_args.spec_path);
            try std.testing.expectEqualStrings("echo", run_args.filter.?);
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
