#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

build_message_map_json() {
    local prepared_json="$1"
    local mode="${2:-default}"
    python3 - "$prepared_json" "$mode" <<'PY'
import json
import sys

groups = json.loads(sys.argv[1])
mode = sys.argv[2]
payload = {}

for item in groups:
    repo_id = item["repo_id"]
    group_id = item["group_id"]
    title = item["group_title"]
    diff = item["staged_diff"]
    files = item["files"]

    repo_bucket = payload.setdefault(repo_id, {})
    if mode == "missing" and group_id == groups[-1]["group_id"] and repo_id == groups[-1]["repo_id"]:
        continue
    if mode == "invalid-verb" and group_id == groups[-1]["group_id"] and repo_id == groups[-1]["repo_id"]:
        repo_bucket[group_id] = {
            "subject": ":sparkles: 新增代码变更",
            "body": ["同步提交本组改动"],
            "footer": [],
        }
        continue

    if "refreshSession" in diff:
        repo_bucket[group_id] = {
            "subject": ":bug: 修复session 逻辑",
            "body": ["补充过期判空保护", "保持续期判断行为"],
            "footer": [],
        }
    elif any(path.endswith(".md") for path in files):
        repo_bucket[group_id] = {
            "subject": ":memo: 更新文档说明",
            "body": ["同步整理提交说明"],
            "footer": [],
        }
    elif any(path.startswith("scripts/") for path in files):
        repo_bucket[group_id] = {
            "subject": ":wrench: 调整scripts 配置",
            "body": ["同步整理脚本入口"],
            "footer": [],
        }
    else:
        repo_bucket[group_id] = {
            "subject": ":sparkles: 添加代码变更",
            "body": ["同步提交本组改动"],
            "footer": [],
        }

print(json.dumps(payload, ensure_ascii=False))
PY
}

run_commit_with_generated_messages() {
    local commit_script="$1"
    local output_file="$2"
    shift 2
    local prepared_json message_map_json
    prepared_json="$(bash "$commit_script" "$@" --prepare-json)"
    message_map_json="$(build_message_map_json "$prepared_json")"
    bash "$commit_script" "$@" --message-map-json "$message_map_json" >"$output_file" 2>&1
    [ -s "$output_file" ] || fail "Expected commit output file to be non-empty: $output_file"
}

test_standalone_commit_single_group() {
    local temp_root repo commit_script subject prepared_json message_map_json
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "standalone")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/standalone.out"
    )

    assert_protocol_field "$temp_root/standalone.out" "RESULT" "success"
    assert_protocol_field "$temp_root/standalone.out" "SCOPE" "standalone"
    assert_protocol_field "$temp_root/standalone.out" "COMMITS" "1"
    assert_contains "$temp_root/standalone.out" "verify: git diff --check"
    assert_contains "$temp_root/standalone.out" "committed:"
    assert_contains "$temp_root/standalone.out" "本次提交结果"
    assert_contains "$temp_root/standalone.out" "[owner]"
    subject="$(git_head_subject "$repo")"
    assert_not_contains "$temp_root/standalone.out" "完成"
    [[ "$subject" == :* ]] || fail "Expected commit subject to start with emoji code, got: $subject"
    [[ "$subject" != *"完成"* ]] || fail "Expected commit subject not to contain 完成, got: $subject"
    assert_equals "2" "$(git_commit_count "$repo")"
    rm -rf "$temp_root"
}

test_commit_message_uses_diff_and_keeps_body_concise() {
    local temp_root repo commit_script body_lines subject prepared_json message_map_json
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "message-body")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    cat > "$repo/src/session.js" <<'EOF'
export function refreshSession(expireAt, now) {
  return expireAt > now;
}
EOF
    (
        cd "$repo"
        git add src/session.js
        git commit -q -m "add session base"
    )
    cat > "$repo/src/session.js" <<'EOF'
export function refreshSession(expireAt, now) {
  if (!expireAt) {
    return false;
  }
  return expireAt > now;
}
EOF

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/message-body.out"
    )

    subject="$(git_head_subject "$repo")"
    [[ "$subject" == :bug:\ 修复* ]] || fail "Expected bug-fix style subject, got: $subject"
    assert_not_contains "$temp_root/message-body.out" "完成"
    body_lines="$(git -C "$repo" log -1 --pretty=%B | tail -n +3 | sed '/^$/d')"
    [ -n "$body_lines" ] || fail "Expected generated commit body"
    printf '%s\n' "$body_lines" | while IFS= read -r line; do
        [ "${#line}" -le 30 ] || fail "Expected concise commit body line, got: $line"
    done
    rm -rf "$temp_root"
}

test_commit_rejects_subject_verb_outside_whitelist() {
    local temp_root repo commit_script prepared_json message_map_json
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "invalid-verb")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        message_map_json="$(build_message_map_json "$prepared_json" invalid-verb)"
        set +e
        bash "$commit_script" --message-map-json "$message_map_json" >"$temp_root/invalid-verb.out" 2>&1
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "Expected invalid subject verb to fail"
    )

    assert_contains "$temp_root/invalid-verb.out" "subject 格式不合法；动词只允许：添加/修复/更新/调整/重构/优化/补充/回滚"
    rm -rf "$temp_root"
}

test_bound_done_rejects_non_done_status() {
    local temp_root project runtime_script commit_script state_slug
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-demo"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"
    write_simple_test_runner "$project"

    set +e
    (
        cd "$project"
        bash "$commit_script" --slug "$state_slug" >"$temp_root/not-done.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected non-DONE slug commit to fail"
    assert_protocol_field "$temp_root/not-done.out" "RESULT" "failed"
    assert_contains "$temp_root/not-done.out" "只有 DONE 允许提交"
    rm -rf "$temp_root"
}

test_bound_done_single_repo_commit() {
    local temp_root project runtime_script commit_script prepared_json message_map_json state_slug
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-demo"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "DONE" "20260503" "demo"
    write_simple_test_runner "$project"
    printf 'done change\n' > "$project/src/review-target.txt"

    (
        cd "$project"
        run_commit_with_generated_messages "$commit_script" "$temp_root/bound-single.out" --slug "$state_slug"
    )

    assert_protocol_field "$temp_root/bound-single.out" "RESULT" "success"
    assert_protocol_field "$temp_root/bound-single.out" "SCOPE" "bound"
    assert_protocol_field "$temp_root/bound-single.out" "SLUG" "$state_slug"
    assert_protocol_field "$temp_root/bound-single.out" "COMMITS" "1"
    assert_equals "2" "$(git_commit_count "$project")"
    rm -rf "$temp_root"
}

test_standalone_merges_related_changes_into_single_group() {
    local temp_root repo commit_script prepared_json message_map_json
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "ambiguous")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    mkdir -p "$repo/scripts"
    printf 'app\n' > "$repo/src/app.txt"
    printf 'tool\n' > "$repo/scripts/tool.sh"

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/multi-group.out"
    )

    assert_protocol_field "$temp_root/multi-group.out" "RESULT" "success"
    assert_protocol_field "$temp_root/multi-group.out" "SCOPE" "standalone"
    assert_protocol_field "$temp_root/multi-group.out" "COMMITS" "1"
    assert_contains "$temp_root/multi-group.out" "识别到 1 个业务提交组"
    assert_contains "$temp_root/multi-group.out" "提交组 standalone-1:"
    assert_contains "$temp_root/multi-group.out" "file: scripts/tool.sh"
    assert_contains "$temp_root/multi-group.out" "file: src/app.txt"
    assert_equals "2" "$(git_commit_count "$repo")"
    rm -rf "$temp_root"
}

test_standalone_splits_unrelated_changes_into_multiple_groups() {
    local temp_root repo commit_script prepared_json message_map_json
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "unrelated")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    mkdir -p "$repo/billing" "$repo/search"
    printf 'invoice\n' > "$repo/billing/invoice.txt"
    printf 'index\n' > "$repo/search/index.txt"

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/unrelated-group.out"
    )

    assert_protocol_field "$temp_root/unrelated-group.out" "RESULT" "success"
    assert_protocol_field "$temp_root/unrelated-group.out" "SCOPE" "standalone"
    assert_protocol_field "$temp_root/unrelated-group.out" "COMMITS" "2"
    assert_contains "$temp_root/unrelated-group.out" "识别到 2 个业务提交组"
    assert_contains "$temp_root/unrelated-group.out" "提交组 standalone-1:"
    assert_contains "$temp_root/unrelated-group.out" "提交组 standalone-2:"
    assert_contains "$temp_root/unrelated-group.out" "file: billing/invoice.txt"
    assert_contains "$temp_root/unrelated-group.out" "file: search/index.txt"
    assert_equals "3" "$(git_commit_count "$repo")"
    rm -rf "$temp_root"
}

test_plan_repos_commit_uses_dependency_order() {
    local temp_root workspace runtime_script commit_script scope alpha beta prepared_json message_map_json state_slug
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-multi-demo"

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
        bash "$runtime_script" record-plan-review --slug "$state_slug" --result passed --engine Fixture --model fixture-model >/dev/null
        bash "$runtime_script" start-execute "$state_slug" >/dev/null
        bash "$runtime_script" finish-implementation "$state_slug" >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503-multi-demo-review.md" "multi-demo" ".ai-flow/plans/20260503-multi-demo.md" "regular" "1" "passed" "multi-demo"
        bash "$runtime_script" record-review --slug "$state_slug" --mode regular --result passed --report-file ".ai-flow/reports/20260503-multi-demo-review.md" >/dev/null
    )
    printf 'alpha local\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta local\n' > "$workspace/repo-beta/src/beta.txt"

    (
        cd "$workspace"
        run_commit_with_generated_messages "$commit_script" "$temp_root/multi.out" --slug "$state_slug"
    )

    assert_protocol_field "$temp_root/multi.out" "RESULT" "success"
    assert_protocol_field "$temp_root/multi.out" "COMMITS" "2"
    assert_contains "$temp_root/multi.out" "verify: git diff --check"
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
    local temp_root workspace runtime_script commit_script scope prepared_json message_map_json state_slug
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-multi-no-dep"

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
        bash "$runtime_script" record-plan-review --slug "$state_slug" --result passed --engine Fixture --model fixture-model >/dev/null
        bash "$runtime_script" start-execute "$state_slug" >/dev/null
        bash "$runtime_script" finish-implementation "$state_slug" >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503-multi-no-dep-review.md" "multi-no-dep" ".ai-flow/plans/20260503-multi-no-dep.md" "regular" "1" "passed" "multi-no-dep"
        bash "$runtime_script" record-review --slug "$state_slug" --mode regular --result passed --report-file ".ai-flow/reports/20260503-multi-no-dep-review.md" >/dev/null
    )
    printf 'alpha local\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta local\n' > "$workspace/repo-beta/src/beta.txt"

    (
        cd "$workspace"
        run_commit_with_generated_messages "$commit_script" "$temp_root/multi-no-dep.out" --slug "$state_slug"
    )

    assert_protocol_field "$temp_root/multi-no-dep.out" "RESULT" "success"
    assert_contains "$temp_root/multi-no-dep.out" "plan 未声明跨仓依赖表"
    rm -rf "$temp_root"
}

test_standalone_auto_conflict_preserves_both_sides() {
    local temp_root repo remote_dir commit_script prepared_json message_map_json
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "conflict")"
    remote_dir="$temp_root/conflict-remote.git"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local line\n' > "$repo/src/app.txt"
    make_remote_change "$remote_dir" "src/app.txt" "remote line"

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/conflict.out" --conflict-mode auto
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
        bash "$commit_script" --conflict-mode manual --prepare-json >"$temp_root/manual-conflict.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected manual conflict mode to stop"
    assert_protocol_field "$temp_root/manual-conflict.out" "RESULT" "failed"
    assert_contains "$temp_root/manual-conflict.out" "发生冲突"
    rm -rf "$temp_root"
}

test_commit_rejects_missing_message_map_entry() {
    local temp_root repo commit_script prepared_json message_map_json rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "missing-message")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    mkdir -p "$repo/billing" "$repo/search"
    printf 'invoice\n' > "$repo/billing/invoice.txt"
    printf 'index\n' > "$repo/search/index.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        message_map_json="$(build_message_map_json "$prepared_json" missing)"
        bash "$commit_script" --message-map-json "$message_map_json" >"$temp_root/missing-message.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected commit to fail when a message entry is missing"
    assert_protocol_field "$temp_root/missing-message.out" "RESULT" "failed"
    assert_contains "$temp_root/missing-message.out" "缺少合法的 commit message"
    rm -rf "$temp_root"
}

test_plan_repos_commit_with_non_git_root() {
    local temp_root workspace runtime_script commit_script scope alpha beta alpha_git_root beta_git_root prepared_json message_map_json state_slug
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260514-non-git-root"

    mkdir -p "$workspace"
    setup_project_dirs "$workspace" "20260514"
    mkdir -p "$workspace/repos"
    alpha="$(setup_git_remote_pair "$workspace/repos" "repo-alpha")"
    beta="$(setup_git_remote_pair "$workspace/repos" "repo-beta")"
    mv "$alpha" "$workspace/repo-alpha"
    mv "$beta" "$workspace/repo-beta"
    
    alpha_git_root=$(git -C "$workspace/repo-alpha" rev-parse --show-toplevel)
    beta_git_root=$(git -C "$workspace/repo-beta" rev-parse --show-toplevel)
    scope=$(cat <<EOF
{
  "mode": "plan_repos",
  "repos": [
    { "id": "owner", "path": ".", "git_root": "$workspace", "role": "owner" },
    { "id": "repo-alpha", "path": "repo-alpha", "git_root": "$alpha_git_root", "role": "participant" },
    { "id": "repo-beta", "path": "repo-beta", "git_root": "$beta_git_root", "role": "participant" }
  ]
}
EOF
)
    write_plan_repos_commit_plan "$workspace" "non-git-root" "20260514" "1"
    (
        cd "$workspace"
        bash "$runtime_script" create --slug non-git-root --title "non-git-root" --plan-file ".ai-flow/plans/20260514-non-git-root.md" --repo-scope-json "$scope" >/dev/null
        python3 - ".ai-flow/state/${state_slug}.json" <<'PY'
import json, sys; from pathlib import Path
p = Path(sys.argv[1]); s = json.loads(p.read_text()); s["current_status"] = "DONE"; p.write_text(json.dumps(s))
PY
    )
    printf 'alpha change\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta change\n' > "$workspace/repo-beta/src/beta.txt"

    (
        cd "$workspace"
        run_commit_with_generated_messages "$commit_script" "$temp_root/non-git-root.out" --slug "$state_slug"
    )

    assert_protocol_field "$temp_root/non-git-root.out" "RESULT" "success"
    assert_protocol_field "$temp_root/non-git-root.out" "COMMITS" "2"
    assert_contains "$temp_root/non-git-root.out" "[owner] 根目录非 Git 仓库，跳过该仓库的 Git 操作"
    rm -rf "$temp_root"
}

test_stash_pop_conflict_auto_resolve_cleans_up_stash() {
    local temp_root repo remote_dir commit_script prepared_json message_map_json
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "stash-cleanup")"
    remote_dir="$temp_root/stash-cleanup-remote.git"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"

    printf 'line 1\n' > "$repo/src/app.txt"
    (cd "$repo" && git add . && git commit -m "base" && git push origin main)
    make_remote_change "$remote_dir" "src/app.txt" "remote change\nline 1"
    printf 'local change\nline 1\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/stash-cleanup.out" --conflict-mode auto
    )

    assert_protocol_field "$temp_root/stash-cleanup.out" "RESULT" "success"
    [ -z "$(git -C "$repo" stash list)" ] || fail "Expected stash list to be empty after auto-resolve"
    rm -rf "$temp_root"
}

test_standalone_commit_single_group
test_bound_done_rejects_non_done_status
test_bound_done_single_repo_commit
test_commit_rejects_subject_verb_outside_whitelist
test_standalone_merges_related_changes_into_single_group
test_standalone_splits_unrelated_changes_into_multiple_groups
test_plan_repos_commit_uses_dependency_order
test_plan_repos_commit_falls_back_to_scope_order_without_dependency_table
test_standalone_auto_conflict_preserves_both_sides
test_standalone_manual_conflict_requires_user_action
test_commit_message_uses_diff_and_keeps_body_concise
test_commit_rejects_missing_message_map_entry
test_plan_repos_commit_with_non_git_root
test_stash_pop_conflict_auto_resolve_cleans_up_stash
