#!/bin/bash
# test_flow_code_optimize.sh — flow-code-optimize.sh 单元测试
# 测试 code-optimize 状态门禁。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

CODE_OPTIMIZE_SH="$SCRIPTS_DIR/flow-code-optimize.sh"
FLOW_STATE_SH="$SCRIPTS_DIR/flow-state.sh"

echo "=== flow-code-optimize.sh 测试 ==="
echo ""

# --- 测试 1: 无 slug ---
test_no_slug() {
    local output exit_code=0
    output="$(bash "$CODE_OPTIMIZE_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "无 slug 时退出码为1"
    assert_contains "$output" "用法" "无 slug 时显示用法"
}

# --- 测试 2: 找不到 slug ---
test_slug_not_found() {
    local dir
    dir="$(create_temp_project "code-opt-2")"
    local output exit_code=0
    output="$(bash "$CODE_OPTIMIZE_SH" "nonexist" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "找不到 slug 时失败"
    cleanup_temp_project "$dir"
}

# --- 测试 3: AWAITING_REVIEW 状态允许优化 ---
test_awaiting_review_allows_optimize() {
    local dir
    dir="$(create_temp_project "code-opt-3")"
    create_minimal_state "$dir" "20260519-test-opt-ar"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-opt-ar" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-opt-ar" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-opt-ar" \
        --event implementation_completed >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-opt-ar" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "AWAITING_REVIEW" "AWAITING_REVIEW 状态正确"
    test_info "AWAITING_REVIEW 状态允许 code-optimize（需要 rule-loader 环境）"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 4: PLANNED 状态不允许优化 ---
test_planned_not_allowed() {
    local dir
    dir="$(create_temp_project "code-opt-4")"
    create_minimal_state "$dir" "20260519-test-opt-pl"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-opt-pl" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-opt-pl" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "PLANNED" "PLANNED 状态正确"
    test_info "PLANNED 状态不应允许进入 code-optimize"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 5: IMPLEMENTING 状态不允许优化 ---
test_implementing_not_allowed() {
    local dir
    dir="$(create_temp_project "code-opt-5")"
    create_minimal_state "$dir" "20260519-test-opt-impl"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-opt-impl" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-opt-impl" \
        --event execute_started >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-opt-impl" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "IMPLEMENTING" "IMPLEMENTING 状态正确"
    test_info "IMPLEMENTING 状态不应允许进入 code-optimize"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 运行 ---
test_no_slug
test_slug_not_found
test_awaiting_review_allows_optimize
test_planned_not_allowed
test_implementing_not_allowed

print_summary
exit "$fail_count"
