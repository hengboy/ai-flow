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
    plan_file="$workspace/.ai-flow/plans/20260503/ws-change.md"

    (
        cd "$workspace"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" ws-change "[新增] workspace 扩展功能 — 影响步骤: Step 1" >/dev/null
    )

    assert_contains "$plan_file" "\\[新增\\] workspace 扩展功能"
    assert_not_contains "$plan_file" "{YYYY-MM-DD HH:MM}"
    rm -rf "$temp_root"
}

test_workspace_change_updates_workspace_owned_plan
