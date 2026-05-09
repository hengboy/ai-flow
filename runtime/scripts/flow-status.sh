#!/bin/bash
# flow-status.sh — 查看当前项目的 AI Flow JSON 状态

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/flow-common.sh"
ai_flow_setup_runtime_logging "${BASH_SOURCE[0]}" existing

# Resolve flow root: prefer workspace manifest, fall back to pwd/.ai-flow
resolve_flow_root() {
    local candidate
    candidate="$(pwd)"
    while true; do
        if [ -f "$candidate/.ai-flow/workspace.json" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        if [ -d "$candidate/.ai-flow" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        local parent
        parent="$(cd "$candidate/.." 2>/dev/null && pwd)" || break
        if [ "$parent" = "$candidate" ]; then
            break
        fi
        candidate="$parent"
    done
    printf '%s' "$(pwd)"
    return 1
}

FLOW_ROOT="$(resolve_flow_root)" || true
PROJECT_DIR="$FLOW_ROOT"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
STATE_DIR="$FLOW_DIR/state"
FLOW_STATE_SH="$SCRIPT_DIR/flow-state.sh"

if [ ! -d "$FLOW_DIR" ]; then
    echo "当前项目没有 .ai-flow/ 目录"
    echo "项目路径: $PROJECT_DIR"
    exit 0
fi

# Detect workspace mode
WORKSPACE_MODE=0
WORKSPACE_NAME=""
WORKSPACE_REPO_COUNT=0
if [ -f "$FLOW_DIR/workspace.json" ]; then
    WORKSPACE_MODE=1
    WORKSPACE_NAME="$(python3 -c "import json; d=json.load(open('$FLOW_DIR/workspace.json')); print(d.get('name',''))")"
    WORKSPACE_REPO_COUNT="$(python3 -c "import json; d=json.load(open('$FLOW_DIR/workspace.json')); print(len(d.get('repos',[])))")"
fi

VALID_LIST="$(mktemp)"
INVALID_LIST="$(mktemp)"
trap 'rm -f "$VALID_LIST" "$INVALID_LIST"' EXIT

if [ -d "$STATE_DIR" ]; then
    shopt -s nullglob
    for path in "$STATE_DIR"/*.json; do
        slug="$(basename "$path" .json)"
        error_file="$(mktemp)"
        if "$FLOW_STATE_SH" validate "$slug" >/dev/null 2>"$error_file"; then
            printf '%s\n' "$path" >>"$VALID_LIST"
        else
            error_text_b64="$(python3 - "$error_file" <<'PY'
import base64
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
print(base64.b64encode(text.encode("utf-8")).decode("ascii"))
PY
)"
            printf '%s\t%s\n' "$path" "$error_text_b64" >>"$INVALID_LIST"
        fi
        rm -f "$error_file"
    done
    shopt -u nullglob
fi

python3 - "$PROJECT_DIR" "$VALID_LIST" "$INVALID_LIST" "$FLOW_STATE_SH" "$WORKSPACE_MODE" "$WORKSPACE_NAME" "$WORKSPACE_REPO_COUNT" "$FLOW_DIR" <<'PY'
import json
import sys
import base64
from collections import Counter
from pathlib import Path

project_dir = Path(sys.argv[1]).resolve()
valid_list = Path(sys.argv[2])
invalid_list = Path(sys.argv[3])
flow_state_sh = Path(sys.argv[4])
workspace_mode = sys.argv[5] == "1"
workspace_name = sys.argv[6]
workspace_repo_count = int(sys.argv[7]) if sys.argv[7].isdigit() else 0
flow_dir = Path(sys.argv[8])
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
if valid_list.exists():
    for line in valid_list.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        states.append(json.loads(Path(line).read_text(encoding="utf-8")))

invalid_states = []
if invalid_list.exists():
    for line in invalid_list.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        path_value, error_b64 = line.split("\t", 1)
        error = base64.b64decode(error_b64.encode("ascii")).decode("utf-8", errors="replace")
        invalid_states.append((Path(path_value), error))

print("===============================")
if workspace_mode:
    print(f"  AI Flow 工作区: {workspace_name}")
    print(f"  范围: workspace ({workspace_repo_count} repos)")
else:
    print(f"  AI Flow 状态: {project_dir.name}")
print("===============================")
print()

print("--- 无效状态文件 ---")
if not invalid_states:
    print("  (无)")
else:
    for path, error in invalid_states:
        slug = path.stem
        print(f"  ⚠ {slug} [{rel(path)}]")
        error_lines = [line.rstrip() for line in error.splitlines() if line.strip()]
        if not error_lines:
            error_lines = ["(空错误输出)"]
        for idx, line in enumerate(error_lines):
            prefix = "    detail: " if idx == 0 else "            "
            print(f"{prefix}{line}")
        print(f"    fix: {flow_state_sh} normalize --slug {slug}")
print()

print("--- 状态文件 ---")
if not states:
    print("  (无)")
else:
    for state in states:
        latest = state["latest_recheck_review_file"] or state["latest_regular_review_file"]
        scope_info = ""
        exec_scope = state.get("execution_scope", {})
        if isinstance(exec_scope, dict):
            mode = exec_scope.get("mode", "")
            if mode == "workspace":
                repos = exec_scope.get("repos", [])
                scope_info = f" [scope:workspace repos:{len(repos)}]"
            elif mode == "single_repo":
                scope_info = " [scope:single_repo]"
        print(
            f"  {state['slug']:<20} [{state['current_status']}]  "
            f"plan: {rel(state['plan_file'])}  latest: {rel(latest)}{scope_info}"
        )
print()

status_labels = [
    ("AWAITING_PLAN_REVIEW", "📝", "待计划审核"),
    ("PLAN_REVIEW_FAILED", "📌", "待修订计划"),
    ("PLANNED", "⏳", "计划已审核通过，待编码"),
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
        if status == "AWAITING_PLAN_REVIEW":
            next_action = "ai-flow-plan-review"
        elif status == "PLAN_REVIEW_FAILED":
            next_action = "ai-flow-plan"
        elif status in {"PLANNED", "IMPLEMENTING", "REVIEW_FAILED", "FIXING_REVIEW"}:
            next_action = "ai-flow-plan-coding"
        else:
            next_action = "ai-flow-plan-coding-review"
        print(f"  {icon} {state['slug']} [{status}] {label}  {detail}  next: {next_action}")
    print()
if states:
    pass

counts = Counter(state["current_status"] for state in states)
print("--- 统计 ---")
print(f"  总数: {len(states) + len(invalid_states)}")
print(f"  INVALID: {len(invalid_states)}")
for status, _, _ in status_labels:
    print(f"  {status}: {counts.get(status, 0)}")
print("===============================")
PY
