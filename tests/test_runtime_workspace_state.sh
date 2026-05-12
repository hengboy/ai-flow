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
        bash "$state_script" create --slug plan-scope --title "plan scope" --plan-file .ai-flow/plans/20260503-plan-scope.md \
            --repo-scope-json "$scope" >/dev/null
    )

    assert_equals "3" "$(state_field "$owner" "plan-scope" "schema_version")"
    assert_equals "plan_repos" "$(state_field "$owner" "plan-scope" "execution_scope.mode")"
    assert_equals "owner" "$(state_field "$owner" "plan-scope" "execution_scope.repos.0.id")"
    assert_equals "." "$(state_field "$owner" "plan-scope" "execution_scope.repos.0.path")"
    assert_equals "owner" "$(state_field "$owner" "plan-scope" "execution_scope.repos.0.role")"
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
        bash "$state_script" create --slug no-owner --title "no owner" --plan-file .ai-flow/plans/20260503-no-owner.md \
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
        bash "$state_script" create --slug multi-owner --title "multi owner" --plan-file .ai-flow/plans/20260503-multi-owner.md \
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
        bash "$state_script" create --slug dup --title "dup" --plan-file .ai-flow/plans/20260503-dup.md \
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
        bash "$state_script" create --slug bad-path --title "bad path" --plan-file .ai-flow/plans/20260503-bad-path.md \
            --repo-scope-json "$scope" >"$temp_root/bad-path.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected invalid repo path to fail"
    assert_contains "$temp_root/bad-path.out" "path 不存在"
    rm -rf "$temp_root"
}

test_plan_repo_state_rejects_old_schema_normalize() {
    local temp_root owner state_script rc
    temp_root=$(make_temp_root)
    owner="$temp_root/owner"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$owner" "20260503"
    setup_git_repo_clean "$owner"
    (
        cd "$owner"
        bash "$state_script" create --slug legacy --title "legacy" --plan-file .ai-flow/plans/20260503-legacy.md >/dev/null
    )
    python3 - "$owner/.ai-flow/state/legacy.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["schema_version"] = 2
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

    set +e
    (
        cd "$owner"
        bash "$state_script" normalize --slug legacy >"$temp_root/legacy.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected old schema normalize to fail"
    assert_contains "$temp_root/legacy.out" "旧格式已废弃"
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
        bash "$state_script" create --slug ws --title "ws" --plan-file .ai-flow/plans/20260503-ws.md \
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
test_plan_repo_state_rejects_old_schema_normalize
test_plan_repo_state_rejects_workspace_file_arg
