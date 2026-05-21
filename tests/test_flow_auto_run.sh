#!/bin/bash
# test_flow_auto_run.sh — flow-auto-run.sh 单元测试
# 测试 list/resolve/dirty 三个子命令。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

AUTO_RUN_SH="$SCRIPTS_DIR/flow-auto-run.sh"
FLOW_STATE_SH="$SCRIPTS_DIR/flow-state.sh"

snapshot_json_for_entries() {
    local repo_id="$1"
    shift
    python3 - "$repo_id" "$@" <<'PY'
import json
import sys

repo_id, *pairs = sys.argv[1:]
if len(pairs) % 2 != 0:
    raise SystemExit("path/token pairs required")

entries = []
for index in range(0, len(pairs), 2):
    path = pairs[index]
    token = pairs[index + 1]
    entries.append({"path": path, "tokens": [token]})

print(json.dumps({
    "repos": [
        {
            "repo_id": repo_id,
            "entries": entries,
        }
    ]
}, ensure_ascii=False))
PY
}

echo "=== flow-auto-run.sh 测试 ==="
echo ""

# --- 测试 1: 无状态文件时 list 为空 ---
test_list_no_states() {
    local dir
    dir="$(create_temp_project "auto-run-1")"
    cd "$dir"
    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" list 2>&1)" || exit_code=$?
    # 有 .ai-flow/state 但无 json 文件，list 应输出空
    assert_exit_code "$exit_code" 0 "list 在无状态文件时正常退出"
    if [[ -z "$output" ]]; then
        test_pass "list 在无状态文件时输出为空"
    else
        test_fail "list 在无状态文件时输出为空" "实际输出: $output"
    fi
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 2: 有合法状态时 list 有输出 ---
test_list_with_valid_state() {
    local dir
    dir="$(create_temp_project "auto-run-2")"
    create_minimal_state "$dir" "20260519-test-auto-run"
    # 先转换到 PLANNED 状态
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-auto-run" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" list 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "list 有状态文件时正常退出"
    assert_contains "$output" "20260519-test-auto-run" "list 输出包含 slug"
    assert_contains "$output" "PLANNED" "list 输出包含状态"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 3: 过滤掉不自动运行的状态 ---
test_list_filters_non_auto_states() {
    local dir
    dir="$(create_temp_project "auto-run-3")"
    # AWAITING_PLAN_REVIEW 不在自动运行状态列表中
    create_minimal_state "$dir" "20260519-test-filter"
    cd "$dir"
    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" list 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "list 过滤非自动状态"
    if [[ -z "$output" ]]; then
        test_pass "list 过滤掉 AWAITING_PLAN_REVIEW"
    else
        test_fail "list 过滤掉 AWAITING_PLAN_REVIEW" "不应输出: $output"
    fi
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 4: DONE 且 clean 时不进入候选 ---
test_list_excludes_done_when_clean() {
    local dir
    dir="$(create_temp_project "auto-run-4")"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md
    git add README.md
    git commit -q -m "init"

    create_minimal_state "$dir" "20260519-test-done-clean"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-done-clean" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-done-clean" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-done-clean" \
        --event implementation_completed >/dev/null 2>&1

    printf 'change\n' >> README.md
    create_minimal_review_report "$dir" "r1.md"
    local snapshot
    snapshot="$(snapshot_json_for_entries "owner" "README.md" "M")"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-done-clean" \
        --event review_passed --result passed \
        --report-file .ai-flow/reports/r1.md \
        --engine test-engine --model test-model \
        --worktree-snapshot-json "$snapshot" >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" list 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "DONE clean 时 list 正常退出"
    assert_not_contains "$output" "20260519-test-done-clean" "DONE clean 不进入 auto-run 候选"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 5: DONE 且 dirty 时保留候选 ---
test_list_includes_done_when_dirty() {
    local dir
    dir="$(create_temp_project "auto-run-5")"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md
    git add README.md
    git commit -q -m "init"

    create_minimal_state "$dir" "20260519-test-done-dirty"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-done-dirty" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-done-dirty" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-done-dirty" \
        --event implementation_completed >/dev/null 2>&1

    printf 'change\n' >> README.md
    create_minimal_review_report "$dir" "r1.md"
    local snapshot
    snapshot="$(snapshot_json_for_entries "owner" "README.md" "M")"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-done-dirty" \
        --event review_passed --result passed \
        --report-file .ai-flow/reports/r1.md \
        --engine test-engine --model test-model \
        --worktree-snapshot-json "$snapshot" >/dev/null 2>&1

    printf 'new\n' > extra.txt

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" list 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "DONE dirty 时 list 正常退出"
    assert_contains "$output" "20260519-test-done-dirty" "DONE dirty 保留在 auto-run 候选"
    assert_contains "$output" "DONE" "DONE dirty 候选仍显示状态"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 6: resolve 精确匹配 ---
test_resolve_exact() {
    local dir
    dir="$(create_temp_project "auto-run-6")"
    create_minimal_state "$dir" "20260519-test-resolve"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-resolve" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" resolve "20260519-test-resolve" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "resolve 精确匹配"
    assert_contains "$output" "20260519-test-resolve" "resolve 输出 slug"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 7: resolve 模糊匹配 ---
test_resolve_fuzzy() {
    local dir
    dir="$(create_temp_project "auto-run-7")"
    create_minimal_state "$dir" "20260519-test-fuzzy"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-fuzzy" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" resolve "fuzzy" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "resolve 模糊匹配"
    assert_contains "$output" "20260519-test-fuzzy" "resolve 模糊匹配成功"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 8: resolve 匹配多个 ---
test_resolve_multiple() {
    local dir
    dir="$(create_temp_project "auto-run-8")"
    create_minimal_state "$dir" "20260519-test-multi-a"
    create_minimal_state "$dir" "20260519-test-multi-b"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-multi-a" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-multi-b" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" resolve "test-multi" 2>&1)" || exit_code=$?
    # 匹配多个应失败
    assert_exit_code "$exit_code" 1 "resolve 匹配多个时失败"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 9: resolve 无匹配 ---
test_resolve_no_match() {
    local dir
    dir="$(create_temp_project "auto-run-9")"
    create_minimal_state "$dir" "20260519-test-nomatch"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-nomatch" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" resolve "notexist" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "resolve 无匹配时失败"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 10: usage ---
test_usage() {
    local output exit_code=0
    output="$(bash "$AUTO_RUN_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "无参数时显示用法"
}

# --- 测试 11: DONE 状态缺少快照时即使仓库干净也保守返回 dirty ---
test_dirty_clean() {
    local dir
    dir="$(create_temp_project "auto-run-11")"
    # 初始化 git 仓库
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md
    git add README.md
    git commit -q -m "init"

    create_minimal_state "$dir" "20260519-test-dirty-clean"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-clean" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" dirty "20260519-test-dirty-clean" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "缺少快照时 dirty check 正常退出"
    assert_contains "$output" "dirty" "缺少快照时干净仓库也保守返回 dirty"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 12: DONE 状态下与最近通过审查快照一致，返回 clean ---
test_dirty_clean_when_snapshot_matches() {
    local dir
    dir="$(create_temp_project "auto-run-12")"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md
    git add README.md
    git commit -q -m "init"

    create_minimal_state "$dir" "20260519-test-dirty-snapshot-clean"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-clean" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-clean" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-clean" \
        --event implementation_completed >/dev/null 2>&1

    printf 'change\n' >> README.md
    create_minimal_review_report "$dir" "r1.md"
    local snapshot
    snapshot="$(snapshot_json_for_entries "owner" "README.md" "M")"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-clean" \
        --event review_passed --result passed \
        --report-file .ai-flow/reports/r1.md \
        --engine test-engine --model test-model \
        --worktree-snapshot-json "$snapshot" >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" dirty "20260519-test-dirty-snapshot-clean" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "快照一致时 dirty check 正常退出"
    assert_contains "$output" "clean" "快照一致返回 clean"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 13: DONE 状态下与最近通过审查快照不一致，返回 dirty ---
test_dirty_when_snapshot_differs() {
    local dir
    dir="$(create_temp_project "auto-run-13")"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md
    git add README.md
    git commit -q -m "init"

    create_minimal_state "$dir" "20260519-test-dirty-snapshot-diff"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-diff" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-diff" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-diff" \
        --event implementation_completed >/dev/null 2>&1

    printf 'change\n' >> README.md
    create_minimal_review_report "$dir" "r1.md"
    local snapshot
    snapshot="$(snapshot_json_for_entries "owner" "README.md" "M")"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-diff" \
        --event review_passed --result passed \
        --report-file .ai-flow/reports/r1.md \
        --engine test-engine --model test-model \
        --worktree-snapshot-json "$snapshot" >/dev/null 2>&1

    printf 'new\n' > extra.txt

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" dirty "20260519-test-dirty-snapshot-diff" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "快照不一致时 dirty check 正常退出"
    assert_contains "$output" "dirty" "快照不一致返回 dirty"
    assert_contains "$output" "owner" "快照不一致输出 repo 标识"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 14: DONE 状态缺少快照时保守返回 dirty ---
test_dirty_when_snapshot_missing() {
    local dir
    dir="$(create_temp_project "auto-run-14")"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md
    git add README.md
    git commit -q -m "init"

    create_minimal_state "$dir" "20260519-test-dirty-snapshot-missing"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-missing" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-missing" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-missing" \
        --event implementation_completed >/dev/null 2>&1

    printf 'change\n' >> README.md
    create_minimal_review_report "$dir" "r1.md"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-snapshot-missing" \
        --event review_passed --result passed \
        --report-file .ai-flow/reports/r1.md \
        --engine test-engine --model test-model >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" dirty "20260519-test-dirty-snapshot-missing" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "缺少快照时 dirty check 正常退出"
    assert_contains "$output" "dirty" "缺少快照时保守返回 dirty"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 15: 真实 git 状态 token（?? / MM）与快照一致时返回 clean ---
test_dirty_clean_with_real_git_status_tokens() {
    local dir
    dir="$(create_temp_project "auto-run-15")"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    printf 'base\n' > tracked.txt
    git add tracked.txt
    git commit -q -m "init"

    create_minimal_state "$dir" "20260519-test-dirty-real-status"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-real-status" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-real-status" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-real-status" \
        --event implementation_completed >/dev/null 2>&1

    printf 'staged\n' >> tracked.txt
    git add tracked.txt
    printf 'unstaged\n' >> tracked.txt
    printf 'new\n' > extra.txt

    create_minimal_review_report "$dir" "r1.md"
    local snapshot
    snapshot="$(snapshot_json_for_entries "owner" "extra.txt" "??" "tracked.txt" "MM")"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-dirty-real-status" \
        --event review_passed --result passed \
        --report-file .ai-flow/reports/r1.md \
        --engine test-engine --model test-model \
        --worktree-snapshot-json "$snapshot" >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_ACTOR=test bash "$AUTO_RUN_SH" dirty "20260519-test-dirty-real-status" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "真实 git 状态 token 时 dirty check 正常退出"
    assert_contains "$output" "clean" "真实 git 状态 token 一致时返回 clean"
    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 运行 ---
test_list_no_states
test_list_with_valid_state
test_list_filters_non_auto_states
test_list_excludes_done_when_clean
test_list_includes_done_when_dirty
test_resolve_exact
test_resolve_fuzzy
test_resolve_multiple
test_resolve_no_match
test_usage
test_dirty_clean
test_dirty_clean_when_snapshot_matches
test_dirty_when_snapshot_differs
test_dirty_when_snapshot_missing
test_dirty_clean_with_real_git_status_tokens

print_summary
exit "$fail_count"
