# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Induct is an executable specification engine for AI-driven development, written in Zig. YAML で振る舞いを定義し、コマンド一つで検証する。言語やフレームワークに依存しない。

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
│   └── reporter.zig   # Text/JSON/JUnit output formatting, schema/help output
├── core/
│   ├── spec.zig       # Spec, TestCase, SetupCommand, TeardownCommand structs
│   ├── result.zig     # SpecResult, RunSummary types
│   ├── executor.zig   # Spec execution engine (executeSpec, executeSpecFromFile, executeSpecsFromDir)
│   └── validator.zig  # Output and exit code validation
├── process/
│   └── runner.zig     # Shell command execution (sh -c wrapper, stdin/stdout capture)
└── yaml/
    └── parser.zig     # Custom YAML parser (no external dependencies)
```

## CLI Usage

```bash
induct run <spec.yaml>       # Run a spec and verify results
induct run-dir <dir>         # Run all specs in a directory
induct validate <spec.yaml>  # Validate spec syntax without executing
induct schema                # Show YAML spec schema reference
induct init [file.yaml]      # Generate template spec file
induct version               # Show version
induct help                  # Show help
```

Flags: `-v/--verbose`, `--json`, `--junit`, `--fail-fast`, `--dry-run`, `--filter <pattern>`, `-j <N>`, `--with-setup`

## YAML Spec Format

```yaml
name: spec name
description: optional description

setup:                                    # Optional pre-test commands
  - run: echo "setup"

test:
  command: echo hello                     # Required: command to execute
  input: "stdin data"                     # Optional: stdin input
  expect_output: "hello\n"               # Optional: exact output match
  expect_output_contains: "llo"          # Optional: substring match
  expect_output_not_contains: "error"    # Optional: negative substring match
  expect_output_regex: "hel+"            # Optional: regex match (POSIX ERE)
  expect_stderr: "warn\n"               # Optional: exact stderr match
  expect_stderr_contains: "warn"         # Optional: stderr substring match
  expect_exit_code: 0                    # Optional: expected exit code (default: 0)
  env:                                   # Optional: environment variables
    KEY: value
  working_dir: /path/to/dir             # Optional: working directory
  timeout_ms: 5000                       # Optional: timeout in milliseconds

teardown:                                # Optional cleanup
  - run: rm -f /tmp/test.txt
  - kill_process: server                 # Kill named process
```

### Multi-Step Spec (steps: replaces test:)

```yaml
name: scenario name
steps:
  - name: step one
    command: echo hello
    expect_output: "hello\n"
  - name: step two
    command: echo world
    expect_output_contains: "world"
```

Steps execute sequentially. If one fails, remaining steps are skipped.

## Key Implementation Details

- Process execution uses `sh -c` wrapper via `std.process.Child`
- YAML parser is custom-built (no dependencies) in `yaml/parser.zig`
- Executor generates unique run IDs using timestamp + counter
- Output capture limited to 10MB per command

## Development Flow (Induct-Driven Development)

When adding features or fixing bugs in this project, use the following flow:

### 1. Check the Schema

```bash
induct schema
```

### 2. Write Spec First

Create a YAML spec file in `specs/` that describes the expected behavior:

```yaml
name: new feature test
description: |
  Description of what this feature should do.
test:
  command: ./zig-out/bin/induct <args>
  expect_output_contains: "expected text"
  expect_exit_code: 0
```

### 3. Validate and Run (RED)

```bash
induct validate specs/path/to/spec.yaml
induct run specs/path/to/spec.yaml
```

The spec should fail (RED phase).

### 4. Implement the Feature

Write the minimal code to make the spec pass.

### 5. Run Spec to Verify (GREEN)

```bash
induct run specs/path/to/spec.yaml
```

### 6. Run All Specs (No Regressions)

```bash
induct run specs/inductspec.yaml
```

### Spec Organization

```
specs/
├── inductspec.yaml      # Project spec (includes other specs)
├── cli/                 # CLI behavior specs
├── execution/           # Spec execution specs
├── errors/              # Error handling specs
└── examples/            # Example specs
```
