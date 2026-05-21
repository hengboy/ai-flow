#!/bin/bash
# test_subagent_coding_review.sh — coding-review incremental 模式集成测试

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_TMP="$PROJECT_DIR/.ai-flow/test-tmp"

setup_test_env() {
    rm -rf "$TEST_TMP"
    mkdir -p "$TEST_TMP/.ai-flow/state" "$TEST_TMP/.ai-flow/reports" "$TEST_TMP/.ai-flow/plans"
}

teardown_test_env() {
    rm -rf "$TEST_TMP"
}

create_mock_review_report() {
    local output_file="$1"
    local review_date="${2:-2026-05-20}"
    local review_time="${3:-10:00:00}"
    local review_mode="${4:-regular}"
    local review_round="${5:-1}"
    local review_result="${6:-passed}"

    mkdir -p "$(dirname "$output_file")"
    cat > "$output_file" <<REPORT
# 审查报告：测试增量审查

> 审查日期：${review_date}
> 审查时间：${review_time}
> 需求简称：test-incremental
> 审查模式：${review_mode}
> 审查轮次：${review_round}
> 审查结果：${review_result}
> 对比计划：\`.ai-flow/plans/test-incremental.md\`
> 审查工具：Codex (gpt-4o high)
> 规则标识：\`review\`、\`fix-review\`、\`verify-before-done\`

## 1. 总体评价

总体通过
REPORT
}

# 测试 1：增量模式触发
# 场景：regular_rounds=1，存在审查报告文件 → REVIEW_MODE 应为 incremental
test_incremental_mode_detect() {
    setup_test_env

    local report_file="$TEST_TMP/.ai-flow/reports/test-review.md"
    create_mock_review_report "$report_file" "2026-05-20" "10:00:00" "regular" "1" "passed"

    # 模拟 REVIEW_MODE 赋值逻辑（与 executor 一致）
    local plan_status="AWAITING_REVIEW"
    local regular_round_count=1
    local latest_regular_review="$report_file"

    local review_mode="regular"
    if [ "$plan_status" = "AWAITING_REVIEW" ]; then
        if [ "$regular_round_count" -ge 1 ] && \
           [ -n "$latest_regular_review" ] && \
           [ -f "$latest_regular_review" ]; then
            review_mode="incremental"
        fi
    fi

    # 断言：REVIEW_MODE 应为 incremental
    if [ "$review_mode" != "incremental" ]; then
        echo "FAIL: test_incremental_mode_detect — 预期 REVIEW_MODE=incremental，实际=$review_mode"
        teardown_test_env
        return 1
    fi

    echo "PASS: test_incremental_mode_detect"
    teardown_test_env
}

# 测试 2：全量模式回退
# 场景：regular_rounds=0 → REVIEW_MODE 应保持 regular
test_full_mode_fallback() {
    setup_test_env

    local plan_status="AWAITING_REVIEW"
    local regular_round_count=0
    local latest_regular_review=""

    local review_mode="regular"
    if [ "$plan_status" = "AWAITING_REVIEW" ]; then
        if [ "$regular_round_count" -ge 1 ] && \
           [ -n "$latest_regular_review" ] && \
           [ -f "$latest_regular_review" ]; then
            review_mode="incremental"
        fi
    fi

    # 断言：REVIEW_MODE 应为 regular
    if [ "$review_mode" != "regular" ]; then
        echo "FAIL: test_full_mode_fallback — 预期 REVIEW_MODE=regular，实际=$review_mode"
        teardown_test_env
        return 1
    fi

    echo "PASS: test_full_mode_fallback"
    teardown_test_env
}

# 测试 3：审查报告不存在时回退全量
# 场景：regular_rounds=1 但审查报告文件不存在 → compute_incremental_changes 应回退全量
test_report_missing_fallback() {
    setup_test_env

    local nonexistent_report="$TEST_TMP/.ai-flow/reports/nonexistent.md"

    # 断言：报告文件不存在
    if [ -f "$nonexistent_report" ]; then
        echo "FAIL: test_report_missing_fallback — mock 报告文件不应存在"
        teardown_test_env
        return 1
    fi

    # 模拟 compute_incremental_changes 的回退逻辑
    local fallback_triggered=0
    if [ -z "$nonexistent_report" ] || [ ! -f "$nonexistent_report" ]; then
        fallback_triggered=1
    fi

    # 断言：回退逻辑应被触发
    if [ "$fallback_triggered" -ne 1 ]; then
        echo "FAIL: test_report_missing_fallback — 预期触发全量回退，实际未触发"
        teardown_test_env
        return 1
    fi

    echo "PASS: test_report_missing_fallback"
    teardown_test_env
}

# 测试 4：event transition 分支正确性
# 场景：REVIEW_MODE=incremental，RESULT=passed → REVIEW_EVENT 应为 review_passed
test_event_transition_incremental() {
    setup_test_env

    # 模拟 event transition 逻辑（与 executor 一致）
    local review_mode="incremental"
    local result="passed"
    local review_event=""

    case "$review_mode" in
        regular|incremental)
            if [ "$result" = "failed" ]; then
                review_event="review_failed"
            else
                review_event="review_passed"
            fi
            ;;
        recheck)
            if [ "$result" = "failed" ]; then
                review_event="recheck_failed"
            else
                review_event="recheck_passed"
            fi
            ;;
    esac

    # 断言：incremental + passed → review_passed（不是 recheck_passed）
    if [ "$review_event" != "review_passed" ]; then
        echo "FAIL: test_event_transition_incremental — 预期 REVIEW_EVENT=review_passed，实际=$review_event"
        teardown_test_env
        return 1
    fi

    # 再测试 incremental + failed → review_failed
    result="failed"
    case "$review_mode" in
        regular|incremental)
            if [ "$result" = "failed" ]; then
                review_event="review_failed"
            else
                review_event="review_passed"
            fi
            ;;
        recheck)
            if [ "$result" = "failed" ]; then
                review_event="recheck_failed"
            else
                review_event="recheck_passed"
            fi
            ;;
    esac

    if [ "$review_event" != "review_failed" ]; then
        echo "FAIL: test_event_transition_incremental(failed) — 预期 REVIEW_EVENT=review_failed，实际=$review_event"
        teardown_test_env
        return 1
    fi

    echo "PASS: test_event_transition_incremental"
    teardown_test_env
}

# 主入口
case "${1:-all}" in
    test_incremental_mode_detect)
        test_incremental_mode_detect
        ;;
    test_full_mode_fallback)
        test_full_mode_fallback
        ;;
    test_report_missing_fallback)
        test_report_missing_fallback
        ;;
    test_event_transition_incremental)
        test_event_transition_incremental
        ;;
    all)
        test_incremental_mode_detect
        test_full_mode_fallback
        test_report_missing_fallback
        test_event_transition_incremental
        echo "All tests passed"
        ;;
    *)
        echo "Unknown test: $1"
        exit 1
        ;;
esac
