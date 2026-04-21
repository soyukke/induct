# URI Example (RFC 3986)

`examples/uri` は RFC 3986 の URI 解析と参照解決を実装した CLI です。

## Build

```bash
cd examples/uri
zig build
```

## Commands

```bash
./zig-out/bin/uri parse
./zig-out/bin/uri resolve
```

## Specs

- Project spec: `examples/uri/inductspec.yaml`
- Canonical RFC specs: `examples/uri/specs/*.yaml`

Run from repository root:

```bash
./zig-out/bin/induct run examples/uri/inductspec.yaml
```
