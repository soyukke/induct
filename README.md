# Induct

AIと人間が共有する、実行可能な仕様書エンジン。

YAMLで振る舞いを定義し、コマンド一つで検証する。言語やフレームワークに依存しない。

## 思想

ソフトウェアの仕様は実行できるべきだ。

1. **人間とAIが一緒に仕様（YAML）を書く**
2. **AIが仕様をpassするまで実装する**
3. **仕様がそのままドキュメントとして残る**

```
人間+AI → YAML仕様作成 → AIが実装 → induct run → FAIL → AI修正 → ... → PASS
```

## Quick Start

```bash
# スキーマを確認して仕様の書き方を知る
induct schema

# 仕様を書く
cat > specs/hello.yaml << 'EOF'
name: hello world
test:
  command: ./hello
  expect_output: "Hello, World!\n"
EOF

# 構文チェック
induct validate specs/hello.yaml

# 実行して検証（最初は FAIL）
induct run specs/hello.yaml

# 実装したら再実行（PASS を目指す）
induct run specs/hello.yaml
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
-v, --verbose     詳細出力
--json            JSON形式で結果出力
--junit           JUnit XML形式で出力
--fail-fast       最初の失敗で停止
--dry-run         パースのみ（実行しない）
--filter <pattern> 仕様名でフィルタ
-j <N>            並列実行数
```

## 仕様の書き方

```yaml
name: string                            # 必須: 仕様名
description: string                     # 任意: 説明

setup:                                  # 任意: 事前準備
  - run: string

test:
  command: string                       # 必須: 実行コマンド
  input: string                         # 任意: stdin入力
  expect_output: string                 # 任意: stdout完全一致
  expect_output_contains: string        # 任意: stdout部分一致
  expect_output_not_contains: string    # 任意: stdout除外パターン
  expect_output_regex: string           # 任意: stdout正規表現(POSIX ERE)
  expect_stderr: string                 # 任意: stderr完全一致
  expect_stderr_contains: string        # 任意: stderr部分一致
  expect_exit_code: number              # 任意: 終了コード (デフォルト: 0)
  env:                                  # 任意: 環境変数
    KEY: value
  working_dir: string                   # 任意: 作業ディレクトリ
  timeout_ms: number                    # 任意: タイムアウト(ms)

teardown:                               # 任意: 後片付け
  - run: string
  - kill_process: string
```

### マルチステップ仕様（`test:` の代わりに `steps:` を使用）

```yaml
name: string
steps:
  - name: string                        # 必須: ステップ名
    command: string                     # 必須: 実行コマンド
    expect_output: string               # test: と同じフィールドが使える
  - name: string
    command: string
```

- ステップは順番に実行される
- 1つ失敗すると残りはスキップ
- setup は全ステップの前に1回、teardown は後に1回実行

## 仕様の例

### コマンド出力の検証

```yaml
name: echo test
test:
  command: echo "hello"
  expect_output: "hello\n"
```

### API レスポンスの検証

```yaml
name: POST /users
test:
  command: curl -s -X POST -H "Content-Type: application/json" -d '{"name":"alice"}' http://localhost:8080/users
  expect_output_contains: '"id":'
  expect_exit_code: 0
```

### セットアップ・ティアダウン

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

### マルチステップ（シナリオテスト）

```yaml
name: user CRUD flow
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

### 複数仕様の一括管理

```yaml
name: my project specs
include:
  - specs/api.yaml
  - specs/cli.yaml
```

## AI駆動開発での使い方

CLAUDE.md やプロジェクトの指示書に以下を書く：

```markdown
## 開発フロー
1. `induct schema` でYAML仕様の書き方を確認
2. specs/ にYAML仕様を作成
3. `induct validate <spec.yaml>` で構文確認
4. `induct run <spec.yaml>` で FAIL を確認
5. PASS するまで実装
```

AIツール（Claude Code, Cursor 等）はCLI経由で `induct` を実行できるので、特別な統合は不要。

## Build

```bash
git clone https://github.com/soyukke/induct.git
cd induct
zig build
```

Requires Zig 0.15.0+

## License

MIT
