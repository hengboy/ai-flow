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
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" demo "[新增] 扩展测试覆盖 — 影响步骤: Step 1" >/dev/null
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" demo "[root-cause-review-loop] 根因：遗漏缺陷族；受影响缺陷族：测试/证据；前两轮遗漏原因：只看单点；补充验证：bash tests/run.sh" >/dev/null
    )

    assert_contains "$plan_file" "[新增] 扩展测试覆盖"
    assert_contains "$plan_file" "[root-cause-review-loop]"
    assert_not_contains "$plan_file" "{YYYY-MM-DD HH:MM}"
    rm -rf "$temp_root"
}

test_change_appends_audit_rows
