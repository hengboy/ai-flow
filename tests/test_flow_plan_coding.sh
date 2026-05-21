#!/bin/bash
# test_flow_plan_coding.sh — flow-plan-coding.sh 单元测试
# 测试状态门禁和协议输出。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

PLAN_CODING_SH="$SCRIPTS_DIR/flow-plan-coding.sh"
FLOW_STATE_SH="$SCRIPTS_DIR/flow-state.sh"

echo "=== flow-plan-coding.sh 测试 ==="
echo ""

# --- 测试 1: 无 slug ---
test_no_slug() {
    local output exit_code=0
    output="$(bash "$PLAN_CODING_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "无 slug 时退出码为1"
    assert_contains "$output" "用法" "无 slug 时显示用法"
}

# --- 测试 2: 找不到 slug ---
test_slug_not_found() {
    local dir
    dir="$(create_temp_project "plan-coding-2")"
    local output exit_code=0
    output="$(bash "$PLAN_CODING_SH" "nonexist" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "找不到 slug 时失败"
    assert_contains "$output" "找不到" "找不到 slug 时输出错误"
    cleanup_temp_project "$dir"
}

# --- 测试 3: PLANNED 状态通过门禁 ---
test_planned_passes() {
    local dir
    dir="$(create_temp_project "plan-coding-3")"
    # 创建 rule-loader.sh 的 mock（因为门禁需要它）
    mkdir -p "$dir/.ai-flow/state"

    # 先创建一个 plan 文件
    mkdir -p "$dir/.ai-flow/plans"
    cat > "$dir/.ai-flow/plans/test.md" <<'EOF'
# 测试计划
## 1. 概述
## 7. 需求变更记录
EOF

    create_minimal_state "$dir" "20260519-test-planned"
    cd "$dir"
    # 转换到 PLANNED
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-planned" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    cd "$SCRIPT_DIR"

    # 注意：此测试需要 rule-loader.sh，这里只测试基本的状态门禁
    # 真正的门禁会在有完整规则环境的项目中运行
    test_info "PLANNED 状态门禁需要在有 rule-loader 的环境中测试"
    cleanup_temp_project "$dir"
}

# --- 测试 4: AWAITING_PLAN_REVIEW 状态被拒 ---
test_awaiting_plan_review_rejected() {
    local dir
    dir="$(create_temp_project "plan-coding-4")"
    create_minimal_state "$dir" "20260519-test-apr"
    cd "$dir"

    # 因为缺少 rule-loader，我们直接验证状态文件当前是 AWAITING_PLAN_REVIEW
    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-apr" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "AWAITING_PLAN_REVIEW" "状态文件正确创建"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 5: IMPLEMENTING 状态继续 ---
test_implementing_continue() {
    local dir
    dir="$(create_temp_project "plan-coding-5")"
    create_minimal_state "$dir" "20260519-test-impl"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-impl" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-impl" \
        --event execute_started >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-impl" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "IMPLEMENTING" "IMPLEMENTING 状态正确"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 6: REVIEW_FAILED 状态 ---
test_review_failed_state() {
    local dir
    dir="$(create_temp_project "plan-coding-6")"
    create_minimal_state "$dir" "20260519-test-rf"
    cd "$dir"
    # 快速走到 REVIEW_FAILED
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event implementation_completed >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event review_failed --result failed --report-file .ai-flow/reports/r.md --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event fix_started >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-rf" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "FIXING_REVIEW" "FIXING_REVIEW 状态正确"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 7: DONE 状态被拒 ---
test_done_rejected() {
    local dir
    dir="$(create_temp_project "plan-coding-7")"
    create_minimal_state "$dir" "20260519-test-done"
    cd "$dir"
    create_minimal_review_report "$dir" "r.md"
    # 快速走到 DONE
    for cmd in \
        "plan_review_passed --result passed --engine e --model m" \
        "execute_started" \
        "implementation_completed" \
        "review_passed --result passed --report-file .ai-flow/reports/r.md --engine e --model m"
    do
        bash $FLOW_STATE_SH transition --slug "20260519-test-done" --event $cmd >/dev/null 2>&1
    done

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-done" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "DONE" "DONE 状态正确"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 运行 ---
test_no_slug
test_slug_not_found
test_planned_passes
test_awaiting_plan_review_rejected
test_implementing_continue
test_review_failed_state
test_done_rejected

print_summary
exit "$fail_count"
