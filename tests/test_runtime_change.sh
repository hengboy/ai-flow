#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_change_appends_audit_rows() {
    local temp_root project plan_file
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "demo" "PLANNED" "20260503" "demo"
    plan_file="$project/.ai-flow/plans/20260503/demo.md"

    (
        cd "$project"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" demo "[新增] 扩展测试覆盖 — 影响步骤: Step 1" >/dev/null
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" demo "[root-cause-review-loop] 根因：遗漏缺陷族；受影响缺陷族：测试/证据；前两轮遗漏原因：只看单点；补充验证：bash tests/run.sh" >/dev/null
    )

    assert_contains "$plan_file" "\\[新增\\] 扩展测试覆盖"
    assert_contains "$plan_file" "\\[root-cause-review-loop\\]"
    assert_not_contains "$plan_file" "{YYYY-MM-DD HH:MM}"
    rm -rf "$temp_root"
}

test_change_failure_reports_log_path() {
    local temp_root project log_path
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_root "$project"

    set +e
    (
        cd "$project"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" missing "desc" >"$temp_root/change-fail.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected flow-change failure to exit non-zero"
    assert_contains "$temp_root/change-fail.out" "错误: 找不到包含关键词 'missing' 的状态文件"
    assert_contains "$temp_root/change-fail.out" "完整日志: .ai-flow/logs/"
    log_path="$(log_path_from_output "$temp_root/change-fail.out")"
    assert_file_exists "$project/$log_path"
    assert_contains "$project/$log_path" "错误: 找不到包含关键词 'missing' 的状态文件"
    rm -rf "$temp_root"
}

test_change_appends_audit_rows
test_change_failure_reports_log_path
