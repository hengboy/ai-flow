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
        bash "$AI_FLOW_STATE_SCRIPT" create --slug demo --title demo --plan-file .ai-flow/plans/20260503/demo.md >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug demo --result passed --engine Codex --model gpt-test >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" start-execute demo >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" finish-implementation demo >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review.md" "demo" ".ai-flow/plans/20260503/demo.md" "regular" "1" "failed"
        bash "$AI_FLOW_STATE_SCRIPT" record-review --slug demo --mode regular --result failed --report-file .ai-flow/reports/20260503/demo-review.md >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" start-fix demo >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" finish-fix demo >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review-v2.md" "demo" ".ai-flow/plans/20260503/demo.md" "regular" "2" "passed"
        bash "$AI_FLOW_STATE_SCRIPT" record-review --slug demo --mode regular --result passed --report-file .ai-flow/reports/20260503/demo-review-v2.md >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review-recheck.md" "demo" ".ai-flow/plans/20260503/demo.md" "recheck" "1" "failed"
        bash "$AI_FLOW_STATE_SCRIPT" record-review --slug demo --mode recheck --result failed --report-file .ai-flow/reports/20260503/demo-review-recheck.md >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" start-fix demo >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" finish-fix demo >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review-v3.md" "demo" ".ai-flow/plans/20260503/demo.md" "regular" "3" "passed"
        bash "$AI_FLOW_STATE_SCRIPT" record-review --slug demo --mode regular --result passed --report-file .ai-flow/reports/20260503/demo-review-v3.md >/dev/null

        write_review_report_fixture ".ai-flow/reports/20260503/demo-review-recheck-v2.md" "demo" ".ai-flow/plans/20260503/demo.md" "recheck" "2" "passed"
        bash "$AI_FLOW_STATE_SCRIPT" record-review --slug demo --mode recheck --result passed --report-file .ai-flow/reports/20260503/demo-review-recheck-v2.md >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" validate demo >/dev/null
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
events = [item["event"] for item in state["transitions"]]
assert events[:2] == ["plan_created", "plan_review_passed"], events
last = state["transitions"][-1]
assert state["updated_at"] == last["at"]
assert state["current_status"] == last["to"]
assert state["active_fix"] is None
PY
    rm -rf "$temp_root"
}

test_plan_review_transitions_support_failed_then_passed() {
    local temp_root project status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_plan_file "$project" "demo" "20260503" "demo"

    (
        cd "$project" || exit 1
        bash "$AI_FLOW_STATE_SCRIPT" create --slug demo --title demo --plan-file .ai-flow/plans/20260503/demo.md >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug demo --result failed --engine Codex --model gpt-test >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug demo --result passed --engine Codex --model gpt-test >/dev/null
    )

    status=$(state_field "$project" "demo" "current_status")
    assert_equals "PLANNED" "$status"
    python3 - "$project/.ai-flow/state/demo.json" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
events = [item["event"] for item in state["transitions"]]
assert events == ["plan_created", "plan_review_failed", "plan_review_passed"], events
rounds = [item["artifacts"]["round"] for item in state["transitions"] if item["event"].startswith("plan_review_")]
assert rounds == [1, 2], rounds
PY
    rm -rf "$temp_root"
}

test_plan_review_failed_can_repeat() {
    local temp_root project status
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_plan_file "$project" "demo" "20260503" "demo"

    (
        cd "$project" || exit 1
        bash "$AI_FLOW_STATE_SCRIPT" create --slug demo --title demo --plan-file .ai-flow/plans/20260503/demo.md >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug demo --result failed --engine Codex --model gpt-test >/dev/null
        bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug demo --result failed --engine OpenCode --model glm-test >/dev/null
    )

    status=$(state_field "$project" "demo" "current_status")
    assert_equals "PLAN_REVIEW_FAILED" "$status"
    python3 - "$project/.ai-flow/state/demo.json" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
events = [item["event"] for item in state["transitions"]]
assert events == ["plan_created", "plan_review_failed", "plan_review_failed"], events
engines = [item["artifacts"]["engine"] for item in state["transitions"] if item["event"] == "plan_review_failed"]
assert engines == ["Codex", "OpenCode"], engines
PY
    rm -rf "$temp_root"
}

test_start_execute_rejects_unreviewed_and_failed_plan_states() {
    local temp_root project rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"

    create_state "$project" "awaiting" "AWAITING_PLAN_REVIEW" "20260503"
    set +e
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" start-execute awaiting) > "$temp_root/awaiting.out" 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected start-execute to reject AWAITING_PLAN_REVIEW"
    assert_contains "$temp_root/awaiting.out" "只有 PLANNED 可以 start-execute"

    create_state "$project" "failed" "PLAN_REVIEW_FAILED" "20260503"
    set +e
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" start-execute failed) > "$temp_root/failed.out" 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected start-execute to reject PLAN_REVIEW_FAILED"
    assert_contains "$temp_root/failed.out" "只有 PLANNED 可以 start-execute"
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
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" validate demo) > "$temp_root/validate.out" 2>&1
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
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" start-execute demo) > "$temp_root/lock.out" 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected lock conflict to fail"
    assert_contains "$temp_root/lock.out" "状态锁已存在"
    cmp -s "$temp_root/original.json" "$project/.ai-flow/state/demo.json" || fail "State changed during lock conflict"
    rmdir "$project/.ai-flow/state/.locks/demo.lock"

    chmod 500 "$project/.ai-flow/state"
    set +e
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" start-execute demo) > "$temp_root/write.out" 2>&1
    rc=$?
    set -e
    chmod 700 "$project/.ai-flow/state"
    [ "$rc" -ne 0 ] || fail "Expected write failure to fail"
    cmp -s "$temp_root/original.json" "$project/.ai-flow/state/demo.json" || fail "State changed during write failure"
    (cd "$project" && bash "$AI_FLOW_STATE_SCRIPT" validate demo) > /dev/null
    rm -rf "$temp_root"
}

test_full_transition_chain_and_invariants
test_plan_review_transitions_support_failed_then_passed
test_plan_review_failed_can_repeat
test_start_execute_rejects_unreviewed_and_failed_plan_states
test_active_fix_only_allowed_in_fixing_review
test_lock_conflict_and_write_failure_do_not_corrupt_json
