#!/bin/bash
# flow-plan-history.sh — 列出指定 slug 的 plan 版本历史

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
    echo "用法: flow-plan-history.sh --slug <slug> [--json]" >&2
}

SLUG=""
JSON_MODE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --slug)
            if [ $# -lt 2 ]; then
                usage
                exit 1
            fi
            SLUG="$2"
            shift 2
            ;;
        --slug=*)
            SLUG="${1#*=}"
            shift
            ;;
        --json)
            JSON_MODE=true
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

if [ -z "$SLUG" ]; then
    echo "错误: --slug 为必填参数" >&2
    usage
    exit 1
fi

# 从项目根或环境变量定位 .ai-flow 目录
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
HISTORY_DIR="$FLOW_DIR/plans/history/$SLUG"

if [ ! -d "$HISTORY_DIR" ]; then
    if [ "$JSON_MODE" = true ]; then
        echo '[]'
    else
        echo "无版本历史"
    fi
    exit 0
fi

MANIFEST="$HISTORY_DIR/manifest.json"
if [ ! -f "$MANIFEST" ]; then
    if [ "$JSON_MODE" = true ]; then
        echo '[]'
    else
        echo "无版本历史"
    fi
    exit 0
fi

if [ "$JSON_MODE" = true ]; then
    cat "$MANIFEST"
    exit 0
fi

python3 - "$MANIFEST" "$HISTORY_DIR" <<'PY'
import json
import os
import sys

manifest_path = sys.argv[1]
history_dir = sys.argv[2]

try:
    data = json.load(open(manifest_path))
except (json.JSONDecodeError, FileNotFoundError):
    print("无版本历史")
    sys.exit(0)

if not data:
    print("无版本历史")
    sys.exit(0)

print(f"版本历史 ({len(data)} 个版本)")
print()
print(f"{'版本号':<10} {'时间戳':<28} {'大小(字节)':<12} {'文件'}")
print("-" * 70)

for entry in data:
    version = entry.get("version", "?")
    timestamp = entry.get("timestamp", "?")
    snapshot = entry.get("plan_file_snapshot", "")
    file_path = os.path.join(history_dir, snapshot)
    size = os.path.getsize(file_path) if os.path.exists(file_path) else 0
    print(f"{version:<10} {timestamp:<28} {size:<12} {snapshot}")
PY
