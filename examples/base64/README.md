# Base64 Example (RFC 4648)

`examples/base64` は RFC 4648 の Base64 エンコード/デコードを実装した CLI です。

## Build

```bash
cd examples/base64
zig build
```

## Commands

```bash
./zig-out/bin/base64 encode
./zig-out/bin/base64 decode
```

## Specs

- Project spec: `examples/base64/inductspec.yaml`
- Canonical RFC specs: `examples/base64/specs/*.yaml`

Run from repository root:

```bash
./zig-out/bin/induct run examples/base64/inductspec.yaml
```
