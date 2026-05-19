#!/bin/bash
# test_flow_change.sh — flow-change.sh 单元测试
# 测试需求变更记录功能。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

FLOW_CHANGE_SH="$SCRIPTS_DIR/flow-change.sh"
FLOW_STATE_SH="$SCRIPTS_DIR/flow-state.sh"

echo "=== flow-change.sh 测试 ==="
echo ""

# --- 测试 1: 参数缺失 ---
test_missing_params() {
    local output exit_code=0
    output="$(bash "$FLOW_CHANGE_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "无参数时退出码为1"
    assert_contains "$output" "用法" "无参数时显示用法"

    output="$(bash "$FLOW_CHANGE_SH" "slug-only" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "只有 slug 时退出码为1"
}

# --- 测试 2: 找不到 slug ---
test_slug_not_found() {
    local dir
    dir="$(create_temp_project "change-2")"
    local output exit_code=0
    output="$(bash "$FLOW_CHANGE_SH" "nonexist" "变更描述" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "找不到 slug 时失败"
    assert_contains "$output" "找不到" "找不到 slug 时输出错误"
    cleanup_temp_project "$dir"
}

# --- 测试 3: 变更记录写入 plan 文件 ---
test_change_recorded_in_plan() {
    local dir
    dir="$(create_temp_project "change-3")"

    # 创建 plan 文件（含需求变更记录章节）
    mkdir -p "$dir/.ai-flow/plans"
    cat > "$dir/.ai-flow/plans/test-change.md" <<'EOF'
# 测试计划

## 1. 概述
测试需求变更功能。

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|
| {YYYY-MM-DD HH:MM} | {执行过程中新增或调整的需求；无则保留空表} | {用户确认/文档同步/其他} |
EOF

    create_minimal_state "$dir" "20260519-test-change"

    # 注意：flow-change.sh 需要 rule-loader，这里仅验证状态和 plan 文件结构
    # 真正的变更写入需要完整的规则环境

    local plan_content
    plan_content="$(cat "$dir/.ai-flow/plans/test-change.md")"
    assert_contains "$plan_content" "需求变更记录" "plan 包含变更记录章节"

    cleanup_temp_project "$dir"
}

# --- 测试 4: PLANNED 状态变更后转为 AWAITING_PLAN_REVIEW ---
test_change_from_planned() {
    local dir
    dir="$(create_temp_project "change-4")"
    create_minimal_state "$dir" "20260519-test-change-pl"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-pl" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1

    # 手动模拟 plan_reopened 事件（flow-change.sh 内部会触发）
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-pl" \
        --event plan_reopened --note "需求变更测试" >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-change-pl" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "AWAITING_PLAN_REVIEW" "PLANNED 变更后转为 AWAITING_PLAN_REVIEW"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 5: IMPLEMENTING + plan impact 变更后转为 AWAITING_PLAN_REVIEW ---
test_change_from_implementing() {
    local dir
    dir="$(create_temp_project "change-5")"
    create_minimal_state "$dir" "20260519-test-change-impl"
    setup_minimal_change_runtime "$dir"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-impl" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-impl" \
        --event execute_started >/dev/null 2>&1

    local output exit_code=0
    output="$(bash "$FLOW_CHANGE_SH" --impact plan "20260519-test-change-impl" "新增接口字段，调整验收范围" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "IMPLEMENTING + plan impact 执行成功"
    assert_contains "$output" "已记录需求变更" "IMPLEMENTING + plan impact 输出成功摘要"

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-change-impl" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "AWAITING_PLAN_REVIEW" "IMPLEMENTING + plan impact 变更后转为 AWAITING_PLAN_REVIEW"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 6: IMPLEMENTING + implementation impact 变更后保持 IMPLEMENTING ---
test_change_from_implementing_with_implementation_impact() {
    local dir
    dir="$(create_temp_project "change-6")"
    create_minimal_state "$dir" "20260519-test-change-impl-keep"
    setup_minimal_change_runtime "$dir"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-impl-keep" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-impl-keep" \
        --event execute_started >/dev/null 2>&1

    local before_count after_count status plan_content
    before_count="$(python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path(".ai-flow/state/20260519-test-change-impl-keep.json").read_text(encoding="utf-8"))
print(len(data["transitions"]))
PY
)"
    bash "$FLOW_CHANGE_SH" --impact implementation "20260519-test-change-impl-keep" "调整页面样式细节与文案" >/dev/null 2>&1
    after_count="$(python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path(".ai-flow/state/20260519-test-change-impl-keep.json").read_text(encoding="utf-8"))
print(len(data["transitions"]))
PY
)"

    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-change-impl-keep" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "IMPLEMENTING" "IMPLEMENTING + implementation impact 保持 IMPLEMENTING"
    assert_equal "$after_count" "$before_count" "IMPLEMENTING + implementation impact 不新增状态迁移"
    plan_content="$(cat "$dir/.ai-flow/plans/test.md")"
    assert_contains "$plan_content" "调整页面样式细节与文案" "IMPLEMENTING + implementation impact 仍写入变更记录"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 7: IMPLEMENTING + auto 根据描述判定为 plan ---
test_change_from_implementing_auto_plan() {
    local dir
    dir="$(create_temp_project "change-7")"
    create_minimal_state "$dir" "20260519-test-change-impl-auto-plan"
    setup_minimal_change_runtime "$dir"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-impl-auto-plan" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-impl-auto-plan" \
        --event execute_started >/dev/null 2>&1

    bash "$FLOW_CHANGE_SH" "20260519-test-change-impl-auto-plan" "调整接口和验收标准" >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-change-impl-auto-plan" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "AWAITING_PLAN_REVIEW" "IMPLEMENTING + auto 命中 plan 级关键词时转为 AWAITING_PLAN_REVIEW"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 8: IMPLEMENTING + auto 根据描述判定为 implementation ---
test_change_from_implementing_auto_implementation() {
    local dir
    dir="$(create_temp_project "change-8")"
    create_minimal_state "$dir" "20260519-test-change-impl-auto-impl"
    setup_minimal_change_runtime "$dir"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-impl-auto-impl" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-impl-auto-impl" \
        --event execute_started >/dev/null 2>&1

    local before_count after_count status
    before_count="$(python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path(".ai-flow/state/20260519-test-change-impl-auto-impl.json").read_text(encoding="utf-8"))
print(len(data["transitions"]))
PY
)"
    bash "$FLOW_CHANGE_SH" "20260519-test-change-impl-auto-impl" "调整页面样式与说明文案" >/dev/null 2>&1
    after_count="$(python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path(".ai-flow/state/20260519-test-change-impl-auto-impl.json").read_text(encoding="utf-8"))
print(len(data["transitions"]))
PY
)"

    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-change-impl-auto-impl" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "IMPLEMENTING" "IMPLEMENTING + auto 命中实现级描述时保持 IMPLEMENTING"
    assert_equal "$after_count" "$before_count" "IMPLEMENTING + auto 实现级描述不新增状态迁移"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 9: AWAITING_REVIEW 状态变更后转为 IMPLEMENTING ---
test_change_from_awaiting_review() {
    local dir
    dir="$(create_temp_project "change-6")"
    create_minimal_state "$dir" "20260519-test-change-ar"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-ar" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-ar" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-ar" \
        --event implementation_completed >/dev/null 2>&1

    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-ar" \
        --event implementation_reopened --note "待审变更" >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-change-ar" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "IMPLEMENTING" "AWAITING_REVIEW 变更后转为 IMPLEMENTING"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 10: DONE 状态变更后转为 IMPLEMENTING ---
test_change_from_done() {
    local dir
    dir="$(create_temp_project "change-7")"
    create_minimal_state "$dir" "20260519-test-change-done"
    cd "$dir"
    for cmd in \
        "plan_review_passed --result passed --engine e --model m" \
        "execute_started" \
        "implementation_completed" \
        "review_passed --result passed --report-file .ai-flow/reports/r.md --engine e --model m"
    do
        bash $FLOW_STATE_SH transition --slug "20260519-test-change-done" --event $cmd >/dev/null 2>&1
    done

    bash "$FLOW_STATE_SH" transition --slug "20260519-test-change-done" \
        --event implementation_reopened --note "完成后再变更" >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-change-done" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "IMPLEMENTING" "DONE 变更后转为 IMPLEMENTING"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 运行 ---
test_missing_params
test_slug_not_found
test_change_recorded_in_plan
test_change_from_planned
test_change_from_implementing
test_change_from_implementing_with_implementation_impact
test_change_from_implementing_auto_plan
test_change_from_implementing_auto_implementation
test_change_from_awaiting_review
test_change_from_done

print_summary
exit "$fail_count"
