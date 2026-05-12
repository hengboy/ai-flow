#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_plan_repos_status_shows_repo_scope() {
    local temp_root owner out state_script repo_scope
    temp_root=$(make_temp_root)
    owner="$temp_root/owner"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$owner" "20260503"
    setup_git_repo_clean "$owner"
    mkdir -p "$owner/repo-alpha/src" "$owner/repo-beta/src"
    setup_git_repo_clean "$owner/repo-alpha"
    setup_git_repo_clean "$owner/repo-beta"

    repo_scope="$(repo_scope_json "$owner" "owner::." "repo-alpha::repo-alpha" "repo-beta::repo-beta")"
    create_plan_file "$owner" "multi-repo" "20260503" "multi-repo-status-test"
    (
        cd "$owner"
        bash "$state_script" create --slug multi-repo --title "multi-repo-status-test" --plan-file ".ai-flow/plans/20260503-multi-repo.md" \
            --repo-scope-json "$repo_scope" >/dev/null
        bash "$state_script" record-plan-review --slug multi-repo --result passed --engine Fixture --model fixture-model >/dev/null
    )

    (
        cd "$owner"
        bash "$SOURCE_FLOW_STATUS_SCRIPT" > "$temp_root/scope-status.out" 2>&1
    )
    out="$temp_root/scope-status.out"

    assert_contains "$out" "multi-repo"
    assert_contains "$out" "plan_repos"
    rm -rf "$temp_root"
}

test_plan_repos_status_shows_execution_scope() {
    local temp_root owner out state_script repo_scope
    temp_root=$(make_temp_root)
    owner="$temp_root/owner"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$owner" "20260503"
    setup_git_repo_clean "$owner"
    mkdir -p "$owner/repo-alpha/src" "$owner/repo-beta/src"
    setup_git_repo_clean "$owner/repo-alpha"
    setup_git_repo_clean "$owner/repo-beta"

    repo_scope="$(repo_scope_json "$owner" "owner::." "repo-alpha::repo-alpha" "repo-beta::repo-beta")"
    create_plan_file "$owner" "exec-scope" "20260503" "exec-scope-test"
    (
        cd "$owner"
        bash "$state_script" create --slug exec-scope --title "exec-scope-test" --plan-file ".ai-flow/plans/20260503-exec-scope.md" \
            --repo-scope-json "$repo_scope" >/dev/null
    )

    (
        cd "$owner"
        bash "$SOURCE_FLOW_STATUS_SCRIPT" > "$temp_root/exec-scope.out" 2>&1
    )
    out="$temp_root/exec-scope.out"

    # Should show execution scope with plan_repos mode and repo count
    assert_contains "$out" "scope:plan_repos"
    assert_contains "$out" "repos:3"
    rm -rf "$temp_root"
}

test_plan_repos_status_shows_repo_scope
test_plan_repos_status_shows_execution_scope
