#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_standalone_commit_single_group() {
    local temp_root repo commit_script
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "standalone")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        bash "$commit_script" >"$temp_root/standalone.out" 2>&1
    )

    assert_protocol_field "$temp_root/standalone.out" "RESULT" "success"
    assert_protocol_field "$temp_root/standalone.out" "SCOPE" "standalone"
    assert_protocol_field "$temp_root/standalone.out" "COMMITS" "1"
    assert_contains "$temp_root/standalone.out" "committed:"
    assert_contains "$temp_root/standalone.out" "本次提交结果"
    assert_contains "$temp_root/standalone.out" "[owner]"
    assert_contains "$temp_root/standalone.out" ":sparkles:"
    assert_equals "2" "$(git_commit_count "$repo")"
    rm -rf "$temp_root"
}

test_bound_done_rejects_non_done_status() {
    local temp_root project runtime_script commit_script
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"
    write_simple_test_runner "$project"

    set +e
    (
        cd "$project"
        bash "$commit_script" --slug demo >"$temp_root/not-done.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected non-DONE slug commit to fail"
    assert_protocol_field "$temp_root/not-done.out" "RESULT" "failed"
    assert_contains "$temp_root/not-done.out" "只有 DONE 允许提交"
    rm -rf "$temp_root"
}

test_bound_done_single_repo_commit() {
    local temp_root project runtime_script commit_script
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "DONE" "20260503" "demo"
    write_simple_test_runner "$project"
    printf 'done change\n' > "$project/src/review-target.txt"

    (
        cd "$project"
        bash "$commit_script" --slug demo >"$temp_root/bound-single.out" 2>&1
    )

    assert_protocol_field "$temp_root/bound-single.out" "RESULT" "success"
    assert_protocol_field "$temp_root/bound-single.out" "SCOPE" "bound"
    assert_protocol_field "$temp_root/bound-single.out" "SLUG" "demo"
    assert_protocol_field "$temp_root/bound-single.out" "COMMITS" "1"
    assert_equals "3" "$(git_commit_count "$project")"
    rm -rf "$temp_root"
}

test_standalone_rejects_ambiguous_grouping() {
    local temp_root repo commit_script
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "ambiguous")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    mkdir -p "$repo/scripts"
    printf 'app\n' > "$repo/src/app.txt"
    printf 'tool\n' > "$repo/scripts/tool.sh"

    set +e
    (
        cd "$repo"
        bash "$commit_script" >"$temp_root/ambiguous.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected ambiguous standalone grouping to fail"
    assert_protocol_field "$temp_root/ambiguous.out" "RESULT" "failed"
    assert_contains "$temp_root/ambiguous.out" "无法可靠判断业务分组"
    rm -rf "$temp_root"
}

test_plan_repos_commit_uses_dependency_order() {
    local temp_root workspace runtime_script commit_script scope alpha beta
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"

    setup_workspace_root_with_repos "$workspace" "workspace-test" "20260503" "repo-alpha::repo-alpha" "repo-beta::repo-beta"
    printf "repo-alpha/\nrepo-beta/\nrepos/\n" > "$workspace/.gitignore"
    (
        cd "$workspace" || exit 1
        git add .gitignore
        git commit -q -m "ignore nested repos"
    )
    mkdir -p "$workspace/repos"
    alpha="$(setup_git_remote_pair "$workspace/repos" "repo-alpha")"
    beta="$(setup_git_remote_pair "$workspace/repos" "repo-beta")"
    mkdir -p "$workspace/repo-alpha" "$workspace/repo-beta"
    rm -rf "$workspace/repo-alpha" "$workspace/repo-beta"
    mv "$alpha" "$workspace/repo-alpha"
    mv "$beta" "$workspace/repo-beta"
    write_plan_repos_commit_plan "$workspace" "multi-demo" "20260503" "1"
    scope="$(repo_scope_json "$workspace" "owner::." "repo-alpha::repo-alpha" "repo-beta::repo-beta")"
    (
        cd "$workspace"
        bash "$runtime_script" create --slug multi-demo --title "multi demo" --plan-file ".ai-flow/plans/20260503-multi-demo.md" --repo-scope-json "$scope" >/dev/null
        bash "$runtime_script" record-plan-review --slug multi-demo --result passed --engine Fixture --model fixture-model >/dev/null
        bash "$runtime_script" start-execute multi-demo >/dev/null
        bash "$runtime_script" finish-implementation multi-demo >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503/multi-demo-review.md" "multi-demo" ".ai-flow/plans/20260503-multi-demo.md" "regular" "1" "passed" "multi-demo"
        bash "$runtime_script" record-review --slug multi-demo --mode regular --result passed --report-file ".ai-flow/reports/20260503/multi-demo-review.md" >/dev/null
    )
    printf 'alpha local\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta local\n' > "$workspace/repo-beta/src/beta.txt"

    (
        cd "$workspace"
        bash "$commit_script" --slug multi-demo >"$temp_root/multi.out" 2>&1
    )

    assert_protocol_field "$temp_root/multi.out" "RESULT" "success"
    assert_protocol_field "$temp_root/multi.out" "COMMITS" "2"
    first_beta="$(git -C "$workspace/repo-beta" rev-parse --short HEAD)"
    first_alpha="$(git -C "$workspace/repo-alpha" rev-parse --short HEAD)"
    assert_contains "$temp_root/multi.out" "repo-beta] (participant)"
    assert_contains "$temp_root/multi.out" "repo-alpha] (participant)"
    assert_contains "$temp_root/multi.out" "[repo-beta] $first_beta"
    assert_contains "$temp_root/multi.out" "[repo-alpha] $first_alpha"
    assert_contains "$temp_root/multi.out" "$first_beta"
    assert_contains "$temp_root/multi.out" "$first_alpha"
    rm -rf "$temp_root"
}

test_plan_repos_commit_falls_back_to_scope_order_without_dependency_table() {
    local temp_root workspace runtime_script commit_script scope
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"

    setup_workspace_root_with_repos "$workspace" "workspace-test" "20260503" "repo-alpha::repo-alpha" "repo-beta::repo-beta"
    printf "repo-alpha/\nrepo-beta/\n" > "$workspace/.gitignore"
    (
        cd "$workspace" || exit 1
        git add .gitignore
        git commit -q -m "ignore nested repos"
    )
    rm -rf "$workspace/repo-alpha" "$workspace/repo-beta"
    setup_workspace_single_git_repo "$workspace" "repo-alpha"
    setup_workspace_single_git_repo "$workspace" "repo-beta"
    write_simple_test_runner "$workspace/repo-alpha"
    write_simple_test_runner "$workspace/repo-beta"
    write_plan_repos_commit_plan "$workspace" "multi-no-dep" "20260503" "0"
    scope="$(repo_scope_json "$workspace" "owner::." "repo-alpha::repo-alpha" "repo-beta::repo-beta")"
    (
        cd "$workspace"
        bash "$runtime_script" create --slug multi-no-dep --title "multi no dep" --plan-file ".ai-flow/plans/20260503-multi-no-dep.md" --repo-scope-json "$scope" >/dev/null
        bash "$runtime_script" record-plan-review --slug multi-no-dep --result passed --engine Fixture --model fixture-model >/dev/null
        bash "$runtime_script" start-execute multi-no-dep >/dev/null
        bash "$runtime_script" finish-implementation multi-no-dep >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503/multi-no-dep-review.md" "multi-no-dep" ".ai-flow/plans/20260503-multi-no-dep.md" "regular" "1" "passed" "multi-no-dep"
        bash "$runtime_script" record-review --slug multi-no-dep --mode regular --result passed --report-file ".ai-flow/reports/20260503/multi-no-dep-review.md" >/dev/null
    )
    printf 'alpha local\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta local\n' > "$workspace/repo-beta/src/beta.txt"

    (
        cd "$workspace"
        bash "$commit_script" --slug multi-no-dep >"$temp_root/multi-no-dep.out" 2>&1
    )

    assert_protocol_field "$temp_root/multi-no-dep.out" "RESULT" "success"
    assert_contains "$temp_root/multi-no-dep.out" "plan 未声明跨仓依赖表"
    rm -rf "$temp_root"
}

test_standalone_auto_conflict_preserves_both_sides() {
    local temp_root repo remote_dir commit_script
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "conflict")"
    remote_dir="$temp_root/conflict-remote.git"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local line\n' > "$repo/src/app.txt"
    make_remote_change "$remote_dir" "src/app.txt" "remote line"

    (
        cd "$repo"
        bash "$commit_script" --conflict-mode auto >"$temp_root/conflict.out" 2>&1
    )

    assert_protocol_field "$temp_root/conflict.out" "RESULT" "success"
    assert_contains "$repo/src/app.txt" "local line"
    assert_contains "$repo/src/app.txt" "remote line"
    rm -rf "$temp_root"
}

test_standalone_manual_conflict_requires_user_action() {
    local temp_root repo remote_dir commit_script rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "manual-conflict")"
    remote_dir="$temp_root/manual-conflict-remote.git"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local line\n' > "$repo/src/app.txt"
    make_remote_change "$remote_dir" "src/app.txt" "remote line"

    set +e
    (
        cd "$repo"
        bash "$commit_script" --conflict-mode manual >"$temp_root/manual-conflict.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected manual conflict mode to stop"
    assert_protocol_field "$temp_root/manual-conflict.out" "RESULT" "failed"
    assert_contains "$temp_root/manual-conflict.out" "发生冲突"
    rm -rf "$temp_root"
}

test_standalone_commit_single_group
test_bound_done_rejects_non_done_status
test_bound_done_single_repo_commit
test_standalone_rejects_ambiguous_grouping
test_plan_repos_commit_uses_dependency_order
test_plan_repos_commit_falls_back_to_scope_order_without_dependency_table
test_standalone_auto_conflict_preserves_both_sides
test_standalone_manual_conflict_requires_user_action
