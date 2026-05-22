#!/bin/bash
# flow-plan-group.sh — AI Flow 计划组编排入口
# 用法:
#   flow-plan-group.sh list
#   flow-plan-group.sh resolve <slug或唯一关键词>
#   flow-plan-group.sh create --group-slug <slug> --title <标题> --group-file <路径> [--children-json <json>]
#   flow-plan-group.sh start-child --group-slug <slug>
#   flow-plan-group.sh child-completed --group-slug <slug>
#   flow-plan-group.sh final-review --group-slug <slug>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FLOW_PLAN_GROUP_STATE_SH="$SCRIPT_DIR/flow-plan-group-state.sh"
FLOW_STATE_SH="$SCRIPT_DIR/flow-state.sh"

usage() {
    cat >&2 <<'EOF'
用法:
  flow-plan-group.sh list
  flow-plan-group.sh resolve <slug或唯一关键词>
  flow-plan-group.sh create --group-slug <slug> --title <标题> --group-file <路径>
  flow-plan-group.sh start-child --group-slug <slug>
  flow-plan-group.sh child-completed --group-slug <slug>
  flow-plan-group.sh final-review --group-slug <slug>
EOF
    exit 1
}

fail() {
    echo "$1" >&2
    exit 1
}

# Resolve flow root
if [ ! -f "${AI_FLOW_HOME}/lib/flow-root-helper.sh" ]; then
    echo "错误: 缺少 flow-root-helper.sh: ${AI_FLOW_HOME}/lib/flow-root-helper.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${AI_FLOW_HOME}/lib/flow-root-helper.sh"

validate_dependencies() {
    [ -x "$FLOW_PLAN_GROUP_STATE_SH" ] || fail "错误: 缺少 flow-plan-group-state.sh: $FLOW_PLAN_GROUP_STATE_SH"
    [ -x "$FLOW_STATE_SH" ] || fail "错误: 缺少 flow-state.sh: $FLOW_STATE_SH"
}

validate_dependencies
PROJECT_DIR="$(resolve_flow_root)" || fail "当前目录不在包含 .ai-flow/plan-groups/state 的 flow root 内。"
GROUPS_DIR="$PROJECT_DIR/.ai-flow/plan-groups"
STATE_DIR="$GROUPS_DIR/state"
PLAN_DIR="$PROJECT_DIR/.ai-flow/plans"
PLAN_STATE_DIR="$PROJECT_DIR/.ai-flow/state"
mkdir -p "$STATE_DIR" "$GROUPS_DIR/reports"

cmd_list() {
    shopt -s nullglob
    local files=("$STATE_DIR"/*.json)
    shopt -u nullglob

    if [ ${#files[@]} -eq 0 ]; then
        echo "没有计划组。"
        return 0
    fi

    python3 - "${files[@]}" <<'PY'
import json
import sys
from pathlib import Path

for path in sys.argv[1:]:
    try:
        state = json.loads(Path(path).read_text(encoding="utf-8"))
        slug = state.get("group_slug", Path(path).stem)
        status = state.get("current_status", "unknown")
        title = state.get("title", "")
        children_count = len(state.get("children", []))
        current_child = state.get("current_child_id") or "(none)"
        print(f"{slug}\t{status}\t{title}\tchildren={children_count}\tcurrent_child={current_child}")
    except Exception as e:
        print(f"{Path(path).stem}\tERROR\t{e}", file=sys.stderr)
PY
}

cmd_resolve() {
    local query="$1"
    shopt -s nullglob
    local files=("$STATE_DIR"/*.json)
    shopt -u nullglob

    [ ${#files[@]} -gt 0 ] || fail "当前项目没有计划组。"

    python3 - "$query" "${files[@]}" <<'PY'
import sys
from pathlib import Path

query = sys.argv[1].strip().lower()
if not query:
    raise SystemExit("resolve 需要提供 slug 或唯一关键词")

rows = []
for path in sys.argv[2:]:
    import json
    state = json.loads(Path(path).read_text(encoding="utf-8"))
    rows.append({
        "slug": state.get("group_slug", Path(path).stem),
        "title": state.get("title", ""),
        "group_file": state.get("group_file", ""),
    })

exact = [r for r in rows if r["slug"] == query or r["slug"].lower() == query]
if len(exact) == 1:
    print(exact[0]["slug"])
    raise SystemExit(0)

needle = query
matched = [r for r in rows if needle in r["slug"].lower() or needle in r["title"].lower()]
if not matched:
    raise SystemExit(f"找不到匹配 '{query}' 的计划组。")
if len(matched) > 1:
    details = "、".join(r["slug"] for r in matched)
    raise SystemExit(f"匹配到多个计划组，请改用更精确的 slug: {details}")
print(matched[0]["slug"])
PY
}

cmd_create() {
    local group_slug="" title="" group_file="" children_json=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --group-slug) group_slug="$2"; shift 2 ;;
            --title) title="$2"; shift 2 ;;
            --group-file) group_file="$2"; shift 2 ;;
            --children-json) children_json="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    [ -n "$group_slug" ] || fail "--group-slug 不能为空"
    [ -n "$title" ] || fail "--title 不能为空"
    [ -n "$group_file" ] || fail "--group-file 不能为空"

    local args=("transition" "--group-slug" "$group_slug" "--event" "group_created" "--title" "$title" "--group-file" "$group_file")
    if [ -n "$children_json" ]; then
        args+=("--children-json" "$children_json")
    fi

    bash "$FLOW_PLAN_GROUP_STATE_SH" "${args[@]}"

    # 创建空的计划组文档
    local group_md_path="$PROJECT_DIR/$group_file"
    if [ ! -f "$group_md_path" ]; then
        mkdir -p "$(dirname "$group_md_path")"
        cat > "$group_md_path" <<EOF
# 计划组：$title

> 创建日期：$(date +%Y-%m-%d)
> 创建时间：$(date +%H:%M:%S)
> 需求简称：$group_slug

## 子计划列表

| 子项 ID | 标题 | 依赖 | 语义 Slug | 状态 |
|---------|------|------|-----------|------|
EOF
    fi
}

find_next_unlocked_child() {
    local group_slug="$1"
    local state_file="$STATE_DIR/${group_slug}.json"

    python3 - "$state_file" "$PLAN_STATE_DIR" <<'PY'
import json
import sys
from pathlib import Path

state_file = Path(sys.argv[1])
plan_state_dir = Path(sys.argv[2])
state = json.loads(state_file.read_text(encoding="utf-8"))
children = state.get("children", [])

created_slugs = {}
for child in children:
    if child.get("created_slug"):
        created_slugs[child["child_id"]] = child["created_slug"]

done_children = set()
for child_id, slug in created_slugs.items():
    child_state_path = plan_state_dir / f"{slug}.json"
    if child_state_path.exists():
        child_state = json.loads(child_state_path.read_text(encoding="utf-8"))
        if child_state.get("current_status") == "DONE":
            done_children.add(child_id)

for child in children:
    child_id = child["child_id"]
    if child_id in created_slugs:
        continue  # 已创建，跳过
    deps = child.get("depends_on", [])
    if all(dep in done_children for dep in deps):
        print(child_id)
        raise SystemExit(0)

print("none")
PY
}

cmd_start_child() {
    local group_slug=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --group-slug) group_slug="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    [ -n "$group_slug" ] || fail "--group-slug 不能为空"

    local current_status
    current_status="$(bash "$FLOW_PLAN_GROUP_STATE_SH" show --group-slug "$group_slug" --field current_status)"

    # 允许从 GROUP_PLANNED 或 GROUP_REVIEW_FAILED（追加 child 后）启动
    # 也允许从 RUNNING_CHILD 启动（当被 child-completed 调用时）
    if [ "$current_status" != "GROUP_PLANNED" ] && [ "$current_status" != "GROUP_REVIEW_FAILED" ] && [ "$current_status" != "RUNNING_CHILD" ]; then
        fail "Current status is $current_status, must be GROUP_PLANNED, GROUP_REVIEW_FAILED or RUNNING_CHILD to start child."
    fi

    # 如果是 GROUP_REVIEW_FAILED，先通过 child_added 回到 GROUP_PLANNED
    if [ "$current_status" = "GROUP_REVIEW_FAILED" ]; then
        bash "$FLOW_PLAN_GROUP_STATE_SH" transition --group-slug "$group_slug" --event child_added --note "追加新 child 后回到 GROUP_PLANNED"
        current_status="GROUP_PLANNED"
    fi

    # RUNNING_CHILD 状态下不需要额外的状态转换，直接创建下一个 child

    local next_child
    next_child="$(find_next_unlocked_child "$group_slug")"
    [ "$next_child" != "none" ] || fail "没有可启动的子计划（所有 child 已创建或依赖未满足）。"

    # 读取 child 元数据
    local child_meta
    child_meta="$(python3 - "$STATE_DIR/${group_slug}.json" "$next_child" <<'PY'
import json
import sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
child_id = sys.argv[2]
for child in state["children"]:
    if child["child_id"] == child_id:
        print(json.dumps({
            "title": child["title"],
            "planned_semantic_slug": child["planned_semantic_slug"],
            "scope_summary": child["scope_summary"],
        }))
        raise SystemExit(0)
raise SystemExit(f"找不到 child: {child_id}")
PY
    )"

    local child_title child_semantic_slug
    child_title="$(echo "$child_meta" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")"
    child_semantic_slug="$(echo "$child_meta" | python3 -c "import sys,json; print(json.load(sys.stdin)['planned_semantic_slug'])")"

    # 生成 dated slug
    local date_prefix
    date_prefix="$(date +%Y%m%d)"
    local dated_slug="${date_prefix}-${child_semantic_slug}"

    # 创建子 plan 状态（进入 AWAITING_PLAN_REVIEW）
    local plan_file=".ai-flow/plans/${dated_slug}.md"
    local repo_scope_json
    repo_scope_json='{"mode":"plan_repos","repos":[{"id":"owner","path":".","git_root":"'"$(git rev-parse --show-toplevel)"'","role":"owner"}]}'

    bash "$FLOW_STATE_SH" transition --slug "$dated_slug" --event plan_created \
        --title "[$group_slug] $child_title" \
        --plan-file "$plan_file" \
        --repo-scope-json "$repo_scope_json" \
        --note "由计划组 $group_slug 的 $next_child 创建"

    # 创建子 plan 文档（带计划组元数据头）
    local plan_md_path="$PROJECT_DIR/$plan_file"
    mkdir -p "$(dirname "$plan_md_path")"
    cat > "$plan_md_path" <<EOF
# 实施计划：$child_title

> 创建日期：$(date +%Y-%m-%d)
> 创建时间：$(date +%H:%M:%S)
> 所属计划组：$group_slug
> 计划组子项：$next_child

## 需求概述

${child_meta}
EOF

    # 更新 group state 的 children[] 中对应 child 的 created_slug、plan_file、state_file
    python3 - "$STATE_DIR/${group_slug}.json" "$next_child" "$dated_slug" "$plan_file" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
child_id = sys.argv[2]
dated_slug = sys.argv[3]
plan_file = sys.argv[4]

state = json.loads(state_path.read_text(encoding="utf-8"))
for child in state["children"]:
    if child["child_id"] == child_id:
        child["created_slug"] = dated_slug
        child["plan_file"] = plan_file
        child["state_file"] = f".ai-flow/state/{dated_slug}.json"
        break

state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

    # 触发 child_bound 事件（仅在 GROUP_PLANNED 时）
    if [ "$current_status" = "GROUP_PLANNED" ]; then
        bash "$FLOW_PLAN_GROUP_STATE_SH" transition --group-slug "$group_slug" --event child_bound \
            --note "绑定子计划 $next_child ($dated_slug)"
    fi

    # 更新 current_child_id
    python3 - "$STATE_DIR/${group_slug}.json" "$next_child" <<'PY'
import json
import sys
from pathlib import Path
state_path = Path(sys.argv[1])
child_id = sys.argv[2]
state = json.loads(state_path.read_text(encoding="utf-8"))
state["current_child_id"] = child_id
state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

    echo "子计划 $next_child ($dated_slug) 已创建，状态进入 AWAITING_PLAN_REVIEW。"
}

cmd_child_completed() {
    local group_slug=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --group-slug) group_slug="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    [ -n "$group_slug" ] || fail "--group-slug 不能为空"

    local current_status
    current_status="$(bash "$FLOW_PLAN_GROUP_STATE_SH" show --group-slug "$group_slug" --field current_status)"
    [ "$current_status" = "RUNNING_CHILD" ] || fail "当前状态为 $current_status，只允许在 RUNNING_CHILD 时处理 child-completed。"

    local current_child_id
    current_child_id="$(bash "$FLOW_PLAN_GROUP_STATE_SH" show --group-slug "$group_slug" --field current_child_id)"
    [ "$current_child_id" != "null" ] && [ -n "$current_child_id" ] || fail "current_child_id 为空。"

    # 确认 current_child_id 对应的 state_file 的 current_status 为 DONE
    local child_state_path
    child_state_path="$(python3 - "$STATE_DIR/${group_slug}.json" "$current_child_id" <<'PY'
import json
import sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
child_id = sys.argv[2]
for child in state["children"]:
    if child["child_id"] == child_id:
        sf = child.get("state_file")
        if not sf:
            raise SystemExit("null")
        print(sf)
        raise SystemExit(0)
print("null")
PY
    )"

    if [ "$child_state_path" = "null" ]; then
        fail "子计划 $current_child_id 没有 state_file。"
    fi

    local child_status
    child_status="$(python3 -c "
import json, sys
state = json.loads(open('$PROJECT_DIR/$child_state_path').read())
print(state.get('current_status', 'unknown'))
")"

    [ "$child_status" = "DONE" ] || fail "子计划 $current_child_id 当前状态为 $child_status，不是 DONE。"

    # 检查是否还有下一个已解锁 child
    local next_child
    next_child="$(find_next_unlocked_child "$group_slug")"

    if [ "$next_child" != "none" ]; then
        # 有下一个 child：创建后保持 RUNNING_CHILD
        cmd_start_child --group-slug "$group_slug"
        bash "$FLOW_PLAN_GROUP_STATE_SH" transition --group-slug "$group_slug" --event child_completed \
            --note "子计划 $current_child_id 完成，已启动下一个 $next_child"
        echo "子计划 $current_child_id 完成，已启动下一个子计划 $next_child。"
    else
        # 无下一个 child：触发 child_completed，判断最终状态
        local result_status
        result_status="$(bash "$FLOW_PLAN_GROUP_STATE_SH" transition --group-slug "$group_slug" --event child_completed \
            --note "子计划 $current_child_id 完成，等待最终审核")"
        if echo "$result_status" | grep -q "AWAITING_GROUP_FINAL_REVIEW"; then
            echo "所有子计划已完成，计划组进入 AWAITING_GROUP_FINAL_REVIEW。"
        else
            echo "子计划 $current_child_id 已完成，仍有子计划未 DONE，保持 RUNNING_CHILD。"
        fi
    fi
}

cmd_final_review() {
    local group_slug=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --group-slug) group_slug="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    [ -n "$group_slug" ] || fail "--group-slug 不能为空"

    local current_status
    current_status="$(bash "$FLOW_PLAN_GROUP_STATE_SH" show --group-slug "$group_slug" --field current_status)"
    [ "$current_status" = "AWAITING_GROUP_FINAL_REVIEW" ] || fail "当前状态为 $current_status，只允许在 AWAITING_GROUP_FINAL_REVIEW 时执行 final-review。"

    # 检查所有 children 的 state_file 的 current_status 都为 DONE
    python3 - "$STATE_DIR/${group_slug}.json" "$PLAN_STATE_DIR" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
plan_state_dir = Path(sys.argv[2])
children = state.get("children", [])
all_done = True
for child in children:
    sf = child.get("state_file")
    if not sf:
        print(f"SKIP {child['child_id']}: 未创建（无 state_file）")
        continue
    sp = plan_state_dir.parent / "state" / f"{Path(sf).stem}.json"
    if not sp.exists():
        # 尝试从 .ai-flow/state/ 查找
        sp2 = plan_state_dir / f"{Path(sf).stem}.json"
        if not sp2.exists():
            print(f"FAIL {child['child_id']}: state_file 不存在: {sf}")
            all_done = False
            continue
        sp = sp2
    cs = json.loads(sp.read_text(encoding="utf-8"))
    status = cs.get("current_status", "unknown")
    if status != "DONE":
        print(f"FAIL {child['child_id']}: 状态为 {status}，不是 DONE")
        all_done = False
    else:
        print(f"OK {child['child_id']}: DONE")

if not all_done:
    raise SystemExit("存在未完成的子计划，无法执行最终审核。")
print("\n所有已创建子计划均处于 DONE 状态，可以执行最终审核。")
PY

    echo ""
    echo "final-review 检查完成。请由 /ai-flow-plan-review 执行最终审核。"
}

case "${1:-}" in
    list)
        cmd_list
        ;;
    resolve)
        [ $# -eq 2 ] || usage
        cmd_resolve "$2"
        ;;
    create)
        shift
        cmd_create "$@"
        ;;
    start-child)
        shift
        cmd_start_child "$@"
        ;;
    child-completed)
        shift
        cmd_child_completed "$@"
        ;;
    final-review)
        shift
        cmd_final_review "$@"
        ;;
    *)
        usage
        ;;
esac
