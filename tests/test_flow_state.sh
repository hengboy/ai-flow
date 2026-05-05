#!/bin/bash
set -euo pipefail

# shellcheck source=tests/helpers.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.bash"

test_full_transition_chain_and_invariants() {
    local temp_root project status regular_round recheck_round
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_plan_file "$project" "demo" "20260503" "demo"

    (
        cd "$project" || exit 1
        bash "$TEST_ROOT/workflows/flow-state.sh" create --slug demo --title demo --plan-file .ai-flow/plans/20260503/demo.md >/dev/null
        bash "$TEST_ROOT/workflows/flow-state.sh" start-execute demo >/dev/null
        bash "$TEST_ROOT/workflows/flow-state.sh" finish-implementation demo >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review.md" "demo" ".ai-flow/plans/20260503/demo.md" "regular" "1" "failed"
        bash "$TEST_ROOT/workflows/flow-state.sh" record-review --slug demo --mode regular --result failed --report-file .ai-flow/reports/20260503/demo-review.md >/dev/null
        bash "$TEST_ROOT/workflows/flow-state.sh" start-fix demo >/dev/null
        bash "$TEST_ROOT/workflows/flow-state.sh" finish-fix demo >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review-v2.md" "demo" ".ai-flow/plans/20260503/demo.md" "regular" "2" "passed"
        bash "$TEST_ROOT/workflows/flow-state.sh" record-review --slug demo --mode regular --result passed --report-file .ai-flow/reports/20260503/demo-review-v2.md >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review-recheck.md" "demo" ".ai-flow/plans/20260503/demo.md" "recheck" "1" "failed"
        bash "$TEST_ROOT/workflows/flow-state.sh" record-review --slug demo --mode recheck --result failed --report-file .ai-flow/reports/20260503/demo-review-recheck.md >/dev/null
        bash "$TEST_ROOT/workflows/flow-state.sh" start-fix demo >/dev/null
        bash "$TEST_ROOT/workflows/flow-state.sh" finish-fix demo >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review-v3.md" "demo" ".ai-flow/plans/20260503/demo.md" "regular" "3" "passed"
        bash "$TEST_ROOT/workflows/flow-state.sh" record-review --slug demo --mode regular --result passed --report-file .ai-flow/reports/20260503/demo-review-v3.md >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review-recheck-v2.md" "demo" ".ai-flow/plans/20260503/demo.md" "recheck" "2" "passed"
        bash "$TEST_ROOT/workflows/flow-state.sh" record-review --slug demo --mode recheck --result passed --report-file .ai-flow/reports/20260503/demo-review-recheck-v2.md >/dev/null
        bash "$TEST_ROOT/workflows/flow-state.sh" validate demo >/dev/null
    )

    status=$(state_field "$project" "demo" "current_status")
    regular_round=$(state_field "$project" "demo" "review_rounds.regular")
    recheck_round=$(state_field "$project" "demo" "review_rounds.recheck")
    assert_equals "DONE" "$status"
    assert_equals "3" "$regular_round"
    assert_equals "2" "$recheck_round"
    python3 - "$project/.ai-flow/state/demo.json" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
last = state["transitions"][-1]
assert state["updated_at"] == last["at"]
assert state["current_status"] == last["to"]
assert state["active_fix"] is None
PY
    rm -rf "$temp_root"
}

test_invalid_transition_rejected() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state "$project" "demo" "PLANNED" "20260503"

    set +e
    (cd "$project" && bash "$TEST_ROOT/workflows/flow-state.sh" finish-implementation demo) > "$temp_root/invalid.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected invalid transition to fail"
    assert_contains "$temp_root/invalid.out" "只有 IMPLEMENTING 可以 finish-implementation"
    rm -rf "$temp_root"
}

test_active_fix_only_allowed_in_fixing_review() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state "$project" "demo" "REVIEW_FAILED" "20260503"

    python3 - "$project/.ai-flow/state/demo.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
state = json.loads(path.read_text(encoding="utf-8"))
state["active_fix"] = {
    "mode": "regular",
    "round": 1,
    "report_file": ".ai-flow/reports/20260503/demo-review.md",
    "at": state["updated_at"],
}
path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

    set +e
    (cd "$project" && bash "$TEST_ROOT/workflows/flow-state.sh" validate demo) > "$temp_root/validate.out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected invalid active_fix to fail validation"
    assert_contains "$temp_root/validate.out" "只有 FIXING_REVIEW 状态允许 active_fix 非空"
    rm -rf "$temp_root"
}

test_lock_conflict_and_write_failure_do_not_corrupt_json() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state "$project" "demo" "PLANNED" "20260503"
    cp "$project/.ai-flow/state/demo.json" "$temp_root/original.json"

    mkdir "$project/.ai-flow/state/.locks/demo.lock"
    set +e
    (cd "$project" && bash "$TEST_ROOT/workflows/flow-state.sh" start-execute demo) > "$temp_root/lock.out" 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected lock conflict to fail"
    assert_contains "$temp_root/lock.out" "状态锁已存在"
    cmp -s "$temp_root/original.json" "$project/.ai-flow/state/demo.json" || fail "State changed during lock conflict"
    rmdir "$project/.ai-flow/state/.locks/demo.lock"

    chmod 500 "$project/.ai-flow/state"
    set +e
    (cd "$project" && bash "$TEST_ROOT/workflows/flow-state.sh" start-execute demo) > "$temp_root/write.out" 2>&1
    rc=$?
    set -e
    chmod 700 "$project/.ai-flow/state"
    [ "$rc" -ne 0 ] || fail "Expected write failure to fail"
    cmp -s "$temp_root/original.json" "$project/.ai-flow/state/demo.json" || fail "State changed during write failure"
    (cd "$project" && bash "$TEST_ROOT/workflows/flow-state.sh" validate demo) > /dev/null
    rm -rf "$temp_root"
}

test_full_transition_chain_and_invariants
test_invalid_transition_rejected
test_active_fix_only_allowed_in_fixing_review
test_lock_conflict_and_write_failure_do_not_corrupt_json
