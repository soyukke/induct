# Induct

AIと人間が共有する、実行可能な仕様書エンジン。

YAMLで「何が正しい振る舞いか」を宣言し、コマンド一つで検証する。言語・フレームワーク非依存。

## なぜ Induct？

テストコードは言語やフレームワークに縛られる。シェルスクリプトで検証を書くと散らかる。

Induct は **宣言的なYAML** でコマンドの期待動作を定義する。コマンドが実行できるものなら何でも検証できる — CLI、API、ビルド、スクリプト、何でも。

- **宣言的**: 手続きを書かない。「何を期待するか」だけ書く
- **言語非依存**: コマンドが実行できれば検証できる
- **AI親和性**: YAMLスキーマを渡せばAIが仕様を書ける。仕様がそのままドキュメントになる
- **ゼロ依存**: シングルバイナリ。ランタイム不要

## インストール

```bash
npx @soyukke/induct help
```

または、ソースからビルド：

```bash
git clone https://github.com/soyukke/induct.git
cd induct
nix develop        # Zig 0.16.0 を自動で揃える
zig build
```

ワンショットで実行するなら：

```bash
nix develop -c zig build
```

### pre-commit でローカルチェック

このリポジトリには `.pre-commit-config.yaml` があり、コミット時に以下を実行する。

- `zig fmt --check src`
- `zig run scripts/check_style.zig -- --root src --strict`

初回セットアップ:

```bash
pipx install pre-commit
pre-commit install
pre-commit run --all-files
```

## Quick Start

```bash
# 仕様を書く
cat > hello.yaml << 'EOF'
name: hello world
test:
  command: echo "Hello, World!"
  expect_output: "Hello, World!\n"
  expect_exit_code: 0
EOF

# 実行して検証
npx @soyukke/induct run hello.yaml
```

出力：

```
[PASS] hello world (3ms)

----------------------------------------
Total: 1 | passed: 1 | failed: 0 | Duration: 3ms

All specs passed!
```

失敗するとこうなる：

```
[FAIL] hello world (2ms)
  Error: Output mismatch
  Expected: "Hello, World!\n"
  Actual:   "something else\n"

----------------------------------------
Total: 1 | passed: 0 | failed: 1 | Duration: 2ms

Failed:
  - hello world: Output mismatch
```

## CLI

```bash
induct run <spec.yaml>       # 仕様を実行・検証
induct run-dir <dir>         # ディレクトリ内の全仕様を実行
induct validate <spec.yaml>  # 構文チェック（実行しない）
induct schema                # YAML仕様のスキーマを出力
induct init [file.yaml]      # テンプレート生成
induct help                  # ヘルプ
```

### オプション

```
-v, --verbose        詳細出力
--json               JSON形式で結果出力
--junit              JUnit XML形式で出力（CI連携用）
--fail-fast          最初の失敗で停止
--dry-run            パースのみ（実行しない）
--filter <pattern>   仕様名でフィルタ（run-dir用）
-j <N>               並列実行数（run-dir用）
--template <type>    テンプレート種類: basic, setup, api, cli, project（init用）
```

### テンプレート生成

```bash
induct init                              # 標準テンプレートを stdout に出力
induct init my-spec.yaml                 # ファイルに書き出し
induct init api-test.yaml --template api # APIテスト用テンプレート
induct init project.yaml --template project  # プロジェクト用テンプレート
```

テンプレート種類: `basic`（デフォルト）, `setup`, `api`, `cli`, `project`

## 仕様の書き方

### 基本形

```yaml
name: string                            # 必須: 仕様のタイトル
description: |                          # 推奨: 仕様の本文
  何をするシステムか、どう振る舞うべきかを書く。
  name がタイトル、description が仕様本体。
  test: セクションがその検証手段。

test:
  command: string                       # 必須: 実行コマンド
  args:                                 # 任意: 引数配列（shell を介さず direct argv 実行）
    - string
  input: string                         # 任意: stdin入力
  expect_output: string                 # 任意: stdout完全一致
  expect_output_contains: string        # 任意: stdout部分一致
  expect_output_not_contains: string    # 任意: stdout除外パターン
  expect_output_regex: string           # 任意: stdout正規表現
  expect_stderr: string                 # 任意: stderr完全一致
  expect_stderr_contains: string        # 任意: stderr部分一致
  expect_exit_code: number              # 任意: 終了コード (デフォルト: 0)
  env:                                  # 任意: 環境変数
    KEY: value
  working_dir: string                   # 任意: 作業ディレクトリ
  timeout_ms: number                    # 任意: タイムアウト(ms)
```

`vars:` と `test_table:` のテンプレートでは `${EXEEXT}` が組み込みで使える。Unix 系では `""`、Windows では `".exe"` に展開される。

### セットアップ・ティアダウン

```yaml
name: string

setup:                                  # 任意: test/steps の前に実行
  - run: string

test:
  command: string

teardown:                               # 任意: test/steps の後に必ず実行
  - run: string
  - kill_process: string                # プロセス名で kill
```

### マルチステップ仕様

`test:` の代わりに `steps:` を使うと、複数コマンドを順次実行できる。

```yaml
name: string
steps:
  - name: string                        # 必須: ステップ名
    command: string                     # 必須: 実行コマンド
    args:                               # 任意: 引数配列（shell を介さず direct argv 実行）
      - string
    expect_output: string               # test: と同じフィールドが使える
  - name: string
    command: string
```

- ステップは順番に実行される
- 1つ失敗すると残りはスキップ（`[SKIP]` 表示）
- `steps:` と `test:` は排他（同時に使えない）
- setup は全ステップの前に1回、teardown は後に1回実行

### プロジェクトスペック

複数の仕様をまとめて管理する。インライン定義と外部ファイル参照の両方が使える。

```yaml
name: my project
description: プロジェクト全体の仕様

specs:                                  # インラインで仕様を定義
  - name: sanity check
    test:
      command: echo "ok"
      expect_output: "ok\n"

include:                                # 外部ファイルを参照
  - specs/api.yaml
  - specs/cli.yaml
```

`induct run inductspec.yaml` で全仕様を一括実行。

### RFC Example Layout

RFCサンプルは、実装と仕様を `examples/*` 配下で近接配置している。

- URI (RFC 3986): `examples/uri/src/main.zig` + `examples/uri/specs/*.yaml`
- CSV (RFC 4180): `examples/csv/src/main.zig` + `examples/csv/specs/*.yaml`
- Base64 (RFC 4648): `examples/base64/src/main.zig` + `examples/base64/specs/*.yaml`
- Email (RFC 5322): `examples/email/src/main.zig` + `examples/email/specs/*.yaml`

各 example には `examples/<name>/inductspec.yaml` があり、単体で実行できる。

## 使用例

### コマンド出力の検証

```yaml
name: echo test
description: |
  echo に文字列を渡すと、その文字列が改行付きで stdout に出力される。
test:
  command: echo "hello"
  expect_output: "hello\n"
```

### API レスポンスの検証

```yaml
name: ユーザー作成API
description: |
  POST /users に名前を送ると、IDが振られたユーザーが返る。
  レスポンスには "id" フィールドが含まれること。
test:
  command: curl -s -X POST -H "Content-Type: application/json" -d '{"name":"alice"}' http://localhost:8080/users
  expect_output_contains: '"id":'
  expect_exit_code: 0
```

### シナリオテスト（マルチステップ）

```yaml
name: ユーザーCRUDフロー
description: |
  ユーザーの作成・取得・削除が一連の操作として正しく動作する。
  作成したユーザーを取得でき、削除後は正常終了する。
setup:
  - run: start-server &

steps:
  - name: create user
    command: curl -s -X POST http://localhost:8080/users -d '{"name":"alice"}'
    expect_output_contains: '"id":'

  - name: get user
    command: curl -s http://localhost:8080/users/1
    expect_output_contains: '"alice"'

  - name: delete user
    command: curl -s -X DELETE http://localhost:8080/users/1
    expect_exit_code: 0

teardown:
  - kill_process: start-server
```

### エラーケースの検証

```yaml
name: 存在しないファイルの読み取り
description: |
  存在しないファイルを cat すると、終了コード1で
  stderr に "No such file" を含むエラーメッセージが出力される。
test:
  command: cat /nonexistent
  expect_exit_code: 1
  expect_stderr_contains: "No such file"
```

## AI駆動開発での使い方

CLAUDE.md やプロジェクトの指示書に以下を書く：

```markdown
## 開発フロー
1. `induct schema` でYAML仕様の書き方を確認
2. specs/ にYAML仕様を作成
3. `induct validate <spec.yaml>` で構文確認
4. `induct run <spec.yaml>` で FAIL を確認（RED）
5. PASS するまで実装（GREEN）
6. `induct run specs/inductspec.yaml` で全仕様の回帰テスト
```

AIツール（Claude Code, Cursor 等）はCLI経由で `induct` を実行できるので、特別な統合は不要。

### ワークフロー

```
人間+AI → YAML仕様作成 → induct run → FAIL → AIが実装 → induct run → PASS
                ↑                                              |
                └──────── 次の仕様を追加 ←─────────────────────┘
```

仕様ファイルがそのまま「何をテストしたか」のドキュメントとして残る。

## License

MIT
