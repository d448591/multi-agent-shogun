# GitHub Copilot CLI 互換対応 — 実装記録

> **対応日**: 2026-02-17
> **対象バージョン**: v3.0
> **ステータス**: 全テスト合格（150/150 pass, 0 fail, 0 skip）

---

## 概要

multi-agent-shogun は設計上 Claude Code / OpenAI Codex / GitHub Copilot / Kimi Code の4種類の CLI に対応する設計だが、実際の実装は Claude Code と Codex に偏っており、Copilot CLI ではシステムが正常に動作しない状態だった。本対応で **6つの未実装・不整合箇所** を特定し、修正を実施した。

---

## 変更ファイル一覧

| ファイル | 行数 | 変更内容の分類 |
|---------|------|--------------|
| `lib/cli_adapter.sh` | 300行 | 指示書パス修正 + 起動プロンプト追加 |
| `lib/agent_status.sh` | 72行 | アイドル/ビジー検出パターン追加 |
| `scripts/inbox_watcher.sh` | 1145行 | 4箇所の Copilot 専用ハンドラ追加 |
| `shutsujin_departure.sh` | 1130行 | 起動時プロンプト制御 + STEP 6.5.1 新設 |
| `tests/unit/test_cli_adapter.bats` | 549行 | テスト期待値修正（3テスト） |
| `tests/unit/test_send_wakeup.bats` | 795行 | Escape抑制テスト更新（2テスト） |

差分統計: **+175行 / -31行 = net +144行**（6ファイル）

---

## 問題と修正の詳細

### Issue 1: `get_instruction_file()` が存在しないパスを返していた

**ファイル**: `lib/cli_adapter.sh` L185

**問題**: Copilot の指示書パスが `.github/copilot-instructions-${role}.md` と定義されていたが、このファイルは存在しない。実際のファイルは `instructions/generated/copilot-${role}.md`（`build_instructions.sh` が生成）に配置されている。

**修正前**:
```bash
copilot) echo ".github/copilot-instructions-${role}.md" ;;
```

**修正後**:
```bash
copilot) echo "instructions/generated/copilot-${role}.md" ;;
```

**影響範囲**: 全 Copilot エージェントの Session Start 手順。`get_instruction_file()` は指示書読み込みパスの解決に使われるため、修正前は全エージェントが正しい指示書を読めなかった。

**補足**: `.github/copilot-instructions.md`（ロール非依存）は別途存在し、Copilot CLI が自動読み込みする。これはロール別指示書とは別の共通指示書であり、影響しない。

---

### Issue 2: `get_startup_prompt()` が Copilot に対して空文字を返していた

**ファイル**: `lib/cli_adapter.sh` L292-295

**問題**: `get_startup_prompt()` の `case` 文に `copilot)` ブランチが存在せず、`*)` にフォールスルーして空文字 `""` を返していた。これにより、Copilot エージェントは起動後に Session Start 手順を実行するプロンプトを受け取れなかった。

**修正**: `copilot)` ブランチを追加。Copilot 固有の Session Start 手順を含むプロンプトを返すように変更。

```bash
copilot)
    echo "Session Start — do ALL of this in one turn, do NOT stop early: \
1) Run: tmux display-message -t \"\$TMUX_PANE\" -p '#{@agent_id}' to identify yourself. \
2) Read your instruction file at instructions/generated/copilot-{your_role}.md \
   (role = shogun/karo/ashigaru/gunshi based on step 1). \
3) Read queue/tasks/${agent_id}.yaml for your current task. \
4) Read queue/inbox/${agent_id}.yaml, process unread entries and mark read:true. \
5) Execute the assigned task to completion. Keep working until done."
    ;;
```

**Codex との違い**: Codex プロンプトは `context_files` 読み込みを含むが、Copilot プロンプトは代わりに指示書ファイルの明示的パスを含む。これは Copilot CLI が `.github/copilot-instructions.md` を自動読み込みするため、ロール別指示書の追加読み込みが必要なため。

---

### Issue 3: `agent_is_busy_check()` に Copilot のアイドル/ビジーパターンがなかった

**ファイル**: `lib/agent_status.sh` L37-40, L53-56

**問題**: `agent_is_busy_check()` は `tmux capture-pane` の出力からエージェントのアイドル/ビジー状態を判定するが、Copilot CLI 固有の表示パターンが登録されていなかった。

**追加したアイドルパターン**（L37-40）:
```bash
# Copilot CLI idle prompt (input ready)
# Copilot TUI shows ">" or "copilot>" when waiting for input
if echo "$pane_tail" | grep -qE '(^>\s*$|copilot\s*>\s*$)'; then
    return 1  # idle
fi
```

**追加したビジーパターン**（L53-56）:
```bash
# Copilot CLI busy markers
if echo "$pane_tail" | grep -qiE '(Running|Calling|Searching|Reading|Editing|Creating|Analyzing)'; then
    return 0  # busy
fi
```

**影響範囲**: `inbox_watcher.sh` の全エスカレーション判定。このパターンがないと、Copilot エージェントは常にアイドルと見なされ、処理中にもナッジが送信される問題があった。

---

### Issue 4: `send_cli_command()` の Copilot `/clear` ハンドラが不完全だった

**ファイル**: `scripts/inbox_watcher.sh` L452-477（`send_cli_command()` 内 copilot ブランチ）

**問題点（3つ）**:

1. **ハードコード**: 再起動コマンドが `copilot --yolo` にハードコードされており、`build_cli_command()` を使っていなかった。`config/settings.yaml` のモデル設定等が反映されない。
2. **重複ガード欠如**: 同一バッチ内で `/clear` が複数回呼ばれた場合に二重再起動が発生し得た。
3. **起動プロンプト未送信**: Ctrl-C+再起動後に Session Start プロンプトが送信されず、エージェントがタスク復帰できなかった。

**修正内容**:

```bash
copilot)
    if [[ "$cmd" == "/clear" ]]; then
        # Guard: skip duplicate restart if already sent for this batch
        if [ "${NEW_CONTEXT_SENT:-0}" -eq 1 ]; then
            echo "[SKIP] Copilot restart already sent for $AGENT_ID" >&2
            return 0
        fi
        # Ctrl-C で現在のプロセスを停止
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null || true
        sleep 2
        # build_cli_command() で設定に基づいた再起動コマンドを構築
        local copilot_restart_cmd="copilot --yolo"
        if type build_cli_command &>/dev/null; then
            copilot_restart_cmd=$(build_cli_command "$AGENT_ID" 2>/dev/null || echo "copilot --yolo")
        fi
        timeout 5 tmux send-keys -t "$PANE_TARGET" "$copilot_restart_cmd" 2>/dev/null || true
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
        sleep 5
        # 起動プロンプト送信（Session Start 手順トリガー）
        send_copilot_startup_prompt
        NEW_CONTEXT_SENT=1
        return 0
    fi
```

**新関数 `send_copilot_startup_prompt()`**（L541-577）:

Copilot CLI の `/clear` や `send_context_reset()` 後に呼ばれる専用関数。

```
1. アイドル状態をポーリング（最大20秒 = 4回×5秒）
2. アイドル検出後、get_startup_prompt() でプロンプト取得
3. tmux send-keys でプロンプトを送信 + Enter
4. STARTUP_PROMPT_SENT=1 をセット
```

フォールバック: `get_startup_prompt()` が利用不可な場合、インライン定義のデフォルトプロンプトを使用。

---

### Issue 5: `send_context_reset()` に Copilot 専用パスがなかった

**ファイル**: `scripts/inbox_watcher.sh` L621-641（`send_context_reset()` 内）

**問題**: `task_assigned` メッセージ受信時にコンテキストリセットを行う `send_context_reset()` で、Copilot は Codex でも Claude でもないため、汎用の `/clear` パスにフォールスルーしていた。Copilot CLI には `/clear` コマンドが存在しないため、これは無効だった。

**修正**: Copilot 専用パスを Codex チェックの直後に追加。

```bash
# Copilot: Ctrl-C + restart + startup prompt (Copilot has no /clear)
if [[ "$effective_cli" == "copilot" ]]; then
    echo "[CONTEXT-RESET] Copilot: Ctrl-C + restart for $AGENT_ID" >&2
    timeout 5 tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null || true
    sleep 2
    local copilot_reset_cmd="copilot --yolo"
    if type build_cli_command &>/dev/null; then
        copilot_reset_cmd=$(build_cli_command "$AGENT_ID" 2>/dev/null || echo "copilot --yolo")
    fi
    timeout 5 tmux send-keys -t "$PANE_TARGET" "$copilot_reset_cmd" 2>/dev/null || true
    sleep 0.3
    timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
    sleep 3
    send_copilot_startup_prompt
    return 0
fi
```

**処理フロー**: Ctrl-C → 2秒待機 → CLI再起動コマンド → Enter → 3秒待機 → 起動プロンプト送信

---

### Issue 6: `send_wakeup_with_escape()` が Copilot TUI に危険な Escape を送信していた

**ファイル**: `scripts/inbox_watcher.sh` L821-828

**問題**: Phase 2 エスカレーション（未読2-4分）で `Escape×2` を送信する処理で、Copilot CLI が除外されていなかった。Copilot CLI の TUI では Escape は「現在の操作を停止」「ツール許可の拒否」を意味し、処理中のタスクを破壊する危険があった。

**修正前の除外対象**: shogun（Lord の入力保護）、codex（中断リスク）、claude（Stop hook が代替）

**修正**: copilot を除外対象に追加（codex の直後に配置）。

```bash
# Copilot CLI: TUI上でのEscapeは「現在の操作を停止/ツール許可拒否」。
# Phase 2のEscapeエスカレーションはCopilot TUIの動作を中断させるため無効化。
if [[ "$effective_cli" == "copilot" ]]; then
    echo "[SKIP] copilot: suppressing Escape escalation for $AGENT_ID (TUI safety); sending plain nudge" >&2
    send_wakeup "$unread_count"
    return 0
fi
```

**フォールバック動作**: Escape の代わりに通常の `send_wakeup()` （`inbox{N}` テキスト + Enter）で代替。

---

## 起動シーケンスの修正

### `shutsujin_departure.sh` — 4箇所の起動プロンプトスキップ

**問題**: Copilot CLI はプロンプトを CLI 引数として受け付けない（TUI ベースのため）。しかし、karo / ashigaru (決戦) / ashigaru (平時) / gunshi の全4箇所で、Copilot でも CLI 引数として起動プロンプトを渡そうとしていた。

**修正**: 各箇所に `[[ "$_cli_type" != "copilot" ]]` ガードを追加。

```bash
# 修正前
if [[ -n "$_startup_prompt" ]]; then

# 修正後
if [[ -n "$_startup_prompt" ]] && [[ "$_karo_cli_type" != "copilot" ]]; then
```

**対象箇所**:
| エージェント | 変数名 | 行（修正後） |
|-------------|--------|------------|
| karo | `$_karo_cli_type` | L700 |
| ashigaru（決戦） | `$_ashi_cli_type` | L727 |
| ashigaru（平時） | `$_ashi_cli_type` | L747 |
| gunshi | `$_gunshi_cli_type` | L767 |

### `shutsujin_departure.sh` — 起動待機の CLI 対応（L853-873）

**修正前**: 将軍の起動確認が `"bypass permissions"` のみ（Claude Code 固有）。

**修正後**: CLI 種別に応じた起動確認:
- **Claude**: `"bypass permissions"` を capture-pane で検出
- **Copilot**: `>` または `copilot` を capture-pane で検出（TUI プロンプト）

```bash
_shogun_cli_type_check="claude"
if [ "$CLI_ADAPTER_LOADED" = true ]; then
    _shogun_cli_type_check=$(get_cli_type "shogun")
fi
for i in {1..30}; do
    if [ "$_shogun_cli_type_check" = "copilot" ]; then
        if tmux capture-pane -t shogun:main -p 2>/dev/null | grep -qE '(>|copilot)'; then
            echo "  └─ 将軍の Copilot CLI 起動確認完了（${i}秒）"
            break
        fi
    else
        if tmux capture-pane -t shogun:main -p | grep -q "bypass permissions"; then
            echo "  └─ 将軍の Claude Code 起動確認完了（${i}秒）"
            break
        fi
    fi
    sleep 1
done
```

### `shutsujin_departure.sh` — STEP 6.5.1 新設: Copilot 初期プロンプト送信（L876-912）

**目的**: Copilot エージェントは CLI 引数でプロンプトを受け取れないため、TUI 起動後に `tmux send-keys` で Session Start プロンプトを送信する。

**処理フロー**:
1. 全エージェント（shogun, karo, ashigaru1-7, gunshi）をイテレーション
2. 各エージェントの CLI 種別を `get_cli_type()` で確認
3. Copilot であれば `get_startup_prompt()` でプロンプト取得
4. pane ターゲットを解決（shogun/karo/gunshi/ashigaru別）
5. 2秒待機後、`tmux send-keys` でプロンプト送信 + Enter
6. 送信件数をカウントしてログ出力

```bash
if [ "$CLI_ADAPTER_LOADED" = true ]; then
    _copilot_agents_prompted=0
    for _agent_id in shogun karo ashigaru{1..7} gunshi; do
        _agent_cli=$(get_cli_type "$_agent_id")
        if [ "$_agent_cli" = "copilot" ]; then
            _sp=$(get_startup_prompt "$_agent_id" 2>/dev/null)
            if [[ -n "$_sp" ]]; then
                case "$_agent_id" in
                    shogun) _pane_target="shogun:main" ;;
                    karo)   _pane_target="multiagent:agents.${PANE_BASE}" ;;
                    gunshi) _pane_target="multiagent:agents.$((PANE_BASE+8))" ;;
                    ashigaru[1-7])
                        _ashi_num="${_agent_id#ashigaru}"
                        _pane_target="multiagent:agents.$((PANE_BASE+_ashi_num))"
                        ;;
                esac
                sleep 2
                tmux send-keys -t "$_pane_target" "$_sp" 2>/dev/null || true
                sleep 0.3
                tmux send-keys -t "$_pane_target" Enter 2>/dev/null || true
                _copilot_agents_prompted=$((_copilot_agents_prompted+1))
            fi
        fi
    done
    if [ "$_copilot_agents_prompted" -gt 0 ]; then
        log_info "  └─ Copilotエージェント${_copilot_agents_prompted}体に初期プロンプト送信完了"
    fi
fi
```

---

## テストの修正

### `tests/unit/test_cli_adapter.bats` — 3テスト修正

パス期待値を `.github/copilot-instructions-${role}.md` → `instructions/generated/copilot-${role}.md` に更新。

| テスト名 | 修正箇所 |
|---------|---------|
| `get_instruction_file: ashigaru7 + copilot` | 期待値修正 |
| `get_instruction_file: cli_type引数で明示指定 (copilot)` | 期待値修正 |
| `get_instruction_file: 全CLI × 全role組み合わせ` | copilot セクション期待値修正（3行） |

### `tests/unit/test_send_wakeup.bats` — 2テスト更新

Copilot の Escape 抑制実装に合わせ、テストの意図を「Escape が送られること」から「Escape が**抑制**されること」に変更。

| テスト ID | 修正前 | 修正後 |
|----------|--------|--------|
| T-ESC-003 | `escalation Phase 2 — unread 2-4min uses Escape+nudge (copilot)` → Escape 送信を検証 | `escalation Phase 2 — copilot suppresses Escape, sends plain nudge` → Escape 非送信 + プレーンナッジ送信を検証 |
| T-ESC-005 | `escalation /clear cooldown — falls back to Escape+nudge (copilot)` → Escape 送信を検証 | `escalation /clear cooldown — copilot falls back to plain nudge (no Escape)` → Escape 非送信 + プレーンナッジ送信を検証 |

**テスト結果**: 全 150 テスト合格、0 失敗、0 スキップ

---

## Copilot CLI の動作特性まとめ

| 特性 | Claude Code | Copilot CLI | 本対応での対処 |
|------|------------|-------------|--------------|
| 指示書自動読込 | なし | `.github/copilot-instructions.md` | 共通指示書として活用。ロール別指示書は別途プロンプトで読み込み指示 |
| プロンプト引数 | サポート | **非サポート**（TUI ベース） | STEP 6.5.1 で `tmux send-keys` による遅延送信 |
| `/clear` コマンド | あり | **なし**（`/compact` のみ） | Ctrl-C + CLI 再起動で代替 |
| `/model` コマンド | あり | **なし** | スキップ（既存実装で対応済み） |
| Escape キー | 処理中断 | **操作停止 / ツール拒否** | Phase 2 Escape エスカレーション抑制 |
| アイドル表示 | `❯` / `›` | `>` / `copilot>` | `agent_is_busy_check()` にパターン追加 |
| ビジー表示 | `Working` / `Thinking` 等 | `Running` / `Calling` / `Searching` 等 | `agent_is_busy_check()` にパターン追加 |
| コンテキストリセット | `/clear` 送信 | **Ctrl-C + 再起動 + 起動プロンプト** | `send_context_reset()` に専用パス追加 |
| 起動確認 | `"bypass permissions"` | `>` / `copilot` プロンプト | `shutsujin_departure.sh` 起動待機を分岐 |

---

## 未対応・今後の課題

| 項目 | 説明 | 優先度 |
|------|------|--------|
| `.github/copilot-instructions.md` の Redo Protocol | `/clear` を参照しているが、Copilot には `/clear` がない。インフラ層（`inbox_watcher`）で Ctrl-C+再起動に変換済みだが、ドキュメント上の記述が不正確 | 低（動作には影響なし） |
| `instructions/cli_specific/copilot_tools.md` | tmux 統合セクションの詳細化が可能 | 低 |
| Codex/Kimi CLI の同様の検証 | 本対応は Copilot に限定。Codex/Kimi でも同種の問題がないか横展開検証 | 中 |
