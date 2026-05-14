#!/bin/bash
# flow-code-optimize.sh — optimize 绑定 slug 时的统一状态与规则门禁
# 用法: flow-code-optimize.sh {slug或唯一关键词}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RULE_LOADER_SH="$AI_FLOW_HOME/lib/rule-loader.sh"
FLOW_STATE_SH="$SCRIPT_DIR/flow-state.sh"
if [ ! -f "$RULE_LOADER_SH" ]; then
    RULE_LOADER_SH="$(cd "$SCRIPT_DIR/../.." && pwd)/subagents/shared/lib/rule-loader.sh"
fi

if [ -z "${1:-}" ]; then
    echo "用法: flow-code-optimize.sh {slug或唯一关键词}" >&2
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
    echo "AGENT: ai-flow-code-optimize"
    echo "ARTIFACT: none"
    echo "SCOPE: bound"
    echo "STATE: $PROTOCOL_STATE"
    echo "NEXT: $PROTOCOL_NEXT"
    echo "SUMMARY: $PROTOCOL_SUMMARY"
}

fail_protocol() {
    PROTOCOL_RESULT="failed"
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

report_all_blocking_routes_are_optimize() {
    local report_file="$1"
    python3 - "$report_file" <<'PY'
import sys
from pathlib import Path

def parse_rows(lines):
    rows = []
    for line in lines:
        if not line.startswith("|"):
            continue
        cells = [part.strip() for part in line.split("|")[1:-1]]
        if not cells or cells[0] in {"#", "缺陷编号"}:
            continue
        if set(cells[0]) == {"-"}:
            continue
        rows.append(cells)
    return rows

text = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
in_defect = False
blocking_routes = set()
for line in text:
    if line.startswith("## 4. 缺陷清单"):
        in_defect = True
        continue
    if line.startswith("## 5. ") and in_defect:
        break
    if not in_defect:
        continue
    for cells in parse_rows([line]):
        severity = cells[1] if len(cells) > 1 else ""
        route = cells[-2] if len(cells) > 2 else ""
        status = cells[-1] if cells else ""
        is_blocking = severity in {"Critical", "Important"} or status == "[待修复]"
        if not is_blocking:
            continue
        if route not in {"ai-flow-plan-coding", "ai-flow-code-optimize"}:
            print("invalid")
            raise SystemExit(0)
        blocking_routes.add(route)

if not blocking_routes:
    print("none")
elif blocking_routes == {"ai-flow-code-optimize"}:
    print("optimize-only")
else:
    print("mixed")
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
PROTOCOL_RESULT="failed"
PROTOCOL_STATE="$CURRENT_STATUS"
PROTOCOL_NEXT="none"
PROTOCOL_SUMMARY=""

RULE_REPO_ARGS=()
while IFS= read -r repo_arg; do
    [ -n "$repo_arg" ] || continue
    RULE_REPO_ARGS+=("$repo_arg")
done < <(collect_rule_repo_args "$STATE_FILE")

if [ ${#RULE_REPO_ARGS[@]} -eq 0 ]; then
    RULE_REPO_ARGS=("owner::${PROJECT_DIR}")
fi

if ! RULE_BUNDLE_JSON="$(load_rule_bundle_json "code_optimize_runtime" "ai-flow-code-optimize" "" "${RULE_REPO_ARGS[@]}" 2>&1)"; then
    fail_protocol "$(extract_rule_loader_error "$RULE_BUNDLE_JSON")"
fi

REQUIRED_READS_OUTPUT=""
if ! REQUIRED_READS_OUTPUT="$(render_required_reads_block "$RULE_BUNDLE_JSON" 2>&1)"; then
    fail_protocol "$(extract_rule_loader_error "$REQUIRED_READS_OUTPUT")"
fi

case "$CURRENT_STATUS" in
    AWAITING_REVIEW)
        PROTOCOL_RESULT="success"
        PROTOCOL_STATE="AWAITING_REVIEW"
        PROTOCOL_NEXT="ai-flow-code-optimize"
        PROTOCOL_SUMMARY="当前状态为 AWAITING_REVIEW，可在不推进状态的前提下执行优化。"
        ;;
    REVIEW_FAILED)
        REPORT_FILE="$(state_field "$STATE_FILE" "last_review.report_file")"
        case "$(report_all_blocking_routes_are_optimize "$PROJECT_DIR/$REPORT_FILE")" in
            optimize-only)
                bash "$FLOW_STATE_SH" start-fix "$SLUG" >/dev/null
                PROTOCOL_RESULT="success"
                PROTOCOL_STATE="FIXING_REVIEW"
                PROTOCOL_NEXT="ai-flow-code-optimize"
                PROTOCOL_SUMMARY="阻塞缺陷全部路由到 ai-flow-code-optimize，已进入 FIXING_REVIEW。"
                ;;
            mixed)
                fail_protocol "最近失败审查包含 ai-flow-plan-coding 路由的阻塞缺陷，不能直接进入代码优化。"
                ;;
            none)
                fail_protocol "最近失败审查未识别到阻塞缺陷流向，不能进入代码优化。"
                ;;
            *)
                fail_protocol "最近失败审查中的阻塞缺陷修复流向非法，不能进入代码优化。"
                ;;
        esac
        ;;
    FIXING_REVIEW)
        REPORT_FILE="$(state_field "$STATE_FILE" "active_fix.report_file")"
        case "$(report_all_blocking_routes_are_optimize "$PROJECT_DIR/$REPORT_FILE")" in
            optimize-only)
                PROTOCOL_RESULT="success"
                PROTOCOL_STATE="FIXING_REVIEW"
                PROTOCOL_NEXT="ai-flow-code-optimize"
                PROTOCOL_SUMMARY="当前已在 FIXING_REVIEW，可继续执行优化修复。"
                ;;
            mixed)
                fail_protocol "当前修复上下文包含 ai-flow-plan-coding 路由的阻塞缺陷，不能继续仅做代码优化。"
                ;;
            none)
                fail_protocol "当前修复上下文未识别到阻塞缺陷流向，不能继续代码优化。"
                ;;
            *)
                fail_protocol "当前修复上下文中的阻塞缺陷修复流向非法，不能继续代码优化。"
                ;;
        esac
        ;;
    AWAITING_PLAN_REVIEW|PLAN_REVIEW_FAILED|PLANNED|IMPLEMENTING|DONE)
        fail_protocol "当前状态为 ${CURRENT_STATUS}，不允许进入绑定优化。"
        ;;
    *)
        fail_protocol "不支持的当前状态: ${CURRENT_STATUS}"
        ;;
esac

emit_protocol
