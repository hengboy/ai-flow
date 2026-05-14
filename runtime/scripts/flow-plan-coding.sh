#!/bin/bash
# flow-plan-coding.sh — 进入 ai-flow-plan-coding 前的统一状态与规则门禁
# 用法: flow-plan-coding.sh {slug或唯一关键词}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RULE_LOADER_SH="$AI_FLOW_HOME/lib/rule-loader.sh"
FLOW_STATE_SH="$SCRIPT_DIR/flow-state.sh"
if [ ! -f "$RULE_LOADER_SH" ]; then
    RULE_LOADER_SH="$(cd "$SCRIPT_DIR/../.." && pwd)/subagents/shared/lib/rule-loader.sh"
fi

if [ -z "${1:-}" ]; then
    echo "用法: flow-plan-coding.sh {slug或唯一关键词}" >&2
    exit 1
fi

if [ ! -f "$RULE_LOADER_SH" ]; then
    echo "错误: 缺少 rule loader: $RULE_LOADER_SH" >&2
    exit 1
fi

if [ ! -f "$FLOW_STATE_SH" ]; then
    echo "错误: 缺少 flow-state 脚本: $FLOW_STATE_SH" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$RULE_LOADER_SH"

resolve_flow_root() {
    local start candidate
    start="$(pwd)"
    candidate="$start"
    while true; do
        if [ -d "$candidate/.ai-flow/state" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        if [ "$candidate" = "/" ] || [ "$candidate" = "//" ]; then
            break
        fi
        local parent
        parent="$(cd "$candidate/.." 2>/dev/null && pwd)" || break
        if [ -z "$parent" ] || [ "$parent" = "$candidate" ]; then
            break
        fi
        candidate="$parent"
    done
    printf '%s' "$start"
}

emit_protocol() {
    echo "RESULT: $PROTOCOL_RESULT"
    echo "AGENT: ai-flow-plan-coding"
    echo "ARTIFACT: $PROTOCOL_ARTIFACT"
    echo "STATE: $PROTOCOL_STATE"
    echo "NEXT: $PROTOCOL_NEXT"
    echo "SUMMARY: $PROTOCOL_SUMMARY"
}

fail_protocol() {
    PROTOCOL_RESULT="failed"
    PROTOCOL_ARTIFACT="${PROTOCOL_ARTIFACT:-none}"
    PROTOCOL_STATE="${PROTOCOL_STATE:-none}"
    PROTOCOL_NEXT="${PROTOCOL_NEXT:-none}"
    PROTOCOL_SUMMARY="$1"
    emit_protocol
    exit 1
}

state_field() {
    local state_file="$1"
    local field="$2"
    python3 - "$state_file" "$field" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = state
for part in sys.argv[2].split("."):
    if value is None:
        break
    if isinstance(value, dict):
        value = value.get(part)
    elif isinstance(value, list) and part.isdigit():
        index = int(part)
        value = value[index] if 0 <= index < len(value) else None
    else:
        value = None
        break
if value is None:
    sys.exit(1)
print(value)
PY
}

collect_rule_repo_args() {
    local state_file="$1"
    python3 - "$state_file" "$PROJECT_DIR" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
owner = Path(sys.argv[2]).resolve()
scope = state.get("execution_scope") or {}
repos = scope.get("repos") or []
for repo in repos:
    repo_id = str(repo.get("id") or "").strip()
    repo_path = str(repo.get("path") or "").strip()
    if not repo_id or not repo_path:
        continue
    repo_root = (owner / repo_path).resolve()
    print(f"{repo_id}::{repo_root}")
PY
}

validate_plan_rule_paths() {
    local bundle_json="$1"
    local plan_file="$2"
    python3 - "$bundle_json" "$plan_file" <<'PY'
import json
import sys
from pathlib import Path

bundle = json.loads(sys.argv[1])
plan_file = Path(sys.argv[2]).resolve()
plan = plan_file.read_text(encoding="utf-8")
repos = bundle.get("repos", []) or []
repo_ids = {str(item.get("repo_id") or "").strip() for item in repos}

def extract_section_table(text: str, needle: str):
    lines = text.splitlines()
    in_section = False
    table = []
    for line in lines:
        if line.startswith("##") or line.startswith("###"):
            if needle in line:
                in_section = True
                table = []
                continue
            if in_section:
                break
        if in_section and line.startswith("|"):
            table.append(line)
    if len(table) < 3:
        return []
    rows = []
    for raw in table[2:]:
        cells = [cell.strip() for cell in raw.strip().strip("|").split("|")]
        if len(cells) >= 5 and any(cells):
            rows.append(cells)
    return rows

def matches(path: str, pattern: str) -> bool:
    import fnmatch
    return fnmatch.fnmatch(path, pattern.strip().replace("\\", "/"))

rows = extract_section_table(plan, "文件边界总览")
errors = []
for row in rows:
    path = row[0].strip().replace("`", "")
    repo_id = row[1].strip() or "owner"
    if repo_id not in repo_ids:
        repo_id = "owner"
    if not path:
        continue
    for item in bundle.get("merged", {}).get("protected_paths", []):
        pattern = str(item.get("path") or "").strip()
        if item.get("repo_id") == repo_id and pattern and matches(path, pattern):
            errors.append(f"命中 protected_paths，计划声明的执行边界不可修改: [{repo_id}] {path} -> {pattern}")
    for item in bundle.get("merged", {}).get("forbidden_changes", []):
        pattern = str(item.get("path") or "").strip()
        if item.get("repo_id") == repo_id and pattern and matches(path, pattern):
            reason = str(item.get("reason") or "").strip()
            suffix = f"：{reason}" if reason else ""
            errors.append(f"命中 forbidden_changes，计划声明的执行边界不可修改: [{repo_id}] {path} -> {pattern}{suffix}")

if errors:
    print("\n".join(errors))
PY
}

MATCHED_STATES=()
PROJECT_DIR="$(resolve_flow_root)"
FLOW_DIR="$PROJECT_DIR/.ai-flow"

while IFS= read -r -d '' f; do
    MATCHED_STATES+=("$f")
done < <(find "$FLOW_DIR/state" -name "*${1}*.json" -type f -print0 2>/dev/null)

if [ ${#MATCHED_STATES[@]} -eq 0 ]; then
    fail_protocol "找不到包含关键词 '$1' 的状态文件。"
elif [ ${#MATCHED_STATES[@]} -gt 1 ]; then
    fail_protocol "匹配到多个状态文件，请改用更精确的 slug。"
else
    STATE_FILE="${MATCHED_STATES[0]}"
fi

SLUG="$(basename "$STATE_FILE" .json)"
CURRENT_STATUS="$(state_field "$STATE_FILE" "current_status")"
PLAN_FILE="$(state_field "$STATE_FILE" "plan_file")"
case "$PLAN_FILE" in
    /*) ;;
    *) PLAN_FILE="$PROJECT_DIR/$PLAN_FILE" ;;
esac

PROTOCOL_ARTIFACT="$PLAN_FILE"
PROTOCOL_STATE="$CURRENT_STATUS"
PROTOCOL_NEXT="none"
PROTOCOL_RESULT="failed"
PROTOCOL_SUMMARY=""

case "$CURRENT_STATUS" in
    AWAITING_PLAN_REVIEW)
        fail_protocol "当前状态为 AWAITING_PLAN_REVIEW，需先运行 /ai-flow-plan-review 审核计划。"
        ;;
    PLAN_REVIEW_FAILED)
        fail_protocol "当前状态为 PLAN_REVIEW_FAILED，需先回到 /ai-flow-plan 修订并复审。"
        ;;
    AWAITING_REVIEW)
        fail_protocol "当前状态为 AWAITING_REVIEW，需先运行 /ai-flow-plan-coding-review。"
        ;;
    DONE)
        fail_protocol "当前状态为 DONE，如需再次审查请运行 /ai-flow-plan-coding-review。"
        ;;
    PLANNED|IMPLEMENTING|REVIEW_FAILED|FIXING_REVIEW)
        ;;
    *)
        fail_protocol "不支持的当前状态: $CURRENT_STATUS"
        ;;
esac

RULE_REPO_ARGS=()
while IFS= read -r repo_arg; do
    [ -n "$repo_arg" ] || continue
    RULE_REPO_ARGS+=("$repo_arg")
done < <(collect_rule_repo_args "$STATE_FILE")

if [ ${#RULE_REPO_ARGS[@]} -eq 0 ]; then
    RULE_REPO_ARGS=("owner::${PROJECT_DIR}")
fi

if ! RULE_BUNDLE_JSON="$(load_rule_bundle_json "plan_coding_runtime" "ai-flow-plan-coding" "" "${RULE_REPO_ARGS[@]}" 2>&1)"; then
    fail_protocol "$(extract_rule_loader_error "$RULE_BUNDLE_JSON")"
fi

REQUIRED_READS_OUTPUT=""
if ! REQUIRED_READS_OUTPUT="$(render_required_reads_block "$RULE_BUNDLE_JSON" 2>&1)"; then
    fail_protocol "$(extract_rule_loader_error "$REQUIRED_READS_OUTPUT")"
fi

RULE_PATH_ERROR="$(validate_plan_rule_paths "$RULE_BUNDLE_JSON" "$PLAN_FILE")"

if [ -n "$RULE_PATH_ERROR" ]; then
    fail_protocol "$RULE_PATH_ERROR"
fi

case "$CURRENT_STATUS" in
    PLANNED)
        bash "$FLOW_STATE_SH" start-execute "$SLUG" >/dev/null
        PROTOCOL_STATE="IMPLEMENTING"
        PROTOCOL_SUMMARY="已进入 IMPLEMENTING，可按计划继续执行。"
        ;;
    REVIEW_FAILED)
        bash "$FLOW_STATE_SH" start-fix "$SLUG" >/dev/null
        PROTOCOL_STATE="FIXING_REVIEW"
        PROTOCOL_SUMMARY="已进入 FIXING_REVIEW，可按审查结论继续修复。"
        ;;
    IMPLEMENTING)
        PROTOCOL_STATE="IMPLEMENTING"
        PROTOCOL_SUMMARY="当前已在 IMPLEMENTING，可继续按计划执行。"
        ;;
    FIXING_REVIEW)
        PROTOCOL_STATE="FIXING_REVIEW"
        PROTOCOL_SUMMARY="当前已在 FIXING_REVIEW，可继续按审查结论修复。"
        ;;
esac

PROTOCOL_RESULT="success"
PROTOCOL_NEXT="ai-flow-plan-coding"
emit_protocol
