#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_transition_happy_path_and_derived_view() {
    local temp_root project state_script state_slug raw_out view_out
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    state_slug="demo"
    setup_project_dirs "$project" "20260503"
    create_plan_file "$project" "demo" "20260503" "demo"
    setup_git_repo_clean "$project"

    (
        cd "$project"
        local repo_scope
        repo_scope="$(repo_scope_json "$project" "owner::.")"
        bash "$state_script" transition --slug "$state_slug" --event plan_created --title demo --plan-file .ai-flow/plans/20260503-demo.md --repo-scope-json "$repo_scope" >/dev/null
        bash "$state_script" transition --slug "$state_slug" --event plan_review_passed --result passed --engine Fixture --model fixture >/dev/null
        bash "$state_script" transition --slug "$state_slug" --event execute_started >/dev/null
        bash "$state_script" transition --slug "$state_slug" --event implementation_completed >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503-demo-review.md" "demo" ".ai-flow/plans/20260503-demo.md" "regular" "1" "failed" "demo"
        bash "$state_script" transition --slug "$state_slug" --event review_failed --result failed --report-file .ai-flow/reports/20260503-demo-review.md --engine Fixture --model fixture >/dev/null
        bash "$state_script" transition --slug "$state_slug" --event fix_started >/dev/null
        bash "$state_script" transition --slug "$state_slug" --event fix_completed >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503-demo-review-v2.md" "demo" ".ai-flow/plans/20260503-demo.md" "regular" "2" "passed_with_notes" "demo"
        bash "$state_script" transition --slug "$state_slug" --event review_passed --result passed_with_notes --report-file .ai-flow/reports/20260503-demo-review-v2.md --engine Fixture --model fixture >/dev/null
        bash "$state_script" transition --slug "$state_slug" --event implementation_reopened --note "需求变更" >/dev/null
        bash "$state_script" show --slug "$state_slug" --raw >"$temp_root/raw.json"
        bash "$state_script" show --slug "$state_slug" >"$temp_root/view.json"
    )

    assert_equals "IMPLEMENTING" "$(state_field "$project" "$state_slug" "current_status")"
    assert_equals "passed_with_notes" "$(state_field "$project" "$state_slug" "derived.last_review.result")"
    assert_equals ".ai-flow/reports/20260503-demo-review-v2.md" "$(state_field "$project" "$state_slug" "derived.last_review.report_file")"
    assert_equals "2" "$(state_field "$project" "$state_slug" "derived.review_rounds.regular")"
    assert_equals "0" "$(state_field "$project" "$state_slug" "derived.review_rounds.recheck")"
    assert_equals "implementation_reopened" "$(state_field "$project" "$state_slug" "transitions.8.event")"

    raw_out="$temp_root/raw.json"
    view_out="$temp_root/view.json"
    assert_not_contains "$raw_out" "\"derived\""
    assert_not_contains "$raw_out" "\"last_review\""
    assert_contains "$view_out" "\"derived\""
    assert_contains "$view_out" "\"active_fix\": null"
    rm -rf "$temp_root"
}

test_lock_conflict_rejected() {
    local temp_root project state_script rc state_slug
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    state_slug="20260503-demo"
    setup_project_dirs "$project" "20260503"
    create_plan_file "$project" "demo" "20260503" "demo"
    setup_git_repo_clean "$project"

    (
        cd "$project"
        local repo_scope
        repo_scope="$(repo_scope_json "$project" "owner::.")"
        bash "$state_script" transition --slug "$state_slug" --event plan_created --title demo --plan-file .ai-flow/plans/20260503-demo.md --repo-scope-json "$repo_scope" >/dev/null
        mkdir -p ".ai-flow/state/.locks/${state_slug}.lock"
        set +e
        bash "$state_script" transition --slug "$state_slug" --event plan_review_passed --result passed --engine Fixture --model fixture >"$temp_root/lock.out" 2>&1
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "Expected lock conflict to fail"
    )

    assert_contains "$temp_root/lock.out" "状态锁已存在"
    rm -rf "$temp_root"
}

test_transition_rejects_engine_alias_in_model() {
    local temp_root project state_script rc state_slug
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    state_slug="demo"
    setup_project_dirs "$project" "20260503"
    create_plan_file "$project" "demo" "20260503" "demo"
    setup_git_repo_clean "$project"

    (
        cd "$project"
        local repo_scope
        repo_scope="$(repo_scope_json "$project" "owner::.")"
        bash "$state_script" transition --slug "$state_slug" --event plan_created --title demo --plan-file .ai-flow/plans/20260503-demo.md --repo-scope-json "$repo_scope" >/dev/null

        set +e
        bash "$state_script" transition --slug "$state_slug" --event plan_review_passed --result passed --engine ai-flow-claude-plan-review --model claude >"$temp_root/model-alias.out" 2>&1
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "Expected engine alias model to be rejected"
    )

    assert_contains "$temp_root/model-alias.out" "model 必须是具体模型名，不能是引擎别名"
    rm -rf "$temp_root"
}

test_transition_happy_path_and_derived_view
test_lock_conflict_rejected
test_transition_rejects_engine_alias_in_model
