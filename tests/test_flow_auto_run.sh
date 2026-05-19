#!/bin/bash
# test_flow_auto_run.sh — flow-auto-run.sh 单元测试
# 测试 list/resolve/dirty 三个子命令。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

AUTO_RUN_SH="$SCRIPTS_DIR/flow-auto-run.sh"
FLOW_STATE_SH="$SCRIPTS_DIR/flow-state.sh"

echo "=== flow-auto-run.sh 测试 ==="
echo ""

# --- 测试 1: 无状态文件时 list 为空 ---
test_list_no_states() {
    local dir
    dir="$(create_temp_project "auto-run-1")"
    cd "$dir"
    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" list 2>&1)" || exit_code=$?
    # 有 .ai-flow/state 但无 json 文件，list 应输出空
    assert_exit_code "$exit_code" 0 "list 在无状态文件时正常退出"
    if [[ -z "$output" ]]; then
        test_pass "list 在无状态文件时输出为空"
    else
        test_fail "list 在无状态文件时输出为空" "实际输出: $output"
    fi
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 2: 有合法状态时 list 有输出 ---
test_list_with_valid_state() {
    local dir
    dir="$(create_temp_project "auto-run-2")"
    create_minimal_state "$dir" "20260519-test-auto-run"
    # 先转换到 PLANNED 状态
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-auto-run" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" list 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "list 有状态文件时正常退出"
    assert_contains "$output" "20260519-test-auto-run" "list 输出包含 slug"
    assert_contains "$output" "PLANNED" "list 输出包含状态"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 3: 过滤掉不自动运行的状态 ---
test_list_filters_non_auto_states() {
    local dir
    dir="$(create_temp_project "auto-run-3")"
    # AWAITING_PLAN_REVIEW 不在自动运行状态列表中
    create_minimal_state "$dir" "20260519-test-filter"
    cd "$dir"
    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" list 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "list 过滤非自动状态"
    if [[ -z "$output" ]]; then
        test_pass "list 过滤掉 AWAITING_PLAN_REVIEW"
    else
        test_fail "list 过滤掉 AWAITING_PLAN_REVIEW" "不应输出: $output"
    fi
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 4: resolve 精确匹配 ---
test_resolve_exact() {
    local dir
    dir="$(create_temp_project "auto-run-4")"
    create_minimal_state "$dir" "20260519-test-resolve"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-resolve" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" resolve "20260519-test-resolve" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "resolve 精确匹配"
    assert_contains "$output" "20260519-test-resolve" "resolve 输出 slug"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 5: resolve 模糊匹配 ---
test_resolve_fuzzy() {
    local dir
    dir="$(create_temp_project "auto-run-5")"
    create_minimal_state "$dir" "20260519-test-fuzzy"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-fuzzy" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" resolve "fuzzy" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "resolve 模糊匹配"
    assert_contains "$output" "20260519-test-fuzzy" "resolve 模糊匹配成功"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 6: resolve 匹配多个 ---
test_resolve_multiple() {
    local dir
    dir="$(create_temp_project "auto-run-6")"
    create_minimal_state "$dir" "20260519-test-multi-a"
    create_minimal_state "$dir" "20260519-test-multi-b"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-multi-a" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-multi-b" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" resolve "test-multi" 2>&1)" || exit_code=$?
    # 匹配多个应失败
    assert_exit_code "$exit_code" 1 "resolve 匹配多个时失败"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 7: resolve 无匹配 ---
test_resolve_no_match() {
    local dir
    dir="$(create_temp_project "auto-run-7")"
    create_minimal_state "$dir" "20260519-test-nomatch"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-nomatch" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" resolve "notexist" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "resolve 无匹配时失败"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 8: usage ---
test_usage() {
    local output exit_code=0
    output="$(bash "$AUTO_RUN_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "无参数时显示用法"
}

# --- 测试 9: dirty check 干净 ---
test_dirty_clean() {
    local dir
    dir="$(create_temp_project "auto-run-9")"
    # 初始化 git 仓库
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md
    git add README.md
    git commit -q -m "init"

    create_minimal_state "$dir" "20260519-test-dirty-clean"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-clean" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" dirty "20260519-test-dirty-clean" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "dirty check 干净仓库"
    assert_contains "$output" "clean" "干净仓库返回 clean"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 运行 ---
test_list_no_states
test_list_with_valid_state
test_list_filters_non_auto_states
test_resolve_exact
test_resolve_fuzzy
test_resolve_multiple
test_resolve_no_match
test_usage
test_dirty_clean

print_summary
exit "$fail_count"
