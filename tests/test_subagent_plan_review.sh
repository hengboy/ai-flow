#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_plan_review_passed_with_notes() {
    local temp_root project runtime_script executor plan_file
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-review" "plan-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_PLAN_REVIEW" "20260503" "demo"
    plan_file="$project/.ai-flow/plans/20260503/demo.md"

    (
        cd "$project"
        FAKE_PLAN_REVIEW_RESULT=passed_with_notes run_with_fake_plan_agents "$temp_root" bash "$executor" demo >"$temp_root/review-pass.out"
    )

    assert_equals "PLANNED" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/review-pass.out" "RESULT" "success"
    assert_protocol_field "$temp_root/review-pass.out" "REVIEW_RESULT" "passed_with_notes"
    assert_protocol_field "$temp_root/review-pass.out" "STATE" "PLANNED"
    assert_protocol_field "$temp_root/review-pass.out" "NEXT" "ai-flow-plan-coding"
    assert_contains "$plan_file" "审核状态：passed_with_notes"
    assert_contains "$plan_file" "\\[可选\\]\\[Minor\\]"
    assert_contains "$plan_file" "#### 第 1 轮"
    rm -rf "$temp_root"
}

test_plan_review_failed() {
    local temp_root project runtime_script executor plan_file
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-review" "plan-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_PLAN_REVIEW" "20260503" "demo"
    plan_file="$project/.ai-flow/plans/20260503/demo.md"

    (
        cd "$project"
        FAKE_PLAN_REVIEW_RESULT=failed run_with_fake_plan_agents "$temp_root" bash "$executor" demo >"$temp_root/review-fail.out"
    )

    assert_equals "PLAN_REVIEW_FAILED" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/review-fail.out" "RESULT" "success"
    assert_protocol_field "$temp_root/review-fail.out" "REVIEW_RESULT" "failed"
    assert_protocol_field "$temp_root/review-fail.out" "STATE" "PLAN_REVIEW_FAILED"
    assert_protocol_field "$temp_root/review-fail.out" "NEXT" "ai-flow-plan"
    assert_contains "$plan_file" "审核状态：failed"
    assert_contains "$plan_file" "\\[待修订\\]\\[Important\\]"
    rm -rf "$temp_root"
}

test_plan_review_passed_with_notes
test_plan_review_failed
