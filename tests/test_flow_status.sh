#!/bin/bash
# test_flow_status.sh — flow-status.sh 单元测试
# 测试项目状态展示功能。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

FLOW_STATUS_SH="$SCRIPTS_DIR/flow-status.sh"
FLOW_STATE_SH="$SCRIPTS_DIR/flow-state.sh"

echo "=== flow-status.sh 测试 ==="
echo ""

# --- 测试 1: 没有 .ai-flow 目录 ---
test_no_ai_flow() {
    local dir
    dir="$(mktemp -d)"
    cd "$dir"
    local output exit_code=0
    output="$(bash "$FLOW_STATUS_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "无 .ai-flow 时正常退出"
    assert_contains "$output" "没有" "无 .ai-flow 时提示"
    rm -rf "$dir"
}

# --- 测试 2: 有 .ai-flow 但无状态文件 ---
test_no_states() {
    local dir
    dir="$(create_temp_project "status-2")"
    cd "$dir"
    local output exit_code=0
    output="$(bash "$FLOW_STATUS_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "无状态文件时正常退出"
    assert_contains "$output" "AI Flow" "输出包含标题"
    assert_contains "$output" "(无)" "无状态文件时显示 (无)"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 3: 展示合法状态 ---
test_show_valid_state() {
    local dir
    dir="$(create_temp_project "status-3")"
    create_minimal_state "$dir" "20260519-test-status"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-status" \
        --event plan_review_passed --result passed --engine test-engine --model test-model >/dev/null 2>&1
    local output exit_code=0
    output="$(bash "$FLOW_STATUS_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "有状态文件时正常退出"
    assert_contains "$output" "20260519-test-status" "展示包含 slug"
    assert_contains "$output" "PLANNED" "展示包含状态"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 4: 展示无效状态 ---
test_show_invalid_state() {
    local dir
    dir="$(create_temp_project "status-4")"
    echo '{"schema_version": 4, "slug": "20260519-test-invalid"}' \
        > "$dir/.ai-flow/state/20260519-test-invalid.json"
    cd "$dir"
    local output exit_code=0
    output="$(bash "$FLOW_STATUS_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "含无效状态文件时正常退出"
    assert_contains "$output" "无效" "展示提示状态无效"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 5: 多个状态展示 ---
test_show_multiple_states() {
    local dir
    dir="$(create_temp_project "status-5")"
    create_minimal_state "$dir" "20260519-test-a"
    create_minimal_state "$dir" "20260519-test-b"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-a" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-a" \
        --event execute_started >/dev/null 2>&1
    local output exit_code=0
    output="$(bash "$FLOW_STATUS_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "多个状态正常退出"
    assert_contains "$output" "20260519-test-a" "展示第一个 slug"
    assert_contains "$output" "20260519-test-b" "展示第二个 slug"
    assert_contains "$output" "IMPLEMENTING" "展示第一个状态"
    assert_contains "$output" "AWAITING_PLAN_REVIEW" "展示第二个状态"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 6: 统计输出 ---
test_statistics_output() {
    local dir
    dir="$(create_temp_project "status-6")"
    create_minimal_state "$dir" "20260519-test-stat"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-stat" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    local output exit_code=0
    output="$(bash "$FLOW_STATUS_SH" 2>&1)" || exit_code=$?
    assert_contains "$output" "总数" "统计包含总数"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 运行 ---
test_no_ai_flow
test_no_states
test_show_valid_state
test_show_invalid_state
test_show_multiple_states
test_statistics_output

print_summary
exit "$fail_count"
