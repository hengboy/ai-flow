#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_workspace_plan_accepts_manifest_root() {
    local temp_root workspace runtime_script out today executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_plan_agents "$temp_root"
    workspace="$temp_root/workspace"
    setup_workspace_root "$workspace" "plan-ws"
    setup_workspace_git_repos "$workspace"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    today="$(date +%Y%m%d)"

    # Run from workspace root (no top-level git repo)
    (
        cd "$workspace"
        run_with_fake_plan_agents "$temp_root" bash "$executor" "跨仓库权限扩展" workspace-perms >"$temp_root/plan.out"
    )
    out="$temp_root/plan.out"

    assert_protocol_field "$out" "RESULT" "success"
    assert_protocol_field "$out" "STATE" "AWAITING_PLAN_REVIEW"
    assert_protocol_field "$out" "ARTIFACT" ".ai-flow/plans/$today/workspace-perms.md"
    assert_file_exists "$workspace/.ai-flow/plans/$today/workspace-perms.md"

    # State should record workspace execution_scope
    assert_equals "2" "$(state_field "$workspace" "workspace-perms" "schema_version")"
    assert_equals "workspace" "$(state_field "$workspace" "workspace-perms" "execution_scope.mode")"
    rm -rf "$temp_root"
}

test_workspace_plan_writes_artifacts_at_workspace_root() {
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
    assert_file_exists "$workspace/.ai-flow/plans/$today/ws-artifacts.md"
    assert_file_exists "$workspace/.ai-flow/state/ws-artifacts.json"
    rm -rf "$temp_root"
}

test_workspace_plan_accepts_manifest_root
test_workspace_plan_writes_artifacts_at_workspace_root
