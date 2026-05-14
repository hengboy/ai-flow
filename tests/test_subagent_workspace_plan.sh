#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_plan_scoped_multi_repo_accepts_owner_root() {
    local temp_root workspace runtime_script out today executor state_slug
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    workspace="$temp_root/workspace"
    setup_workspace_root "$workspace" "plan-ws"
    setup_workspace_git_repos "$workspace"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    today="$(date +%Y%m%d)"

    (
        cd "$workspace"
        FAKE_PLAN_INCLUDE_PARTICIPANT_REPOS=1 run_with_fake_plan_agents "$temp_root" bash "$executor" "跨仓库权限扩展" workspace-perms >"$temp_root/plan.out"
    )
    out="$temp_root/plan.out"

    assert_protocol_field "$out" "RESULT" "success"
    assert_protocol_field "$out" "STATE" "AWAITING_PLAN_REVIEW"
    assert_protocol_field "$out" "ARTIFACT" ".ai-flow/plans/${today}-workspace-perms.md"
    assert_file_exists "$workspace/.ai-flow/plans/${today}-workspace-perms.md"

    state_slug="${today}-workspace-perms"
    assert_equals "3" "$(state_field "$workspace" "$state_slug" "schema_version")"
    assert_equals "plan_repos" "$(state_field "$workspace" "$state_slug" "execution_scope.mode")"
    assert_equals "owner" "$(state_field "$workspace" "$state_slug" "execution_scope.repos.0.id")"
    assert_equals "." "$(state_field "$workspace" "$state_slug" "execution_scope.repos.0.path")"
    assert_equals "owner" "$(state_field "$workspace" "$state_slug" "execution_scope.repos.0.role")"
    assert_equals "repo-alpha" "$(state_field "$workspace" "$state_slug" "execution_scope.repos.1.id")"
    assert_equals "repo-alpha" "$(state_field "$workspace" "$state_slug" "execution_scope.repos.1.path")"
    assert_equals "participant" "$(state_field "$workspace" "$state_slug" "execution_scope.repos.1.role")"
    assert_equals "repo-beta" "$(state_field "$workspace" "$state_slug" "execution_scope.repos.2.id")"
    assert_equals "repo-beta" "$(state_field "$workspace" "$state_slug" "execution_scope.repos.2.path")"
    assert_equals "participant" "$(state_field "$workspace" "$state_slug" "execution_scope.repos.2.role")"
    rm -rf "$temp_root"
}

test_plan_scoped_artifacts_stay_at_owner_root() {
    local temp_root workspace runtime_script today executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    workspace="$temp_root/workspace"
    setup_workspace_root "$workspace" "artifact-ws"
    setup_workspace_git_repos "$workspace"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    today="$(date +%Y%m%d)"

    (
        cd "$workspace"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "workspace artifacts" ws-artifacts >/dev/null
    )

    # Plan and state should be at workspace root, not in a sub-repo
    assert_file_exists "$workspace/.ai-flow/plans/${today}-ws-artifacts.md"
    assert_file_exists "$workspace/.ai-flow/state/${today}-ws-artifacts.json"
    rm -rf "$temp_root"
}

test_plan_scoped_multi_repo_accepts_owner_root
test_plan_scoped_artifacts_stay_at_owner_root
