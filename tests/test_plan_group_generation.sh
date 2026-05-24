#!/bin/bash
# test_plan_group_generation.sh — plan executor long-task plan group tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

PLAN_EXECUTOR="$PROJECT_ROOT/subagents/shared/plan/bin/plan-executor.sh"

echo "=== plan group generation 测试 ==="
echo ""

test_long_task_creates_group_without_double_date() {
    local dir output exit_code=0
    local slug="20260523-通用适配"
    dir="$(create_temp_project "plan-group-gen")"
    git -C "$dir" init >/dev/null 2>&1

    cat > "$dir/requirements.md" <<'EOF'
# 通用适配长任务

本需求是长任务，需要拆分为计划组后逐个创建子计划。

## Task 1: 定义装配

统一定义装配入口。

## Task 2: 候选人解析

统一候选人解析语义。

## Task 3: 发布校验

补齐发布校验与接口。
EOF

    output="$(
        cd "$dir" || exit 1
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" \
        AGENT_NAME="test-plan-agent" \
        bash "$PLAN_EXECUTOR" "requirements.md" "$slug" 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "长任务创建计划组成功"
    assert_contains "$output" "RESULT: success" "输出 success 协议"
    assert_contains "$output" "ARTIFACT: .ai-flow/plan-groups/${slug}.md" "artifact 指向计划组文档"
    assert_contains "$output" "STATE: AWAITING_GROUP_REVIEW" "状态进入 AWAITING_GROUP_REVIEW"
    assert_not_contains "$output" "20260523-20260523" "不重复追加日期前缀"

    if [ -f "$dir/.ai-flow/plan-groups/state/${slug}.json" ]; then
        test_pass "创建计划组状态文件"
    else
        test_fail "创建计划组状态文件" "缺少 $dir/.ai-flow/plan-groups/state/${slug}.json"
    fi
    if [ ! -f "$dir/.ai-flow/state/${slug}.json" ]; then
        test_pass "不创建普通 plan 状态文件"
    else
        test_fail "不创建普通 plan 状态文件" "不应存在 $dir/.ai-flow/state/${slug}.json"
    fi

    local child_count
    child_count="$(python3 - "$dir/.ai-flow/plan-groups/state/${slug}.json" <<'PY'
import json
import sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(len(state.get("children", [])))
PY
)"
    assert_equal "$child_count" "3" "按 Task 标题生成 3 个 child"

    cleanup_temp_project "$dir"
}

test_long_task_extracts_step_titles_from_existing_plan_shape() {
    local dir output exit_code=0
    local slug="20260523-adaptation-plan-all"
    dir="$(create_temp_project "plan-group-step-shape")"
    git -C "$dir" init >/dev/null 2>&1

    cat > "$dir/requirements.md" <<'EOF'
# 实施计划：adaptation-plan-all

## 1. 需求概述

这是一个长任务，需要拆分为计划组后逐个创建子计划。

### **原始需求（原文）**

通用适配。

## 2. 技术分析

### 2.1 代码事实

已有 assembler/facade/engine 等边界。

## 3. 实施步骤

### Step 1: 完整定义装配

- Modify: `workflow-rest-api/src/main/java/.../assembler/WorkflowDefinitionAssembler.java`

### Step 2: 统一 Runtime/Migration Facade 定义来源

- Modify: `workflow-rest-api/src/main/java/.../facade/impl/WorkflowRuntimeFacadeImpl.java`

### Step 3: 统一候选人解析

- Modify: `workflow-rest-api/src/main/java/.../service/WorkflowDefinitionApplicationService.java`
EOF

    output="$(
        cd "$dir" || exit 1
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" \
        AGENT_NAME="test-plan-agent" \
        bash "$PLAN_EXECUTOR" "requirements.md" "$slug" 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "Step 结构长任务创建计划组成功"
    assert_contains "$output" "STATE: AWAITING_GROUP_REVIEW" "Step 结构状态进入 AWAITING_GROUP_REVIEW"

    local titles
    titles="$(python3 - "$dir/.ai-flow/plan-groups/state/${slug}.json" <<'PY'
import json
import sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("\n".join(child["title"] for child in state.get("children", [])))
PY
)"
    assert_contains "$titles" "完整定义装配" "按 Step 标题生成 child 1"
    assert_contains "$titles" "统一 Runtime/Migration Facade 定义来源" "按 Step 标题生成 child 2"
    assert_contains "$titles" "统一候选人解析" "按 Step 标题生成 child 3"
    assert_not_contains "$titles" "需求概述" "不把普通章节当 child"
    assert_not_contains "$titles" "代码事实" "不把技术分析子章节当 child"

    cleanup_temp_project "$dir"
}

test_long_task_long_first_line_title_does_not_trip_pipefail() {
    local dir output exit_code=0
    local slug="20260523-long-title"
    dir="$(create_temp_project "plan-group-long-title")"
    git -C "$dir" init >/dev/null 2>&1

    python3 - "$dir/requirements.md" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(
    "长任务" + "标题" * 300 + "\n\n"
    "## Task 1: 第一阶段\n\n"
    "处理第一阶段。\n\n"
    "## Task 2: 第二阶段\n\n"
    "处理第二阶段。\n",
    encoding="utf-8",
)
PY

    output="$(
        cd "$dir" || exit 1
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" \
        AGENT_NAME="test-plan-agent" \
        bash "$PLAN_EXECUTOR" "requirements.md" "$slug" 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "超长首行长任务创建计划组成功"
    assert_contains "$output" "RESULT: success" "超长首行输出 success 协议"
    assert_contains "$output" "STATE: AWAITING_GROUP_REVIEW" "超长首行状态进入 AWAITING_GROUP_REVIEW"

    cleanup_temp_project "$dir"
}

test_long_task_auto_slug_allows_chinese() {
    local dir output exit_code=0
    dir="$(create_temp_project "plan-group-cn")"
    git -C "$dir" init >/dev/null 2>&1

    output="$(
        cd "$dir" || exit 1
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" \
        AGENT_NAME="test-plan-agent" \
        bash "$PLAN_EXECUTOR" "这是一个长任务，需要拆分为多阶段计划组。" "通用适配" 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "中文 slug 长任务创建计划组成功"
    assert_contains "$output" "ARTIFACT: .ai-flow/plan-groups/" "输出计划组 artifact"
    assert_contains "$output" "通用适配" "保留中文 slug"

    cleanup_temp_project "$dir"
}

test_long_task_creates_group_without_double_date
test_long_task_extracts_step_titles_from_existing_plan_shape
test_long_task_long_first_line_title_does_not_trip_pipefail
test_long_task_auto_slug_allows_chinese

print_summary
exit "$fail_count"
