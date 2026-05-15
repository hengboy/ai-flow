#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_change_appends_audit_rows() {
    local temp_root project plan_file
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "demo" "PLANNED" "20260503" "demo"
    plan_file="$project/.ai-flow/plans/20260503-demo.md"

    (
        cd "$project"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" demo "[新增] 扩展测试覆盖 — 影响步骤: review-target-step" >/dev/null
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" demo "[root-cause-review-loop] 根因：遗漏缺陷族；受影响缺陷族：测试/证据；前两轮遗漏原因：只看单点；补充验证：bash tests/run.sh" >/dev/null
    )

    assert_contains "$plan_file" "[新增] 扩展测试覆盖"
    assert_contains "$plan_file" "[root-cause-review-loop]"
    assert_not_contains "$plan_file" "{YYYY-MM-DD HH:MM}"
    rm -rf "$temp_root"
}

test_change_fails_when_required_read_missing() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    write_rule_yaml "$project" $'version: 1\nconstraints:\n  required_reads:\n    - "docs/domain-model.md"\nprompt: {}\nreview: {}\n'
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "demo" "PLANNED" "20260503" "demo"

    set +e
    (
        cd "$project"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" demo "[新增] 缺少必读文件" >"$temp_root/missing-read.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected missing required_reads to fail"
    assert_contains "$temp_root/missing-read.out" "required_reads 文件不存在"
    rm -rf "$temp_root"
}

test_change_fails_when_plan_file_is_protected() {
    local temp_root project rc plan_file
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    plan_file="$project/.ai-flow/plans/20260503-demo.md"
    write_rule_yaml "$project" $'version: 1\nprompt: {}\nconstraints:\n  protected_paths:\n    - ".ai-flow/plans/**"\nreview: {}\n'
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "demo" "PLANNED" "20260503" "demo"

    set +e
    (
        cd "$project"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" demo "[新增] 命中计划保护路径" >"$temp_root/protected.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected protected plan path to fail"
    assert_contains "$temp_root/protected.out" "命中 protected_paths"
    assert_not_contains "$plan_file" "命中计划保护路径"
    rm -rf "$temp_root"
}

test_change_appends_audit_rows
test_change_fails_when_required_read_missing
test_change_fails_when_plan_file_is_protected
