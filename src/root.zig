pub const core = struct {
    pub const spec = @import("core/spec.zig");
    pub const result = @import("core/result.zig");
    pub const validator = @import("core/validator.zig");
    pub const executor = @import("core/executor.zig");
    pub const path_extractor = @import("core/path_extractor.zig");

    pub const Spec = spec.Spec;
    pub const TestCase = spec.TestCase;
    pub const SetupCommand = spec.SetupCommand;
    pub const TeardownCommand = spec.TeardownCommand;
    pub const SpecResult = result.SpecResult;
    pub const SpecStatus = result.SpecStatus;
    pub const GenerateInfo = result.GenerateInfo;
    pub const RunSummary = result.RunSummary;
    pub const extractTestPath = path_extractor.extractTestPath;
    pub const detectFramework = path_extractor.detectFramework;
};

pub const cli = struct {
    pub const args = @import("cli/args.zig");
    pub const reporter = @import("cli/reporter.zig");

    pub const Command = args.Command;
    pub const Reporter = reporter.Reporter;
};

pub const mcp = struct {
    pub const server = @import("mcp/server.zig");
    pub const jsonrpc = @import("mcp/jsonrpc.zig");
    pub const handlers = @import("mcp/handlers.zig");
    pub const types = @import("mcp/types.zig");

    pub const McpServer = server.McpServer;
};

pub const yaml = struct {
    pub const parser = @import("yaml/parser.zig");

    pub const parseSpec = parser.parseSpec;
    pub const parseSpecFromFile = parser.parseSpecFromFile;
};

pub const process = struct {
    pub const runner = @import("process/runner.zig");

    pub const runCommand = runner.runCommand;
    pub const ProcessResult = runner.ProcessResult;
};

test {
    @import("std").testing.refAllDecls(@This());
}
