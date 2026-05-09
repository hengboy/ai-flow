#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_plan_generation_protocol_and_state() {
    local temp_root project out today executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    today="$(date +%Y%m%d)"

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "新增用户权限管理模块" user-permission >"$temp_root/plan.out"
    )
    out="$temp_root/plan.out"

    assert_protocol_field "$out" "RESULT" "success"
    assert_protocol_field "$out" "AGENT" "ai-flow-codex-plan"
    assert_protocol_field "$out" "ARTIFACT" ".ai-flow/plans/$today/user-permission.md"
    assert_protocol_field "$out" "STATE" "AWAITING_PLAN_REVIEW"
    assert_protocol_field "$out" "NEXT" "ai-flow-plan-review"
    assert_file_exists "$project/.ai-flow/plans/$today/user-permission.md"
    assert_equals "AWAITING_PLAN_REVIEW" "$(state_field "$project" "user-permission" "current_status")"
    rm -rf "$temp_root"
}

test_plan_revision_after_failed_review() {
    local temp_root project plan_executor review_executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    plan_executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    review_executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-review" "plan-review-executor.sh")"

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$plan_executor" "新增用户权限管理模块" user-permission >/dev/null
        FAKE_PLAN_REVIEW_RESULT=failed run_with_fake_plan_agents "$temp_root" bash "$review_executor" user-permission >/dev/null
        run_with_fake_plan_agents "$temp_root" bash "$plan_executor" "新增用户权限管理模块" user-permission >"$temp_root/revise.out"
    )

    assert_equals "PLAN_REVIEW_FAILED" "$(state_field "$project" "user-permission" "current_status")"
    assert_protocol_field "$temp_root/revise.out" "RESULT" "success"
    assert_protocol_field "$temp_root/revise.out" "NEXT" "ai-flow-plan-review"
    rm -rf "$temp_root"
}

test_plan_fallback_once() {
    local temp_root project executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    (
        cd "$project"
        FAKE_PLAN_CODEX_MODE=unavailable run_with_fake_plan_agents "$temp_root" bash "$executor" "fallback" fallback >"$temp_root/fallback.out"
    )

    assert_protocol_field "$temp_root/fallback.out" "RESULT" "success"
    assert_contains "$temp_root/fallback.out" "OpenCode"
    assert_equals "1" "$(wc -l < "$temp_root/opencode.plan.calls" | tr -d ' ')"
    rm -rf "$temp_root"
}

test_plan_generation_ignores_explicit_model_override() {
    local temp_root project executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "新增用户权限管理模块" user-permission qwen3.6-plus >"$temp_root/plan-model.out"
    )

    assert_protocol_field "$temp_root/plan-model.out" "RESULT" "success"
    assert_contains "$temp_root/codex.plan.argv" "-m gpt-5.4"
    assert_not_contains "$temp_root/codex.plan.argv" "-m qwen3.6-plus"
    rm -rf "$temp_root"
}

test_plan_generation_allows_negative_tbd_references() {
    local temp_root project out today executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    today="$(date +%Y%m%d)"

    (
        cd "$project"
        FAKE_PLAN_INCLUDE_NEGATIVE_TBD=1 run_with_fake_plan_agents "$temp_root" bash "$executor" "新增用户权限管理模块" guard-notes >"$temp_root/plan-guard.out"
    )
    out="$temp_root/plan-guard.out"

    assert_protocol_field "$out" "RESULT" "success"
    assert_protocol_field "$out" "ARTIFACT" ".ai-flow/plans/$today/guard-notes.md"
    assert_file_exists "$project/.ai-flow/plans/$today/guard-notes.md"
    assert_contains "$project/.ai-flow/plans/$today/guard-notes.md" '计划文件不得包含 `TBD`、`TODO`'
    assert_equals "AWAITING_PLAN_REVIEW" "$(state_field "$project" "guard-notes" "current_status")"
    rm -rf "$temp_root"
}

test_plan_missing_runtime_fails_deterministically() {
    local temp_root project executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    (
        cd "$project"
        AI_FLOW_HOME="$temp_root/missing-runtime" run_with_fake_plan_agents "$temp_root" bash "$executor" "missing runtime" missing >"$temp_root/missing.out"
    ) || true

    assert_protocol_field "$temp_root/missing.out" "RESULT" "failed"
    assert_contains "$temp_root/missing.out" "缺少AI Flow runtime 脚本 flow-state.sh"
    rm -rf "$temp_root"
}

test_plan_failure_writes_debug_log() {
    local temp_root project executor log_path
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    set +e
    (
        cd "$project"
        FAKE_PLAN_CODEX_MODE=error run_with_fake_plan_agents "$temp_root" bash "$executor" "plan error" plan-error >"$temp_root/plan-error.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected plan executor failure to exit non-zero"
    assert_protocol_field "$temp_root/plan-error.out" "RESULT" "failed"
    assert_contains "$temp_root/plan-error.out" "日志: .ai-flow/logs/"
    log_path="$(log_path_from_output "$temp_root/plan-error.out")"
    assert_file_exists "$project/$log_path"
    assert_contains "$project/$log_path" "codex failed during plan execution"
    assert_contains "$project/$log_path" "stack trace line 2"
    rm -rf "$temp_root"
}

test_plan_generation_protocol_and_state
test_plan_revision_after_failed_review
test_plan_fallback_once
test_plan_generation_ignores_explicit_model_override
test_plan_generation_allows_negative_tbd_references
test_plan_missing_runtime_fails_deterministically
test_plan_failure_writes_debug_log
