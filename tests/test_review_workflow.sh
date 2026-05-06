#!/bin/bash
set -euo pipefail

# shellcheck source=tests/helpers.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.bash"

test_invalid_state_rejected() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "PLANNED" "20260503"
    setup_git_repo_with_change "$project"

    set +e
    (cd "$project" && HOME="$temp_root/home" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected review to reject PLANNED state"
    assert_contains "$temp_root/review.out" "不能执行审查"
    rm -rf "$temp_root"
}

test_regular_pass_updates_state_to_done() {
    local temp_root project status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "passed"
    setup_git_repo_with_change "$project"

    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo gpt-test high) > "$temp_root/review.out" 2>&1

    status=$(state_field "$project" "demo" "current_status")
    assert_equals "DONE" "$status"
    assert_file_exists "$project/.ai-flow/reports/20260503/demo-review.md"
    assert_contains "$temp_root/review.out" "状态已验证为 \\[DONE\\]"
    rm -rf "$temp_root"
}

test_regular_passed_with_notes_updates_state_to_done() {
    local temp_root project status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "passed_with_notes" "passed_with_notes_valid"
    setup_git_repo_with_change "$project"

    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1

    status=$(state_field "$project" "demo" "current_status")
    assert_equals "DONE" "$status"
    assert_file_exists "$project/.ai-flow/reports/20260503/demo-review.md"
    assert_contains "$temp_root/review.out" "常规审查通过（存在 Minor 建议）"
    rm -rf "$temp_root"
}

test_regular_failed_updates_state_to_review_failed() {
    local temp_root project status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "failed" "failed_valid"
    setup_git_repo_with_change "$project"

    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1

    status=$(state_field "$project" "demo" "current_status")
    assert_equals "REVIEW_FAILED" "$status"
    assert_file_exists "$project/.ai-flow/reports/20260503/demo-review.md"
    assert_contains "$temp_root/review.out" "状态已更新为 \\[REVIEW_FAILED\\]"
    rm -rf "$temp_root"
}

test_recheck_pass_keeps_done() {
    local temp_root project status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "DONE" "20260503"
    write_fake_codex_review "$temp_root" "passed"
    setup_git_repo_with_change "$project"

    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1

    status=$(state_field "$project" "demo" "current_status")
    assert_equals "DONE" "$status"
    assert_file_exists "$project/.ai-flow/reports/20260503/demo-review-recheck.md"
    assert_contains "$temp_root/review.out" "再审查通过，状态保持 \\[DONE\\]"
    rm -rf "$temp_root"
}

test_recheck_failed_updates_state_to_review_failed() {
    local temp_root project status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "DONE" "20260503"
    write_fake_codex_review "$temp_root" "failed" "failed_valid"
    setup_git_repo_with_change "$project"

    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1

    status=$(state_field "$project" "demo" "current_status")
    assert_equals "REVIEW_FAILED" "$status"
    assert_file_exists "$project/.ai-flow/reports/20260503/demo-review-recheck.md"
    rm -rf "$temp_root"
}

test_regular_review_after_failed_recheck_uses_recheck_report() {
    local temp_root project status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "DONE" "20260503"
    setup_git_repo_with_change "$project"

    write_fake_codex_review "$temp_root" "failed" "failed_valid"
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/recheck.out" 2>&1
    status=$(state_field "$project" "demo" "current_status")
    assert_equals "REVIEW_FAILED" "$status"

    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" start-fix demo >/dev/null)
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" finish-fix demo >/dev/null)
    status=$(state_field "$project" "demo" "current_status")
    assert_equals "AWAITING_REVIEW" "$status"

    write_fake_codex_review "$temp_root" "passed"
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1

    assert_contains "$temp_root/review.out" "上一轮报告: .*demo-review-recheck.md"
    assert_file_exists "$project/.ai-flow/reports/20260503/demo-review-v2.md"
    rm -rf "$temp_root"
}

test_review_prompt_includes_previous_defect_and_tracking_sections() {
    local temp_root project status previous_report
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "REVIEW_FAILED" "20260503"
    setup_git_repo_with_change "$project"

    previous_report="$project/.ai-flow/reports/20260503/demo-review.md"
    cat > "$previous_report" <<'REPORT'
# 审查报告：demo

> 审查日期：2026-05-03
> 需求简称：demo
> 审查模式：regular
> 审查轮次：1
> 审查结果：failed
> 对比计划：`.ai-flow/plans/20260503/demo.md`
> 审查工具：Codex (test xhigh)

## 1. 总体评价

PREV_OVERALL_ONLY

## 4. 缺陷清单

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|
| DEF-9 | Important | src/a | PREV_DEFECT_ONLY | impact | fix | [待修复] |

## 6. 缺陷修复追踪

| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-9 | v1 | [待修复] | PREV_TRACKING_ONLY | 未验证 |
REPORT

    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" start-fix demo >/dev/null)
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" finish-fix demo >/dev/null)
    status=$(state_field "$project" "demo" "current_status")
    assert_equals "AWAITING_REVIEW" "$status"

    write_fake_codex_review "$temp_root" "passed"
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1

    assert_contains "$temp_root/captured-prompt.txt" "PREV_DEFECT_ONLY"
    assert_contains "$temp_root/captured-prompt.txt" "PREV_TRACKING_ONLY"
    assert_not_contains "$temp_root/captured-prompt.txt" "PREV_OVERALL_ONLY"
    rm -rf "$temp_root"
}

test_report_validation_rejects_placeholders() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "passed" "placeholder"
    setup_git_repo_with_change "$project"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected placeholder report validation to fail"
    assert_contains "$temp_root/review.out" "未替换的模板占位符"
    rm -rf "$temp_root"
}

test_report_validation_rejects_passed_with_pending_defects() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "passed" "passed_with_pending"
    setup_git_repo_with_change "$project"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected passed report with optional Minor notes to fail"
    assert_contains "$temp_root/review.out" "仍包含 \\[可选\\] 的 Minor 建议"
    rm -rf "$temp_root"
}

test_report_validation_rejects_passed_with_notes_with_pending_minor() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "passed_with_notes" "passed_with_notes_pending"
    setup_git_repo_with_change "$project"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected passed_with_notes report with pending Minor to fail"
    assert_contains "$temp_root/review.out" "Minor 建议，未处理时必须标记为 \\[可选\\]"
    rm -rf "$temp_root"
}

test_report_validation_rejects_optional_marker_on_defect() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "failed" "optional_on_defect"
    setup_git_repo_with_change "$project"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected DEF optional marker to fail"
    assert_contains "$temp_root/review.out" "阻塞缺陷，不能标记为 \\[可选\\]"
    rm -rf "$temp_root"
}

test_report_validation_rejects_missing_targeted_verification_evidence() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "passed" "missing_validation_evidence"
    setup_git_repo_with_change "$project"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing 1.2 targeted verification evidence to fail"
    assert_contains "$temp_root/review.out" "必须在 1.2 提供定向验证执行证据"
    rm -rf "$temp_root"
}

test_report_validation_rejects_missing_previous_family_coverage() {
    local temp_root project rc previous_report
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "REVIEW_FAILED" "20260503"
    setup_git_repo_with_change "$project"

    previous_report="$project/.ai-flow/reports/20260503/demo-review.md"
    cat > "$previous_report" <<'REPORT'
# 审查报告：demo

> 审查日期：2026-05-03
> 需求简称：demo
> 审查模式：regular
> 审查轮次：1
> 审查结果：failed
> 对比计划：`.ai-flow/plans/20260503/demo.md`
> 审查工具：Codex (test xhigh)

## 1. 总体评价

需要修复

### 1.1 审查上下文
ok

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| `bash tests/test_review_workflow.sh` | FAIL | 失败夹具 |

## 2. 计划覆盖度检查
ok

## 2.1 计划外变更识别
none

## 3. 代码质量审查
### 3.5 逻辑正确性
ok

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| SQL/映射 | 未覆盖 | 上一轮发现 SQL 条件缺失 |

## 4. 缺陷清单

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|
| DEF-9 | Important | src/a | SQL 条件缺失 | impact | fix | [待修复] |

## 5. 审查结论

- [ ] **通过** — 所有步骤已实现，无严重缺陷
- [x] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪

| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-9 | v1 | [待修复] | PREV_TRACKING_ONLY | 未验证 |
REPORT

    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" start-fix demo >/dev/null)
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" finish-fix demo >/dev/null)
    write_fake_codex_review "$temp_root" "passed" "missing_previous_family_coverage"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing previous family coverage to fail"
    assert_contains "$temp_root/review.out" "缺少上一轮严重缺陷对应的缺陷族覆盖状态"
    rm -rf "$temp_root"
}

test_regular_round_three_requires_root_cause_review_loop_record() {
    local temp_root project rc status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "REVIEW_FAILED" "20260503"
    setup_git_repo_with_change "$project"

    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" start-fix demo >/dev/null)
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" finish-fix demo >/dev/null)
    write_fake_codex_review "$temp_root" "failed" "failed_valid"
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review-round2.out" 2>&1
    status=$(state_field "$project" "demo" "current_status")
    assert_equals "REVIEW_FAILED" "$status"

    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" start-fix demo >/dev/null)
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" finish-fix demo >/dev/null)

    set +e
    (cd "$project" && HOME="$temp_root/home" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected regular round 3 without root-cause-review-loop to fail"
    assert_contains "$temp_root/review.out" "\\[root-cause-review-loop\\]"
    assert_file_not_exists "$project/.ai-flow/reports/20260503/demo-review-v3.md"
    rm -rf "$temp_root"
}

test_review_rejects_no_git_changes_before_state_update() {
    local temp_root project rc status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    setup_home_with_templates "$temp_root"
    create_state "$project" "demo" "AWAITING_REVIEW" "20260503"
    write_fake_codex_review "$temp_root" "passed"
    setup_git_repo_clean "$project"

    set +e
    (cd "$project" && run_with_fake_codex "$temp_root" bash "$(installed_skill_script "$temp_root" "ai-flow-review" "codex-review.sh")" demo) > "$temp_root/review.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected review without git changes to fail"
    assert_contains "$temp_root/review.out" "没有可审查的 Git 变更"
    status=$(state_field "$project" "demo" "current_status")
    assert_equals "AWAITING_REVIEW" "$status"
    assert_file_not_exists "$project/.ai-flow/reports/20260503/demo-review.md"
    rm -rf "$temp_root"
}

test_invalid_state_rejected
test_regular_pass_updates_state_to_done
test_regular_passed_with_notes_updates_state_to_done
test_regular_failed_updates_state_to_review_failed
test_recheck_pass_keeps_done
test_recheck_failed_updates_state_to_review_failed
test_regular_review_after_failed_recheck_uses_recheck_report
test_review_prompt_includes_previous_defect_and_tracking_sections
test_report_validation_rejects_placeholders
test_report_validation_rejects_passed_with_pending_defects
test_report_validation_rejects_passed_with_notes_with_pending_minor
test_report_validation_rejects_optional_marker_on_defect
test_report_validation_rejects_missing_targeted_verification_evidence
test_report_validation_rejects_missing_previous_family_coverage
test_regular_round_three_requires_root_cause_review_loop_record
test_review_rejects_no_git_changes_before_state_update
