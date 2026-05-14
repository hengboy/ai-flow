#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_workspace_coding_review_detects_declared_repo_changes() {
    local temp_root workspace runtime_script executor out
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root "$workspace" "review-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$runtime_script" "$workspace" "ws-review" "AWAITING_REVIEW" "20260503" "workspace-review-test"
    setup_workspace_repo_change "$workspace" "repo-alpha" "src/ws-changed.txt"

    (
        cd "$workspace"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" ws-review >"$temp_root/review.out"
    )
    out="$temp_root/review.out"

    assert_protocol_field "$out" "RESULT" "success"
    assert_protocol_field "$out" "REVIEW_RESULT" "passed"
    assert_protocol_field "$out" "STATE" "DONE"
    rm -rf "$temp_root"
}

test_workspace_coding_review_fails_when_only_undeclared_repos_change() {
    local temp_root workspace runtime_script executor rc
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root "$workspace" "undeclared-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$runtime_script" "$workspace" "ws-undeclared" "AWAITING_REVIEW" "20260503" "undeclared-test"

    mkdir -p "$workspace/undeclared-repo/src"
    printf '{"name":"undeclared"}\n' > "$workspace/undeclared-repo/package.json"
    (
        cd "$workspace/undeclared-repo"
        git init -q
        git config user.email test@example.com
        git config user.name Test
        git add .
        git commit -q -m init
    )
    printf 'changed\n' > "$workspace/undeclared-repo/src/changed.txt"

    set +e
    (
        cd "$workspace"
        run_with_fake_coding_review_agents "$temp_root" bash "$executor" ws-undeclared >"$temp_root/undeclared.out" 2>&1
    )
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected review to fail when only undeclared repos have changes"
    rm -rf "$temp_root"
}

test_workspace_coding_review_single_declared_repo() {
    local temp_root workspace runtime_script executor out
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root_with_repos "$workspace" "single-declared-ws" "20260503" \
        "repo-alpha::repo-alpha"
    setup_workspace_single_git_repo "$workspace" "repo-alpha"
    setup_workspace_single_git_repo "$workspace" "repo-beta"
    create_workspace_state_fixture "$runtime_script" "$workspace" "ws-single" "AWAITING_REVIEW" "20260503" "single-repo-test"
    setup_workspace_repo_change "$workspace" "repo-alpha" "src/changed.txt"

    (
        cd "$workspace"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" ws-single >"$temp_root/single-repo.out"
    )
    out="$temp_root/single-repo.out"

    assert_protocol_field "$out" "RESULT" "success"
    assert_protocol_field "$out" "REVIEW_RESULT" "passed"
    assert_protocol_field "$out" "STATE" "DONE"
    rm -rf "$temp_root"
}

test_workspace_coding_review_produces_single_report() {
    local temp_root workspace runtime_script executor out report_file
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root "$workspace" "single-report-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$runtime_script" "$workspace" "ws-report" "AWAITING_REVIEW" "20260503" "single-report-test"
    setup_workspace_repo_change "$workspace" "repo-alpha" "src/a-changed.txt"
    setup_workspace_repo_change "$workspace" "repo-beta" "src/b-changed.txt"

    (
        cd "$workspace"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" ws-report >"$temp_root/review.out"
    )
    out="$temp_root/review.out"

    report_file=$(protocol_field "$out" "ARTIFACT")
    assert_file_exists "$workspace/$report_file"
    assert_equals "DONE" "$(state_field "$workspace" "ws-report" "current_status")"
    rm -rf "$temp_root"
}

test_workspace_coding_review_from_declared_subrepo_uses_workspace_root() {
    local temp_root workspace runtime_script executor out report_file
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root "$workspace" "declared-subrepo-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$runtime_script" "$workspace" "ws-subrepo" "AWAITING_REVIEW" "20260503" "workspace-subrepo-test"
    setup_workspace_repo_change "$workspace" "repo-alpha" "src/from-subrepo.txt"
    setup_workspace_repo_change "$workspace" "repo-beta" "src/from-root.txt"

    (
        cd "$workspace/repo-alpha"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" ws-subrepo >"$temp_root/subrepo.out"
    )
    out="$temp_root/subrepo.out"

    assert_protocol_field "$out" "RESULT" "success"
    assert_protocol_field "$out" "STATE" "DONE"
    report_file=$(protocol_field "$out" "ARTIFACT")
    assert_equals ".ai-flow/reports/ws-subrepo-review.md" "$report_file"
    assert_file_exists "$workspace/$report_file"
    assert_file_not_exists "$workspace/repo-alpha/.ai-flow/reports/ws-subrepo-review.md"
    assert_contains "$temp_root/codex.review.argv" "-C $(cd "$workspace" && pwd -P)"
    rm -rf "$temp_root"
}

test_workspace_coding_review_prefers_ancestor_workspace_over_local_ai_flow_dir() {
    local temp_root workspace runtime_script executor out report_file
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root "$workspace" "ancestor-workspace-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$runtime_script" "$workspace" "ws-local-flow" "AWAITING_REVIEW" "20260503" "workspace-local-flow-test"
    mkdir -p "$workspace/repo-alpha/.ai-flow/state/.locks"
    printf '{ "note": "local only" }\n' > "$workspace/repo-alpha/.ai-flow/local.json"
    setup_workspace_repo_change "$workspace" "repo-alpha" "src/local-flow.txt"

    (
        cd "$workspace/repo-alpha"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" ws-local-flow >"$temp_root/local-flow.out"
    )
    out="$temp_root/local-flow.out"

    assert_protocol_field "$out" "RESULT" "success"
    report_file=$(protocol_field "$out" "ARTIFACT")
    assert_file_exists "$workspace/$report_file"
    assert_file_not_exists "$workspace/repo-alpha/.ai-flow/reports/ws-local-flow-review.md"
    rm -rf "$temp_root"
}

test_workspace_coding_review_from_undeclared_repo_keeps_single_repo_mode() {
    local temp_root workspace runtime_script executor rc
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root "$workspace" "neighbour-ws"
    setup_workspace_git_repos "$workspace"

    mkdir -p "$workspace/standalone/src"
    printf '{ "name": "standalone" }\n' > "$workspace/standalone/package.json"
    mkdir -p "$workspace/standalone/.ai-flow/state/.locks" "$workspace/standalone/.ai-flow/reports" "$workspace/standalone/.ai-flow/plans"
    create_plan_file "$workspace/standalone" "solo" "20260503" "solo"
    (
        cd "$workspace/standalone"
        git init -q
        git config user.email test@example.com
        git config user.name Test
        git add .
        git commit -q -m init
        printf 'changed\n' > src/review-target.txt
        bash "$runtime_script" create --slug solo --title solo --plan-file .ai-flow/plans/20260503-solo.md >/dev/null
        bash "$runtime_script" record-plan-review --slug solo --result passed --engine Fixture --model fixture-model >/dev/null
        bash "$runtime_script" start-execute solo >/dev/null
        bash "$runtime_script" finish-implementation solo >/dev/null
    )

    (
        cd "$workspace/standalone"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" solo >"$temp_root/solo.out"
    )

    assert_protocol_field "$temp_root/solo.out" "RESULT" "success"
    assert_contains "$temp_root/codex.review.argv" "-C $(cd "$workspace/standalone" && pwd -P)"
    rm -rf "$temp_root"
}

test_workspace_coding_review_prompt_includes_workspace_contract() {
    local temp_root workspace runtime_script executor prompt_file
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root "$workspace" "prompt-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$runtime_script" "$workspace" "ws-prompt" "AWAITING_REVIEW" "20260503" "workspace-prompt-test"
    setup_workspace_repo_change "$workspace" "repo-alpha" "src/a.txt"
    setup_workspace_repo_change "$workspace" "repo-beta" "src/b.txt"

    (
        cd "$workspace"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" ws-prompt >"$temp_root/prompt.out"
    )

    prompt_file="$(ls -1t "$temp_root"/codex-review-prompt-*.txt | head -1)"
    assert_file_exists "$prompt_file"
    assert_contains "$prompt_file" 'git -C <git_root> status --porcelain --untracked-files=all'
    assert_contains "$prompt_file" 'git -C <git_root> diff --staged'
    assert_contains "$prompt_file" 'git -C <git_root> diff'
    assert_contains "$prompt_file" '文件路径必须写成 `repo_id/path/to/file`'
    assert_contains "$prompt_file" '`1.2 定向验证执行证据` 必须每个 dirty repo 至少一条验证命令'
    rm -rf "$temp_root"
}

test_workspace_coding_review_rejects_report_missing_dirty_repo() {
    local temp_root workspace runtime_script executor rc
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root "$workspace" "missing-dirty-repo-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$runtime_script" "$workspace" "ws-missing-repo" "AWAITING_REVIEW" "20260503" "workspace-missing-repo-test"
    setup_workspace_repo_change "$workspace" "repo-alpha" "src/a.txt"
    setup_workspace_repo_change "$workspace" "repo-beta" "src/b.txt"

    set +e
    (
        cd "$workspace"
        FAKE_CODE_REVIEW_RESULT=passed FAKE_WORKSPACE_REPORT_OMIT_REPO=repo-beta \
            run_with_fake_coding_review_agents "$temp_root" bash "$executor" ws-missing-repo >"$temp_root/missing-repo.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected workspace review to fail when report omits a dirty repo"
    assert_protocol_field "$temp_root/missing-repo.out" "RESULT" "failed"
    assert_contains "$temp_root/missing-repo.out" "plan_repos 报告缺少 dirty repo 上下文: repo-beta"
    rm -rf "$temp_root"
}

test_workspace_coding_review_detects_declared_repo_changes
test_workspace_coding_review_fails_when_only_undeclared_repos_change
test_workspace_coding_review_single_declared_repo
test_workspace_coding_review_produces_single_report
test_workspace_coding_review_from_declared_subrepo_uses_workspace_root
test_workspace_coding_review_prefers_ancestor_workspace_over_local_ai_flow_dir
test_workspace_coding_review_from_undeclared_repo_keeps_single_repo_mode
test_workspace_coding_review_prompt_includes_workspace_contract
test_workspace_coding_review_rejects_report_missing_dirty_repo
