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
    assert_protocol_field "$out" "ARTIFACT" ".ai-flow/plans/${today}-user-permission.md"
    assert_protocol_field "$out" "STATE" "AWAITING_PLAN_REVIEW"
    assert_protocol_field "$out" "NEXT" "ai-flow-plan-review"
    assert_file_exists "$project/.ai-flow/plans/${today}-user-permission.md"
    assert_equals "AWAITING_PLAN_REVIEW" "$(state_field "$project" "${today}-user-permission" "current_status")"
    rm -rf "$temp_root"
}

test_plan_revision_after_failed_review() {
    local temp_root project plan_executor review_executor today
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    plan_executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    review_executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-review" "plan-review-executor.sh")"
    today="$(date +%Y%m%d)"

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$plan_executor" "新增用户权限管理模块" user-permission >/dev/null
        FAKE_PLAN_REVIEW_RESULT=failed run_with_fake_plan_agents "$temp_root" bash "$review_executor" user-permission >/dev/null
        run_with_fake_plan_agents "$temp_root" bash "$plan_executor" "新增用户权限管理模块" user-permission >"$temp_root/revise.out"
    )

    assert_equals "PLAN_REVIEW_FAILED" "$(state_field "$project" "${today}-user-permission" "current_status")"
    assert_protocol_field "$temp_root/revise.out" "RESULT" "success"
    assert_protocol_field "$temp_root/revise.out" "NEXT" "ai-flow-plan-review"
    rm -rf "$temp_root"
}

test_plan_degraded_when_codex_unavailable() {
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
    assert_protocol_field "$temp_root/fallback.out" "REVIEW_RESULT" "degraded"
    assert_contains "$temp_root/fallback.out" "Codex 不可用"
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

test_plan_generation_defaults_to_high_reasoning() {
    local temp_root project executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "新增用户权限管理模块" user-permission >"$temp_root/plan-reasoning.out"
    )

    assert_protocol_field "$temp_root/plan-reasoning.out" "RESULT" "success"
    assert_contains "$temp_root/codex.plan.argv" "model_reasoning_effort=\"high\""
    rm -rf "$temp_root"
}

test_plan_generation_escalates_reasoning_for_complex_requirements() {
    local temp_root project executor requirement
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    requirement="需要在 workspace 模式下同时覆盖前端、后端、数据库迁移、权限边界和回归验证，补齐失败回滚、跨模块协作、审计日志以及验收闭环，确保多技术栈改动可控且可复盘。还需要把跨仓库依赖、接口兼容、灰度发布、告警埋点、数据修复脚本、权限矩阵、回滚预案、验收证据、失败补救步骤、执行顺序、责任边界、测试覆盖矩阵、手工验证清单、发布窗口限制和风险处置策略全部写清楚，避免实现阶段反复返工。"

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "$requirement" complex-plan >"$temp_root/plan-reasoning-complex.out"
    )

    assert_protocol_field "$temp_root/plan-reasoning-complex.out" "RESULT" "success"
    assert_contains "$temp_root/codex.plan.argv" "model_reasoning_effort=\"xhigh\""
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
    assert_protocol_field "$out" "ARTIFACT" ".ai-flow/plans/${today}-guard-notes.md"
    assert_file_exists "$project/.ai-flow/plans/${today}-guard-notes.md"
    assert_contains "$project/.ai-flow/plans/${today}-guard-notes.md" '计划文件不得包含 `TBD`、`TODO`'
    assert_equals "AWAITING_PLAN_REVIEW" "$(state_field "$project" "${today}-guard-notes" "current_status")"
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

test_plan_codex_mode_fails_when_codex_unavailable() {
    local temp_root project executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    (
        cd "$project"
        AI_FLOW_ENGINE_MODE=codex FAKE_PLAN_CODEX_MODE=unavailable run_with_fake_plan_agents "$temp_root" bash "$executor" "codex only" codex-only >"$temp_root/codex-mode.out"
    ) || true

    assert_protocol_field "$temp_root/codex-mode.out" "RESULT" "failed"
    assert_contains "$temp_root/codex-mode.out" "AI_FLOW_ENGINE_MODE=codex"
    rm -rf "$temp_root"
}

test_plan_generation_protocol_and_state
test_plan_revision_after_failed_review
test_plan_degraded_when_codex_unavailable
test_plan_codex_mode_fails_when_codex_unavailable
test_plan_generation_ignores_explicit_model_override
test_plan_generation_defaults_to_high_reasoning
test_plan_generation_escalates_reasoning_for_complex_requirements
test_plan_generation_allows_negative_tbd_references
test_plan_missing_runtime_fails_deterministically
