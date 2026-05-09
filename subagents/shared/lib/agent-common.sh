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

emit_captured_stderr() {
    local stderr_file="$1"
    local label="${2:-stderr}"
    if [ ! -s "$stderr_file" ]; then
        return 0
    fi
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
