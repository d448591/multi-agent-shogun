# エージェント個別モデル指定機能 — 実装記録

> **対応日**: 2026-02-17
> **対象 CLI**: GitHub Copilot CLI（主対象）、Claude Code / Codex / Kimi も対応済み
> **ステータス**: 全テスト合格（187/187 pass, 0 fail, 0 skip）

---

## 概要

各エージェント（shogun, karo, ashigaru1-7, gunshi）が使用する LLM モデルを `config/settings.yaml` で個別に指定できる機能を実装した。

Copilot CLI が `--model` フラグ（起動時指定）と `/model` コマンド（ランタイム切替）の両方をサポートしていることを確認し、以下の2つの経路でモデル指定を実現した:

1. **起動時**: `build_cli_command()` → `copilot --yolo --model <model>` として CLI 引数に含める
2. **ランタイム**: `send_cli_command()` → `/model <model>` を TUI に `tmux send-keys` で送信

---

## 設定方法

### `config/settings.yaml` でのエージェント個別設定

```yaml
cli:
  default: copilot
  agents:
    shogun:
      type: copilot
      model: opus            # → claude-opus-4.6
    karo:
      type: copilot
      model: sonnet          # → claude-sonnet-4.5
    ashigaru1:
      type: copilot
      model: sonnet
    ashigaru2:
      type: copilot
      model: gpt-5           # GPT-5 も指定可能
    ashigaru3:
      type: copilot
      model: claude-opus-4.6-fast  # 正式名も使用可能
    gunshi:
      type: copilot
      model: opus
```

### 設定の優先順位

`get_agent_model()` は以下の優先順位でモデルを解決する:

1. `cli.agents.<agent_id>.model` — YAML 明示指定（最優先）
2. `models.<agent_id>` — 旧形式の互換セクション
3. CLI 種別ごとのデフォルト値（フォールバック）

---

## モデル短縮名マッピング

Copilot CLI は `--model` に正式なモデル識別子（`claude-sonnet-4.5`, `gpt-5` 等）を要求する。settings.yaml では短縮名を使えるよう、`get_copilot_model_name()` 関数でマッピングを行う。

### 短縮名 → Copilot CLI 正式名

| 短縮名 | Copilot CLI モデル名 | 説明 |
|--------|---------------------|------|
| `opus` | `claude-opus-4.6` | Claude Opus 4.6（最高性能） |
| `opus-fast` | `claude-opus-4.6-fast` | Claude Opus 4.6 高速版 |
| `sonnet` | `claude-sonnet-4.5` | Claude Sonnet 4.5（バランス型） |
| `haiku` | `claude-haiku-4.5` | Claude Haiku 4.5（高速・低コスト） |
| `gpt-5` | `gpt-5` | GPT-5 |
| `gpt-5-mini` | `gpt-5-mini` | GPT-5 Mini |
| `gemini` | `gemini-3-pro-preview` | Gemini 3 Pro Preview |

### 正式名パススルー

`claude-*`, `gpt-*`, `gemini-*` で始まる文字列はそのまま Copilot CLI に渡される。これにより、以下のような正式名も直接指定可能:

```yaml
model: claude-opus-4.5       # パススルー
model: gpt-5.2-codex         # パススルー
model: gpt-5.1-codex-max     # パススルー
model: claude-sonnet-4       # パススルー
```

### Copilot CLI が対応する全モデル一覧

`copilot --help` で確認した利用可能モデル（2026-02-17 時点）:

```
claude-sonnet-4.5, claude-haiku-4.5, claude-opus-4.6, claude-opus-4.6-fast,
claude-opus-4.5, claude-sonnet-4, gemini-3-pro-preview, gpt-5.3-codex,
gpt-5.2-codex, gpt-5.2, gpt-5.1-codex-max, gpt-5.1-codex, gpt-5.1,
gpt-5, gpt-5.1-codex-mini, gpt-5-mini, gpt-4.1
```

---

## 変更ファイルと実装詳細

### 1. `lib/cli_adapter.sh` — モデル指定の中核実装

**変更量**: +53行

#### 1.1 `build_cli_command()` — Copilot に `--model` フラグ追加

**修正前**:
```bash
copilot)
    echo "copilot --yolo"
    ;;
```

**修正後**:
```bash
copilot)
    local cmd="copilot --yolo"
    if [[ -n "$model" ]]; then
        local copilot_model
        copilot_model=$(get_copilot_model_name "$model")
        if [[ -n "$copilot_model" ]]; then
            cmd="$cmd --model $copilot_model"
        fi
    fi
    echo "$cmd"
    ;;
```

**処理フロー**:
1. `get_agent_model()` で内部モデル名（`opus`, `sonnet` 等）を取得
2. `get_copilot_model_name()` で Copilot CLI の正式モデル名に変換
3. 変換成功時のみ `--model` フラグを付与（不明なモデル名の場合はフラグなし = Copilot デフォルト使用）

**生成されるコマンド例**:
```bash
# shogun (model: opus)
copilot --yolo --model claude-opus-4.6

# karo (model: sonnet)
copilot --yolo --model claude-sonnet-4.5

# model 指定なし or 不明
copilot --yolo
```

#### 1.2 `get_copilot_model_name()` — 新規関数

短縮名を Copilot CLI の正式モデル識別子に変換するマッピング関数。

```bash
get_copilot_model_name() {
    local name="$1"
    case "$name" in
        opus)           echo "claude-opus-4.6" ;;
        opus-fast)      echo "claude-opus-4.6-fast" ;;
        sonnet)         echo "claude-sonnet-4.5" ;;
        haiku)          echo "claude-haiku-4.5" ;;
        gpt-5)          echo "gpt-5" ;;
        gpt-5-mini)     echo "gpt-5-mini" ;;
        gemini)         echo "gemini-3-pro-preview" ;;
        claude-*|gpt-*|gemini-*)
            echo "$name" ;;    # 正式名パススルー
        *)  echo "" ;;          # 不明 → 空（デフォルト使用）
    esac
}
```

**設計判断**:
- 不明なモデル名に対して空文字を返すことで、`build_cli_command()` がフラグ自体を省略する（エラーにしない）
- 正式名パススルーにより、Copilot CLI の新モデル追加時にマッピング更新が不要

#### 1.3 `get_agent_model()` — Copilot 固有デフォルト分離

**修正前**: `*)`（Claude Code/Codex/Copilot共通）の1ブランチ

**修正後**: `copilot)` と `*)` を分離し、CLI 種別ごとに独立したデフォルトを持たせた。

```bash
case "$cli_type" in
    kimi)
        case "$agent_id" in
            shogun|karo)    echo "k2.5" ;;
            ashigaru*)      echo "k2.5" ;;
            *)              echo "k2.5" ;;
        esac
        ;;
    copilot)
        # Copilot CLI用デフォルトモデル
        case "$agent_id" in
            shogun)         echo "opus" ;;
            karo)           echo "sonnet" ;;
            gunshi)         echo "opus" ;;
            ashigaru*)      echo "sonnet" ;;
            *)              echo "sonnet" ;;
        esac
        ;;
    *)
        # Claude Code/Codex用デフォルトモデル
        case "$agent_id" in
            shogun)         echo "opus" ;;
            karo)           echo "sonnet" ;;
            gunshi)         echo "opus" ;;
            ashigaru*)      echo "sonnet" ;;
            *)              echo "sonnet" ;;
        esac
        ;;
esac
```

現時点ではデフォルト値は全 CLI で同一だが、将来的に CLI ごとに異なるデフォルトを設定しやすい構造にした。

---

### 2. `scripts/inbox_watcher.sh` — ランタイム `/model` 切替の有効化

**変更量**: +89行（Copilot 互換対応全体を含む）

#### 2.1 `send_cli_command()` — Copilot の `/model` スキップを解除

**修正前**:
```bash
if [[ "$cmd" == /model* ]]; then
    echo "[$(date)] Skipping $cmd (not supported on copilot)" >&2
    return 0
fi
```

**修正後**:
```bash
if [[ "$cmd" == /model* ]]; then
    echo "[$(date)] [SEND-KEYS] Copilot /model: sending model switch for $AGENT_ID" >&2
    timeout 5 tmux send-keys -t "$PANE_TARGET" "$cmd" 2>/dev/null || true
    sleep 0.3
    timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
    sleep 2
    return 0
fi
```

**動作**: `/model claude-opus-4.6` のようなコマンドを TUI に直接送信する。Copilot CLI はこのコマンドを受けてモデルを切り替える。

#### 2.2 ランタイム `/model` の使用方法

家老（Karo）から足軽への `model_switch` タイプの inbox メッセージで切替が行われる:

```bash
# 例: 足軽3のモデルを Claude Opus に切替
bash scripts/inbox_write.sh ashigaru3 "/model claude-opus-4.6" model_switch karo
```

`inbox_watcher.sh` の処理フロー:
1. `queue/inbox/ashigaru3.yaml` に `model_switch` メッセージが書き込まれる
2. `inotifywait` がファイル変更を検知 → エージェントに `inboxN` ナッジ送信
3. `normalize_special_command()` がメッセージを `/model claude-opus-4.6` に正規化
4. `send_cli_command()` が TUI に `/model claude-opus-4.6` + Enter を送信

---

### 3. `config/settings.yaml` — エージェント個別設定の追加

**修正前**:
```yaml
cli:
  default: copilot
```

**修正後**:
```yaml
cli:
  default: copilot
  agents:
    shogun:
      type: copilot
      model: opus
    karo:
      type: copilot
      model: sonnet
    ashigaru1:
      type: copilot
      model: sonnet
    ashigaru2:
      type: copilot
      model: sonnet
    # ... ashigaru3-7 同様
    gunshi:
      type: copilot
      model: opus
```

設定の YAML 構造:
```
cli.agents.<agent_id>.type   → CLI 種別 (claude|codex|copilot|kimi)
cli.agents.<agent_id>.model  → モデル名 (短縮名 or 正式名)
```

---

### 4. テストの追加・修正

**変更量**: test_cli_adapter.bats +102行 / test_send_wakeup.bats +10/-14行

#### 4.1 `test_cli_adapter.bats` — 新規テスト 11 件

**テストフィクスチャ追加**:
```yaml
# settings_copilot_models.yaml
cli:
  default: copilot
  agents:
    shogun:
      type: copilot
      model: opus
    karo:
      type: copilot
      model: gpt-5
    ashigaru1:
      type: copilot
      model: claude-sonnet-4.5
```

**`build_cli_command` テスト（3件）**:

| テスト名 | 入力 | 期待値 |
|---------|------|--------|
| `copilot + default model` | ashigaru7（設定なし、デフォルト sonnet） | `copilot --yolo --model claude-sonnet-4.5` |
| `copilot + explicit model` | shogun（model: opus） | `copilot --yolo --model claude-opus-4.6` |
| `copilot + gpt-5 model` | karo（model: gpt-5） | `copilot --yolo --model gpt-5` |
| `copilot + 正式名パススルー` | ashigaru1（model: claude-sonnet-4.5） | `copilot --yolo --model claude-sonnet-4.5` |

**`get_copilot_model_name` テスト（8件）**:

| テスト名 | 入力 | 期待値 |
|---------|------|--------|
| `opus → claude-opus-4.6` | `opus` | `claude-opus-4.6` |
| `sonnet → claude-sonnet-4.5` | `sonnet` | `claude-sonnet-4.5` |
| `haiku → claude-haiku-4.5` | `haiku` | `claude-haiku-4.5` |
| `gpt-5 → gpt-5` | `gpt-5` | `gpt-5` |
| `gemini → gemini-3-pro-preview` | `gemini` | `gemini-3-pro-preview` |
| `正式名パススルー claude-sonnet-4.5` | `claude-sonnet-4.5` | `claude-sonnet-4.5` |
| `正式名パススルー gpt-5.2-codex` | `gpt-5.2-codex` | `gpt-5.2-codex` |
| `不明な名前 → 空文字` | `unknown_model` | `""` |

#### 4.2 `test_send_wakeup.bats` — T-COPILOT-002 更新

**修正前**: `/model` が copilot でスキップされることを検証
```
T-COPILOT-002: send_cli_command skips /model for copilot
  → ! grep -q "send-keys.*/model" "$MOCK_LOG"
  → echo "$output" | grep -q "not supported on copilot"
```

**修正後**: `/model` が copilot TUI に送信されることを検証
```
T-COPILOT-002: send_cli_command sends /model to copilot via TUI
  → grep -q "send-keys.*/model claude-opus-4.6" "$MOCK_LOG"
  → grep -q "send-keys.*Enter" "$MOCK_LOG"
```

#### 4.3 `test_send_wakeup.bats` — T-CODEX-006 更新

`inbox_watcher.sh` 内の文字列存在チェックから `"not supported on copilot"` を `/model.*model switch` に変更（copilot の `/model` ハンドラが存在することを検証）。

---

## モデル指定のフロー全体図

```
config/settings.yaml
  cli.agents.ashigaru1.model: "opus"
       │
       ▼
get_agent_model("ashigaru1")       ← YAML読取り → "opus"
       │
       ▼
build_cli_command("ashigaru1")
       │
       ├─ claude → "claude --model opus --dangerously-skip-permissions"
       │           (短縮名をそのまま使用、Claude Code が解釈)
       │
       ├─ codex  → "codex --model opus --dangerously-bypass-..."
       │           (短縮名をそのまま使用、Codex が解釈)
       │
       ├─ copilot → get_copilot_model_name("opus")
       │            → "claude-opus-4.6"
       │            → "copilot --yolo --model claude-opus-4.6"
       │
       └─ kimi   → "kimi --yolo --model opus"
                    (短縮名をそのまま使用)
```

**Copilot のみマッピングが必要な理由**: Copilot CLI は `--model` にフルネーム（`claude-opus-4.6`）を要求する。他の CLI は短縮名（`opus`）をそのまま受け付ける。

---

## ランタイムモデル切替（`/model` コマンド）

### CLI 別対応状況

| CLI | `/model` 対応 | 実装方式 |
|-----|-------------|---------|
| Claude Code | ✅ 対応 | そのまま TUI に送信 |
| Codex | ❌ 非対応 | スキップ（ログ出力のみ） |
| Copilot | ✅ 対応 | **本対応で有効化** — TUI にsend-keys送信 |
| Kimi | ❌ 非対応 | 未実装 |

### 切替手順

```bash
# inbox_write.sh 経由で model_switch メッセージ送信
bash scripts/inbox_write.sh ashigaru3 "/model claude-opus-4.6" model_switch karo

# inbox_watcher が検出 → send_cli_command() が TUI に /model コマンドを送信
# Copilot CLI が /model の選択 UI を表示 → 指定モデルに切替
```

---

## 現在のデフォルト設定

| エージェント | CLI | モデル（短縮名） | Copilot CLI モデル名 |
|-------------|-----|----------------|---------------------|
| shogun | copilot | opus | claude-opus-4.6 |
| karo | copilot | sonnet | claude-sonnet-4.5 |
| ashigaru1-7 | copilot | sonnet | claude-sonnet-4.5 |
| gunshi | copilot | opus | claude-opus-4.6 |

---

## 今後の拡張

| 項目 | 説明 | 優先度 |
|------|------|--------|
| Copilot 新モデル追加 | `get_copilot_model_name()` にマッピング追加、または正式名をそのまま使用 | 低（正式名パススルーで対応可能） |
| モデル自動選択 | タスク種別（戦略/実装/レビュー等）に応じた自動モデル選択 | 中 |
| コスト最適化 | ashigaru の一部を haiku / gpt-5-mini に切替える設定パターン | 中 |
| Kimi `/model` 対応 | Kimi CLI のランタイムモデル切替対応 | 低 |
