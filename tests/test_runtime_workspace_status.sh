#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_workspace_status_accepts_root_without_git() {
    local temp_root workspace out
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    setup_workspace_root "$workspace" "status-ws"
    setup_workspace_git_repos "$workspace"

    # Workspace root itself is NOT a git repo — flow-status should still work
    (
        cd "$workspace"
        bash "$SOURCE_FLOW_STATUS_SCRIPT" > "$temp_root/status.out" 2>&1
    )

    assert_contains "$temp_root/status.out" "AI Flow 工作区"
    rm -rf "$temp_root"
}

test_workspace_status_shows_workspace_scope() {
    local temp_root workspace out state_script
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_workspace_root "$workspace" "scope-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$state_script" "$workspace" "ws-status" "AWAITING_PLAN_REVIEW" "20260503" "workspace-status-test"

    (
        cd "$workspace"
        bash "$SOURCE_FLOW_STATUS_SCRIPT" > "$temp_root/scope-status.out" 2>&1
    )
    out="$temp_root/scope-status.out"

    assert_contains "$out" "ws-status"
    assert_contains "$out" "workspace"
    rm -rf "$temp_root"
}

test_workspace_status_shows_repo_inventory() {
    local temp_root workspace out state_script
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_workspace_root "$workspace" "repo-inv-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$state_script" "$workspace" "repo-inv" "PLANNED" "20260503" "repo-inventory-test"

    (
        cd "$workspace"
        bash "$SOURCE_FLOW_STATUS_SCRIPT" > "$temp_root/repo-inv.out" 2>&1
    )
    out="$temp_root/repo-inv.out"

    # Should show repo count or repo ids for workspace flows
    assert_contains "$out" "repo"
    rm -rf "$temp_root"
}

test_workspace_status_accepts_root_without_git
test_workspace_status_shows_workspace_scope
test_workspace_status_shows_repo_inventory
