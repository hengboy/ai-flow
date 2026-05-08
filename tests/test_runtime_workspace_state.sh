#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_workspace_state_create_with_manifest() {
    local temp_root workspace state_script
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_workspace_root "$workspace" "test-ws"
    setup_workspace_git_repos "$workspace"

    (
        cd "$workspace"
        bash "$state_script" create --slug ws-plan --title "workspace plan" --plan-file .ai-flow/plans/20260503/ws-plan.md \
            --scope-mode workspace --workspace-file .ai-flow/workspace.json >/dev/null
    )

    assert_equals "2" "$(state_field "$workspace" "ws-plan" "schema_version")"
    assert_equals "workspace" "$(state_field "$workspace" "ws-plan" "execution_scope.mode")"
    assert_equals ".ai-flow/workspace.json" "$(state_field "$workspace" "ws-plan" "execution_scope.workspace_file")"
    assert_equals "repo-alpha" "$(state_field "$workspace" "ws-plan" "execution_scope.repos.0.id")"
    assert_equals "repo-alpha" "$(state_field "$workspace" "ws-plan" "execution_scope.repos.0.path")"
    assert_equals "repo-beta" "$(state_field "$workspace" "ws-plan" "execution_scope.repos.1.id")"
    rm -rf "$temp_root"
}

test_workspace_state_validate_rejects_missing_repo() {
    local temp_root workspace state_script rc
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_workspace_root "$workspace" "broken-ws"

    # Only create repo-alpha, leave repo-beta missing
    mkdir -p "$workspace/repo-alpha/src"
    printf '{"name":"alpha"}\n' > "$workspace/repo-alpha/package.json"
    (
        cd "$workspace/repo-alpha"
        git init -q
        git config user.email test@example.com
        git config user.name Test
        git add .
        git commit -q -m init
    )

    set +e
    (
        cd "$workspace"
        bash "$state_script" create --slug bad --title "bad" --plan-file .ai-flow/plans/20260503/bad.md \
            --scope-mode workspace --workspace-file .ai-flow/workspace.json >"$temp_root/bad.out" 2>&1
    )
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected creation to fail when a declared repo is missing"
    assert_contains "$temp_root/bad.out" "repo-beta"
    rm -rf "$temp_root"
}

test_workspace_state_validate_rejects_duplicate_repo_id() {
    local temp_root workspace rc
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"

    mkdir -p "$workspace/.ai-flow/state/.locks"
    cat > "$workspace/.ai-flow/workspace.json" <<'WS'
{
  "schema_version": 1,
  "name": "dup-ws",
  "repos": [
    { "id": "same", "path": "repo-a" },
    { "id": "same", "path": "repo-b" }
  ]
}
WS

    for d in repo-a repo-b; do
        mkdir -p "$workspace/$d/src"
        printf '{"name":"%s"}\n' "$d" > "$workspace/$d/package.json"
        (
            cd "$workspace/$d"
            git init -q
            git config user.email test@example.com
            git config user.name Test
            git add .
            git commit -q -m init
        )
    done

    set +e
    (
        cd "$workspace"
        bash "$SOURCE_FLOW_STATE_SCRIPT" create --slug dup --title "dup" --plan-file .ai-flow/plans/20260503/dup.md \
            --scope-mode workspace --workspace-file .ai-flow/workspace.json >"$temp_root/dup.out" 2>&1
    )
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected creation to fail with duplicate repo ids"
    rm -rf "$temp_root"
}

test_single_repo_state_normalize_adds_execution_scope() {
    local temp_root project state_script
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$project" "20260503"
    setup_git_repo_clean "$project"

    # Create a state with schema_version 1 (old format, no execution_scope)
    (
        cd "$project"
        bash "$state_script" create --slug legacy --title "legacy" --plan-file .ai-flow/plans/20260503/legacy.md >/dev/null
        bash "$state_script" normalize --slug legacy --note "add execution scope" >/dev/null
    )

    assert_equals "2" "$(state_field "$project" "legacy" "schema_version")"
    assert_equals "single_repo" "$(state_field "$project" "legacy" "execution_scope.mode")"
    rm -rf "$temp_root"
}

test_workspace_state_create_without_manifest_defaults_to_single_repo() {
    local temp_root project state_script
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$project" "20260503"
    setup_git_repo_clean "$project"

    (
        cd "$project"
        bash "$state_script" create --slug default-scope --title "default scope" --plan-file .ai-flow/plans/20260503/default-scope.md >/dev/null
    )

    assert_equals "single_repo" "$(state_field "$project" "default-scope" "execution_scope.mode")"
    assert_equals "null" "$(state_field "$project" "default-scope" "execution_scope.workspace_file")"
    rm -rf "$temp_root"
}

test_workspace_state_create_without_manifest_defaults_to_single_repo
test_workspace_state_create_with_manifest
test_workspace_state_validate_rejects_missing_repo
test_workspace_state_validate_rejects_duplicate_repo_id
test_single_repo_state_normalize_adds_execution_scope
