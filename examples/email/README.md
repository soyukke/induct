# Email Example (RFC 5322)

`examples/email` は RFC 5322 の主要要素を扱う CLI 実装です。

## Build

```bash
cd examples/email
zig build
```

## Commands

```bash
./zig-out/bin/email unfold
./zig-out/bin/email strip-comments
./zig-out/bin/email unescape
./zig-out/bin/email parse-address
./zig-out/bin/email parse-addresses
./zig-out/bin/email parse-date
./zig-out/bin/email parse-message
```

## Specs

- Project spec: `examples/email/inductspec.yaml`
- Canonical RFC specs: `examples/email/specs/*.yaml`

Run from repository root:

```bash
./zig-out/bin/induct run examples/email/inductspec.yaml
```
