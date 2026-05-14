#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_workspace_change_updates_workspace_owned_plan() {
    local temp_root workspace state_script plan_file
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_workspace_root "$workspace" "change-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$state_script" "$workspace" "ws-change" "PLANNED" "20260503" "workspace-change-test"
    plan_file="$workspace/.ai-flow/plans/20260503-ws-change.md"

    (
        cd "$workspace"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" ws-change "[新增] workspace 扩展功能 — 影响步骤: Step 1" >/dev/null
    )

    assert_contains "$plan_file" "[新增] workspace 扩展功能"
    assert_not_contains "$plan_file" "{YYYY-MM-DD HH:MM}"
    rm -rf "$temp_root"
}

test_workspace_change_from_declared_subrepo_updates_workspace_plan() {
    local temp_root workspace state_script plan_file
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_workspace_root "$workspace" "change-subrepo-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$state_script" "$workspace" "ws-change" "PLANNED" "20260503" "workspace-change-subrepo-test"
    plan_file="$workspace/.ai-flow/plans/20260503-ws-change.md"

    (
        cd "$workspace/repo-alpha"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" ws-change "[修改] 从子仓记录变更 — 影响步骤: Step 1" >/dev/null
    )

    assert_contains "$plan_file" "[修改] 从子仓记录变更"
    assert_file_not_exists "$workspace/repo-alpha/.ai-flow/plans/20260503-ws-change.md"
    rm -rf "$temp_root"
}

test_workspace_change_uses_execution_scope_rules() {
    local temp_root workspace state_script plan_file rc
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_workspace_root "$workspace" "change-rule-ws"
    setup_workspace_git_repos "$workspace"
    plan_file="$workspace/.ai-flow/plans/20260503-ws-change.md"
    write_rule_yaml "$workspace/repo-alpha" $'version: 1\nconstraints:\n  required_reads:\n    - "README.md"\nprompt: {}\nreview: {}\n'
    create_workspace_state_fixture "$state_script" "$workspace" "ws-change" "PLANNED" "20260503" "workspace-change-rule-test"

    set +e
    (
        cd "$workspace"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" ws-change "[新增] workspace 规则校验" >"$temp_root/workspace-rule.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected workspace required_reads to fail"
    assert_contains "$temp_root/workspace-rule.out" "required_reads 文件不存在"
    assert_not_contains "$plan_file" "workspace 规则校验"
    rm -rf "$temp_root"
}

test_workspace_change_does_not_apply_participant_path_rules_to_owner_plan() {
    local temp_root workspace state_script plan_file
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_workspace_root "$workspace" "change-participant-boundary-ws"
    setup_workspace_git_repos "$workspace"
    plan_file="$workspace/.ai-flow/plans/20260503-ws-change.md"
    write_rule_yaml "$workspace/repo-alpha" $'version: 1\nconstraints:\n  protected_paths:\n    - "**/*.md"\nprompt: {}\nreview: {}\n'
    create_workspace_state_fixture "$state_script" "$workspace" "ws-change" "PLANNED" "20260503" "workspace-change-boundary-test"

    (
        cd "$workspace"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" ws-change "[新增] owner plan 不应被 participant 规则误伤" >/dev/null
    )

    assert_contains "$plan_file" "owner plan 不应被 participant 规则误伤"
    rm -rf "$temp_root"
}

test_workspace_change_updates_workspace_owned_plan
test_workspace_change_from_declared_subrepo_updates_workspace_plan
test_workspace_change_uses_execution_scope_rules
test_workspace_change_does_not_apply_participant_path_rules_to_owner_plan
