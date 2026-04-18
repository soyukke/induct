# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Induct is an executable specification engine for AI-driven development, written in Zig. YAML で振る舞いを定義し、コマンド一つで検証する。言語やフレームワークに依存しない。

## Build Commands

```bash
nix develop            # Enter the pinned Zig 0.16.0 dev shell
zig build              # Compile the project
zig build run          # Run the executable
zig build run -- [args]  # Run with arguments (e.g., zig build run -- run specs/examples/echo.yaml)
zig build test         # Run all tests (unit tests for both root module and exe module)
```

Requires Zig 0.16.0 or later. Output binary: `zig-out/bin/induct`

### Self-Test (Regression Check)

Induct uses itself for integration testing. After building, run the full self-test suite:

```bash
zig build && ./zig-out/bin/induct run specs/inductspec.yaml
```

To run a single spec file:

```bash
./zig-out/bin/induct run specs/cli/help.yaml
```

## Architecture

```
src/
├── main.zig           # CLI entry point
├── root.zig           # Public module exports
├── VERSION            # Single-line version string (e.g., "0.2.1"), read at build time
├── cli/
│   ├── args.zig       # Argument parsing (Command union type)
│   └── reporter.zig   # Text/JSON/JUnit output formatting, schema/help output
├── core/
│   ├── spec.zig       # Spec, TestCase, ProjectSpec, SetupCommand, TeardownCommand structs
│   ├── result.zig     # SpecResult, RunSummary types
│   ├── executor.zig   # Spec execution engine (executeSpec, executeSpecFromFile, executeSpecsFromDir)
│   └── validator.zig  # Output and exit code validation
├── process/
│   └── runner.zig     # Shell command execution (sh -c wrapper, stdin/stdout capture)
└── yaml/
    └── parser.zig     # Custom YAML parser (no external dependencies)
```

### Data Flow

1. CLI (`args.zig`) parses command + flags → `Command` union
2. `reporter.zig` dispatches to the appropriate handler
3. For `run`/`run-dir`: YAML file → `parser.zig` → `Spec` or `ProjectSpec` → `executor.zig`
4. `executor.zig` runs commands via `runner.zig`, validates output via `validator.zig` → `SpecResult`
5. Results formatted by `reporter.zig` (text/JSON/JUnit)

### ProjectSpec (Spec Aggregation)

`ProjectSpec` (`spec.zig`) aggregates multiple specs via two mechanisms:
- `specs:` — inline spec definitions within the YAML
- `include:` — references to external spec YAML files (relative paths)

`specs/inductspec.yaml` is the root ProjectSpec that includes all test suites. New specs should be added to the appropriate `specs/` subdirectory and registered in `inductspec.yaml`'s `include:` list. Any YAML file with top-level `include:` or `specs:` keys is auto-detected as a ProjectSpec.

## CLI Usage

```bash
induct run <spec.yaml>       # Run a spec and verify results
induct run-dir <dir>         # Run all specs in a directory
induct validate <spec.yaml>  # Validate spec syntax without executing
induct schema                # Show YAML spec schema reference
induct init [file.yaml]      # Generate template spec file
induct list <spec.yaml>      # List spec names
induct version               # Show version
induct help                  # Show help
```

Flags: `-v/--verbose`, `--json`, `--junit`, `--fail-fast`, `--dry-run`, `--filter <pattern>`, `-j <N>`, `--with-setup`

## YAML Spec Format

```yaml
name: spec name
description: optional description

vars:                                     # Optional: template variables
  BIN: ./my-tool                          #   Expanded as ${BIN} in commands

setup:                                    # Optional pre-test commands
  - run: echo "setup"

test:
  command: ${BIN} hello                   # Required: command to execute
  input: "stdin data"                     # Optional: stdin input
  expect_output: "hello\n"               # Optional: exact output match
  expect_output_contains: "llo"          # Optional: substring match
  expect_output_not_contains: "error"    # Optional: negative substring match
  expect_output_regex: "hel+"            # Optional: regex match (POSIX ERE)
  expect_stderr: "warn\n"               # Optional: exact stderr match
  expect_stderr_contains: "warn"         # Optional: stderr substring match
  expect_stderr_regex: "warn.*"          # Optional: stderr regex (POSIX ERE)
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

### Table-Driven Spec (test_table: replaces test:/steps:)

```yaml
name: RFC 4648 Base64 encoding
test_table:
  command: "printf '${input}' | ./base64 encode"
  cases:
    - input: f
      expect_output: "Zg=="
    - input: foo
      expect_output_contains: "m9"
    - input: "!!"
      expect_exit_code: 1
```

`${var}` in command is replaced per case. Each case can use any `expect_*` assertion. Expanded to steps internally.

### ProjectSpec Auto-Detection

ProjectSpec is detected by:
1. Filename ending with `inductspec.yaml` (convention)
2. Content having top-level `include:` or `specs:` keys (auto-detection)

Any YAML file with `include:` or `specs:` is treated as a ProjectSpec regardless of filename.

## Key Implementation Details

- Process execution uses `sh -c` wrapper via `std.process.Child`
- YAML parser is custom-built (no dependencies) in `yaml/parser.zig`
- Executor generates unique run IDs using timestamp + counter
- Output capture limited to 10MB per command
- Version is stored in `src/VERSION` (single line, no newline) and also in `build.zig.zon`

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
zig build && ./zig-out/bin/induct run specs/inductspec.yaml
```

### Spec Organization

```
specs/
├── inductspec.yaml      # Root ProjectSpec (includes all test suites)
├── cli/                 # CLI behavior specs
├── execution/           # Spec execution specs
├── errors/              # Error handling specs
└── examples/            # Example specs
```
