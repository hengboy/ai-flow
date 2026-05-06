#!/bin/bash
set -euo pipefail

# shellcheck source=tests/helpers.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.bash"

test_flow_status_groups_by_json_state_only() {
    local temp_root project
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"

    create_state "$project" "draft" "AWAITING_PLAN_REVIEW" "20260503"
    create_state "$project" "plan-broken" "PLAN_REVIEW_FAILED" "20260503"
    create_state "$project" "todo" "PLANNED" "20260503"
    create_state "$project" "doing" "IMPLEMENTING" "20260503"
    create_state "$project" "reviewing" "AWAITING_REVIEW" "20260503"
    create_state "$project" "broken" "REVIEW_FAILED" "20260503"
    create_state "$project" "fixing" "FIXING_REVIEW" "20260503"
    create_state "$project" "done" "DONE" "20260503"

    printf 'old failed report\n' > "$project/.ai-flow/reports/20260503/done-review-recheck.md"

    (cd "$project" && bash "$AI_FLOW_STATUS_SCRIPT") > "$temp_root/status.out"

    assert_contains "$temp_root/status.out" "draft \\[AWAITING_PLAN_REVIEW\\] 待计划审核"
    assert_contains "$temp_root/status.out" "plan-broken \\[PLAN_REVIEW_FAILED\\] 待修订计划"
    assert_contains "$temp_root/status.out" "todo \\[PLANNED\\] 计划已审核通过，待编码"
    assert_contains "$temp_root/status.out" "doing \\[IMPLEMENTING\\] 开发中"
    assert_contains "$temp_root/status.out" "reviewing \\[AWAITING_REVIEW\\] 待审查"
    assert_contains "$temp_root/status.out" "broken \\[REVIEW_FAILED\\] 待修复"
    assert_contains "$temp_root/status.out" "fixing \\[FIXING_REVIEW\\] 修复中"
    assert_contains "$temp_root/status.out" "done \\[DONE\\] 可再审查"
    assert_contains "$temp_root/status.out" "next: ai-flow-plan"
    assert_contains "$temp_root/status.out" "next: ai-flow-execute"
    assert_contains "$temp_root/status.out" "next: ai-flow-review"
    assert_not_contains "$temp_root/status.out" "done \\[REVIEW_FAILED\\]"
    rm -rf "$temp_root"
}

test_flow_status_does_not_duplicate_old_failed_reports() {
    local temp_root project
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"

    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    printf 'stale failed report\n' > "$project/.ai-flow/reports/20260503/demo-review.md"

    (cd "$project" && bash "$AI_FLOW_STATUS_SCRIPT") > "$temp_root/status.out"

    assert_contains "$temp_root/status.out" "demo \\[AWAITING_REVIEW\\] 待审查"
    assert_not_contains "$temp_root/status.out" "demo \\[REVIEW_FAILED\\]"
    rm -rf "$temp_root"
}

test_flow_status_groups_by_json_state_only
test_flow_status_does_not_duplicate_old_failed_reports
