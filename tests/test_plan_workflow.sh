#!/bin/bash
set -euo pipefail

# shellcheck source=tests/helpers.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.bash"

test_plan_generation_happy_path_waits_for_review_then_marks_planned() {
    local temp_root project plan_file status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_plan_workflow_engines "$temp_root" "review_passed"

    (cd "$project" && run_with_fake_plan_engines "$temp_root" "review_passed" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "新增用户权限管理模块" user-permission) > "$temp_root/plan.out" 2>&1

    plan_file="$project/.ai-flow/plans/$(date +%Y%m%d)/user-permission.md"
    assert_file_exists "$plan_file"
    assert_file_exists "$project/.ai-flow/state/user-permission.json"
    status=$(state_field "$project" "user-permission" "current_status")
    assert_equals "PLANNED" "$status"
    assert_contains "$plan_file" "### 8.1 当前审核结论"
    assert_contains "$plan_file" "审核状态：passed"
    assert_contains "$plan_file" "是否允许进入 \`/ai-flow-execute\`：是"
    assert_contains "$plan_file" "#### 第 1 轮"
    assert_contains "$temp_root/plan.out" "已创建状态:"
    assert_contains "$temp_root/plan.out" "AWAITING_PLAN_REVIEW"
    assert_contains "$temp_root/plan.out" "状态已验证为 \\[PLANNED\\]"
    assert_contains "$temp_root/plan.out" "AI-FLOW执行方案已经通过计划审核"
    assert_contains "$temp_root/codex.args.1" "-C $project"
    assert_contains "$temp_root/codex.args.1" "--skip-git-repo-check"
    assert_contains "$temp_root/codex.args.2" "-C $project"
    assert_contains "$temp_root/codex.args.2" "--skip-git-repo-check"
    rm -rf "$temp_root"
}

test_plan_generation_passed_with_notes_still_allows_execute() {
    local temp_root project plan_file status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_plan_workflow_engines "$temp_root" "review_notes"

    (cd "$project" && run_with_fake_plan_engines "$temp_root" "review_notes" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "新增用户权限管理模块" user-permission) > "$temp_root/plan.out" 2>&1

    plan_file="$project/.ai-flow/plans/$(date +%Y%m%d)/user-permission.md"
    status=$(state_field "$project" "user-permission" "current_status")
    assert_equals "PLANNED" "$status"
    assert_contains "$plan_file" "审核状态：passed_with_notes"
    assert_contains "$plan_file" "\\[可选\\]\\[Minor\\]"
    assert_contains "$temp_root/plan.out" "状态已验证为 \\[PLANNED\\]"
    assert_contains "$temp_root/plan.out" "AI-FLOW执行方案已经通过计划审核"
    rm -rf "$temp_root"
}

test_plan_generation_failed_blocks_execute_and_keeps_failed_state() {
    local temp_root project plan_file status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_plan_workflow_engines "$temp_root" "review_failed"

    (cd "$project" && run_with_fake_plan_engines "$temp_root" "review_failed" env AI_FLOW_PLAN_MAX_REVIEW_ROUNDS=1 bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "新增用户权限管理模块" user-permission) > "$temp_root/plan.out" 2>&1

    plan_file="$project/.ai-flow/plans/$(date +%Y%m%d)/user-permission.md"
    status=$(state_field "$project" "user-permission" "current_status")
    assert_equals "PLAN_REVIEW_FAILED" "$status"
    assert_contains "$plan_file" "审核状态：failed"
    assert_contains "$plan_file" "\\[待修订\\]\\[Important\\]"
    assert_contains "$temp_root/plan.out" "状态已验证为 \\[PLAN_REVIEW_FAILED\\]"
    assert_contains "$temp_root/plan.out" "禁止进入 /ai-flow-execute"
    assert_not_contains "$temp_root/plan.out" "AI-FLOW执行方案已经通过计划审核"
    rm -rf "$temp_root"
}

test_plan_generation_failed_then_revised_and_re_reviewed() {
    local temp_root project plan_file status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_plan_workflow_engines "$temp_root" "review_fail_then_pass"

    (cd "$project" && run_with_fake_plan_engines "$temp_root" "review_fail_then_pass" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "新增用户权限管理模块" user-permission) > "$temp_root/plan.out" 2>&1

    plan_file="$project/.ai-flow/plans/$(date +%Y%m%d)/user-permission.md"
    status=$(state_field "$project" "user-permission" "current_status")
    assert_equals "PLANNED" "$status"
    assert_contains "$plan_file" "#### 第 1 轮"
    assert_contains "$plan_file" "#### 第 2 轮"
    assert_contains "$plan_file" "审核状态：passed"
    assert_contains "$temp_root/plan.out" "按审核意见修订 plan"
    assert_contains "$temp_root/plan.out" "执行第 2 轮计划审核"
    python3 - "$project/.ai-flow/state/user-permission.json" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
events = [item["event"] for item in state["transitions"]]
assert events == ["plan_created", "plan_review_failed", "plan_review_passed"], events
PY
    rm -rf "$temp_root"
}

test_plan_generation_review_falls_back_to_opencode_when_codex_unavailable() {
    local temp_root project plan_file status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_plan_workflow_engines "$temp_root" "review_fallback_pass"

    (cd "$project" && run_with_fake_plan_engines "$temp_root" "review_fallback_pass" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "新增用户权限管理模块" user-permission) > "$temp_root/plan.out" 2>&1

    plan_file="$project/.ai-flow/plans/$(date +%Y%m%d)/user-permission.md"
    status=$(state_field "$project" "user-permission" "current_status")
    assert_equals "PLANNED" "$status"
    assert_contains "$plan_file" "审核引擎/模型：OpenCode / zhipuai-coding-plan/glm-5.1"
    assert_contains "$temp_root/plan.out" "降级到 OpenCode"
    assert_contains "$temp_root/opencode.args" "--dir $project"
    assert_contains "$temp_root/opencode.args" "--variant max"
    rm -rf "$temp_root"
}

test_chinese_requirement_without_slug_does_not_collide() {
    local temp_root project state_count
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_plan_workflow_engines "$temp_root" "review_passed"

    (cd "$project" && run_with_fake_plan_engines "$temp_root" "review_passed" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "新增用户权限管理模块") > "$temp_root/first.out" 2>&1
    rm -f "$temp_root/fake-plan-codex-call-count" "$temp_root/fake-plan-opencode-call-count"
    (cd "$project" && run_with_fake_plan_engines "$temp_root" "review_passed" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "优化数据查询接口性能") > "$temp_root/second.out" 2>&1

    state_count=$(find "$project/.ai-flow/state" -name "*.json" -type f | wc -l | tr -d ' ')
    assert_equals "2" "$state_count"
    rm -rf "$temp_root"
}

test_plan_generation_rejects_placeholder_output_and_no_state_created() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "placeholder"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "add plan validation" plan-validation) > "$temp_root/plan.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected placeholder plan validation to fail"
    assert_contains "$temp_root/plan.out" "计划结构校验失败"
    assert_file_not_exists "$project/.ai-flow/state/plan-validation.json"
    rm -rf "$temp_root"
}

test_detects_shell_markdown_stack_without_git() {
    local temp_root project
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    printf '#!/bin/bash\n' > "$project/tool.sh"
    printf '# Docs\n' > "$project/README.md"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_plan_workflow_engines "$temp_root" "review_passed"

    (cd "$project" && run_with_fake_plan_engines "$temp_root" "review_passed" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "add shell guard" shell-guard) > "$temp_root/plan.out" 2>&1

    assert_contains "$temp_root/plan.out" "Shell/Bash"
    assert_contains "$temp_root/plan.out" "Markdown"
    rm -rf "$temp_root"
}

test_plan_prompt_forbids_custom_state_schema() {
    local temp_root project
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_plan_workflow_engines "$temp_root" "review_passed"

    (cd "$project" && run_with_fake_plan_engines "$temp_root" "review_passed" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "add shell guard" shell-guard) > "$temp_root/plan.out" 2>&1

    assert_contains "$temp_root/captured-plan-prompt.txt" "不得为 .ai-flow/state/shell-guard.json 设计任何 JSON 结构"
    assert_contains "$temp_root/captured-plan-prompt.txt" "不要写进 state JSON 设计"
    assert_contains "$temp_root/captured-plan-prompt.txt" "缺陷族"
    assert_contains "$temp_root/captured-plan-prompt.txt" "定向验证矩阵"
    rm -rf "$temp_root"
}

test_plan_generation_rejects_custom_state_schema_output() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "custom_state_schema"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "bad state schema" bad-state-schema) > "$temp_root/plan.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected custom state schema plan validation to fail"
    assert_contains "$temp_root/plan.out" "计划中不得为状态文件设计自定义 schema 字段"
    assert_file_not_exists "$project/.ai-flow/state/bad-state-schema.json"
    rm -rf "$temp_root"
}

test_plan_generation_rejects_missing_risk_family_section() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "missing_risk_families"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "missing risk family section" missing-risk-family) > "$temp_root/plan.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing 2.6 section plan validation to fail"
    assert_contains "$temp_root/plan.out" "缺少强制小节: ### 2.6 高风险路径与缺陷族"
    assert_file_not_exists "$project/.ai-flow/state/missing-risk-family.json"
    rm -rf "$temp_root"
}

test_plan_generation_rejects_missing_validation_matrix() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_minimal_project_root "$project"
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "missing_validation_matrix"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "missing validation matrix" missing-validation-matrix) > "$temp_root/plan.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing 4.4 section plan validation to fail"
    assert_contains "$temp_root/plan.out" "缺少强制小节: ### 4.4 定向验证矩阵"
    assert_file_not_exists "$project/.ai-flow/state/missing-validation-matrix.json"
    rm -rf "$temp_root"
}

test_plan_generation_rejects_non_project_root_with_multiple_module_candidates() {
    local temp_root workspace rc
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    mkdir -p "$workspace/isp-case/src/main/java" "$workspace/isp-auth/src/main/java"
    printf '<project />\n' > "$workspace/isp-case/pom.xml"
    printf '<project />\n' > "$workspace/isp-auth/pom.xml"
    setup_home_with_templates "$temp_root"

    set +e
    (cd "$workspace" && bash "$(installed_skill_script "$temp_root" "ai-flow-plan" "codex-plan.sh")" "workflow api integration test" workflow-api-integration-test) > "$temp_root/plan-root.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected non-project-root directory to be rejected"
    assert_contains "$temp_root/plan-root.out" "当前目录不是可识别的项目根目录"
    assert_contains "$temp_root/plan-root.out" "$workspace/isp-case"
    assert_contains "$temp_root/plan-root.out" "$workspace/isp-auth"
    assert_file_not_exists "$workspace/.ai-flow/plans/$(date +%Y%m%d)/workflow-api-integration-test.md"
    assert_file_not_exists "$workspace/.ai-flow/state/workflow-api-integration-test.json"
    rm -rf "$temp_root"
}

test_plan_generation_happy_path_waits_for_review_then_marks_planned
test_plan_generation_passed_with_notes_still_allows_execute
test_plan_generation_failed_blocks_execute_and_keeps_failed_state
test_plan_generation_failed_then_revised_and_re_reviewed
test_plan_generation_review_falls_back_to_opencode_when_codex_unavailable
test_chinese_requirement_without_slug_does_not_collide
test_plan_generation_rejects_placeholder_output_and_no_state_created
test_detects_shell_markdown_stack_without_git
test_plan_prompt_forbids_custom_state_schema
test_plan_generation_rejects_custom_state_schema_output
test_plan_generation_rejects_missing_risk_family_section
test_plan_generation_rejects_missing_validation_matrix
test_plan_generation_rejects_non_project_root_with_multiple_module_candidates
