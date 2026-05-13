#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_status_only_uses_state_files() {
    local temp_root project out
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "await-plan" "AWAITING_PLAN_REVIEW" "20260503" "await-plan"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "plan-failed" "PLAN_REVIEW_FAILED" "20260503" "plan-failed"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "planned" "PLANNED" "20260503" "planned"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "await-review" "AWAITING_REVIEW" "20260503" "await-review"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "done" "DONE" "20260503" "done"
    printf '# 审查报告：bogus\nREVIEW_FAILED\n' > "$project/.ai-flow/reports/20260503/noise.md"
    printf '# 实施计划：bogus\nDONE\n' > "$project/.ai-flow/plans/20260503-noise.md"

    (
        cd "$project"
        bash "$SOURCE_FLOW_STATUS_SCRIPT" > "$temp_root/status.out"
    )
    out="$temp_root/status.out"
    assert_contains "$out" "await-plan [AWAITING_PLAN_REVIEW]"
    assert_contains "$out" "next: ai-flow-plan-review"
    assert_contains "$out" "plan-failed [PLAN_REVIEW_FAILED]"
    assert_contains "$out" "next: ai-flow-plan"
    assert_contains "$out" "planned [PLANNED]"
    assert_contains "$out" "next: ai-flow-plan-coding"
    assert_contains "$out" "await-review [AWAITING_REVIEW]"
    assert_contains "$out" "next: ai-flow-plan-coding-review"
    assert_contains "$out" "done [DONE]"
    assert_contains "$out" "AWAITING_PLAN_REVIEW: 1"
    assert_contains "$out" "DONE: 1"
    rm -rf "$temp_root"
}

test_status_surfaces_invalid_state_files() {
    local temp_root project out
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "valid" "PLANNED" "20260503" "valid"
    create_state_with_status "$SOURCE_FLOW_STATE_SCRIPT" "$project" "broken" "REVIEW_FAILED" "20260503" "broken"

    python3 - "$project/.ai-flow/state/broken.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["last_review"] = None
payload["transitions"][-1]["event"] = "coding_review_failed"
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

    (
        cd "$project"
        bash "$SOURCE_FLOW_STATUS_SCRIPT" > "$temp_root/status-invalid.out"
    )
    out="$temp_root/status-invalid.out"
    assert_contains "$out" "--- 无效状态文件 ---"
    assert_contains "$out" "broken"
    assert_contains "$out" "coding_review_failed"
    assert_contains "$out" "normalize --slug broken"
    assert_contains "$out" "valid [PLANNED]"
    assert_contains "$out" "next: ai-flow-plan-coding"
    assert_contains "$out" "INVALID: 1"
    rm -rf "$temp_root"
}

test_status_only_uses_state_files
test_status_surfaces_invalid_state_files
