#!/bin/bash
set -euo pipefail

# shellcheck source=tests/helpers.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.bash"

test_flow_change_normalizes_table_cells() {
    local temp_root project row_count
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state "$project" "demo" "PLANNED" "20260503"

    (cd "$project" && bash "$TEST_ROOT/workflows/flow-change.sh" demo $'第一行\n第二行 | 带竖线') > "$temp_root/change.out" 2>&1

    assert_not_contains "$project/.ai-flow/plans/20260503/demo.md" "{YYYY-MM-DD HH:MM}"
    assert_contains "$project/.ai-flow/plans/20260503/demo.md" "第一行 第二行 \\\\| 带竖线"
    row_count=$(awk '
        /^## 7\. 需求变更记录/ {in_section=1; next}
        /^## / && in_section {exit}
        in_section && /^\|/ {count++}
        END {print count + 0}
    ' "$project/.ai-flow/plans/20260503/demo.md")
    assert_equals "3" "$row_count"
    rm -rf "$temp_root"
}

test_flow_change_register_is_in_review_prompt() {
    local temp_root project
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "change-register" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "passed"
    setup_git_repo_with_change "$project"

    (cd "$project" && bash "$TEST_ROOT/workflows/flow-change.sh" change-register "用户确认追加导出按钮") > "$temp_root/change.out" 2>&1
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-review.sh" change-register) > "$temp_root/review.out" 2>&1

    assert_contains "$project/.ai-flow/plans/20260503/change-register.md" "用户确认追加导出按钮"
    assert_contains "$temp_root/captured-prompt.txt" "需求变更记录"
    assert_contains "$temp_root/captured-prompt.txt" "用户确认追加导出按钮"
    rm -rf "$temp_root"
}

test_root_cause_review_loop_change_allows_regular_round_three() {
    local temp_root project status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "REVIEW_FAILED" "20260503"
    setup_git_repo_with_change "$project"

    (cd "$project" && bash "$TEST_ROOT/workflows/flow-state.sh" start-fix demo >/dev/null)
    (cd "$project" && bash "$TEST_ROOT/workflows/flow-state.sh" finish-fix demo >/dev/null)
    write_fake_codex_review "$temp_root" "failed" "failed_valid"
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-review.sh" demo) > "$temp_root/review-round2.out" 2>&1
    status=$(state_field "$project" "demo" "current_status")
    assert_equals "REVIEW_FAILED" "$status"

    (cd "$project" && bash "$TEST_ROOT/workflows/flow-state.sh" start-fix demo >/dev/null)
    (cd "$project" && bash "$TEST_ROOT/workflows/flow-state.sh" finish-fix demo >/dev/null)
    (cd "$project" && bash "$TEST_ROOT/workflows/flow-change.sh" demo "[root-cause-review-loop] 根因：遗漏缺陷族；受影响缺陷族：测试/证据；前两轮遗漏原因：只看单点；补充验证：bash tests/test_review_workflow.sh") > "$temp_root/change.out" 2>&1

    write_fake_codex_review "$temp_root" "passed"
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-review.sh" demo) > "$temp_root/review-round3.out" 2>&1

    status=$(state_field "$project" "demo" "current_status")
    assert_equals "DONE" "$status"
    assert_contains "$project/.ai-flow/plans/20260503/demo.md" "\\[root-cause-review-loop\\]"
    assert_contains "$temp_root/captured-prompt.txt" "\\[root-cause-review-loop\\]"
    assert_file_exists "$project/.ai-flow/reports/20260503/demo-review-v3.md"
    rm -rf "$temp_root"
}

test_flow_change_normalizes_table_cells
test_flow_change_register_is_in_review_prompt
test_root_cause_review_loop_change_allows_regular_round_three
