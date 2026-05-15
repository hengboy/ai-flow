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
    setup_git_repo_clean "$project"
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
    assert_file_not_exists "$project/.ai-flow/workspace.json"
    assert_equals "plan_repos" "$(state_field "$project" "${today}-user-permission" "execution_scope.mode")"
    assert_equals "owner" "$(state_field "$project" "${today}-user-permission" "execution_scope.repos.0.id")"
    rm -rf "$temp_root"
}

test_plan_without_slug_auto_generates_new_plan() {
    local temp_root project executor today out
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    setup_git_repo_clean "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    today="$(date +%Y%m%d)"

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "Build user permissions" >"$temp_root/no-slug.out"
    )
    out="$temp_root/no-slug.out"

    assert_protocol_field "$out" "RESULT" "success"
    assert_protocol_field "$out" "ARTIFACT" ".ai-flow/plans/${today}-build-user-permissions.md"
    assert_file_exists "$project/.ai-flow/plans/${today}-build-user-permissions.md"
    assert_equals "AWAITING_PLAN_REVIEW" "$(state_field "$project" "${today}-build-user-permissions" "current_status")"
    rm -rf "$temp_root"
}

test_plan_revision_after_failed_review() {
    local temp_root project plan_executor review_executor today
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    setup_git_repo_clean "$project"
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
    setup_git_repo_clean "$project"
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
    setup_git_repo_clean "$project"
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
    setup_git_repo_clean "$project"
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
    setup_git_repo_clean "$project"
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
    setup_git_repo_clean "$project"
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

test_plan_generation_rewrites_full_implementation_plan_input() {
    local temp_root project out today executor requirement plan_file
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    setup_git_repo_clean "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    today="$(date +%Y%m%d)"
    requirement=$'完整实施方案：\n目标：增强 ai-flow-plan，使完整实施方案输入可生成标准 plan。\n文件边界：修改 subagents/shared/plan/prompts/plan-generation.md；新增 tests/test_subagent_plan.sh 覆盖。\n实施步骤：1. 增加输入类型处理规则。2. 验证 plan 仍符合 8 章模板。\n测试计划：运行 bash tests/test_subagent_plan.sh。\n验收标准：生成的 plan 保留原始方案，并只使用模板章节。'

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "$requirement" full-plan-input >"$temp_root/full-plan.out"
    )
    out="$temp_root/full-plan.out"
    plan_file="$project/.ai-flow/plans/${today}-full-plan-input.md"

    assert_protocol_field "$out" "RESULT" "success"
    assert_file_exists "$plan_file"
    assert_contains "$plan_file" "## 1. 需求概述"
    assert_contains "$plan_file" "## 8. 计划审核记录"
    assert_contains "$plan_file" "完整实施方案："
    assert_contains "$plan_file" "验收标准：生成的 plan 保留原始方案"
    assert_contains "$temp_root/codex-plan-prompt.log" "如果”需求描述”是一份完整实施方案"
    assert_contains "$temp_root/codex-plan-prompt.log" "全部映射到下方"
    assert_contains "$temp_root/codex-plan-prompt.log" "先做头脑风暴式 intake"
    assert_contains "$temp_root/codex-plan-prompt.log" "只要存在任何不确定项，必须先询问用户"
    rm -rf "$temp_root"
}

test_plan_generation_allows_document_links_as_original_requirement() {
    local temp_root project out today executor requirement plan_file
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    setup_git_repo_clean "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    today="$(date +%Y%m%d)"
    requirement=$'https://docs.example.com/specs/ai-flow-plan-input\n./docs/requirements/plan-input.md'

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "$requirement" doc-link-input >"$temp_root/doc-link.out"
    )
    out="$temp_root/doc-link.out"
    plan_file="$project/.ai-flow/plans/${today}-doc-link-input.md"

    assert_protocol_field "$out" "RESULT" "success"
    assert_file_exists "$plan_file"
    assert_contains "$plan_file" "https://docs.example.com/specs/ai-flow-plan-input"
    assert_contains "$plan_file" "./docs/requirements/plan-input.md"
    assert_contains "$temp_root/codex-plan-prompt.log" "只包含一个或多个文档地址"
    assert_contains "$temp_root/codex-plan-prompt.log" "可以直接引用这些文档地址"
    rm -rf "$temp_root"
}

test_plan_generation_injects_rule_prompt_and_required_reads() {
    local temp_root project executor readme_rule
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    printf '# Domain Model\n' > "$project/README.md"
    write_rule_yaml "$project" $'version: 1\nprompt:\n  shared_context:\n    - "项目背景：权限域"\nconstraints:\n  required_reads:\n    - "README.md"\nreview: {}\n'
    setup_git_repo_clean "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "新增用户权限管理模块" rules-demo >"$temp_root/rule-plan.out"
    )

    assert_protocol_field "$temp_root/rule-plan.out" "RESULT" "success"
    assert_contains "$temp_root/codex-plan-prompt.log" "## AI Flow 项目规则"
    assert_contains "$temp_root/codex-plan-prompt.log" "项目背景：权限域"
    assert_contains "$temp_root/codex-plan-prompt.log" "### Required Read [owner] README.md"
    rm -rf "$temp_root"
}

test_plan_generation_state_file_notice_uses_date_prefix() {
    local temp_root project out today executor plan_file
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    setup_git_repo_clean "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    today="$(date +%Y%m%d)"
    plan_file="$project/.ai-flow/plans/${today}-dated-state.md"

    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "验证状态文件日期前缀" dated-state >"$temp_root/dated-state.out"
    )
    out="$temp_root/dated-state.out"

    assert_protocol_field "$out" "RESULT" "success"
    assert_contains "$plan_file" ".ai-flow/state/${today}-dated-state.json"
    assert_file_exists "$project/.ai-flow/state/${today}-dated-state.json"
    rm -rf "$temp_root"
}

test_plan_generation_fails_when_required_read_missing() {
    local temp_root project executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    write_rule_yaml "$project" $'version: 1\nconstraints:\n  required_reads:\n    - "docs/domain-model.md"\nprompt: {}\nreview: {}\n'
    setup_git_repo_clean "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    set +e
    (
        cd "$project"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "新增用户权限管理模块" missing-read >"$temp_root/missing-read.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing required_reads to fail"
    assert_protocol_field "$temp_root/missing-read.out" "RESULT" "failed"
    assert_contains "$temp_root/missing-read.out" "required_reads 文件不存在"
    rm -rf "$temp_root"
}

test_plan_missing_runtime_fails_deterministically() {
    local temp_root project executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    setup_git_repo_clean "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    (
        cd "$project"
        AI_FLOW_HOME="$temp_root/missing-runtime" run_with_fake_plan_agents "$temp_root" bash "$executor" "missing runtime" missing >"$temp_root/missing.out"
    ) || true

    assert_protocol_field "$temp_root/missing.out" "RESULT" "failed"
    assert_contains "$temp_root/missing.out" "缺少AI Flow runtime 脚本 flow-state.sh"
    rm -rf "$temp_root"
}

test_flow_state_create_normalizes_slug_from_plan_file_date_prefix() {
    local temp_root project state_script out
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$project" "20260503"
    setup_git_repo_clean "$project"
    create_plan_file "$project" "dated-demo" "20260503" "dated-demo"

    (
        cd "$project"
        bash "$state_script" create --slug dated-demo --title "dated demo" --plan-file .ai-flow/plans/20260503-dated-demo.md >"$temp_root/create.out"
    )
    out="$temp_root/create.out"

    assert_contains "$out" ".ai-flow/state/20260503-dated-demo.json"
    assert_file_exists "$project/.ai-flow/state/20260503-dated-demo.json"
    assert_file_not_exists "$project/.ai-flow/state/dated-demo.json"
    assert_equals "20260503-dated-demo" "$(state_field "$project" "20260503-dated-demo" "slug")"
    rm -rf "$temp_root"
}

test_plan_codex_mode_fails_when_codex_unavailable() {
    local temp_root project executor setting_json
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    project="$temp_root/project"
    setup_project_root "$project"
    setup_git_repo_clean "$project"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"

    # Override engine_mode via setting.json
    setting_json="$temp_root/home/.config/ai-flow/setting.json"
    python3 -c "
import json
from pathlib import Path
p = Path('$setting_json')
c = json.loads(p.read_text())
c['engine_mode'] = 'codex'
p.write_text(json.dumps(c, indent=2, ensure_ascii=False))
"

    (
        cd "$project"
        FAKE_PLAN_CODEX_MODE=unavailable run_with_fake_plan_agents "$temp_root" bash "$executor" "codex only" codex-only >"$temp_root/codex-mode.out"
    ) || true

    assert_protocol_field "$temp_root/codex-mode.out" "RESULT" "failed"
    assert_contains "$temp_root/codex-mode.out" "PLAN_ENGINE_MODE=codex"
    rm -rf "$temp_root"
}

test_plan_generation_protocol_and_state
test_plan_without_slug_auto_generates_new_plan
test_plan_revision_after_failed_review
test_plan_degraded_when_codex_unavailable
test_plan_codex_mode_fails_when_codex_unavailable
test_plan_generation_ignores_explicit_model_override
test_plan_generation_defaults_to_high_reasoning
test_plan_generation_escalates_reasoning_for_complex_requirements
test_plan_generation_allows_negative_tbd_references
test_plan_generation_rewrites_full_implementation_plan_input
test_plan_generation_allows_document_links_as_original_requirement
test_plan_generation_injects_rule_prompt_and_required_reads
test_plan_generation_state_file_notice_uses_date_prefix
test_plan_generation_fails_when_required_read_missing
test_plan_missing_runtime_fails_deterministically
test_flow_state_create_normalizes_slug_from_plan_file_date_prefix
