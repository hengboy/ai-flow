#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_regular_passed_with_notes_to_done() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed_with_notes run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-notes.out"
    )

    assert_equals "DONE" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/review-notes.out" "RESULT" "success"
    assert_protocol_field "$temp_root/review-notes.out" "REVIEW_RESULT" "passed_with_notes"
    assert_protocol_field "$temp_root/review-notes.out" "STATE" "DONE"
    assert_protocol_field "$temp_root/review-notes.out" "NEXT" "none"
    assert_equals "review_passed" "$(state_field "$project" "demo" "transitions.4.event")"
    assert_equals "ai-flow-codex-plan-coding-review" "$(state_field "$project" "demo" "transitions.4.actor")"
    assert_equals "passed_with_notes" "$(state_field "$project" "demo" "transitions.4.artifacts.result")"
    assert_equals "1" "$(wc -l < "$temp_root/codex.review.calls" | tr -d ' ')"
    assert_file_not_exists "$temp_root/opencode.review.calls"
    rm -rf "$temp_root"
}

test_regular_failed_to_review_failed() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=failed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-failed.out"
    )

    assert_equals "REVIEW_FAILED" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/review-failed.out" "REVIEW_RESULT" "failed"
    assert_protocol_field "$temp_root/review-failed.out" "NEXT" "ai-flow-plan-coding"
    assert_equals "review_failed" "$(state_field "$project" "demo" "transitions.4.event")"
    assert_equals "ai-flow-codex-plan-coding-review" "$(state_field "$project" "demo" "transitions.4.actor")"
    rm -rf "$temp_root"
}

test_recheck_pass_keeps_done() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "DONE" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/recheck.out"
    )

    assert_equals "DONE" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/recheck.out" "REVIEW_RESULT" "passed"
    assert_equals "recheck_passed" "$(state_field "$project" "demo" "transitions.5.event")"
    assert_equals "ai-flow-codex-plan-coding-review" "$(state_field "$project" "demo" "transitions.5.actor")"
    rm -rf "$temp_root"
}

test_passed_with_notes_ignores_status_guide_text() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_REVIEW_INCLUDE_STATUS_NOTE=1 FAKE_CODE_REVIEW_RESULT=passed_with_notes run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-status-note.out"
    )

    assert_protocol_field "$temp_root/review-status-note.out" "RESULT" "success"
    assert_protocol_field "$temp_root/review-status-note.out" "REVIEW_RESULT" "passed_with_notes"
    assert_protocol_field "$temp_root/review-status-note.out" "STATE" "DONE"
    assert_equals "DONE" "$(state_field "$project" "demo" "current_status")"
    rm -rf "$temp_root"
}

test_adhoc_review_without_slug() {
    local temp_root project executor today
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_root "$project"
    setup_git_repo_clean "$project"
    printf 'changed\n' > "$project/src/review-target.txt"
    today="$(date +%Y%m%d)"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" >"$temp_root/adhoc.out"
    )

    assert_protocol_field "$temp_root/adhoc.out" "STATE" "none"
    assert_protocol_field "$temp_root/adhoc.out" "NEXT" "none"
    assert_contains "$temp_root/adhoc.out" "adhoc"
    assert_file_exists "$project/.ai-flow/reports/adhoc/$(basename "$(protocol_field "$temp_root/adhoc.out" "ARTIFACT")")"
    rm -rf "$temp_root"
}

test_no_git_changes_rejected() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_clean "$project"

    set +e
    (
        cd "$project"
        run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/no-change.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected review without git changes to fail"
    assert_protocol_field "$temp_root/no-change.out" "RESULT" "failed"
    assert_contains "$temp_root/no-change.out" "无可审查的 Git 变更"
    rm -rf "$temp_root"
}

test_root_cause_gate_and_fallback() {
    local temp_root project runtime_script executor change_script
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    change_script="$(installed_runtime_script "$temp_root" "flow-change.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        write_review_report_fixture ".ai-flow/reports/20260503/demo-review.md" "demo" ".ai-flow/plans/20260503-demo.md" "regular" "1" "failed" "demo"
        bash "$runtime_script" record-review --slug demo --mode regular --result failed --report-file .ai-flow/reports/20260503/demo-review.md >/dev/null || true
    ) >/dev/null 2>&1 || true

    (
        cd "$project"
        bash "$runtime_script" repair --slug demo --status REVIEW_FAILED --note "fixture align" >/dev/null
        bash "$runtime_script" start-fix demo >/dev/null
        bash "$runtime_script" finish-fix demo >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503/demo-review-v2.md" "demo" ".ai-flow/plans/20260503-demo.md" "regular" "2" "failed" "demo"
        bash "$runtime_script" record-review --slug demo --mode regular --result failed --report-file .ai-flow/reports/20260503/demo-review-v2.md >/dev/null
        bash "$runtime_script" start-fix demo >/dev/null
        bash "$runtime_script" finish-fix demo >/dev/null
    )

    set +e
    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/root-cause-miss.out"
    )
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected round-three gate to fail without root-cause record"
    assert_contains "$temp_root/root-cause-miss.out" "root-cause-review-loop"

    (
        cd "$project"
        bash "$change_script" demo "[root-cause-review-loop] 根因：遗漏缺陷族；受影响缺陷族：测试/证据；前两轮遗漏原因：只看单点；补充验证：bash tests/run.sh" >/dev/null
        FAKE_REVIEW_CODEX_MODE=unavailable run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/root-cause-pass.out"
    )

    assert_protocol_field "$temp_root/root-cause-pass.out" "RESULT" "success"
    assert_protocol_field "$temp_root/root-cause-pass.out" "REVIEW_RESULT" "degraded"
    assert_contains "$temp_root/root-cause-pass.out" "Codex 不可用"
    rm -rf "$temp_root"
}

test_coding_review_ignores_model_override_but_keeps_reasoning() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo qwen3.6-plus high >"$temp_root/review-model.out"
    )

    assert_protocol_field "$temp_root/review-model.out" "RESULT" "success"
    assert_contains "$temp_root/codex.review.argv" "-m gpt-5.4"
    assert_not_contains "$temp_root/codex.review.argv" "-m qwen3.6-plus"
    assert_contains "$temp_root/codex.review.argv" "model_reasoning_effort=\"xhigh\""
    rm -rf "$temp_root"
}

test_coding_review_defaults_to_xhigh_reasoning_for_plan_repos() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-default-reasoning.out"
    )

    assert_protocol_field "$temp_root/review-default-reasoning.out" "RESULT" "success"
    assert_contains "$temp_root/codex.review.argv" "model_reasoning_effort=\"xhigh\""
    rm -rf "$temp_root"
}

test_coding_review_escalates_reasoning_on_recheck() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "DONE" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-recheck-reasoning.out"
    )

    assert_protocol_field "$temp_root/review-recheck-reasoning.out" "RESULT" "success"
    assert_contains "$temp_root/codex.review.argv" "model_reasoning_effort=\"xhigh\""
    rm -rf "$temp_root"
}

test_coding_review_codex_mode_fails_when_codex_unavailable() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        AI_FLOW_ENGINE_MODE=codex FAKE_REVIEW_CODEX_MODE=unavailable run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/codex-mode.out"
    ) || true

    assert_protocol_field "$temp_root/codex-mode.out" "RESULT" "failed"
    assert_contains "$temp_root/codex-mode.out" "AI_FLOW_ENGINE_MODE=codex"
    rm -rf "$temp_root"
}

test_regular_passed_with_notes_to_done
test_regular_failed_to_review_failed
test_recheck_pass_keeps_done
test_passed_with_notes_ignores_status_guide_text
test_adhoc_review_without_slug
test_no_git_changes_rejected
test_root_cause_gate_and_fallback
test_coding_review_ignores_model_override_but_keeps_reasoning
test_coding_review_defaults_to_xhigh_reasoning_for_plan_repos
test_coding_review_escalates_reasoning_on_recheck
test_coding_review_codex_mode_fails_when_codex_unavailable
