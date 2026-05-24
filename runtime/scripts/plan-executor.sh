#!/bin/bash
# plan-executor.sh — AI Flow 统一 plan/group/child 创建入口
# 用法:
#   plan-executor.sh [--group|--no-group] "需求" [slug]
#   plan-executor.sh --child-of-group <group_slug> --child-id <child_id> --child-meta-json <json> "child需求" <child_slug>
#   plan-executor.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FLOW_STATE_SH="$SCRIPT_DIR/flow-state.sh"
FLOW_PLAN_GROUP_STATE_SH="$SCRIPT_DIR/flow-plan-group-state.sh"
FLOW_PLAN_GROUP_SH="$SCRIPT_DIR/flow-plan-group.sh"

# ─── helpers ───────────────────────────────────────────────────────────────

fail() {
    echo "错误: $1" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
用法:
  plan-executor.sh [--group|--no-group] "需求" [slug]
  plan-executor.sh --child-of-group <group_slug> --child-id <child_id> --child-meta-json <json> "child需求" <child_slug>
  plan-executor.sh --help

选项:
  --group              强制创建 plan group
  --no-group           强制普通 plan，关闭关键词/长度自动 group 判断
  --child-of-group     child 模式：所属 group slug
  --child-id           child 模式：子项 ID
  --child-meta-json    child 模式：子项元数据 JSON
  --help               显示此帮助信息
EOF
    exit 1
}

# resolve_flow_root — 从当前目录向上找到包含 .ai-flow/plan-groups/state 或 .ai-flow/state 的目录
resolve_flow_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.ai-flow/state" ] || [ -d "$dir/.ai-flow/plan-groups/state" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# should_use_group — 根据需求描述自动判断是否使用 group
should_use_group() {
    local demand="$1"
    local lower_demand
    lower_demand="$(echo "$demand" | tr '[:upper:]' '[:lower:]')"

    # 关键词匹配
    local keywords=("长任务" "计划组" "拆分" "多阶段" "long task" "plan group" "multi-stage")
    for kw in "${keywords[@]}"; do
        if [[ "$lower_demand" == *"$kw"* ]]; then
            return 0
        fi
    done

    return 1
}

# backup_plan — 版本备份
backup_plan() {
    local slug="$1"
    local plan_dir="$2"
    local plan_file="$plan_dir/${slug}.md"

    if [ ! -f "$plan_file" ]; then
        return 0
    fi

    local history_dir="$plan_dir/history/$slug"
    mkdir -p "$history_dir"

    # 找到下一个版本号
    local max_version=0
    if [ -d "$history_dir" ]; then
        for f in "$history_dir"/v*.md; do
            if [ -f "$f" ]; then
                local ver
                ver="$(basename "$f" .md | sed 's/^v//')"
                if [[ "$ver" =~ ^[0-9]+$ ]] && [ "$ver" -gt "$max_version" ]; then
                    max_version="$ver"
                fi
            fi
        done
    fi

    local next_version=$((max_version + 1))
    local backup_file="$history_dir/v${next_version}.md"

    cp "$plan_file" "$backup_file"

    # 维护 manifest.json
    local manifest="$history_dir/manifest.json"
    if [ ! -f "$manifest" ]; then
        echo '{"versions":[]}' > "$manifest"
    fi

    python3 - "$manifest" "$next_version" "$plan_file" <<'PY'
import json
import sys
from pathlib import Path
from datetime import datetime

manifest_path = Path(sys.argv[1])
version = int(sys.argv[2])
original_path = sys.argv[3]

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["versions"].append({
    "version": version,
    "backup_file": f"v{version}.md",
    "backed_up_at": datetime.now().isoformat(),
    "original_path": original_path,
})
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

# ─── 参数解析 ──────────────────────────────────────────────────────────────

FORCE_GROUP=0
FORCE_NO_GROUP=0
CHILD_MODE=0
CHILD_GROUP_SLUG=""
CHILD_ID=""
CHILD_META_JSON=""
DEMAND=""
SLUG=""

parse_args() {
    local args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                ;;
            --group)
                FORCE_GROUP=1
                shift
                ;;
            --no-group)
                FORCE_NO_GROUP=1
                shift
                ;;
            --child-of-group)
                CHILD_MODE=1
                CHILD_GROUP_SLUG="$2"
                shift 2
                ;;
            --child-id)
                CHILD_ID="$2"
                shift 2
                ;;
            --child-meta-json)
                CHILD_META_JSON="$2"
                shift 2
                ;;
            -*)
                fail "未知选项: $1"
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # 互斥校验
    if [ "$FORCE_GROUP" -eq 1 ] && [ "$FORCE_NO_GROUP" -eq 1 ]; then
        fail "--group 与 --no-group 不能同时使用"
    fi

    # child 模式与 --group 互斥
    if [ "$CHILD_MODE" -eq 1 ] && [ "$FORCE_GROUP" -eq 1 ]; then
        fail "child 模式下不能使用 --group 参数"
    fi

    # 提取需求和 slug
    if [ "${#args[@]}" -ge 1 ]; then
        DEMAND="${args[0]}"
    fi
    if [ "${#args[@]}" -ge 2 ]; then
        SLUG="${args[1]}"
    fi

    if [ -z "$DEMAND" ] && [ "$CHILD_MODE" -eq 0 ]; then
        fail "需求描述不能为空"
    fi

    # child 模式参数校验
    if [ "$CHILD_MODE" -eq 1 ]; then
        [ -n "$CHILD_GROUP_SLUG" ] || fail "--child-of-group 不能为空"
        [ -n "$CHILD_ID" ] || fail "--child-id 不能为空"
        [ -n "$CHILD_META_JSON" ] || fail "--child-meta-json 不能为空"
        [ -n "$DEMAND" ] || fail "child 需求描述不能为空"
        [ -n "$SLUG" ] || fail "child slug 不能为空"
    fi
}

# ─── 创建普通 plan ────────────────────────────────────────────────────────

create_plan() {
    local demand="$1"
    local slug="$2"
    local force_group="$3"

    # 生成 slug
    if [ -z "$slug" ]; then
        local date_prefix
        date_prefix="$(date +%Y%m%d)"
        # 从需求中提取简短关键词作为 slug 后缀
        local keyword
        keyword="$(echo "$demand" | head -c 50 | sed 's/[^a-zA-Z0-9一-龥]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | tr '[:upper:]' '[:lower:]')"
        slug="${date_prefix}-${keyword}"
    fi

    local plan_file=".ai-flow/plans/${slug}.md"
    local project_dir
    project_dir="$(resolve_flow_root)" || fail "找不到 .ai-flow/ 目录"

    # 版本备份
    backup_plan "$slug" "$project_dir/.ai-flow/plans"

    # 构建 repo-scope-json
    local git_root
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$project_dir")"
    local repo_scope_json='{"mode":"plan_repos","repos":[{"id":"owner","path":".","git_root":"'"$git_root"'","role":"owner"}]}'

    # 调用 flow-state.sh transition
    bash "$FLOW_STATE_SH" transition --slug "$slug" --event plan_created \
        --title "$demand" \
        --plan-file "$plan_file" \
        --repo-scope-json "$repo_scope_json" \
        --note "由 plan-executor.sh 创建"

    # 创建空 plan 文档
    local plan_md_path="$project_dir/$plan_file"
    mkdir -p "$(dirname "$plan_md_path")"
    if [ ! -f "$plan_md_path" ]; then
        cat > "$plan_md_path" <<EOF
# 实施计划：${demand}

> 创建日期：$(date +%Y-%m-%d)
> 创建时间：$(date +%H:%M:%S)
> 需求简称：${slug}
EOF
    fi

    echo ""
    echo "RESULT: success"
    echo "AGENT: plan-executor"
    echo "ARTIFACT: $plan_file"
    echo "STATE: AWAITING_PLAN_REVIEW"
    echo "NEXT: ai-flow-plan-review"
    echo "SUMMARY: 普通 plan $slug 已创建，状态进入 AWAITING_PLAN_REVIEW。"
}

# ─── 创建 group plan ──────────────────────────────────────────────────────

create_group() {
    local demand="$1"
    local group_slug="$2"

    if [ -z "$group_slug" ]; then
        local date_prefix
        date_prefix="$(date +%Y%m%d)"
        local keyword
        keyword="$(echo "$demand" | head -c 50 | sed 's/[^a-zA-Z0-9一-龥]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | tr '[:upper:]' '[:lower:]')"
        group_slug="${date_prefix}-${keyword}"
    fi

    local group_file=".ai-flow/plan-groups/${group_slug}.md"
    local project_dir
    project_dir="$(resolve_flow_root)" || fail "找不到 .ai-flow/ 目录"

    # 调用 flow-plan-group.sh create
    bash "$FLOW_PLAN_GROUP_SH" create \
        --group-slug "$group_slug" \
        --title "$demand" \
        --group-file "$group_file"

    echo ""
    echo "RESULT: success"
    echo "AGENT: plan-executor"
    echo "ARTIFACT: $group_file"
    echo "STATE: AWAITING_GROUP_REVIEW"
    echo "NEXT: ai-flow-plan-review"
    echo "SUMMARY: 计划组 $group_slug 已创建，状态进入 AWAITING_GROUP_REVIEW。"
}

# ─── 创建 child plan ──────────────────────────────────────────────────────

create_child() {
    local group_slug="$1"
    local child_id="$2"
    local child_meta_json="$3"
    local demand="$4"
    local child_slug="$5"

    local project_dir
    project_dir="$(resolve_flow_root)" || fail "找不到 .ai-flow/ 目录"

    # 从 child-meta-json 解析 title、planned_semantic_slug、scope_summary
    local child_title child_semantic_slug
    child_title="$(echo "$child_meta_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('title',''))")"
    child_semantic_slug="$(echo "$child_meta_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('planned_semantic_slug',''))")"

    # 生成 dated slug
    local date_prefix
    date_prefix="$(date +%Y%m%d)"
    if [ -z "$child_semantic_slug" ]; then
        child_semantic_slug="$(echo "$demand" | head -c 50 | sed 's/[^a-zA-Z0-9一-龥]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | tr '[:upper:]' '[:lower:]')"
    fi
    local dated_slug="${date_prefix}-${child_semantic_slug}"

    # 如果提供了 child_slug，使用它（不带日期前缀的话自动添加）
    if [ -n "$child_slug" ]; then
        if [[ "$child_slug" =~ ^[0-9]{8}- ]]; then
            dated_slug="$child_slug"
        else
            dated_slug="${date_prefix}-${child_slug}"
        fi
    fi

    local plan_file=".ai-flow/plans/${dated_slug}.md"

    # 版本备份
    backup_plan "$dated_slug" "$project_dir/.ai-flow/plans"

    # 构建 repo-scope-json
    local git_root
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$project_dir")"
    local repo_scope_json='{"mode":"plan_repos","repos":[{"id":"owner","path":".","git_root":"'"$git_root"'","role":"owner"}]}'

    # 先创建子 plan 状态（进入 AWAITING_PLAN_REVIEW）
    bash "$FLOW_STATE_SH" transition --slug "$dated_slug" --event plan_created \
        --title "[$group_slug] $child_id: $demand" \
        --plan-file "$plan_file" \
        --repo-scope-json "$repo_scope_json" \
        --note "由计划组 $group_slug 的 $child_id 创建 (plan-executor.sh child 模式)"

    # 创建子 plan 文档（带计划组元数据头 + 8 章空结构）
    local plan_md_path="$project_dir/$plan_file"
    mkdir -p "$(dirname "$plan_md_path")"
    cat > "$plan_md_path" <<EOF
# 实施计划：${demand}

> 创建日期：$(date +%Y-%m-%d)
> 创建时间：$(date +%H:%M:%S)
> 所属计划组：${group_slug}
> 计划组子项：${child_id}

## 1. 需求概述

## 2. 技术分析

## 3. 实施步骤

## 4. 测试计划

## 5. 风险与注意事项

## 6. 验收标准

## 7. 需求变更记录

## 8. 计划审核记录
EOF

    # 回写 group state 的 children[] 中的 created_slug、plan_file、state_file
    python3 - "$project_dir/.ai-flow/plan-groups/state/${group_slug}.json" "$child_id" "$dated_slug" "$plan_file" <<'PY'
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

    # 触发 child_bound 事件
    bash "$FLOW_PLAN_GROUP_STATE_SH" transition --group-slug "$group_slug" --event child_bound \
        --note "绑定子计划 $child_id ($dated_slug) by plan-executor.sh"

    echo ""
    echo "RESULT: success"
    echo "AGENT: plan-executor"
    echo "ARTIFACT: $plan_file"
    echo "STATE: AWAITING_PLAN_REVIEW"
    echo "NEXT: ai-flow-plan-review"
    echo "SUMMARY: Child plan $dated_slug ($child_id) 已创建，状态进入 AWAITING_PLAN_REVIEW。"
}

# ─── 主入口 ────────────────────────────────────────────────────────────────

main() {
    # 依赖校验
    [ -x "$FLOW_STATE_SH" ] || fail "缺少 flow-state.sh: $FLOW_STATE_SH"
    [ -x "$FLOW_PLAN_GROUP_STATE_SH" ] || fail "缺少 flow-plan-group-state.sh: $FLOW_PLAN_GROUP_STATE_SH"
    [ -x "$FLOW_PLAN_GROUP_SH" ] || fail "缺少 flow-plan-group.sh: $FLOW_PLAN_GROUP_SH"

    PROJECT_DIR="$(resolve_flow_root)" || fail "当前目录不在包含 .ai-flow/ 的 flow root 内。"
    export PROJECT_DIR

    parse_args "$@"

    # 路由到不同的创建路径
    if [ "$CHILD_MODE" -eq 1 ]; then
        # child 模式：隐含 --no-group
        create_child "$CHILD_GROUP_SLUG" "$CHILD_ID" "$CHILD_META_JSON" "$DEMAND" "$SLUG"
    elif [ "$FORCE_GROUP" -eq 1 ]; then
        # 强制 group
        create_group "$DEMAND" "$SLUG"
    elif [ "$FORCE_NO_GROUP" -eq 1 ]; then
        # 强制普通 plan
        create_plan "$DEMAND" "$SLUG" "0"
    else
        # 自动判断
        if should_use_group "$DEMAND"; then
            echo "检测到长任务关键词，建议创建计划组。"
            # 检查是否可以通过环境变量跳过确认
            if [ "${AI_FLOW_AUTO_CONFIRM:-0}" = "1" ]; then
                create_group "$DEMAND" "$SLUG"
            else
                echo "是否创建计划组？(y/n)"
                read -r answer
                if [[ "$answer" =~ ^[Yy] ]]; then
                    create_group "$DEMAND" "$SLUG"
                else
                    create_plan "$DEMAND" "$SLUG" "0"
                fi
            fi
        else
            create_plan "$DEMAND" "$SLUG" "0"
        fi
    fi
}

main "$@"
