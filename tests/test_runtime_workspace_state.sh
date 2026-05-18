#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_plan_repo_state_create_with_scope_json() {
    local temp_root owner state_script scope
    temp_root=$(make_temp_root)
    owner="$temp_root/owner"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$owner" "20260503"
    setup_git_repo_clean "$owner"
    scope="$(repo_scope_json "$owner" "owner::.")"

    (
        cd "$owner"
        bash "$state_script" transition --slug 20260503-plan-scope --event plan_created --title "plan scope" --plan-file .ai-flow/plans/20260503-plan-scope.md \
            --repo-scope-json "$scope" >/dev/null
    )

    assert_equals "4" "$(state_field "$owner" "20260503-plan-scope" "schema_version")"
    assert_equals "plan_repos" "$(state_field "$owner" "20260503-plan-scope" "execution_scope.mode")"
    assert_equals "owner" "$(state_field "$owner" "20260503-plan-scope" "execution_scope.repos.0.id")"
    assert_equals "." "$(state_field "$owner" "20260503-plan-scope" "execution_scope.repos.0.path")"
    assert_equals "owner" "$(state_field "$owner" "20260503-plan-scope" "execution_scope.repos.0.role")"
    rm -rf "$temp_root"
}

test_plan_repo_state_rejects_missing_owner() {
    local temp_root owner participant state_script scope rc
    temp_root=$(make_temp_root)
    owner="$temp_root/owner"
    participant="$temp_root/api"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$owner" "20260503"
    setup_git_repo_clean "$owner"
    setup_project_dirs "$participant" "20260503"
    setup_git_repo_clean "$participant"
    scope="$(repo_scope_json "$owner" "api::../api")"
    scope="${scope/\"role\": \"owner\"/\"role\": \"participant\"}"

    set +e
    (
        cd "$owner"
        bash "$state_script" transition --slug 20260503-no-owner --event plan_created --title "no owner" --plan-file .ai-flow/plans/20260503-no-owner.md \
            --repo-scope-json "$scope" >"$temp_root/no-owner.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing owner to fail"
    assert_contains "$temp_root/no-owner.out" "role=owner"
    rm -rf "$temp_root"
}

test_plan_repo_state_rejects_multiple_owners() {
    local temp_root owner api state_script scope rc
    temp_root=$(make_temp_root)
    owner="$temp_root/owner"
    api="$temp_root/api"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$owner" "20260503"
    setup_git_repo_clean "$owner"
    setup_project_dirs "$api" "20260503"
    setup_git_repo_clean "$api"
    scope="$(repo_scope_json "$owner" "owner::." "api::../api")"
    scope="${scope/\"role\": \"participant\"/\"role\": \"owner\"}"

    set +e
    (
        cd "$owner"
        bash "$state_script" transition --slug 20260503-multi-owner --event plan_created --title "multi owner" --plan-file .ai-flow/plans/20260503-multi-owner.md \
            --repo-scope-json "$scope" >"$temp_root/multi-owner.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected multiple owners to fail"
    assert_contains "$temp_root/multi-owner.out" "role=owner"
    rm -rf "$temp_root"
}

test_plan_repo_state_rejects_duplicate_repo_id() {
    local temp_root owner api state_script scope rc
    temp_root=$(make_temp_root)
    owner="$temp_root/owner"
    api="$temp_root/api"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$owner" "20260503"
    setup_git_repo_clean "$owner"
    setup_project_dirs "$api" "20260503"
    setup_git_repo_clean "$api"
    scope="$(repo_scope_json "$owner" "owner::." "api::../api")"
    scope="${scope/\"id\": \"api\"/\"id\": \"owner\"}"

    set +e
    (
        cd "$owner"
        bash "$state_script" transition --slug 20260503-dup --event plan_created --title "dup" --plan-file .ai-flow/plans/20260503-dup.md \
            --repo-scope-json "$scope" >"$temp_root/dup.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected duplicate repo ids to fail"
    assert_contains "$temp_root/dup.out" "重复"
    rm -rf "$temp_root"
}

test_plan_repo_state_rejects_invalid_repo_path() {
    local temp_root owner state_script scope rc
    temp_root=$(make_temp_root)
    owner="$temp_root/owner"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$owner" "20260503"
    setup_git_repo_clean "$owner"
    scope='{"mode":"plan_repos","repos":[{"id":"owner","path":".","git_root":"'"$owner"'","role":"owner"},{"id":"api","path":"../missing","git_root":"'"$temp_root"'/missing","role":"participant"}]}'

    set +e
    (
        cd "$owner"
        bash "$state_script" transition --slug 20260503-bad-path --event plan_created --title "bad path" --plan-file .ai-flow/plans/20260503-bad-path.md \
            --repo-scope-json "$scope" >"$temp_root/bad-path.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected invalid repo path to fail"
    assert_contains "$temp_root/bad-path.out" "path 不存在"
    rm -rf "$temp_root"
}

test_plan_repo_state_rejects_workspace_file_arg() {
    local temp_root owner state_script rc
    temp_root=$(make_temp_root)
    owner="$temp_root/owner"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$owner" "20260503"
    setup_git_repo_clean "$owner"

    set +e
    (
        cd "$owner"
        bash "$state_script" transition --slug 20260503-ws --event plan_created --title "ws" --plan-file .ai-flow/plans/20260503-ws.md \
            --workspace-file .ai-flow/workspace.json >"$temp_root/ws-arg.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected --workspace-file to be rejected"
    assert_contains "$temp_root/ws-arg.out" "unrecognized arguments"
    rm -rf "$temp_root"
}

test_plan_repo_state_create_with_scope_json
test_plan_repo_state_rejects_missing_owner
test_plan_repo_state_rejects_multiple_owners
test_plan_repo_state_rejects_duplicate_repo_id
test_plan_repo_state_rejects_invalid_repo_path
test_plan_repo_state_rejects_workspace_file_arg
