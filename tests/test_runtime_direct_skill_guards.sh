#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_bug_fix_runtime_reuses_plan_coding_gate() {
    local temp_root project state_script runtime_script
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-bug-fix.sh")"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$state_script" "$project" "demo" "PLANNED" "20260503" "demo"

    (
        cd "$project"
        bash "$runtime_script" demo >"$temp_root/bug-fix.out"
    )

    assert_protocol_field "$temp_root/bug-fix.out" "AGENT" "ai-flow-plan-coding"
    assert_protocol_field "$temp_root/bug-fix.out" "STATE" "IMPLEMENTING"
    rm -rf "$temp_root"
}

test_code_refactor_runtime_reuses_plan_coding_gate() {
    local temp_root project state_script runtime_script
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-code-refactor.sh")"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$state_script" "$project" "demo" "REVIEW_FAILED" "20260503" "demo"

    (
        cd "$project"
        bash "$runtime_script" demo >"$temp_root/refactor.out"
    )

    assert_protocol_field "$temp_root/refactor.out" "AGENT" "ai-flow-plan-coding"
    assert_protocol_field "$temp_root/refactor.out" "STATE" "FIXING_REVIEW"
    rm -rf "$temp_root"
}

test_code_optimize_runtime_allows_awaiting_review_without_transition() {
    local temp_root project state_script runtime_script
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-code-optimize.sh")"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$state_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"

    (
        cd "$project"
        bash "$runtime_script" demo >"$temp_root/opt-awaiting-review.out"
    )

    assert_protocol_field "$temp_root/opt-awaiting-review.out" "RESULT" "success"
    assert_protocol_field "$temp_root/opt-awaiting-review.out" "SCOPE" "bound"
    assert_protocol_field "$temp_root/opt-awaiting-review.out" "STATE" "AWAITING_REVIEW"
    rm -rf "$temp_root"
}

test_code_optimize_runtime_starts_fix_when_all_blocking_routes_are_optimize() {
    local temp_root project state_script runtime_script
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-code-optimize.sh")"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$state_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    write_review_report_fixture "$project/.ai-flow/reports/20260503-demo-review.md" "demo" ".ai-flow/plans/20260503-demo.md" "regular" "1" "failed" "demo"
    python3 - "$project/.ai-flow/reports/20260503-demo-review.md" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
text = path.read_text(encoding='utf-8').replace('ai-flow-plan-coding', 'ai-flow-code-optimize')
path.write_text(text, encoding='utf-8')
PY
    (
        cd "$project"
        bash "$state_script" record-review --slug demo --mode regular --result failed --report-file ".ai-flow/reports/20260503-demo-review.md" >/dev/null
        bash "$runtime_script" demo >"$temp_root/opt-fix.out"
    )

    assert_protocol_field "$temp_root/opt-fix.out" "RESULT" "success"
    assert_protocol_field "$temp_root/opt-fix.out" "STATE" "FIXING_REVIEW"
    assert_equals "FIXING_REVIEW" "$(state_field "$project" "demo" "current_status")"
    rm -rf "$temp_root"
}

test_code_optimize_runtime_rejects_mixed_blocking_routes() {
    local temp_root project state_script runtime_script rc
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-code-optimize.sh")"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$state_script" "$project" "demo" "REVIEW_FAILED" "20260503" "demo"
    python3 - "$project/.ai-flow/reports/20260503-demo-review.md" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
text = path.read_text(encoding='utf-8')
text = text.replace(
    '| DEF-1 | Important | src/review-target.txt | problem | impact | fix | ai-flow-plan-coding | [待修复] |',
    '| DEF-1 | Important | src/review-target.txt | problem | impact | fix | ai-flow-plan-coding | [待修复] |\n| DEF-2 | Important | src/other.txt | problem2 | impact2 | fix2 | ai-flow-code-optimize | [待修复] |'
)
path.write_text(text, encoding='utf-8')
PY

    set +e
    (
        cd "$project"
        bash "$runtime_script" demo >"$temp_root/opt-mixed.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected mixed blocking routes to fail"
    assert_contains "$temp_root/opt-mixed.out" "不能直接进入代码优化"
    assert_equals "REVIEW_FAILED" "$(state_field "$project" "demo" "current_status")"
    rm -rf "$temp_root"
}

test_code_optimize_runtime_rejects_planned_status() {
    local temp_root project state_script runtime_script rc
    temp_root=$(make_temp_root)
    install_ai_flow "$temp_root"
    project="$temp_root/project"
    state_script="$(installed_runtime_script "$temp_root" "flow-state.sh")"
    runtime_script="$(installed_runtime_script "$temp_root" "flow-code-optimize.sh")"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$state_script" "$project" "demo" "PLANNED" "20260503" "demo"

    set +e
    (
        cd "$project"
        bash "$runtime_script" demo >"$temp_root/opt-planned.out"
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected planned optimize to fail"
    assert_contains "$temp_root/opt-planned.out" "不允许进入绑定优化"
    rm -rf "$temp_root"
}

test_bug_fix_runtime_reuses_plan_coding_gate
test_code_refactor_runtime_reuses_plan_coding_gate
test_code_optimize_runtime_allows_awaiting_review_without_transition
test_code_optimize_runtime_starts_fix_when_all_blocking_routes_are_optimize
test_code_optimize_runtime_rejects_mixed_blocking_routes
test_code_optimize_runtime_rejects_planned_status
