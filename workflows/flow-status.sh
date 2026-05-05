#!/bin/bash
# flow-status.sh — 查看当前项目的 AI Flow JSON 状态

set -euo pipefail

PROJECT_DIR="$(pwd)"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
STATE_DIR="$FLOW_DIR/state"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_STATE_SH="$SCRIPT_DIR/flow-state.sh"

if [ ! -d "$FLOW_DIR" ]; then
    echo "当前项目没有 .ai-flow/ 目录"
    echo "项目路径: $PROJECT_DIR"
    exit 0
fi

if [ -d "$STATE_DIR" ]; then
    "$FLOW_STATE_SH" validate --all >/dev/null
fi

python3 - "$PROJECT_DIR" <<'PY'
import json
import sys
from collections import Counter
from pathlib import Path

project_dir = Path(sys.argv[1]).resolve()
flow_dir = project_dir / ".ai-flow"
state_dir = flow_dir / "state"

def rel(path_value):
    if not path_value:
        return "-"
    path = Path(path_value)
    if path.is_absolute():
        try:
            return path.resolve().relative_to(project_dir).as_posix()
        except ValueError:
            return path.resolve().as_posix()
    return path.as_posix()

states = []
if state_dir.exists():
    for path in sorted(state_dir.glob("*.json")):
        states.append(json.loads(path.read_text(encoding="utf-8")))

print("===============================")
print(f"  AI Flow 状态: {project_dir.name}")
print("===============================")
print()

print("--- 状态文件 ---")
if not states:
    print("  (无)")
else:
    for state in states:
        latest = state["latest_recheck_review_file"] or state["latest_regular_review_file"]
        print(
            f"  {state['slug']:<20} [{state['current_status']}]  "
            f"plan: {rel(state['plan_file'])}  latest: {rel(latest)}"
        )
print()

status_labels = [
    ("PLANNED", "⏳", "待编码"),
    ("IMPLEMENTING", "🔨", "开发中"),
    ("AWAITING_REVIEW", "🔍", "待审查"),
    ("REVIEW_FAILED", "🔧", "待修复"),
    ("FIXING_REVIEW", "🩹", "修复中"),
    ("DONE", "✅", "可再审查"),
]

print("--- 待处理 ---")
for status, icon, label in status_labels:
    print(f"{status}:")
    matched = [state for state in states if state["current_status"] == status]
    if not matched:
        print("  (无)")
        continue
    for state in matched:
        latest = state["latest_recheck_review_file"] or state["latest_regular_review_file"]
        detail = f"report: {rel(latest)}" if latest else "report: -"
        print(f"  {icon} {state['slug']} [{status}] {label}  {detail}")
    print()
if states:
    pass

counts = Counter(state["current_status"] for state in states)
print("--- 统计 ---")
print(f"  总数: {len(states)}")
for status, _, _ in status_labels:
    print(f"  {status}: {counts.get(status, 0)}")
print("===============================")
PY
