#!/bin/bash
# flow-plan-group-summary.sh — 计划组总结脚本
# 用法:
#   flow-plan-group-summary.sh --group-slug <slug>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FLOW_PLAN_GROUP_STATE_SH="$SCRIPT_DIR/flow-plan-group-state.sh"

fail() {
    echo "$1" >&2
    exit 1
}

if [ ! -f "${AI_FLOW_HOME}/lib/flow-root-helper.sh" ]; then
    echo "错误: 缺少 flow-root-helper.sh: ${AI_FLOW_HOME}/lib/flow-root-helper.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${AI_FLOW_HOME}/lib/flow-root-helper.sh"

PROJECT_DIR="$(resolve_flow_root)" || fail "当前目录不在 flow root 内。"
GROUPS_DIR="$PROJECT_DIR/.ai-flow/plan-groups"
STATE_DIR="$GROUPS_DIR/state"
REPORTS_DIR="$GROUPS_DIR/reports"
PLAN_STATE_DIR="$PROJECT_DIR/.ai-flow/state"
PLAN_REPORTS_DIR="$PROJECT_DIR/.ai-flow/reports"

GROUP_SLUG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --group-slug) GROUP_SLUG="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -n "$GROUP_SLUG" ] || fail "--group-slug 不能为空"

STATE_FILE="$STATE_DIR/${GROUP_SLUG}.json"
[ -f "$STATE_FILE" ] || fail "计划组状态文件不存在: $STATE_FILE"

# 输出计划组状态
echo "## 计划组状态"
echo ""
python3 - "$STATE_FILE" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(f"- **group_slug**: {state.get('group_slug')}")
print(f"- **title**: {state.get('title')}")
print(f"- **current_status**: {state.get('current_status')}")
print(f"- **created_at**: {state.get('created_at')}")
print(f"- **updated_at**: {state.get('updated_at')}")
print(f"- **current_child_id**: {state.get('current_child_id') or '(none)'}")
print(f"- **children 数量**: {len(state.get('children', []))}")
PY

echo ""
echo "## 子计划列表"
echo ""

# 子计划列表（含运行时状态）
python3 - "$STATE_FILE" "$PLAN_STATE_DIR" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
plan_state_dir = Path(sys.argv[2])
children = state.get("children", [])

print("| 子项 ID | 标题 | 依赖 | 语义 Slug | Created Slug | 运行时状态 |")
print("|---------|------|------|-----------|--------------|------------|")

for child in children:
    child_id = child.get("child_id", "")
    title = child.get("title", "")
    depends_on = ", ".join(child.get("depends_on", [])) or "(无)"
    semantic = child.get("planned_semantic_slug", "")
    created = child.get("created_slug") or "(未创建)"

    runtime_status = "(未创建)"
    if child.get("state_file"):
        sf = plan_state_dir / f"{Path(child['state_file']).stem}.json"
        if sf.exists():
            cs = json.loads(sf.read_text(encoding="utf-8"))
            runtime_status = cs.get("current_status", "unknown")
        elif child.get("created_slug"):
            sf2 = plan_state_dir.parent / "state" / f"{child['created_slug']}.json"
            if sf2.exists():
                cs = json.loads(sf2.read_text(encoding="utf-8"))
                runtime_status = cs.get("current_status", "unknown")

    print(f"| {child_id} | {title} | {depends_on} | {semantic} | {created} | {runtime_status} |")
PY

echo ""
echo "## Group Review 历史"
echo ""

shopt -s nullglob
group_review_files=("$REPORTS_DIR/${GROUP_SLUG}-group-review-r"*.md)
shopt -u nullglob

if [ ${#group_review_files[@]} -eq 0 ]; then
    echo "无 group review 记录。"
else
    for f in "${group_review_files[@]}"; do
        echo "- $(basename "$f")"
    done
fi

echo ""
echo "## Final Review 历史"
echo ""

shopt -s nullglob
final_review_files=("$REPORTS_DIR/${GROUP_SLUG}-final-review-r"*.md)
shopt -u nullglob

if [ ${#final_review_files[@]} -eq 0 ]; then
    echo "无 final review 记录。"
else
    for f in "${final_review_files[@]}"; do
        echo "- $(basename "$f")"
    done
fi

echo ""
echo "## 子计划 Latest Review"
echo ""

python3 - "$STATE_FILE" "$PLAN_REPORTS_DIR" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
plan_reports_dir = Path(sys.argv[2])
children = state.get("children", [])

for child in children:
    child_id = child.get("child_id", "")
    created_slug = child.get("created_slug")
    if not created_slug:
        print(f"- {child_id}: (未创建，无 review)")
        continue

    # 查找 review 报告
    review_patterns = [
        f"{created_slug}-review.md",
        f"{created_slug}-coding-review.md",
    ]
    found = []
    for pattern in review_patterns:
        p = plan_reports_dir / pattern
        if p.exists():
            found.append(pattern)

    if found:
        print(f"- {child_id} ({created_slug}): {', '.join(found)}")
    else:
        print(f"- {child_id} ({created_slug}): (无 review 记录)")
PY
