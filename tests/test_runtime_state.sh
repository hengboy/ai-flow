#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_transitions_and_repair() {
    local temp_root project state_script status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$project" "20260503"
    create_plan_file "$project" "demo" "20260503" "demo"
    setup_git_repo_clean "$project"

    (
        cd "$project"
        bash "$state_script" create --slug demo --title demo --plan-file .ai-flow/plans/20260503-demo.md >/dev/null
        bash "$state_script" record-plan-review --slug demo --result passed --engine Fixture --model fixture >/dev/null
        bash "$state_script" start-execute demo >/dev/null
        bash "$state_script" finish-implementation demo >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503-demo-review.md" "demo" ".ai-flow/plans/20260503-demo.md" "regular" "1" "failed" "demo"
        bash "$state_script" record-review --slug demo --mode regular --result failed --report-file .ai-flow/reports/20260503-demo-review.md >/dev/null
        bash "$state_script" start-fix demo >/dev/null
        bash "$state_script" finish-fix demo >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503-demo-review-v2.md" "demo" ".ai-flow/plans/20260503-demo.md" "regular" "2" "passed_with_notes" "demo"
        bash "$state_script" record-review --slug demo --mode regular --result passed_with_notes --report-file .ai-flow/reports/20260503-demo-review-v2.md >/dev/null
        bash "$state_script" repair --slug demo --status IMPLEMENTING --note "需求变更" >/dev/null
    )

    status=$(state_field "$project" "demo" "current_status")
    assert_equals "IMPLEMENTING" "$status"
    assert_equals "passed_with_notes" "$(state_field "$project" "demo" "last_review.result")"
    assert_equals "repair" "$(state_field "$project" "demo" "transitions.8.event")"
    rm -rf "$temp_root"
}

test_lock_conflict_rejected() {
    local temp_root project state_script rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$project" "20260503"
    create_plan_file "$project" "demo" "20260503" "demo"
    setup_git_repo_clean "$project"

    (
        cd "$project"
        bash "$state_script" create --slug demo --title demo --plan-file .ai-flow/plans/20260503-demo.md >/dev/null
        mkdir -p .ai-flow/state/.locks/demo.lock
        set +e
        bash "$state_script" record-plan-review --slug demo --result passed --engine Fixture --model fixture >"$temp_root/lock.out" 2>&1
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "Expected lock conflict to fail"
    )

    assert_contains "$temp_root/lock.out" "状态锁已存在"
    rm -rf "$temp_root"
}

test_validation_failure_preserves_file() {
    local temp_root project state_script before after rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$project" "20260503"
    create_plan_file "$project" "demo" "20260503" "demo"
    setup_git_repo_clean "$project"

    (
        cd "$project"
        bash "$state_script" create --slug demo --title demo --plan-file .ai-flow/plans/20260503-demo.md >/dev/null
    )

    python3 - "$project/.ai-flow/state/demo.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.pop("plan_file", None)
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
    before=$(cat "$project/.ai-flow/state/demo.json")

    set +e
    (
        cd "$project"
        bash "$state_script" repair --slug demo --status PLANNED >"$temp_root/invalid.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected invalid state repair to fail"
    after=$(cat "$project/.ai-flow/state/demo.json")
    assert_equals "$before" "$after"
    assert_contains "$temp_root/invalid.out" "状态文件缺少字段: plan_file"
    rm -rf "$temp_root"
}

test_normalize_repairs_legacy_review_event() {
    local temp_root project state_script
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    state_script="$SOURCE_FLOW_STATE_SCRIPT"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$state_script" "$project" "demo" "REVIEW_FAILED" "20260503" "demo"

    python3 - "$project/.ai-flow/state/demo.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["last_review"] = None
payload["transitions"][-1]["event"] = "coding_review_failed"
payload["transitions"][-1]["artifacts"].pop("mode", None)
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

    set +e
    (
        cd "$project"
        bash "$state_script" validate demo >"$temp_root/legacy-invalid.out" 2>&1
    )
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected legacy state validation to fail"
    assert_contains "$temp_root/legacy-invalid.out" "非法迁移: event=coding_review_failed"

    (
        cd "$project"
        bash "$state_script" normalize --slug demo --note "repair legacy review event" >/dev/null
        bash "$state_script" validate demo >/dev/null
        bash "$state_script" start-fix demo >/dev/null
    )

    assert_equals "FIXING_REVIEW" "$(state_field "$project" "demo" "current_status")"
    assert_equals "review_failed" "$(state_field "$project" "demo" "transitions.4.event")"
    assert_equals "regular" "$(state_field "$project" "demo" "last_review.mode")"
    assert_equals "failed" "$(state_field "$project" "demo" "last_review.result")"
    assert_equals "repair_metadata" "$(state_field "$project" "demo" "transitions.5.event")"
    assert_equals "fix_started" "$(state_field "$project" "demo" "transitions.6.event")"
    rm -rf "$temp_root"
}

test_transitions_and_repair
test_lock_conflict_rejected
test_validation_failure_preserves_file
test_normalize_repairs_legacy_review_event
