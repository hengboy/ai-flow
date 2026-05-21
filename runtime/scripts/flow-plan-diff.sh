#!/bin/bash
# flow-plan-diff.sh — 对比两个 plan 版本或版本与当前 plan 的差异

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FLOW_STATE_SH="$SCRIPT_DIR/flow-state.sh"

usage() {
    echo "用法: flow-plan-diff.sh --slug <slug> --from <vN> --to <vN|current> [--stat]" >&2
}

SLUG=""
FROM_VER=""
TO_VER=""
STAT_MODE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --slug)
            [ $# -lt 2 ] && { usage; exit 1; }
            SLUG="$2"; shift 2
            ;;
        --slug=*)
            SLUG="${1#*=}"; shift
            ;;
        --from)
            [ $# -lt 2 ] && { usage; exit 1; }
            FROM_VER="$2"; shift 2
            ;;
        --from=*)
            FROM_VER="${1#*=}"; shift
            ;;
        --to)
            [ $# -lt 2 ] && { usage; exit 1; }
            TO_VER="$2"; shift 2
            ;;
        --to=*)
            TO_VER="${1#*=}"; shift
            ;;
        --stat)
            STAT_MODE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "错误: 未知参数: $1" >&2
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ -z "$SLUG" ] || [ -z "$FROM_VER" ] || [ -z "$TO_VER" ]; then
    echo "错误: --slug、--from、--to 为必填参数" >&2
    usage
    exit 1
fi

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
HISTORY_DIR="$FLOW_DIR/plans/history/$SLUG"

if [ ! -d "$HISTORY_DIR" ]; then
    echo "错误: 版本历史目录不存在: $HISTORY_DIR" >&2
    exit 1
fi

FROM_FILE="$HISTORY_DIR/${FROM_VER}.md"
if [ ! -f "$FROM_FILE" ]; then
    echo "错误: 版本不存在: $FROM_VER" >&2
    exit 1
fi

if [ "$TO_VER" = "current" ]; then
    if [ ! -f "$FLOW_STATE_SH" ]; then
        echo "错误: 缺少 flow-state.sh: $FLOW_STATE_SH" >&2
        exit 1
    fi
    plan_file_rel=$("$FLOW_STATE_SH" show --slug "$SLUG" --field plan_file 2>/dev/null) || {
        echo "错误: 无法读取 state，无法获取当前 plan 路径" >&2
        exit 1
    }
    if [ -z "$plan_file_rel" ]; then
        echo "错误: state 中未记录 plan_file" >&2
        exit 1
    fi
    # plan_file 可能是相对路径，需要基于项目根目录解析
    if [[ "$plan_file_rel" == /* ]]; then
        TO_FILE="$plan_file_rel"
    else
        TO_FILE="$PROJECT_DIR/$plan_file_rel"
    fi
    if [ ! -f "$TO_FILE" ]; then
        echo "错误: 当前 plan 文件不存在: $TO_FILE" >&2
        exit 1
    fi
else
    TO_FILE="$HISTORY_DIR/${TO_VER}.md"
    if [ ! -f "$TO_FILE" ]; then
        echo "错误: 版本不存在: $TO_VER" >&2
        exit 1
    fi
fi

if [ "$STAT_MODE" = true ]; then
    diff --color=auto -u "$FROM_FILE" "$TO_FILE" | diffstat || true
else
    diff --color=auto -u "$FROM_FILE" "$TO_FILE" || true
fi
