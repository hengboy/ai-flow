#!/bin/bash
# flow-plan-orchestrate.sh — 已有普通 plan 队列编排辅助入口

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE_SH="$SCRIPT_DIR/flow-plan-orchestrate-state.sh"

usage() {
    cat >&2 <<'EOF'
用法:
  flow-plan-orchestrate.sh --queue <queue_slug> <plan_slug_1> <plan_slug_2> ...
  flow-plan-orchestrate.sh --resume <queue_slug>
  flow-plan-orchestrate.sh --status <queue_slug>

内部状态推进:
  flow-plan-orchestrate.sh --start-current <queue_slug>
  flow-plan-orchestrate.sh --mark-reviewed <queue_slug>
  flow-plan-orchestrate.sh --record-heads <queue_slug> --heads-json <json>
  flow-plan-orchestrate.sh --mark-committed <queue_slug> [--commits-json <json>]
  flow-plan-orchestrate.sh --fail <queue_slug> --reason <text>
  flow-plan-orchestrate.sh --reopen-current <queue_slug> [--reason <text>]
EOF
    exit 1
}

fail() {
    echo "$1" >&2
    exit 1
}

if [ ! -f "${AI_FLOW_HOME}/lib/flow-root-helper.sh" ]; then
    fail "错误: 缺少 flow-root-helper.sh: ${AI_FLOW_HOME}/lib/flow-root-helper.sh"
fi
# shellcheck source=/dev/null
source "${AI_FLOW_HOME}/lib/flow-root-helper.sh"

PROJECT_DIR="$(resolve_flow_root)" || fail "当前目录不在包含 .ai-flow/state 的 flow root 内。"
mkdir -p "$PROJECT_DIR/.ai-flow/orchestrations/state"
[ -x "$STATE_SH" ] || fail "错误: 缺少 flow-plan-orchestrate-state.sh: $STATE_SH"

print_queue_summary() {
    local queue_slug="$1"
    local state_json
    state_json="$(bash "$STATE_SH" show --queue-slug "$queue_slug")"
    STATE_JSON="$state_json" python3 - <<'PY'
import json
import os
import sys

state = json.loads(os.environ["STATE_JSON"])
items = state.get("items", [])
active_index = state.get("active_index", 0)
print(f"queue_slug={state.get('queue_slug')}")
print(f"current_status={state.get('current_status')}")
print(f"active_index={active_index}")
if active_index < len(items):
    print(f"active_slug={items[active_index].get('slug')}")
else:
    print("active_slug=none")
for item in items:
    print(f"item[{item.get('index')}]={item.get('slug')}\t{item.get('status')}")
PY
}

cmd_queue() {
    local queue_slug="$1"
    shift
    [ -n "$queue_slug" ] || usage
    [ "$#" -gt 0 ] || fail "--queue 至少需要一个 plan slug"
    (
        cd "$PROJECT_DIR"
        bash "$STATE_SH" create --queue-slug "$queue_slug" "$@"
        print_queue_summary "$queue_slug"
    )
}

cmd_resume() {
    local queue_slug="$1"
    [ -n "$queue_slug" ] || usage
    (
        cd "$PROJECT_DIR"
        bash "$STATE_SH" validate --queue-slug "$queue_slug" >/dev/null
        print_queue_summary "$queue_slug"
    )
}

cmd_status() {
    local queue_slug="$1"
    [ -n "$queue_slug" ] || usage
    (
        cd "$PROJECT_DIR"
        print_queue_summary "$queue_slug"
    )
}

cmd_record_heads() {
    local queue_slug="$1"
    shift
    local heads_json=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --heads-json) heads_json="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$queue_slug" ] || usage
    [ -n "$heads_json" ] || fail "--heads-json 不能为空"
    (cd "$PROJECT_DIR" && bash "$STATE_SH" record-heads --queue-slug "$queue_slug" --heads-json "$heads_json")
}

cmd_mark_committed() {
    local queue_slug="$1"
    shift
    local commits_json="[]"
    while [ $# -gt 0 ]; do
        case "$1" in
            --commits-json) commits_json="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$queue_slug" ] || usage
    (cd "$PROJECT_DIR" && bash "$STATE_SH" mark-committed --queue-slug "$queue_slug" --commits-json "$commits_json")
}

cmd_fail_queue() {
    local queue_slug="$1"
    shift
    local reason=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --reason) reason="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$queue_slug" ] || usage
    [ -n "$reason" ] || reason="orchestration failed"
    (cd "$PROJECT_DIR" && bash "$STATE_SH" fail --queue-slug "$queue_slug" --reason "$reason")
}

cmd_reopen_current() {
    local queue_slug="$1"
    shift
    local reason=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --reason) reason="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$queue_slug" ] || usage
    if [ -n "$reason" ]; then
        (cd "$PROJECT_DIR" && bash "$STATE_SH" reopen-current --queue-slug "$queue_slug" --reason "$reason")
    else
        (cd "$PROJECT_DIR" && bash "$STATE_SH" reopen-current --queue-slug "$queue_slug")
    fi
}

case "${1:-}" in
    --queue)
        shift
        [ $# -ge 2 ] || usage
        queue_slug="$1"
        shift
        cmd_queue "$queue_slug" "$@"
        ;;
    --resume)
        [ $# -eq 2 ] || usage
        cmd_resume "$2"
        ;;
    --status)
        [ $# -eq 2 ] || usage
        cmd_status "$2"
        ;;
    --start-current)
        [ $# -eq 2 ] || usage
        (cd "$PROJECT_DIR" && bash "$STATE_SH" start-current --queue-slug "$2")
        ;;
    --mark-reviewed)
        [ $# -eq 2 ] || usage
        (cd "$PROJECT_DIR" && bash "$STATE_SH" mark-reviewed --queue-slug "$2")
        ;;
    --record-heads)
        shift
        [ $# -ge 1 ] || usage
        queue_slug="$1"
        shift
        cmd_record_heads "$queue_slug" "$@"
        ;;
    --mark-committed)
        shift
        [ $# -ge 1 ] || usage
        queue_slug="$1"
        shift
        cmd_mark_committed "$queue_slug" "$@"
        ;;
    --fail)
        shift
        [ $# -ge 1 ] || usage
        queue_slug="$1"
        shift
        cmd_fail_queue "$queue_slug" "$@"
        ;;
    --reopen-current)
        shift
        [ $# -ge 1 ] || usage
        queue_slug="$1"
        shift
        cmd_reopen_current "$queue_slug" "$@"
        ;;
    *)
        usage
        ;;
esac
