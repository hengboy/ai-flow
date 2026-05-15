#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_auto_run_list_filters_allowed_states_and_sorts_by_updated_at() {
    local temp_root project script first_slug
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    script="$SOURCE_FLOW_AUTO_RUN_SCRIPT"
    setup_project_dirs "$project" "20260503"

    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "20260503-old-planned" "PLANNED" "20260503" "old planned"
    sleep 1
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "20260503-await-plan" "AWAITING_PLAN_REVIEW" "20260503" "await plan"
    sleep 1
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "20260503-new-done" "DONE" "20260503" "new done"

    (
        cd "$project"
        bash "$script" list >"$temp_root/list.out" 2>"$temp_root/list.err"
    )

    assert_contains "$temp_root/list.out" $'20260503-new-done\tDONE\tnew done'
    assert_contains "$temp_root/list.out" $'20260503-old-planned\tPLANNED\told planned'
    assert_not_contains "$temp_root/list.out" "20260503-await-plan"
    first_slug="$(sed -n '1s/\t.*//p' "$temp_root/list.out")"
    assert_equals "20260503-new-done" "$first_slug"
    rm -rf "$temp_root"
}

test_auto_run_list_skips_invalid_states_with_warning() {
    local temp_root project script
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    script="$SOURCE_FLOW_AUTO_RUN_SCRIPT"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "20260503-valid" "PLANNED" "20260503" "valid"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "20260503-broken" "REVIEW_FAILED" "20260503" "broken"

    python3 - "$project/.ai-flow/state/20260503-broken.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["last_review"] = None
payload["transitions"][-1]["event"] = "coding_review_failed"
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

    (
        cd "$project"
        bash "$script" list >"$temp_root/list-invalid.out" 2>"$temp_root/list-invalid.err"
    )

    assert_contains "$temp_root/list-invalid.out" "20260503-valid"
    assert_not_contains "$temp_root/list-invalid.out" "20260503-broken"
    assert_contains "$temp_root/list-invalid.err" "跳过无效状态文件 20260503-broken"
    assert_contains "$temp_root/list-invalid.err" "coding_review_failed"
    rm -rf "$temp_root"
}

test_auto_run_resolve_supports_unique_keyword_and_rejects_ambiguous() {
    local temp_root project script resolved rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    script="$SOURCE_FLOW_AUTO_RUN_SCRIPT"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "20260503-user-auth" "PLANNED" "20260503" "user auth"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "20260503-user-profile" "DONE" "20260503" "user profile"

    (
        cd "$project"
        bash "$script" resolve "auth" >"$temp_root/resolve-auth.out"
    )
    resolved="$(cat "$temp_root/resolve-auth.out")"
    assert_equals "20260503-user-auth" "$resolved"

    set +e
    (
        cd "$project"
        bash "$script" resolve "user" >"$temp_root/resolve-user.out" 2>"$temp_root/resolve-user.err"
    )
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected ambiguous keyword to fail"
    assert_contains "$temp_root/resolve-user.err" "匹配到多个 flow"

    set +e
    (
        cd "$project"
        bash "$script" resolve "missing" >"$temp_root/resolve-missing.out" 2>"$temp_root/resolve-missing.err"
    )
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected missing keyword to fail"
    assert_contains "$temp_root/resolve-missing.err" "找不到匹配 'missing' 的可自动编排 flow"
    rm -rf "$temp_root"
}

test_auto_run_dirty_ignores_ai_flow_metadata_in_single_repo() {
    local temp_root project script
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    script="$SOURCE_FLOW_AUTO_RUN_SCRIPT"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "20260503-demo" "DONE" "20260503" "demo"

    (
        cd "$project"
        bash "$script" dirty "20260503-demo" >"$temp_root/dirty-clean.out"
    )
    assert_equals "clean" "$(head -1 "$temp_root/dirty-clean.out")"

    printf 'metadata\n' > "$project/.ai-flow/reports/notes.md"
    (
        cd "$project"
        bash "$script" dirty "20260503-demo" >"$temp_root/dirty-metadata.out"
    )
    assert_equals "clean" "$(head -1 "$temp_root/dirty-metadata.out")"

    printf 'code change\n' > "$project/src/review-target.txt"
    (
        cd "$project"
        bash "$script" dirty "20260503-demo" >"$temp_root/dirty-code.out"
    )
    assert_equals "dirty" "$(head -1 "$temp_root/dirty-code.out")"
    assert_contains "$temp_root/dirty-code.out" $'owner\t'
    rm -rf "$temp_root"
}

test_auto_run_dirty_detects_plan_repos_participant_changes() {
    local temp_root workspace script slug
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    script="$SOURCE_FLOW_AUTO_RUN_SCRIPT"
    slug="20260503-ws-demo"
    setup_workspace_root "$workspace" "auto-run-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$SOURCE_FLOW_STATE_SCRIPT" "$workspace" "$slug" "DONE" "20260503" "ws demo"

    (
        cd "$workspace"
        bash "$script" dirty "$slug" >"$temp_root/workspace-clean.out"
    )
    assert_equals "clean" "$(head -1 "$temp_root/workspace-clean.out")"

    printf 'ignored owner change\n' > "$workspace/README.md"
    (
        cd "$workspace"
        bash "$script" dirty "$slug" >"$temp_root/workspace-owner-only.out"
    )
    assert_equals "clean" "$(head -1 "$temp_root/workspace-owner-only.out")"

    printf 'participant change\n' > "$workspace/repo-alpha/src/feature.txt"
    (
        cd "$workspace"
        bash "$script" dirty "$slug" >"$temp_root/workspace-dirty.out"
    )
    assert_equals "dirty" "$(head -1 "$temp_root/workspace-dirty.out")"
    assert_contains "$temp_root/workspace-dirty.out" $'repo-alpha\t'
    rm -rf "$temp_root"
}

test_auto_run_list_filters_allowed_states_and_sorts_by_updated_at
test_auto_run_list_skips_invalid_states_with_warning
test_auto_run_resolve_supports_unique_keyword_and_rejects_ambiguous
test_auto_run_dirty_ignores_ai_flow_metadata_in_single_repo
test_auto_run_dirty_detects_plan_repos_participant_changes
