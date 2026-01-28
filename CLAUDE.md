# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Induct is an executable specification engine for AI-era TDD, written in Zig. It executes test specifications defined in YAML files that validate command execution, output, and exit codes.

## Build Commands

```bash
zig build              # Compile the project
zig build run          # Run the executable
zig build run -- [args]  # Run with arguments (e.g., zig build run -- run specs/examples/echo.yaml)
zig build test         # Run all tests
```

Requires Zig 0.15.2 or later. Output binary: `zig-out/bin/induct`

## Architecture

```
src/
├── main.zig           # CLI entry point
├── root.zig           # Public module exports
├── cli/
│   ├── args.zig       # Argument parsing (Command union type)
│   └── reporter.zig   # Text and JSON output formatting
├── core/
│   ├── spec.zig       # Spec, TestCase, SetupCommand, TeardownCommand structs
│   ├── result.zig     # SpecResult, RunSummary types
│   ├── executor.zig   # Test execution engine (executeSpec, executeSpecFromFile, executeSpecsFromDir)
│   └── validator.zig  # Output and exit code validation
├── mcp/
│   ├── server.zig     # MCP server (Model Context Protocol 2024-11-05)
│   ├── jsonrpc.zig    # JSON-RPC request/response handling
│   ├── handlers.zig   # MCP tool handlers with result caching
│   └── types.zig      # MCP type definitions
├── process/
│   └── runner.zig     # Shell command execution (sh -c wrapper, stdin/stdout capture)
└── yaml/
    └── parser.zig     # Custom YAML parser (no external dependencies)
```

## YAML Spec Format

```yaml
name: spec name
description: optional description

setup:                          # Optional pre-test commands
  - run: echo "setup"

test:
  command: echo hello           # Required: command to execute
  input: "stdin data"           # Optional: stdin input
  expect_output: "hello\n"      # Optional: exact output match
  expect_output_contains: "llo" # Optional: substring match
  expect_exit_code: 0           # Optional: expected exit code

teardown:                       # Optional cleanup
  - run: rm -f /tmp/test.txt
  - kill_process: server        # Kill named process
```

## CLI Usage

```bash
induct run <spec.yaml>     # Run single spec
induct run-dir <dir>       # Run all .yaml/.yml specs in directory
induct mcp                 # Start MCP server mode
induct version             # Show version
induct help                # Show help
```

Flags: `-v/--verbose`, `--json`

## Key Implementation Details

- Process execution uses `sh -c` wrapper via `std.process.Child`
- YAML parser is custom-built (no dependencies) in `yaml/parser.zig`
- Executor generates unique run IDs using timestamp + counter
- MCP server uses line-based JSON-RPC protocol with result caching
- Output capture limited to 10MB per command

## Development Flow (TDD with Induct MCP)

When adding features or fixing bugs in this project, use the following flow:

### 1. Write Spec First

Create a YAML spec file in `specs/` that describes the expected behavior:

```yaml
name: new feature test
description: |
  Description of what this feature should do.
  Be specific about inputs and expected outputs.
test:
  command: ./zig-out/bin/induct <args>
  expect_output_contains: "expected text"
  expect_exit_code: 0
```

### 2. Run Spec to Confirm Failure

```
mcp__induct__run_spec({ path: "specs/path/to/spec.yaml" })
```

The spec should fail (RED phase).

### 3. Implement the Feature

Write the minimal code to make the spec pass.

### 4. Run Spec to Verify

```
mcp__induct__run_spec({ path: "specs/path/to/spec.yaml" })
```

The spec should pass (GREEN phase).

### 5. Run All Specs

Ensure no regressions:

```
mcp__induct__run_spec({ path: "specs/inductspec.yaml" })
```

### Available MCP Tools

- `mcp__induct__run_spec`: Execute a spec and return results
- `mcp__induct__list_specs`: List spec files in a directory
- `mcp__induct__read_spec`: Read spec file contents
- `mcp__induct__get_schema`: Get YAML schema reference

### Spec Organization

```
specs/
├── inductspec.yaml      # Project spec (includes other specs)
├── cli/                 # CLI behavior specs
├── execution/           # Spec execution specs
├── errors/              # Error handling specs
└── examples/            # Example specs
```
