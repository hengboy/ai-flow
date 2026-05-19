#!/bin/bash
# flow-root-helper.sh — 统一 flow root 解析，供所有 runtime 脚本 source。
#
# 用法:
#   source "$AI_FLOW_HOME/lib/flow-root-helper.sh"
#   PROJECT_DIR="$(resolve_flow_root)" || { echo "fallback"; PROJECT_DIR="$(pwd)"; }
#
# 规则:
#   从当前目录向上查找最近的 .ai-flow/state，找到即输出该目录并返回 0。
#   若只存在 .ai-flow 但无 state，输出 cwd 并返回 1。
#   若都不存在，输出 cwd 并返回 1。

resolve_flow_root() {
    local start candidate
    start="$(pwd)"
    candidate="$start"

    while true; do
        if [ -d "$candidate/.ai-flow/state" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        if [ "$candidate" = "/" ] || [ "$candidate" = "//" ]; then
            break
        fi
        local parent
        parent="$(cd "$candidate/.." 2>/dev/null && pwd)" || break
        if [ -z "$parent" ] || [ "$parent" = "$candidate" ]; then
            break
        fi
        candidate="$parent"
    done

    printf '%s' "$start"
    return 1
}
