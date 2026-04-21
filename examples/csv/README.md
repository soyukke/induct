# CSV Example (RFC 4180)

`examples/csv` は RFC 4180 の CSV 解析を実装した CLI です。

## Build

```bash
cd examples/csv
zig build
```

## Commands

```bash
./zig-out/bin/csv parse
```

## Specs

- Project spec: `examples/csv/inductspec.yaml`
- Canonical RFC specs: `examples/csv/specs/*.yaml`

Run from repository root:

```bash
./zig-out/bin/induct run examples/csv/inductspec.yaml
```
