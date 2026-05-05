#!/bin/bash
set -euo pipefail

# shellcheck source=tests/helpers.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.bash"

test_plan_generation_creates_planned_state() {
    local temp_root project first_line status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "valid"

    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-plan.sh" "新增用户权限管理模块" user-permission) > "$temp_root/plan.out" 2>&1

    assert_file_exists "$project/.ai-flow/plans/$(date +%Y%m%d)/user-permission.md"
    assert_file_exists "$project/.ai-flow/state/user-permission.json"
    first_line=$(head -1 "$project/.ai-flow/plans/$(date +%Y%m%d)/user-permission.md")
    status=$(state_field "$project" "user-permission" "current_status")
    assert_equals "# 实施计划：fake" "$first_line"
    assert_equals "PLANNED" "$status"
    assert_contains "$temp_root/plan.out" "状态文件"
    rm -rf "$temp_root"
}

test_chinese_requirement_without_slug_does_not_collide() {
    local temp_root project state_count
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "valid"

    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-plan.sh" "新增用户权限管理模块") > "$temp_root/first.out" 2>&1
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-plan.sh" "优化数据查询接口性能") > "$temp_root/second.out" 2>&1

    state_count=$(find "$project/.ai-flow/state" -name "*.json" -type f | wc -l | tr -d ' ')
    assert_equals "2" "$state_count"
    rm -rf "$temp_root"
}

test_plan_generation_rejects_placeholder_output_and_no_state_created() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "placeholder"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-plan.sh" "add plan validation" plan-validation) > "$temp_root/plan.out" 2>&1
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
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "valid"

    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-plan.sh" "add shell guard" shell-guard) > "$temp_root/plan.out" 2>&1

    assert_contains "$temp_root/plan.out" "Shell/Bash"
    assert_contains "$temp_root/plan.out" "Markdown"
    rm -rf "$temp_root"
}

test_plan_prompt_forbids_custom_state_schema() {
    local temp_root project
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    mkdir -p "$project"
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "valid"

    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-plan.sh" "add shell guard" shell-guard) > "$temp_root/plan.out" 2>&1

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
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "custom_state_schema"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-plan.sh" "bad state schema" bad-state-schema) > "$temp_root/plan.out" 2>&1
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
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "missing_risk_families"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-plan.sh" "missing risk family section" missing-risk-family) > "$temp_root/plan.out" 2>&1
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
    setup_home_with_templates "$temp_root"
    write_fake_codex_plan "$temp_root" "missing_validation_matrix"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$TEST_ROOT/workflows/codex-plan.sh" "missing validation matrix" missing-validation-matrix) > "$temp_root/plan.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing 4.4 section plan validation to fail"
    assert_contains "$temp_root/plan.out" "缺少强制小节: ### 4.4 定向验证矩阵"
    assert_file_not_exists "$project/.ai-flow/state/missing-validation-matrix.json"
    rm -rf "$temp_root"
}

test_plan_generation_creates_planned_state
test_chinese_requirement_without_slug_does_not_collide
test_plan_generation_rejects_placeholder_output_and_no_state_created
test_detects_shell_markdown_stack_without_git
test_plan_prompt_forbids_custom_state_schema
test_plan_generation_rejects_custom_state_schema_output
test_plan_generation_rejects_missing_risk_family_section
test_plan_generation_rejects_missing_validation_matrix
