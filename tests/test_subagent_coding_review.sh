#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_regular_passed_with_notes_to_done() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed_with_notes run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-notes.out"
    )

    assert_equals "DONE" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/review-notes.out" "RESULT" "success"
    assert_protocol_field "$temp_root/review-notes.out" "REVIEW_RESULT" "passed_with_notes"
    assert_protocol_field "$temp_root/review-notes.out" "STATE" "DONE"
    assert_protocol_field "$temp_root/review-notes.out" "NEXT" "none"
    assert_equals "review_passed" "$(state_field "$project" "demo" "transitions.4.event")"
    assert_equals "ai-flow-codex-plan-coding-review" "$(state_field "$project" "demo" "transitions.4.actor")"
    assert_equals "passed_with_notes" "$(state_field "$project" "demo" "transitions.4.artifacts.result")"
    assert_equals "1" "$(wc -l < "$temp_root/codex.review.calls" | tr -d ' ')"
    assert_file_not_exists "$temp_root/opencode.review.calls"
    rm -rf "$temp_root"
}

test_regular_failed_to_review_failed() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=failed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-failed.out"
    )

    assert_equals "REVIEW_FAILED" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/review-failed.out" "REVIEW_RESULT" "failed"
    assert_protocol_field "$temp_root/review-failed.out" "NEXT" "ai-flow-plan-coding"
    assert_equals "review_failed" "$(state_field "$project" "demo" "transitions.4.event")"
    assert_equals "ai-flow-codex-plan-coding-review" "$(state_field "$project" "demo" "transitions.4.actor")"
    rm -rf "$temp_root"
}

test_regular_failed_routes_to_optimize_when_all_blockers_are_optimize() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=failed FAKE_CODE_REVIEW_FAILED_ROUTE_MODE=optimize \
            run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-failed-optimize.out"
    )

    assert_equals "REVIEW_FAILED" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/review-failed-optimize.out" "REVIEW_RESULT" "failed"
    assert_protocol_field "$temp_root/review-failed-optimize.out" "NEXT" "ai-flow-code-optimize"
    rm -rf "$temp_root"
}

test_regular_failed_routes_to_coding_when_blockers_are_mixed() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=failed FAKE_CODE_REVIEW_FAILED_ROUTE_MODE=mixed \
            run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-failed-mixed.out"
    )

    assert_equals "REVIEW_FAILED" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/review-failed-mixed.out" "REVIEW_RESULT" "failed"
    assert_protocol_field "$temp_root/review-failed-mixed.out" "NEXT" "ai-flow-plan-coding"
    rm -rf "$temp_root"
}

test_recheck_pass_keeps_done() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "DONE" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/recheck.out"
    )

    assert_equals "DONE" "$(state_field "$project" "demo" "current_status")"
    assert_protocol_field "$temp_root/recheck.out" "REVIEW_RESULT" "passed"
    assert_equals "recheck_passed" "$(state_field "$project" "demo" "transitions.5.event")"
    assert_equals "ai-flow-codex-plan-coding-review" "$(state_field "$project" "demo" "transitions.5.actor")"
    rm -rf "$temp_root"
}

test_passed_with_notes_ignores_status_guide_text() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_REVIEW_INCLUDE_STATUS_NOTE=1 FAKE_CODE_REVIEW_RESULT=passed_with_notes run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-status-note.out"
    )

    assert_protocol_field "$temp_root/review-status-note.out" "RESULT" "success"
    assert_protocol_field "$temp_root/review-status-note.out" "REVIEW_RESULT" "passed_with_notes"
    assert_protocol_field "$temp_root/review-status-note.out" "STATE" "DONE"
    assert_equals "DONE" "$(state_field "$project" "demo" "current_status")"
    rm -rf "$temp_root"
}

test_done_commit_prompt_points_to_ai_flow_git_commit() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/done-prompt.out" 2>&1
    )

    assert_contains "$temp_root/done-prompt.out" "/ai-flow-git-commit"
    assert_not_contains "$temp_root/done-prompt.out" "/git-commit"
    rm -rf "$temp_root"
}

test_standalone_review_without_slug() {
    local temp_root project executor today
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_root "$project"
    setup_git_repo_clean "$project"
    printf 'changed\n' > "$project/src/review-target.txt"
    today="$(date +%Y%m%d)"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" >"$temp_root/standalone.out"
    )

    assert_protocol_field "$temp_root/standalone.out" "STATE" "none"
    assert_protocol_field "$temp_root/standalone.out" "NEXT" "none"
    assert_contains "$temp_root/standalone.out" "standalone"
    assert_file_exists "$project/.ai-flow/reports/standalone/$(basename "$(protocol_field "$temp_root/standalone.out" "ARTIFACT")")"
    rm -rf "$temp_root"
}

test_single_state_without_slug_still_binds_and_rechecks() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "DONE" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" >"$temp_root/auto-bind-recheck.out"
    )

    assert_protocol_field "$temp_root/auto-bind-recheck.out" "STATE" "DONE"
    assert_protocol_field "$temp_root/auto-bind-recheck.out" "REVIEW_RESULT" "passed"
    assert_not_contains "$temp_root/auto-bind-recheck.out" "standalone"
    assert_equals "recheck_passed" "$(state_field "$project" "demo" "transitions.5.event")"
    rm -rf "$temp_root"
}

test_explicit_standalone_review_ignores_existing_state_files() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "DONE" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" --standalone >"$temp_root/standalone-explicit.out"
    )

    assert_protocol_field "$temp_root/standalone-explicit.out" "STATE" "none"
    assert_protocol_field "$temp_root/standalone-explicit.out" "NEXT" "none"
    assert_contains "$temp_root/standalone-explicit.out" "standalone"
    assert_file_exists "$project/.ai-flow/reports/standalone/$(basename "$(protocol_field "$temp_root/standalone-explicit.out" "ARTIFACT")")"
    assert_equals "DONE" "$(state_field "$project" "demo" "current_status")"
    rm -rf "$temp_root"
}

test_no_git_changes_rejected() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_clean "$project"

    set +e
    (
        cd "$project"
        run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/no-change.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected review without git changes to fail"
    assert_protocol_field "$temp_root/no-change.out" "RESULT" "failed"
    assert_contains "$temp_root/no-change.out" "没有可审查的 Git 变更"
    rm -rf "$temp_root"
}

test_review_injects_rule_prompt() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    printf '# Review Guide\n' > "$project/README.md"
    write_rule_yaml "$project" $'version: 1\nprompt:\n  shared_context:\n    - "审查背景：核心权限链路"\nconstraints:\n  required_reads:\n    - "README.md"\nreview:\n  required_checks:\n    - "是否越过文件边界"\n'
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-rule-prompt.out"
    )

    assert_protocol_field "$temp_root/review-rule-prompt.out" "RESULT" "success"
    assert_contains "$temp_root/codex-review-prompt.log" "## AI Flow 项目规则"
    assert_contains "$temp_root/codex-review-prompt.log" "审查背景：核心权限链路"
    assert_contains "$temp_root/codex-review-prompt.log" "### Required Read [owner] README.md"
    rm -rf "$temp_root"
}

test_review_fails_on_protected_path_rule() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    write_rule_yaml "$project" $'version: 1\nprompt: {}\nconstraints:\n  protected_paths:\n    - "src/review-target.txt"\nreview: {}\n'
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    set +e
    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/protected.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected protected path rule to fail"
    assert_protocol_field "$temp_root/protected.out" "RESULT" "failed"
    assert_contains "$temp_root/protected.out" "命中 protected_paths"
    rm -rf "$temp_root"
}

test_review_fails_on_forbidden_change_rule() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    write_rule_yaml "$project" $'version: 1\nprompt: {}\nconstraints:\n  forbidden_changes:\n    - path: "src/review-target.txt"\n      reason: "禁止直接修改评审夹具"\nreview: {}\n'
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    set +e
    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/forbidden.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected forbidden change rule to fail"
    assert_protocol_field "$temp_root/forbidden.out" "RESULT" "failed"
    assert_contains "$temp_root/forbidden.out" "命中 forbidden_changes"
    assert_contains "$temp_root/forbidden.out" "禁止直接修改评审夹具"
    rm -rf "$temp_root"
}

test_review_fails_without_test_evidence_when_rule_requires_it() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    write_rule_yaml "$project" $'version: 1\nprompt: {}\nconstraints:\n  test_policy:\n    require_tests_for_code_change: true\nreview: {}\n'
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"
    printf 'doc only\n' > "$project/README.md"

    cat > "$temp_root/bin/codex" <<'FAKE_CODEX_NO_TEST'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
    cat <<'HELP'
Usage: codex exec [OPTIONS]
      --skip-git-repo-check
HELP
    exit 0
fi
temp_root="${FAKE_REVIEW_TEMP_ROOT:?}"
printf 'call\n' >> "$temp_root/codex.review.calls"
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    fi
    shift || true
done
cat > /dev/null
cat > "$out" <<'REPORT'
# 审查报告：20260503-demo

> 审查日期：2026-05-03
> 需求简称：20260503-demo
> 审查模式：regular
> 审查轮次：1
> 审查结果：passed
> 对比计划：`.ai-flow/plans/20260503-demo.md`
> 审查工具：Codex (test xhigh)
> 规则标识：`review`

## 1. 总体评价

总体通过

### 1.1 审查上下文

| 项目 | 内容 |
|------|------|
| Plan 文件 | `.ai-flow/plans/20260503-demo.md` |
| 变更范围 | staged / unstaged / untracked |
| 上一轮报告 | 无 |
| 验证证据 | 无 |

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| `git diff -- src/review-target.txt` | PASS | 仅查看 diff |

## 2. 计划覆盖度检查

| 实施步骤 | 状态 | 备注 |
|----------|------|------|
| Step 1: 示例 | 已实现 | ok |

**覆盖率**：100%

## 2.1 计划外变更识别

| 变更文件/模块 | 变更内容摘要 | 判定 | 备注 |
|----------|----------|------|------|
| 无 | 无 | 接受 | 无 |

## 3. 代码质量审查

### 3.1 架构与设计

- 合理

### 3.2 规范性

- 合理

### 3.3 安全性

- 无明显问题

### 3.4 性能

- 无明显问题

### 3.5 逻辑正确性

| 检查项 | 审查结果 | 问题描述 |
|--------|----------|----------|
| 边界条件 | 通过 | 已检查 |

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | 已检查 report |

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复流向 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|----------|

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复流向 | 修复状态 |
|---|----------|------|------|------|----------|----------|

## 5. 审查结论

- [x] **通过** — 所有步骤已实现，无严重缺陷
- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪

| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
REPORT
FAKE_CODEX_NO_TEST
    chmod +x "$temp_root/bin/codex"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/no-test-evidence.out"
    )

    assert_protocol_field "$temp_root/no-test-evidence.out" "RESULT" "success"
    assert_protocol_field "$temp_root/no-test-evidence.out" "REVIEW_RESULT" "failed"
    assert_protocol_field "$temp_root/no-test-evidence.out" "STATE" "REVIEW_FAILED"
    assert_protocol_field "$temp_root/no-test-evidence.out" "NEXT" "ai-flow-plan-coding"
    assert_contains "$temp_root/no-test-evidence.out" "缺少测试或自动化验证证据"
    rm -rf "$temp_root"
}

test_review_missing_test_evidence_can_downgrade_to_notes_via_severity_rule() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    write_rule_yaml "$project" $'version: 1\nprompt: {}\nconstraints:\n  test_policy:\n    require_tests_for_code_change: true\nreview:\n  severity_rules:\n    missing_tests_when_required: minor\n'
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    cat > "$temp_root/bin/codex" <<'FAKE_CODEX_NO_TEST_NOTES'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
    cat <<'HELP'
Usage: codex exec [OPTIONS]
      --skip-git-repo-check
HELP
    exit 0
fi
temp_root="${FAKE_REVIEW_TEMP_ROOT:?}"
printf 'call\n' >> "$temp_root/codex.review.calls"
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    fi
    shift || true
done
cat > /dev/null
cat > "$out" <<'REPORT'
# 审查报告：20260503-demo

> 审查日期：2026-05-03
> 需求简称：20260503-demo
> 审查模式：regular
> 审查轮次：1
> 审查结果：passed_with_notes
> 对比计划：`.ai-flow/plans/20260503-demo.md`
> 审查工具：Codex (test xhigh)
> 规则标识：`review`

## 1. 总体评价

总体通过（附建议）

### 1.1 审查上下文

| 项目 | 内容 |
|------|------|
| Plan 文件 | `.ai-flow/plans/20260503-demo.md` |
| 变更范围 | staged / unstaged / untracked |
| 上一轮报告 | 无 |
| 验证证据 | 无 |

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| `git diff -- src/review-target.txt` | PASS | 仅查看 diff |

## 2. 计划覆盖度检查

| 实施步骤 | 状态 | 备注 |
|----------|------|------|
| Step 1: 示例 | 已实现 | ok |

**覆盖率**：100%

## 2.1 计划外变更识别

| 变更文件/模块 | 变更内容摘要 | 判定 | 备注 |
|----------|----------|------|------|
| 无 | 无 | 接受 | 无 |

## 3. 代码质量审查

### 3.1 架构与设计

- 合理

### 3.2 规范性

- 合理

### 3.3 安全性

- 无明显问题

### 3.4 性能

- 无明显问题

### 3.5 逻辑正确性

| 检查项 | 审查结果 | 问题描述 |
|--------|----------|----------|
| 边界条件 | 通过 | 已检查 |

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | 已检查 report |

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复流向 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|----------|

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复流向 | 修复状态 |
|---|----------|------|------|------|----------|----------|
| SUG-1 | Minor | src/review-target.txt | 建议补测试证据 | 增补自动化验证 | ai-flow-plan-coding | [可选] |

## 5. 审查结论

- [ ] **通过** — 所有步骤已实现，无严重缺陷
- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪

| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| SUG-1 | v1 | [可选] | deferred | noted |
REPORT
FAKE_CODEX_NO_TEST_NOTES
    chmod +x "$temp_root/bin/codex"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed_with_notes run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/no-test-evidence-notes.out"
    )

    assert_protocol_field "$temp_root/no-test-evidence-notes.out" "RESULT" "success"
    assert_protocol_field "$temp_root/no-test-evidence-notes.out" "REVIEW_RESULT" "passed_with_notes"
    assert_protocol_field "$temp_root/no-test-evidence-notes.out" "STATE" "DONE"
    rm -rf "$temp_root"
}

test_review_missing_test_evidence_fail_condition_overrides_minor_severity() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    write_rule_yaml "$project" $'version: 1\nprompt: {}\nconstraints:\n  test_policy:\n    require_tests_for_code_change: true\nreview:\n  severity_rules:\n    missing_tests_when_required: minor\n  fail_conditions:\n    - "代码改动但缺少测试证据"\n'
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    cat > "$temp_root/bin/codex" <<'FAKE_CODEX_NO_TEST_FAIL'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
    cat <<'HELP'
Usage: codex exec [OPTIONS]
      --skip-git-repo-check
HELP
    exit 0
fi
temp_root="${FAKE_REVIEW_TEMP_ROOT:?}"
printf 'call\n' >> "$temp_root/codex.review.calls"
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    fi
    shift || true
done
cat > /dev/null
cat > "$out" <<'REPORT'
# 审查报告：20260503-demo

> 审查日期：2026-05-03
> 需求简称：20260503-demo
> 审查模式：regular
> 审查轮次：1
> 审查结果：passed_with_notes
> 对比计划：`.ai-flow/plans/20260503-demo.md`
> 审查工具：Codex (test xhigh)
> 规则标识：`review`

## 1. 总体评价

总体通过（附建议）

### 1.1 审查上下文

| 项目 | 内容 |
|------|------|
| Plan 文件 | `.ai-flow/plans/20260503-demo.md` |
| 变更范围 | staged / unstaged / untracked |
| 上一轮报告 | 无 |
| 验证证据 | 无 |

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| `git diff -- src/review-target.txt` | PASS | 仅查看 diff |

## 2. 计划覆盖度检查

| 实施步骤 | 状态 | 备注 |
|----------|------|------|
| Step 1: 示例 | 已实现 | ok |

**覆盖率**：100%

## 2.1 计划外变更识别

| 变更文件/模块 | 变更内容摘要 | 判定 | 备注 |
|----------|----------|------|------|
| 无 | 无 | 接受 | 无 |

## 3. 代码质量审查

### 3.1 架构与设计

- 合理

### 3.2 规范性

- 合理

### 3.3 安全性

- 无明显问题

### 3.4 性能

- 无明显问题

### 3.5 逻辑正确性

| 检查项 | 审查结果 | 问题描述 |
|--------|----------|----------|
| 边界条件 | 通过 | 已检查 |

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | 已检查 report |

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复流向 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|----------|

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复流向 | 修复状态 |
|---|----------|------|------|------|----------|----------|
| SUG-1 | Minor | src/review-target.txt | 建议补测试证据 | 增补自动化验证 | ai-flow-plan-coding | [可选] |

## 5. 审查结论

- [ ] **通过** — 所有步骤已实现，无严重缺陷
- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪

| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| SUG-1 | v1 | [可选] | deferred | noted |
REPORT
FAKE_CODEX_NO_TEST_FAIL
    chmod +x "$temp_root/bin/codex"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed_with_notes run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/no-test-evidence-fail-condition.out"
    )

    assert_protocol_field "$temp_root/no-test-evidence-fail-condition.out" "RESULT" "success"
    assert_protocol_field "$temp_root/no-test-evidence-fail-condition.out" "REVIEW_RESULT" "failed"
    assert_protocol_field "$temp_root/no-test-evidence-fail-condition.out" "STATE" "REVIEW_FAILED"
    assert_protocol_field "$temp_root/no-test-evidence-fail-condition.out" "NEXT" "ai-flow-plan-coding"
    assert_contains "$temp_root/no-test-evidence-fail-condition.out" "缺少测试或自动化验证证据"
    rm -rf "$temp_root"
}

test_review_fails_without_required_evidence_text() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    write_rule_yaml "$project" $'version: 1\nprompt: {}\nconstraints: {}\nreview:\n  required_evidence:\n    - "说明未执行项及原因"\n'
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    set +e
    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/missing-required-evidence.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing required evidence text to fail"
    assert_protocol_field "$temp_root/missing-required-evidence.out" "RESULT" "failed"
    assert_contains "$temp_root/missing-required-evidence.out" "命中 review.required_evidence"
    assert_contains "$temp_root/missing-required-evidence.out" "说明未执行项及原因"
    rm -rf "$temp_root"
}

test_root_cause_gate_and_fallback() {
    local temp_root project runtime_script executor change_script state_slug
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    change_script="$(installed_runtime_script "$temp_root" "flow-change.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    state_slug="20260503-demo"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        write_review_report_fixture ".ai-flow/reports/20260503-demo-review.md" "demo" ".ai-flow/plans/20260503-demo.md" "regular" "1" "failed" "demo"
        bash "$runtime_script" record-review --slug "$state_slug" --mode regular --result failed --report-file .ai-flow/reports/20260503-demo-review.md >/dev/null || true
    ) >/dev/null 2>&1 || true

    (
        cd "$project"
        bash "$runtime_script" repair --slug "$state_slug" --status REVIEW_FAILED --note "fixture align" >/dev/null
        bash "$runtime_script" start-fix "$state_slug" >/dev/null
        bash "$runtime_script" finish-fix "$state_slug" >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503-demo-review-v2.md" "demo" ".ai-flow/plans/20260503-demo.md" "regular" "2" "failed" "demo"
        bash "$runtime_script" record-review --slug "$state_slug" --mode regular --result failed --report-file .ai-flow/reports/20260503-demo-review-v2.md >/dev/null
        bash "$runtime_script" start-fix "$state_slug" >/dev/null
        bash "$runtime_script" finish-fix "$state_slug" >/dev/null
    )

    set +e
    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/root-cause-miss.out"
    )
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected round-three gate to fail without root-cause record"
    assert_contains "$temp_root/root-cause-miss.out" "root-cause-review-loop"

    (
        cd "$project"
        bash "$change_script" demo "[root-cause-review-loop] 根因：遗漏缺陷族；受影响缺陷族：测试/证据；前两轮遗漏原因：只看单点；补充验证：bash tests/run.sh" >/dev/null
        FAKE_REVIEW_CODEX_MODE=unavailable run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/root-cause-pass.out"
    )

    assert_protocol_field "$temp_root/root-cause-pass.out" "RESULT" "success"
    assert_protocol_field "$temp_root/root-cause-pass.out" "REVIEW_RESULT" "degraded"
    assert_contains "$temp_root/root-cause-pass.out" "Codex 不可用"
    rm -rf "$temp_root"
}

test_coding_review_ignores_model_override_but_keeps_reasoning() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo qwen3.6-plus high >"$temp_root/review-model.out"
    )

    assert_protocol_field "$temp_root/review-model.out" "RESULT" "success"
    assert_contains "$temp_root/codex.review.argv" "-m gpt-5.4"
    assert_not_contains "$temp_root/codex.review.argv" "-m qwen3.6-plus"
    assert_contains "$temp_root/codex.review.argv" "model_reasoning_effort=\"high\""
    rm -rf "$temp_root"
}

test_coding_review_defaults_to_high_reasoning_for_single_repo() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-default-reasoning.out"
    )

    assert_protocol_field "$temp_root/review-default-reasoning.out" "RESULT" "success"
    assert_contains "$temp_root/codex.review.argv" "model_reasoning_effort=\"high\""
    rm -rf "$temp_root"
}

test_coding_review_escalates_reasoning_on_recheck() {
    local temp_root project runtime_script executor
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "DONE" "20260503" "demo"
    setup_git_repo_with_change "$project"

    (
        cd "$project"
        FAKE_CODE_REVIEW_RESULT=passed run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/review-recheck-reasoning.out"
    )

    assert_protocol_field "$temp_root/review-recheck-reasoning.out" "RESULT" "success"
    assert_contains "$temp_root/codex.review.argv" "model_reasoning_effort=\"xhigh\""
    rm -rf "$temp_root"
}

test_coding_review_codex_mode_fails_when_codex_unavailable() {
    local temp_root project runtime_script executor setting_json
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    write_fake_coding_review_agents "$temp_root"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    executor="$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"

    # Override engine_mode via setting.json
    setting_json="$temp_root/home/.config/ai-flow/setting.json"
    python3 -c "
import json
from pathlib import Path
p = Path('$setting_json')
c = json.loads(p.read_text())
c['engine_mode'] = 'codex'
p.write_text(json.dumps(c, indent=2, ensure_ascii=False))
"

    (
        cd "$project"
        FAKE_REVIEW_CODEX_MODE=unavailable run_with_fake_coding_review_agents "$temp_root" bash "$executor" demo >"$temp_root/codex-mode.out"
    ) || true

    assert_protocol_field "$temp_root/codex-mode.out" "RESULT" "failed"
    assert_contains "$temp_root/codex-mode.out" "REVIEW_ENGINE_MODE=codex"
    rm -rf "$temp_root"
}

test_regular_passed_with_notes_to_done
test_regular_failed_to_review_failed
test_regular_failed_routes_to_optimize_when_all_blockers_are_optimize
test_regular_failed_routes_to_coding_when_blockers_are_mixed
test_recheck_pass_keeps_done
test_passed_with_notes_ignores_status_guide_text
test_done_commit_prompt_points_to_ai_flow_git_commit
test_standalone_review_without_slug
test_single_state_without_slug_still_binds_and_rechecks
test_explicit_standalone_review_ignores_existing_state_files
test_no_git_changes_rejected
test_review_injects_rule_prompt
test_review_fails_on_protected_path_rule
test_review_fails_on_forbidden_change_rule
test_review_fails_without_test_evidence_when_rule_requires_it
test_review_missing_test_evidence_can_downgrade_to_notes_via_severity_rule
test_review_missing_test_evidence_fail_condition_overrides_minor_severity
test_review_fails_without_required_evidence_text
test_root_cause_gate_and_fallback
test_coding_review_ignores_model_override_but_keeps_reasoning
test_coding_review_defaults_to_high_reasoning_for_single_repo
test_coding_review_escalates_reasoning_on_recheck
test_coding_review_codex_mode_fails_when_codex_unavailable
