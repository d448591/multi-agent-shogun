# 納品物出力先ディレクトリ設定 — 実装記録

> **対応日**: 2026-02-17
> **ステータス**: 全テスト合格（194/194 pass, 0 fail, 0 skip）

---

## 背景・課題

従来、足軽へのタスク分解時に `target_path`（納品物の出力先）を家老がフルパスでハードコードしていた。出力先ディレクトリに関する一元的な設定がなく、以下の問題があった:

- プロジェクトごとに出力先を変えたい場合、家老が毎回手動でパスを判断する必要がある
- 出力先の変更時に家老の指示書やタスクYAMLを横断的に修正する必要がある
- 足軽には出力先のコンテキストがなく、家老の指定に完全依存

## 解決策

`config/settings.yaml` に `output` セクションを新設し、出力先ディレクトリを設定で管理する。家老がタスク分解時にこの設定を読み取って `target_path` を組み立てる。

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `config/settings.yaml` | `output` セクション新設 |
| `lib/cli_adapter.sh` | `get_output_dir()` 関数追加 |
| `instructions/karo.md` | タスクYAML生成時の `target_path` 組み立てルール追記 |
| `tests/unit/test_cli_adapter.bats` | `get_output_dir` テスト7件 + フィクスチャ3件追加 |

---

## 1. `config/settings.yaml` — `output` セクション

### 追加内容

```yaml
# 納品物出力先設定
# 足軽が生成する納品物（ドキュメント、レポート等）のデフォルト出力先ディレクトリ
# 家老がタスク分解時に target_path を組み立てる際に参照する
#
# default: 全プロジェクト共通のデフォルト出力先
# projects.<project_id>: プロジェクト別の出力先（defaultより優先）
output:
  default: "/work/multi-agent-shogun/saytask"
  # projects:
  #   sample_project: "/path/to/project/deliverables"
  #   another_project: "/mnt/c/work/reports"
```

### 設定キー

| キー | 型 | 説明 |
|-----|----|------|
| `output.default` | string | 全プロジェクト共通のデフォルト出力先ディレクトリ |
| `output.projects.<project_id>` | string | プロジェクト別の出力先（`default` より優先） |

### 設定例（複数プロジェクト）

```yaml
output:
  default: "/work/multi-agent-shogun/saytask"
  projects:
    sample_project: "/work/multi-agent-shogun/saytask"
    client_x: "/mnt/c/work/client_x/deliverables"
    internal_tool: "/home/user/projects/tool/docs"
```

---

## 2. `lib/cli_adapter.sh` — `get_output_dir()` 関数

### 関数シグネチャ

```bash
get_output_dir([project_id])
# 引数:
#   project_id (省略可) — プロジェクトID。cmd の project フィールドに対応
# 戻り値:
#   納品物出力先ディレクトリのフルパス（末尾スラッシュなし）
```

### 解決の優先順位

```
1. output.projects.<project_id>  — プロジェクト別設定（最優先）
2. output.default                — 全プロジェクト共通デフォルト
3. ${CLI_ADAPTER_PROJECT_ROOT}/saytask — フォールバック（設定なし時）
```

### 実装コード

```bash
get_output_dir() {
    local project_id="${1:-}"

    # プロジェクト別設定を確認
    if [[ -n "$project_id" ]]; then
        local project_dir
        project_dir=$(_cli_adapter_read_yaml "output.projects.${project_id}" "")
        if [[ -n "$project_dir" ]]; then
            echo "$project_dir"
            return 0
        fi
    fi

    # デフォルト出力先
    local default_dir
    default_dir=$(_cli_adapter_read_yaml "output.default" "")
    if [[ -n "$default_dir" ]]; then
        echo "$default_dir"
        return 0
    fi

    # フォールバック: saytask/
    echo "${CLI_ADAPTER_PROJECT_ROOT}/saytask"
}
```

### 設計判断

- **プロジェクトID省略時**: `output.default` を返す。cmd にプロジェクトが紐付かないケースに対応
- **未知のプロジェクトID**: `output.projects` に該当キーがなければ `output.default` にフォールバック
- **設定セクション自体がない場合**: `saytask/` ディレクトリにフォールバック（既存動作を維持）
- **内部ヘルパー `_cli_adapter_read_yaml()` を再利用**: python3 + PyYAML で settings.yaml をパースする既存の仕組みに乗る

---

## 3. `instructions/karo.md` — 家老向けルール追記

Task YAML Format セクションに「target_path の組み立てルール」を新設した。

### 追記内容の要点

家老がタスク分解時に `target_path` を組み立てる手順:

```
1. cmd の `project` フィールドからプロジェクトID を取得
2. config/settings.yaml → output.projects.<project_id> を確認
   └─ なければ output.default を使用
3. 出力先ディレクトリ + ファイル名 で target_path を組み立てる
```

### タスクYAML での使用例

**修正前**（パスをハードコード）:
```yaml
task:
  target_path: "/mnt/c/tools/multi-agent-shogun/hello1.md"
```

**修正後**（settings.yaml の出力先に従う）:
```yaml
task:
  target_path: "/work/multi-agent-shogun/saytask/hello1.md"
  #             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  #             output.default の値 + ファイル名
```

### 取得方法（シェルからの利用）

```bash
source lib/cli_adapter.sh
output_dir=$(get_output_dir "sample_project")
target_path="${output_dir}/hello1.md"
```

---

## 4. テスト

### 追加フィクスチャ（3件）

`tests/unit/test_cli_adapter.bats` の `setup()` に以下のテスト用 settings.yaml を追加:

| フィクスチャ | 内容 |
|-------------|------|
| `settings_output_default.yaml` | `output.default` のみ設定 |
| `settings_output_project.yaml` | `output.default` + `output.projects` (proj_a, proj_b) |
| `settings_output_none.yaml` | `output` セクションなし |

### テストケース（7件）

| # | テスト名 | 入力 | 期待値 |
|---|---------|------|--------|
| 1 | `output.default を返す` | フィクスチャ: default のみ、引数なし | `/tmp/test-deliverables` |
| 2 | `project指定なしで output.default を返す` | フィクスチャ: projects あり、引数なし | `/tmp/test-deliverables` |
| 3 | `project指定ありで projects.<id> を優先` | 引数: `proj_a` | `/tmp/proj-a-output` |
| 4 | `project指定あり別プロジェクト` | 引数: `proj_b` | `/mnt/c/work/proj-b` |
| 5 | `未知のproject → output.default にフォールバック` | 引数: `unknown_proj` | `/tmp/test-deliverables` |
| 6 | `output セクションなし → saytask/ にフォールバック` | フィクスチャ: output なし、引数なし | `*/saytask` |
| 7 | `output セクションなし + project指定 → saytask/ にフォールバック` | フィクスチャ: output なし、引数: `any_project` | `*/saytask` |

---

## データフロー全体図

```
config/settings.yaml
  output:
    default: "/work/multi-agent-shogun/saytask"
    projects:
      client_x: "/mnt/c/work/client_x/deliverables"
          │
          ▼
queue/shogun_to_karo.yaml
  cmd:
    project: client_x    ← プロジェクトID
          │
          ▼
家老（Karo）タスク分解
  1. project = "client_x"
  2. settings.yaml → output.projects.client_x
     → "/mnt/c/work/client_x/deliverables"
  3. target_path = "/mnt/c/work/client_x/deliverables/report.md"
          │
          ▼
queue/tasks/ashigaru1.yaml
  task:
    target_path: "/mnt/c/work/client_x/deliverables/report.md"
          │
          ▼
足軽（Ashigaru）が target_path にファイルを生成
```

---

## 今後の拡張

| 項目 | 説明 | 優先度 |
|------|------|--------|
| サブディレクトリ自動作成 | `output.default` 配下にプロジェクトIDでサブディレクトリを自動作成 | 低 |
| `projects.yaml` との統合 | `config/projects.yaml` の各プロジェクトに `output_dir` フィールドを追加 | 中 |
| 出力先の存在チェック | `get_output_dir()` でディレクトリの存在を検証し、なければ作成 | 低 |
