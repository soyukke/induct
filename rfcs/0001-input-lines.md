# RFC 0001: input_lines フィールドの追加

## 概要

テストケースの stdin 入力を行単位で記述できる `input_lines` フィールドを追加し、
YAML エスケープの複雑さを解消する。

## 動機

RFC 4180 (CSV) のような `"` を多用する仕様を Induct spec で記述すると、
YAML のエスケープが深刻な問題になる。

### 現状の問題: 3層エスケープ

CSV フィールドが `"` 1文字だけの場合のテスト:

```yaml
# 層: YAML double-quote → sh -c → printf
command: "printf '\"\"\"\",b\\r\\n' | ${CSV} parse"
```

`input:` フィールドを使っても YAML double-quoted string の制約は残る:

```yaml
# 層: YAML double-quote のみ（改善済みだが依然読みにくい）
input: "\"\"\"\",b\r\n"
```

### 根本原因

YAML の引用スタイルにはトレードオフがある:

| スタイル | `"` の扱い | `\r\n` の扱い |
|---------|-----------|--------------|
| `"..."` double-quoted | `\"` 必要 | `\r` `\n` 解釈される |
| `'...'` single-quoted | そのまま書ける | 解釈されない（リテラル） |
| `\|` block scalar | そのまま書ける | LF のみ（CRLF 不可） |

`"` をエスケープなしで書きたければ single-quoted を使うしかないが、
single-quoted では `\r\n` を表現できない。この二律背反を解消する必要がある。

## 提案

### `input_lines` フィールド

テストケースに `input_lines` フィールドを追加する。行のリストを受け取り、
指定された行末文字を各行の末尾に付与して結合し、stdin に渡す。

```yaml
input_lines:
  line_ending: crlf       # "crlf" | "lf" (デフォルト: "lf")
  trailing: true           # 最終行にも line_ending を付与するか (デフォルト: true)
  lines:
    - 'line 1 content'
    - 'line 2 content'
```

### 行末の種類

| 値 | バイト列 | 用途 |
|----|---------|------|
| `lf` | `\n` (0x0A) | Unix テキスト（デフォルト） |
| `crlf` | `\r\n` (0x0D 0x0A) | RFC 4180 等のネットワークプロトコル |

旧案にあった `none` は削除した。「改行種別」と「末尾改行を付けるか」は独立した概念であり、
混ぜると複数行で最後だけ改行なしのケースを表現できない。
代わりに `trailing: false` で最終行の改行を制御する。

### `trailing` フィールド

`trailing` は最終行の末尾に `line_ending` を付与するかを制御する。

| trailing | 動作 | 生成例（lines: ['a', 'b'], line_ending: crlf） |
|----------|------|-----------------------------------------------|
| `true`（デフォルト） | 全行に付与 | `a\r\nb\r\n` |
| `false` | 最終行以外に付与 | `a\r\nb` |

用途: RFC 4180 Rule 2（末尾改行なし）のテスト:

```yaml
# 末尾 CRLF あり（デフォルト）
input_lines:
  line_ending: crlf
  lines:
    - 'aaa,bbb'

# 末尾 CRLF なし
input_lines:
  line_ending: crlf
  trailing: false
  lines:
    - 'aaa,bbb'
```

### 短縮形

`line_ending` がデフォルト (`lf`) かつ `trailing` がデフォルト (`true`) の場合、
リストを直接書ける:

```yaml
input_lines:
  - 'line 1'
  - 'line 2'
```

これは以下と等価:

```yaml
input_lines:
  line_ending: lf
  trailing: true
  lines:
    - 'line 1'
    - 'line 2'
```

**注意: カスタムYAMLパーサーの制約**

Induct の YAML パーサーは以下の挙動がある。短縮形で single-quoted string を使う場合でも
これらのケースではクォートが必要:

- 未クォートの `:` は map のキーと解釈される（例: `Host: x`, `urn:foo`）
- 未クォート値の前後空白は除去される（末尾スペースが必要な場合はクォート必須）
- 未クォートの `true`/`false` は bool、数値文字列は integer として解釈される
  （`lines` 内では必ず single-quote で囲むことを推奨）
- 空行は空文字列 `''` として記述する

### `input:` との排他

`input:` と `input_lines:` は排他。両方指定した場合はパースエラー。

排他チェックは **parser 時点** で行う。理由: 現行の `validator.zig` は実行結果の
stdout/stderr 検証用であり、spec 構造の検証は担当外。parser でエラーにすれば
`induct validate` と `induct run` の両方で自動的に弾ける。

## 適用範囲

`input_lines` は以下のコンテキストで使用可能:

| コンテキスト | 対応 |
|-------------|------|
| `test:` | 対応 |
| `steps:` の各ステップ | 対応 |
| `test_table.cases` の個別ケース | 対応 |

`test_table` のテンプレートレベルでは `input_lines` を使用しない。
各ケースで完全な `input_lines` を指定する。理由: テンプレートとケースの
マージ規則が複雑になり、実装・理解のコストに見合わないため。

## 使用例

### Before (現状)

```yaml
- name: "Rule 7: field that is just a quote"
  command: "${CSV} parse"
  input: "\"\"\"\",b\r\n"
  expect_output: "[\"][b]\n"
```

### After (提案)

```yaml
- name: "Rule 7: field that is just a quote"
  command: "${CSV} parse"
  input_lines:
    line_ending: crlf
    lines:
      - '"""",b'
  expect_output: "[\"][b]\n"
```

### test_table での使用例

```yaml
name: RFC 4180 CSV parsing
vars:
  CSV: ./examples/csv/zig-out/bin/csv

test_table:
  command: "${CSV} parse"
  cases:
    - name: "Rule 1: CRLF delimited records"
      input_lines:
        line_ending: crlf
        lines:
          - 'aaa,bbb,ccc'
          - 'zzz,yyy,xxx'
      expect_output: "[aaa][bbb][ccc]\n[zzz][yyy][xxx]\n"

    - name: "Rule 2: trailing CRLF absent"
      input_lines:
        line_ending: crlf
        trailing: false
        lines:
          - 'aaa,bbb'
      expect_output: "[aaa][bbb]\n"

    - name: "Rule 5: quoted fields"
      input_lines:
        line_ending: crlf
        lines:
          - '"aaa","bbb","ccc"'
      expect_output: "[aaa][bbb][ccc]\n"

    - name: "Rule 7: field that is just a quote"
      input_lines:
        line_ending: crlf
        lines:
          - '"""",b'
      expect_output: "[\"][b]\n"
```

### 短縮形の使用例（LF テキスト）

```yaml
name: line counter
test:
  command: wc -l
  input_lines:
    - 'first'
    - 'second'
    - 'third'
  expect_output_contains: "3"
```

## エッジケース

### 空行

空行は空文字列 `''` で表現する:

```yaml
input_lines:
  line_ending: lf
  lines:
    - 'first'
    - ''
    - 'third'
# 結果: "first\n\nthird\n"
```

### 空の lines リスト

`lines: []` は許可する。stdin に空のデータ（0バイト）が渡される。

```yaml
input_lines:
  lines: []
# 結果: "" (空文字列)
```

### 不正な line_ending 値

`lf` と `crlf` 以外の値はパースエラーとする。

```yaml
input_lines:
  line_ending: cr    # エラー: unknown line_ending "cr"
  lines:
    - 'test'
```

### 未知のキー

`input_lines` マップ内の未知のキー（`line_ending`, `trailing`, `lines` 以外）は
パースエラーとする。

### フィールド内改行 (CSV Rule 6)

CSV フィールド内に改行が含まれるケースは `input_lines` では行単位の分割と衝突する。
この場合は従来の `input:` を使う:

```yaml
input: "\"line1\r\nline2\",b\r\n"
```

`input_lines` で表現する場合は YAML double-quoted string を使う:

```yaml
input_lines:
  line_ending: crlf
  lines:
    - "\"line1\r\nline2\",b"
```

`input_lines` は行単位入力の可読性を優先する機能であり、
全てのバイナリパターンを表現する汎用機能ではない。

## 実装範囲

### コード変更

1. `spec.zig`: `TestCase` に `input_lines` フィールド追加（`InputLines` struct）
2. `parser.zig`:
   - `input_lines` の YAML パース（マップ形式 + リスト短縮形）
   - `input` と `input_lines` の排他チェック（パース時エラー）
   - `test_table` の reserved key に `input_lines` を追加
   - `parseTestTable` で `input_lines` を抽出するロジック追加
3. `executor.zig`: `input_lines` → stdin バイト列への変換（`line_ending` と `trailing` を適用）

### ドキュメント更新

4. `reporter.zig`: `induct schema` の出力に `input_lines` を追加
5. `README.md`: 仕様の書き方セクションに `input_lines` を追加
6. `CLAUDE.md`: YAML Spec Format セクションに `input_lines` を追加

### テスト

7. ユニットテスト（`parser.zig` / `executor.zig`）:
   - マップ形式（`line_ending` + `lines`）
   - マップ形式（`line_ending` + `trailing` + `lines`）
   - 短縮形（リスト直書き）
   - `line_ending: crlf`
   - `trailing: false`
   - 空行を含む lines
   - 空の lines リスト
   - 不正な `line_ending` 値 → エラー
   - 未知のキー → エラー
   - `input` と `input_lines` の重複 → エラー
8. Induct spec（`specs/execution/`）:
   - `input_lines` の基本動作
   - `test_table` 経由での `input_lines`
9. RFC 4180 spec の `input_lines` 版への書き直し

## 代替案

### A. `input_file:` (外部ファイル参照)

```yaml
input_file: fixtures/rfc4180/just-a-quote.csv
```

- 利点: エスケープが完全に不要
- 欠点: テストケースごとにファイルが必要。spec とデータが分離して読みにくい
- 評価: `input_lines` の代替ではなく **補完機能**。長い fixture やバイナリ入力には将来有用。
  本 RFC のスコープ外とするが、将来の RFC で検討する価値がある。

### B. `input_base64:` / `input_hex:`

```yaml
input_hex: "22 22 22 22 2c 62 0d 0a"
```

- 利点: 任意のバイナリを表現可能
- 欠点: 人間が読めない。仕様書としての価値がない
- 評価: 却下

### C. YAML block scalar のカスタム拡張

```yaml
input: |crlf
  """",b
```

- 利点: 簡潔
- 欠点: YAML 仕様の逸脱。カスタムパーサーなので可能だが混乱を招く
- 評価: 却下

### D. Markdown + YAML ハイブリッド形式

仕様本文を Markdown で書き、コードブロック内の YAML を抽出実行する。
これは `input_lines` とは直交する改善であり、将来的に併用可能。
- 評価: 直交する機能。本 RFC のスコープ外。
