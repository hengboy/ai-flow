#!/bin/bash
# flow-diagram.sh — 可视化流程图生成脚本

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Resolve flow root using shared helper
if [ ! -f "${AI_FLOW_HOME}/lib/flow-root-helper.sh" ]; then
    echo "错误: 缺少 flow-root-helper.sh: ${AI_FLOW_HOME}/lib/flow-root-helper.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${AI_FLOW_HOME}/lib/flow-root-helper.sh"

FLOW_ROOT="$(resolve_flow_root)" || {
    _start="$(pwd)"
    _candidate="$_start"
    _found=""
    while true; do
        if [ -d "$_candidate/.ai-flow" ]; then
            _found="$_candidate"
            break
        fi
        if [ "$_candidate" = "/" ] || [ "$_candidate" = "//" ]; then
            break
        fi
        _parent="$(cd "$_candidate/.." 2>/dev/null && pwd)" || break
        if [ -z "$_parent" ] || [ "$_parent" = "$_candidate" ]; then
            break
        fi
        _candidate="$_parent"
    done
    if [ -n "$_found" ]; then
        FLOW_ROOT="$_found"
    else
        FLOW_ROOT="$_start"
    fi
}
PROJECT_DIR="$FLOW_ROOT"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
STATE_DIR="$FLOW_DIR/state"

FORMAT="ascii"
SLUG_FILTER=""

for arg in "$@"; do
    case "$arg" in
        --ascii) FORMAT="ascii" ;;
        --svg) FORMAT="svg" ;;
        --slug=*) SLUG_FILTER="${arg#*=}" ;;
        --slug) shift; SLUG_FILTER="${1:-}" ;;
        --help)
            echo "用法: flow-diagram.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --ascii       输出 ASCII 流程图（默认）"
            echo "  --svg         输出 SVG 流程图"
            echo "  --slug=SLUG   只显示指定 slug 的流程图"
            echo "  --help        显示此帮助信息"
            exit 0
            ;;
    esac
done

if [ ! -d "$STATE_DIR" ]; then
    echo "没有找到状态文件"
    exit 0
fi

shopt -s nullglob
state_files=("$STATE_DIR"/*.json)
shopt -u nullglob

if [ ${#state_files[@]} -eq 0 ]; then
    echo "没有找到状态文件"
    exit 0
fi

# Filter by slug if specified
if [ -n "$SLUG_FILTER" ]; then
    filtered=()
    for f in "${state_files[@]}"; do
        basename="$(basename "$f" .json)"
        if [ "$basename" = "$SLUG_FILTER" ]; then
            filtered+=("$f")
        fi
    done
    if [ ${#filtered[@]} -eq 0 ]; then
        echo "未找到 slug 为 $SLUG_FILTER 的状态文件"
        exit 0
    fi
    state_files=("${filtered[@]}")
fi

LIB_DIR="$PROJECT_DIR/subagents/shared/lib"
export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"

for state_file in "${state_files[@]}"; do
    slug="$(basename "$state_file" .json)"

    python3 - "$state_file" "$FORMAT" "$LIB_DIR" <<PY
import json
import sys
sys.path.insert(0, sys.argv[3])

fmt = sys.argv[2]

if fmt == "svg":
    from flow_utils import render_svg_flow as render_flow
else:
    from flow_utils import render_ascii_flow as render_flow
from flow_utils import build_flow_graph, calculate_stage_durations

state_file = sys.argv[1]

with open(state_file, "r", encoding="utf-8") as f:
    state = json.load(f)

slug = state["slug"]
current_status = state["current_status"]
transitions = state.get("transitions", [])

stage_durations_list = calculate_stage_durations(transitions)
stage_dur_map = {}
for sd in stage_durations_list:
    stage_dur_map[sd.stage_name] = sd.duration_ms

nodes, edges = build_flow_graph(transitions, current_status, stage_dur_map)
output = render_flow(nodes, edges)

print(f"=== {slug} [{current_status}] ===")
print(output)
print()
PY
done
