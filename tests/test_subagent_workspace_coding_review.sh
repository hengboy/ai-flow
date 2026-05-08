#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_workspace_coding_review_detects_declared_repo_changes() {
    local temp_root workspace runtime_script executor out today
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
    today="$(date +%Y%m%d)"

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

    # Create an undeclared repo with changes
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
    # Only declare repo-alpha in the manifest; repo-beta is an undeclared neighbour
    setup_workspace_root_with_repos "$workspace" "single-declared-ws" "20260503" \
        "repo-alpha::repo-alpha"
    setup_workspace_single_git_repo "$workspace" "repo-alpha"
    # Create an undeclared repo-beta to verify it is ignored
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
    local temp_root workspace runtime_script executor out today
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    workspace="$temp_root/workspace"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    setup_workspace_root "$workspace" "single-report-ws"
    setup_workspace_git_repos "$workspace"
    create_workspace_state_fixture "$runtime_script" "$workspace" "ws-report" "AWAITING_REVIEW" "20260503" "single-report-test"
    # Change both repos
    setup_workspace_repo_change "$workspace" "repo-alpha" "src/a-changed.txt"
    setup_workspace_repo_change "$workspace" "repo-beta" "src/b-changed.txt"
    today="$(date +%Y%m%d)"

    (
        cd "$workspace"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" ws-report >"$temp_root/review.out"
    )
    out="$temp_root/review.out"

    # One report file at workspace root
    local report_file
    report_file=$(protocol_field "$out" "ARTIFACT")
    assert_file_exists "$workspace/$report_file"
    # State should be DONE
    assert_equals "DONE" "$(state_field "$workspace" "ws-report" "current_status")"
    rm -rf "$temp_root"
}

test_workspace_coding_review_detects_declared_repo_changes
test_workspace_coding_review_fails_when_only_undeclared_repos_change
test_workspace_coding_review_single_declared_repo
test_workspace_coding_review_produces_single_report
