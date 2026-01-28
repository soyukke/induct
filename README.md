# Induct

Induct code from tests.

## Quick Start

### 1. MCP Setup

Add to your Claude Code config:

```json
{
  "mcpServers": {
    "induct": {
      "command": "npx",
      "args": ["-y", "induct", "mcp"]
    }
  }
}
```

### 2. Write a Spec with AI

Ask Claude Code:

```
"Write a spec to test the health endpoint at localhost:8080"
```

Claude calls `get_schema` to learn the spec format, then creates `specs/api-health.yaml`:

```yaml
name: API health check
description: Verify health endpoint responds correctly

test:
  command: curl -s http://localhost:8080/health
  expect_output_contains: '"status":"ok"'
  expect_exit_code: 0
```

### 3. Run and Iterate

```
"Run the spec"
```

Claude calls `run_spec` → test fails (RED)

```
"Implement the health endpoint to pass the spec"
```

Claude writes code → runs spec again → test passes (GREEN)

## MCP Tools

| Tool | Description |
|------|-------------|
| `run_spec` | Execute a spec file |
| `list_specs` | List specs in a directory |
| `read_spec` | Read spec file contents |
| `get_schema` | Get YAML schema reference |

## Spec Examples

### Verify command output

```yaml
name: echo test
test:
  command: echo "hello"
  expect_output: "hello\n"
```

### Verify API response

```yaml
name: POST /users
test:
  command: curl -s -X POST -H "Content-Type: application/json" -d '{"name":"alice"}' http://localhost:8080/users
  expect_output_contains: '"id":'
  expect_exit_code: 0
```

### Verify HTTP status code

```yaml
name: returns 404
test:
  command: curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/notfound
  expect_output: "404"
```

### Setup and teardown

```yaml
name: file creation test
setup:
  - run: mkdir -p /tmp/test

test:
  command: ls /tmp/test
  expect_exit_code: 0

teardown:
  - run: rm -rf /tmp/test
```

## Spec Format

```yaml
name: string           # Required: spec name
description: string    # Optional: description

setup:                 # Optional: pre-test commands
  - run: string

test:
  command: string              # Required: command to execute
  input: string                # Optional: stdin input
  expect_output: string        # Optional: exact match
  expect_output_contains: string  # Optional: substring match
  expect_exit_code: number     # Optional: exit code (default: 0)

teardown:              # Optional: post-test commands
  - run: string
  - kill_process: string
```

## CLI

```bash
induct run <spec.yaml>      # Run a spec
induct run-dir <dir>        # Run all specs in directory
induct mcp                  # Start MCP server
induct help                 # Show help
```

## Build

```bash
git clone https://github.com/soyukke/induct.git
cd induct
zig build
```

Requires Zig 0.15.0+

## License

MIT
