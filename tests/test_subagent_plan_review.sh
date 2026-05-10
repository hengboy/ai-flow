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
    assert_equals "plan_review_passed" "$(state_field "$project" "demo" "transitions.1.event")"
    assert_equals "ai-flow-codex-plan-review" "$(state_field "$project" "demo" "transitions.1.actor")"
    assert_equals "1" "$(wc -l < "$temp_root/codex.plan.calls" | tr -d ' ')"
    assert_file_not_exists "$temp_root/opencode.plan.calls"
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
    assert_equals "plan_review_failed" "$(state_field "$project" "demo" "transitions.1.event")"
    assert_equals "ai-flow-codex-plan-review" "$(state_field "$project" "demo" "transitions.1.actor")"
    assert_equals "1" "$(wc -l < "$temp_root/codex.plan.calls" | tr -d ' ')"
    assert_file_not_exists "$temp_root/opencode.plan.calls"
    rm -rf "$temp_root"
}

test_plan_review_failed_then_passed_with_notes_returns_planned() {
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
        FAKE_PLAN_REVIEW_RESULT=failed run_with_fake_plan_agents "$temp_root" bash "$executor" demo >"$temp_root/review-round1.out"
        FAKE_PLAN_REVIEW_RESULT=passed_with_notes run_with_fake_plan_agents "$temp_root" bash "$executor" demo >"$temp_root/review-round2.out"
    )

    assert_equals "PLANNED" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/review-round2.out" "RESULT" "success"
    assert_protocol_field "$temp_root/review-round2.out" "REVIEW_RESULT" "passed_with_notes"
    assert_protocol_field "$temp_root/review-round2.out" "STATE" "PLANNED"
    assert_protocol_field "$temp_root/review-round2.out" "NEXT" "ai-flow-plan-coding"
    assert_equals "plan_review_failed" "$(state_field "$project" "demo" "transitions.1.event")"
    assert_equals "PLAN_REVIEW_FAILED" "$(state_field "$project" "demo" "transitions.1.to")"
    assert_equals "plan_review_passed" "$(state_field "$project" "demo" "transitions.2.event")"
    assert_equals "PLANNED" "$(state_field "$project" "demo" "transitions.2.to")"
    assert_contains "$plan_file" "#### 第 1 轮"
    assert_contains "$plan_file" "#### 第 2 轮"
    assert_equals "2" "$(wc -l < "$temp_root/codex.plan.calls" | tr -d ' ')"
    assert_file_not_exists "$temp_root/opencode.plan.calls"
    rm -rf "$temp_root"
}

test_plan_review_degraded_when_codex_unavailable() {
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
        FAKE_PLAN_CODEX_MODE=unavailable run_with_fake_plan_agents "$temp_root" bash "$executor" demo >"$temp_root/review-fallback.out"
    )

    assert_protocol_field "$temp_root/review-fallback.out" "RESULT" "success"
    assert_protocol_field "$temp_root/review-fallback.out" "REVIEW_RESULT" "degraded"
    assert_contains "$temp_root/review-fallback.out" "Codex 不可用"
    rm -rf "$temp_root"
}

test_plan_review_codex_mode_fails_when_codex_unavailable() {
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
        AI_FLOW_ENGINE_MODE=codex FAKE_PLAN_CODEX_MODE=unavailable run_with_fake_plan_agents "$temp_root" bash "$executor" demo >"$temp_root/review-codex-mode.out"
    ) || true

    assert_protocol_field "$temp_root/review-codex-mode.out" "RESULT" "failed"
    assert_contains "$temp_root/review-codex-mode.out" "AI_FLOW_ENGINE_MODE=codex"
    rm -rf "$temp_root"
}

test_plan_review_ignores_explicit_model_override() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-review" "plan-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_PLAN_REVIEW" "20260503" "demo"

    (
        cd "$project"
        FAKE_PLAN_REVIEW_RESULT=passed run_with_fake_plan_agents "$temp_root" bash "$executor" demo qwen3.6-plus >"$temp_root/review-model.out"
    )

    assert_protocol_field "$temp_root/review-model.out" "RESULT" "success"
    assert_contains "$temp_root/codex.plan.argv" "-m gpt-5.4"
    assert_not_contains "$temp_root/codex.plan.argv" "-m qwen3.6-plus"
    assert_equals "gpt-5.4" "$(state_field "$project" "demo" "transitions.1.artifacts.model")"
    rm -rf "$temp_root"
}

test_plan_review_passed_with_notes
test_plan_review_failed
test_plan_review_failed_then_passed_with_notes_returns_planned
test_plan_review_degraded_when_codex_unavailable
test_plan_review_codex_mode_fails_when_codex_unavailable
test_plan_review_ignores_explicit_model_override
