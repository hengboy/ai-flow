#!/bin/bash
# plan-gen-executor.sh — 生成或修订 draft plan

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$AGENT_DIR/lib/agent-common.sh"
source "$AGENT_DIR/lib/rule-loader.sh"
exec 3>&1 1>&2

AI_FLOW_HOME="${AI_FLOW_HOME:-$HOME/.config/ai-flow}"
FLOW_STATE_SH="$AI_FLOW_HOME/scripts/flow-state.sh"
FLOW_UTILS_PY="$AGENT_DIR/../lib/flow_utils.py"
ORIGINAL_PROJECT_DIR="$(pwd)"
PROJECT_DIR="$ORIGINAL_PROJECT_DIR"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
STATE_DIR="$FLOW_DIR/state"

SLUG="${2:-}"
DATE_PREFIX="$(date +%Y%m%d)"
PLANS_DIR="$FLOW_DIR/plans"
OWNER_GIT_ROOT=""
REPO_SCOPE_JSON=""
PLAN_REPO_IDS=()
PLAN_REPO_PATHS=()
PLAN_REPO_GIT_ROOTS=()
TEMPLATE="$AGENT_DIR/templates/plan-template.md"
PLAN_PROMPT_TEMPLATE="$AGENT_DIR/prompts/plan-generation.md"
PLAN_REVISION_PROMPT_TEMPLATE="$AGENT_DIR/prompts/plan-revision.md"
PLAN_REASONING="$(default_reasoning_for_engine "$AGENT_ENGINE")"
PLAN_ENGINE_MODE="${ENGINE_MODE_OVERRIDE:-auto}"
PLAN_ENGINE_NAME=""
PLAN_ENGINE_MODEL=""
REQUIREMENT="${1:-}"
MODEL="$(default_model_for_engine "$AGENT_ENGINE")"
RULE_BUNDLE_JSON=""
RULE_PROMPT_BLOCK=""
RULE_REQUIRED_READS_BLOCK=""
PROTOCOL_ARTIFACT="none"
PROTOCOL_STATE="none"
PROTOCOL_NEXT="none"
PROTOCOL_SUMMARY=""
PROTOCOL_EMITTED=0

if [ -z "$REQUIREMENT" ]; then
    echo "用法: plan-gen-executor.sh \"需求描述\" <slug>" >&2
    exit 1
fi

emit_current_protocol() {
    PROTOCOL_EMITTED=1
    emit_protocol "success" "$PROTOCOL_ARTIFACT" "$PROTOCOL_STATE" "$PROTOCOL_NEXT" "$PROTOCOL_SUMMARY"
}

fail_protocol() {
    local summary="$1"
    PROTOCOL_EMITTED=1
    emit_protocol "failed" "$PROTOCOL_ARTIFACT" "$PROTOCOL_STATE" "$PROTOCOL_NEXT" "$summary"
    exit 1
}

trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "$PROTOCOL_EMITTED" -eq 0 ]; then emit_protocol "failed" "$PROTOCOL_ARTIFACT" "$PROTOCOL_STATE" "$PROTOCOL_NEXT" "${PROTOCOL_SUMMARY:-执行失败}"; fi' EXIT

# ... (rest of the script logic, keeping only generation)
# Actually, I'll use a more surgical approach to keep the functions.
