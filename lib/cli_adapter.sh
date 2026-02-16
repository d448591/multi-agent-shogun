#!/usr/bin/env bash
# cli_adapter.sh — CLI抽象化レイヤー
# Multi-CLI統合設計書 (reports/design_multi_cli_support.md) §2.2 準拠
#
# 提供関数:
#   get_cli_type(agent_id)                  → "claude" | "codex" | "copilot" | "kimi"
#   build_cli_command(agent_id)             → 完全なコマンド文字列
#   get_instruction_file(agent_id [,cli_type]) → 指示書パス
#   validate_cli_availability(cli_type)     → 0=OK, 1=NG
#   get_agent_model(agent_id)               → "opus" | "sonnet" | "haiku" | "k2.5"
#   get_copilot_model_name(internal_name)    → "claude-opus-4.6" | "claude-sonnet-4" | ...
#   get_startup_prompt(agent_id)            → 初期プロンプト文字列 or ""
#   get_output_dir([project_id])            → 納品物出力先ディレクトリパス

# プロジェクトルートを基準にsettings.yamlのパスを解決
CLI_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_ADAPTER_PROJECT_ROOT="$(cd "${CLI_ADAPTER_DIR}/.." && pwd)"
CLI_ADAPTER_SETTINGS="${CLI_ADAPTER_SETTINGS:-${CLI_ADAPTER_PROJECT_ROOT}/config/settings.yaml}"

# 許可されたCLI種別
CLI_ADAPTER_ALLOWED_CLIS="claude codex copilot kimi"

# --- 内部ヘルパー ---

# _cli_adapter_read_yaml key [fallback]
# python3でsettings.yamlから値を読み取る
_cli_adapter_read_yaml() {
    local key_path="$1"
    local fallback="${2:-}"
    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys
try:
    with open('${CLI_ADAPTER_SETTINGS}') as f:
        cfg = yaml.safe_load(f) or {}
    keys = '${key_path}'.split('.')
    val = cfg
    for k in keys:
        if isinstance(val, dict):
            val = val.get(k)
        else:
            val = None
            break
    if val is not None:
        print(val)
    else:
        print('${fallback}')
except Exception:
    print('${fallback}')
" 2>/dev/null)
    if [[ -z "$result" ]]; then
        echo "$fallback"
    else
        echo "$result"
    fi
}

# _cli_adapter_is_valid_cli cli_type
# 許可されたCLI種別かチェック
_cli_adapter_is_valid_cli() {
    local cli_type="$1"
    local allowed
    for allowed in $CLI_ADAPTER_ALLOWED_CLIS; do
        [[ "$cli_type" == "$allowed" ]] && return 0
    done
    return 1
}

# --- 公開API ---

# get_cli_type(agent_id)
# 指定エージェントが使用すべきCLI種別を返す
# フォールバック: cli.agents.{id}.type → cli.agents.{id}(文字列) → cli.default → "claude"
get_cli_type() {
    local agent_id="$1"
    if [[ -z "$agent_id" ]]; then
        echo "claude"
        return 0
    fi

    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys
try:
    with open('${CLI_ADAPTER_SETTINGS}') as f:
        cfg = yaml.safe_load(f) or {}
    cli = cfg.get('cli', {})
    if not isinstance(cli, dict):
        print('claude'); sys.exit(0)
    agents = cli.get('agents', {})
    if not isinstance(agents, dict):
        print(cli.get('default', 'claude') if cli.get('default', 'claude') in ('claude','codex','copilot','kimi') else 'claude')
        sys.exit(0)
    agent_cfg = agents.get('${agent_id}')
    if isinstance(agent_cfg, dict):
        t = agent_cfg.get('type', '')
        if t in ('claude', 'codex', 'copilot', 'kimi'):
            print(t); sys.exit(0)
    elif isinstance(agent_cfg, str):
        if agent_cfg in ('claude', 'codex', 'copilot', 'kimi'):
            print(agent_cfg); sys.exit(0)
    default = cli.get('default', 'claude')
    if default in ('claude', 'codex', 'copilot', 'kimi'):
        print(default)
    else:
        print('claude', file=sys.stderr)
        print('claude')
except Exception as e:
    print('claude', file=sys.stderr)
    print('claude')
" 2>/dev/null)

    if [[ -z "$result" ]]; then
        echo "claude"
    else
        if ! _cli_adapter_is_valid_cli "$result"; then
            echo "[WARN] Invalid CLI type '$result' for agent '$agent_id'. Falling back to 'claude'." >&2
            echo "claude"
        else
            echo "$result"
        fi
    fi
}

# build_cli_command(agent_id)
# エージェントを起動するための完全なコマンド文字列を返す
build_cli_command() {
    local agent_id="$1"
    local cli_type
    cli_type=$(get_cli_type "$agent_id")
    local model
    model=$(get_agent_model "$agent_id")

    case "$cli_type" in
        claude)
            local cmd="claude"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            cmd="$cmd --dangerously-skip-permissions"
            echo "$cmd"
            ;;
        codex)
            local cmd="codex"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            cmd="$cmd --dangerously-bypass-approvals-and-sandbox --no-alt-screen"
            echo "$cmd"
            ;;
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
        kimi)
            local cmd="kimi --yolo"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            echo "$cmd"
            ;;
        *)
            echo "claude --dangerously-skip-permissions"
            ;;
    esac
}

# get_instruction_file(agent_id [,cli_type])
# CLIが自動読込すべき指示書ファイルのパスを返す
get_instruction_file() {
    local agent_id="$1"
    local cli_type="${2:-$(get_cli_type "$agent_id")}"
    local role

    case "$agent_id" in
        shogun)    role="shogun" ;;
        karo)      role="karo" ;;
        gunshi)    role="gunshi" ;;
        ashigaru*) role="ashigaru" ;;
        *)
            echo "" >&2
            return 1
            ;;
    esac

    case "$cli_type" in
        claude)  echo "instructions/${role}.md" ;;
        codex)   echo "instructions/codex-${role}.md" ;;
        copilot) echo "instructions/generated/copilot-${role}.md" ;;
        kimi)    echo "instructions/generated/kimi-${role}.md" ;;
        *)       echo "instructions/${role}.md" ;;
    esac
}

# validate_cli_availability(cli_type)
# 指定CLIがシステムにインストールされているか確認
# 0=利用可能, 1=利用不可
validate_cli_availability() {
    local cli_type="$1"
    case "$cli_type" in
        claude)
            command -v claude &>/dev/null || {
                echo "[ERROR] Claude Code CLI not found. Install from https://claude.ai/download" >&2
                return 1
            }
            ;;
        codex)
            command -v codex &>/dev/null || {
                echo "[ERROR] OpenAI Codex CLI not found. Install with: npm install -g @openai/codex" >&2
                return 1
            }
            ;;
        copilot)
            command -v copilot &>/dev/null || {
                echo "[ERROR] GitHub Copilot CLI not found. Install with: brew install copilot-cli" >&2
                return 1
            }
            ;;
        kimi)
            if ! command -v kimi-cli &>/dev/null && ! command -v kimi &>/dev/null; then
                echo "[ERROR] Kimi CLI not found. Install from https://platform.moonshot.cn/" >&2
                return 1
            fi
            ;;
        *)
            echo "[ERROR] Unknown CLI type: '$cli_type'. Allowed: $CLI_ADAPTER_ALLOWED_CLIS" >&2
            return 1
            ;;
    esac
    return 0
}

# get_copilot_model_name(internal_name)
# 内部モデル名をCopilot CLIのモデル識別子に変換する
# Copilot CLI --model は正式名（claude-sonnet-4, gpt-5 等）を要求するため
# 短縮名（opus, sonnet, haiku 等）からマッピングする
# 正式名がそのまま渡された場合はパススルーする
get_copilot_model_name() {
    local name="$1"
    case "$name" in
        # 短縮名 → Copilot CLI正式名
        opus)           echo "claude-opus-4.6" ;;
        opus-fast)      echo "claude-opus-4.6-fast" ;;
        sonnet)         echo "claude-sonnet-4.5" ;;
        haiku)          echo "claude-haiku-4.5" ;;
        gpt-5)          echo "gpt-5" ;;
        gpt-5-mini)     echo "gpt-5-mini" ;;
        gemini)         echo "gemini-3-pro-preview" ;;
        # 正式名パススルー（claude-opus-4.6, gpt-5.2-codex 等）
        claude-*|gpt-*|gemini-*)
            echo "$name" ;;
        # 不明な名前 → 空（デフォルト使用）
        *)
            echo "" ;;
    esac
}

# get_agent_model(agent_id)
# エージェントが使用すべきモデル名を返す
get_agent_model() {
    local agent_id="$1"

    # まずsettings.yamlのcli.agents.{id}.modelを確認
    local model_from_yaml
    model_from_yaml=$(_cli_adapter_read_yaml "cli.agents.${agent_id}.model" "")

    if [[ -n "$model_from_yaml" ]]; then
        echo "$model_from_yaml"
        return 0
    fi

    # 既存のmodelsセクションを確認
    local model_from_models
    model_from_models=$(_cli_adapter_read_yaml "models.${agent_id}" "")

    if [[ -n "$model_from_models" ]]; then
        echo "$model_from_models"
        return 0
    fi

    # デフォルトロジック（CLI種別に応じた初期値）
    local cli_type
    cli_type=$(get_cli_type "$agent_id")

    case "$cli_type" in
        kimi)
            # Kimi CLI用デフォルトモデル
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
}

# get_startup_prompt(agent_id)
# CLIが初回起動時に自動実行すべき初期プロンプトを返す
# Codex CLI: [PROMPT]引数として渡す（サジェストUI停止問題の根本対策）
# Claude Code: 空（CLAUDE.md自動読込でSession Start手順が起動）
# Copilot/Kimi: 空（今後対応）
get_startup_prompt() {
    local agent_id="$1"
    local cli_type
    cli_type=$(get_cli_type "$agent_id")

    case "$cli_type" in
        codex)
            echo "Session Start — do ALL of this in one turn, do NOT stop early: 1) tmux display-message -t \"\$TMUX_PANE\" -p '#{@agent_id}' to identify yourself. 2) Read queue/tasks/${agent_id}.yaml. 3) Read queue/inbox/${agent_id}.yaml, mark read:true. 4) Read files listed in context_files. 5) Execute the assigned task to completion — edit files, run commands, write reports. Keep working until the task is done."
            ;;
        copilot)
            echo "Session Start — do ALL of this in one turn, do NOT stop early: 1) Run: tmux display-message -t \"\$TMUX_PANE\" -p '#{@agent_id}' to identify yourself. 2) Read your instruction file at instructions/generated/copilot-{your_role}.md (role = shogun/karo/ashigaru/gunshi based on step 1). 3) Read queue/tasks/${agent_id}.yaml for your current task. 4) Read queue/inbox/${agent_id}.yaml, process unread entries and mark read:true. 5) Execute the assigned task to completion. Keep working until done."
            ;;
        *)
            echo ""
            ;;
    esac
}

# get_output_dir([project_id])
# 納品物のデフォルト出力先ディレクトリを返す
# 優先順位: output.projects.<project_id> → output.default → saytask/
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
