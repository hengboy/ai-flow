#!/bin/bash

agent_frontmatter_value() {
    local key="$1"
    python3 - "$AGENT_DIR/AGENT.md" "$key" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
text = path.read_text(encoding="utf-8").splitlines()

if not text or text[0].strip() != "---":
    sys.exit(0)

for line in text[1:]:
    if line.strip() == "---":
        break
    if ":" not in line:
        continue
    current_key, value = line.split(":", 1)
    if current_key.strip() != key:
        continue
    value = value.strip()
    if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
        value = value[1:-1]
    print(value)
    break
PY
}

derive_engine_from_name() {
    case "$1" in
        ai-flow-codex-*) echo "codex" ;;
        ai-flow-opencode-*) echo "opencode" ;;
        *) echo "" ;;
    esac
}

derive_flow_role_from_name() {
    case "$1" in
        ai-flow-*-plan-coding-review) echo "coding_review" ;;
        ai-flow-*-plan-review) echo "plan_review" ;;
        ai-flow-*-plan) echo "plan" ;;
        *) echo "" ;;
    esac
}

derive_fallback_agent_from_name() {
    case "$1" in
        ai-flow-codex-*) echo "${1/ai-flow-codex-/ai-flow-opencode-}" ;;
        ai-flow-opencode-*) echo "${1/ai-flow-opencode-/ai-flow-codex-}" ;;
        *) echo "" ;;
    esac
}

display_path() {
    local base="$1"
    local path="$2"
    case "$path" in
        "$base"/*) echo "${path#"$base"/}" ;;
        *) echo "$path" ;;
    esac
}

normalize_one_line() {
    printf '%s' "${1:-}" | tr '\r\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

sanitize_for_filename() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

agent_log_path() {
    local log_file="${1:-${AI_FLOW_LOG_FILE:-}}"
    if [ -z "$log_file" ]; then
        return 1
    fi
    if [ -n "${PROJECT_DIR:-}" ]; then
        display_path "$PROJECT_DIR" "$log_file"
    else
        printf '%s\n' "$log_file"
    fi
}

append_log_path_to_summary() {
    local summary="${1:-}"
    local log_path
    log_path="$(agent_log_path 2>/dev/null || true)"
    if [ -z "$log_path" ]; then
        printf '%s' "$summary"
        return 0
    fi
    case "$summary" in
        *"$log_path"*)
            printf '%s' "$summary"
            ;;
        "")
            printf '日志: %s' "$log_path"
            ;;
        *)
            printf '%s；日志: %s' "$summary" "$log_path"
            ;;
    esac
}

setup_agent_logging() {
    local project_dir="$1"
    local context="${2:-$AGENT_NAME}"
    local slug="${3:-}"
    local flow_dir logs_dir safe_context timestamp

    if [ -n "$slug" ]; then
        safe_context="$(sanitize_for_filename "$slug")"
    else
        safe_context="$(sanitize_for_filename "$context")"
    fi
    [ -n "$safe_context" ] || safe_context="agent"

    flow_dir="$project_dir/.ai-flow"
    logs_dir="$flow_dir/logs/$(date +%Y%m%d)"
    mkdir -p "$logs_dir"

    timestamp="$(date +%H%M%S)"
    AI_FLOW_LOG_FILE="$logs_dir/${timestamp}-${safe_context}-$$.log"
    export AI_FLOW_LOG_FILE

    : > "$AI_FLOW_LOG_FILE"
    # Save original stderr to fd4, then tee both stdout and stderr into the log.
    # The display copy goes to fd4 (original stderr). This works correctly
    # whether or not the caller has already done exec 3>&1 1>&2:
    #   - fd3 (if set) still points at original stdout for protocol output.
    #   - fd1 and fd2 both go through tee into the log.
    exec 4>&2
    exec 1> >(tee -a "$AI_FLOW_LOG_FILE" >&4) 2>&1
    echo ">>> 日志文件: $(display_path "$project_dir" "$AI_FLOW_LOG_FILE")" >&4
}

emit_captured_stderr() {
    local stderr_file="$1"
    local label="${2:-stderr}"
    if [ ! -s "$stderr_file" ]; then
        return 0
    fi
    # Output goes to stdout, which (after setup_agent_logging) is teed into the
    # log file and displayed on the original stderr.
    echo ">>> ${label}:"
    cat "$stderr_file"
}

require_file() {
    local path="$1"
    local label="$2"
    if [ -f "$path" ]; then
        return 0
    fi
    echo "错误: 缺少${label}: $path"
    exit 1
}

default_model_for_engine() {
    case "$1" in
        codex) echo "${AI_FLOW_CODEX_DEFAULT_MODEL:-gpt-5.4}" ;;
        opencode) echo "${AI_FLOW_OPENCODE_DEFAULT_MODEL:-zhipuai-coding-plan/glm-5.1}" ;;
        *) echo "${AI_FLOW_DEFAULT_MODEL:-gpt-5.4}" ;;
    esac
}

map_reasoning_to_opencode_variant() {
    case "${1:-}" in
        xhigh) echo "max" ;;
        high) echo "high" ;;
        *) echo "minimal" ;;
    esac
}

emit_protocol() {
    local result="$1"
    local artifact="${2:-none}"
    local state="${3:-none}"
    local next="${4:-none}"
    local summary="${5:-}"
    local review_result="${6:-}"

    [ -n "$artifact" ] || artifact="none"
    [ -n "$state" ] || state="none"
    [ -n "$next" ] || next="none"
    if [ "$result" = "failed" ]; then
        summary="$(append_log_path_to_summary "$summary")"
    fi

    printf 'RESULT: %s\n' "$result" >&3
    printf 'AGENT: %s\n' "$AGENT_NAME" >&3
    printf 'ARTIFACT: %s\n' "$artifact" >&3
    printf 'STATE: %s\n' "$state" >&3
    printf 'NEXT: %s\n' "$next" >&3
    if [ -n "$review_result" ]; then
        printf 'REVIEW_RESULT: %s\n' "$review_result" >&3
    fi
    printf 'SUMMARY: %s\n' "$(normalize_one_line "$summary")" >&3
}

AGENT_NAME="${AGENT_NAME:-}"
AGENT_ENGINE="${AGENT_ENGINE:-}"
FLOW_ROLE="${FLOW_ROLE:-}"
FALLBACK_AGENT="${FALLBACK_AGENT:-}"

if [ -n "${AGENT_DIR:-}" ] && [ -f "$AGENT_DIR/AGENT.md" ]; then
    [ -n "$AGENT_NAME" ] || AGENT_NAME="$(agent_frontmatter_value name)"
    [ -n "$AGENT_NAME" ] || AGENT_NAME="$(basename "$AGENT_DIR")"
    [ -n "$AGENT_ENGINE" ] || AGENT_ENGINE="$(derive_engine_from_name "$AGENT_NAME")"
    [ -n "$FLOW_ROLE" ] || FLOW_ROLE="$(derive_flow_role_from_name "$AGENT_NAME")"
    [ -n "$FALLBACK_AGENT" ] || FALLBACK_AGENT="$(derive_fallback_agent_from_name "$AGENT_NAME")"
fi

# Source workspace helpers when available (kept separate for overlay safety).
if [ -f "$SCRIPT_DIR/workspace-common.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/workspace-common.sh"
elif [ -n "${AGENT_DIR:-}" ] && [ -f "$AGENT_DIR/lib/workspace-common.sh" ]; then
    # shellcheck source=/dev/null
    source "$AGENT_DIR/lib/workspace-common.sh"
fi
