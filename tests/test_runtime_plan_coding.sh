#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_plan_coding_runtime_starts_execute_from_planned() {
    local temp_root project runtime_script state_script
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-plan-coding.sh")"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$state_script" "$project" "demo" "PLANNED" "20260503" "demo"

    (
        cd "$project"
        bash "$runtime_script" demo >"$temp_root/plan-coding.out"
    )

    assert_protocol_field "$temp_root/plan-coding.out" "RESULT" "success"
    assert_protocol_field "$temp_root/plan-coding.out" "STATE" "IMPLEMENTING"
    assert_protocol_field "$temp_root/plan-coding.out" "NEXT" "ai-flow-plan-coding"
    assert_equals "IMPLEMENTING" "$(state_field "$project" "demo" "current_status")"
    rm -rf "$temp_root"
}

test_plan_coding_runtime_starts_fix_from_review_failed() {
    local temp_root project runtime_script state_script
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-plan-coding.sh")"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$state_script" "$project" "demo" "REVIEW_FAILED" "20260503" "demo"

    (
        cd "$project"
        bash "$runtime_script" demo >"$temp_root/fix-coding.out"
    )

    assert_protocol_field "$temp_root/fix-coding.out" "RESULT" "success"
    assert_protocol_field "$temp_root/fix-coding.out" "STATE" "FIXING_REVIEW"
    assert_equals "FIXING_REVIEW" "$(state_field "$project" "demo" "current_status")"
    rm -rf "$temp_root"
}

test_plan_coding_runtime_rejects_missing_required_reads() {
    local temp_root project runtime_script state_script rc
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-plan-coding.sh")"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    setup_project_dirs "$project" "20260503"
    write_rule_yaml "$project" $'version: 1\nconstraints:\n  required_reads:\n    - "docs/domain-model.md"\nprompt: {}\nreview: {}\n'
    create_state_with_status "$state_script" "$project" "demo" "PLANNED" "20260503" "demo"

    set +e
    (
        cd "$project"
        bash "$runtime_script" demo >"$temp_root/missing-read.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing required_reads to fail"
    assert_protocol_field "$temp_root/missing-read.out" "RESULT" "failed"
    assert_contains "$temp_root/missing-read.out" "required_reads 文件不存在"
    assert_equals "PLANNED" "$(state_field "$project" "demo" "current_status")"
    rm -rf "$temp_root"
}

test_plan_coding_runtime_rejects_protected_path_in_plan_boundary() {
    local temp_root project runtime_script state_script rc
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-plan-coding.sh")"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    setup_project_dirs "$project" "20260503"
    write_rule_yaml "$project" $'version: 1\nconstraints:\n  protected_paths:\n    - "src/review-target.txt"\nprompt: {}\nreview: {}\n'
    create_state_with_status "$state_script" "$project" "demo" "PLANNED" "20260503" "demo"

    set +e
    (
        cd "$project"
        bash "$runtime_script" demo >"$temp_root/protected.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected protected_paths to fail"
    assert_protocol_field "$temp_root/protected.out" "RESULT" "failed"
    assert_contains "$temp_root/protected.out" "命中 protected_paths"
    assert_equals "PLANNED" "$(state_field "$project" "demo" "current_status")"
    rm -rf "$temp_root"
}

test_plan_coding_runtime_uses_workspace_scope_rules() {
    local temp_root workspace runtime_script state_script rc
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-plan-coding.sh")"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    setup_workspace_root "$workspace" "runtime-coding-ws"
    setup_workspace_git_repos "$workspace"
    write_rule_yaml "$workspace/repo-alpha" $'version: 1\nconstraints:\n  required_reads:\n    - "README.md"\nprompt: {}\nreview: {}\n'
    create_workspace_state_fixture "$state_script" "$workspace" "ws-demo" "PLANNED" "20260503" "ws-demo"

    set +e
    (
        cd "$workspace"
        bash "$runtime_script" ws-demo >"$temp_root/workspace-required.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected workspace required_reads to fail"
    assert_contains "$temp_root/workspace-required.out" "required_reads 文件不存在"
    assert_equals "PLANNED" "$(state_field "$workspace" "ws-demo" "current_status")"
    rm -rf "$temp_root"
}

test_plan_coding_runtime_allows_workspace_owner_plan_when_participant_protects_markdown() {
    local temp_root workspace runtime_script state_script
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-plan-coding.sh")"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    setup_workspace_root "$workspace" "runtime-coding-boundary-ws"
    setup_workspace_git_repos "$workspace"
    write_rule_yaml "$workspace/repo-alpha" $'version: 1\nconstraints:\n  protected_paths:\n    - "**/*.md"\nprompt: {}\nreview: {}\n'
    create_workspace_state_fixture "$state_script" "$workspace" "ws-demo" "PLANNED" "20260503" "ws-demo"

    (
        cd "$workspace"
        bash "$runtime_script" ws-demo >"$temp_root/workspace-owner-boundary.out"
    )

    assert_protocol_field "$temp_root/workspace-owner-boundary.out" "RESULT" "success"
    assert_protocol_field "$temp_root/workspace-owner-boundary.out" "STATE" "IMPLEMENTING"
    rm -rf "$temp_root"
}

test_plan_coding_runtime_starts_execute_from_planned
test_plan_coding_runtime_starts_fix_from_review_failed
test_plan_coding_runtime_rejects_missing_required_reads
test_plan_coding_runtime_rejects_protected_path_in_plan_boundary
test_plan_coding_runtime_uses_workspace_scope_rules
test_plan_coding_runtime_allows_workspace_owner_plan_when_participant_protects_markdown
