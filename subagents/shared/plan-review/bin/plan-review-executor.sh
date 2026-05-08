#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_EXECUTOR="$SCRIPT_DIR/plan-executor.sh"

if [ -z "${1:-}" ]; then
    echo "用法: plan-review-executor.sh {slug或唯一关键词}" >&2
    exit 1
fi

if [ ! -f "$PLAN_EXECUTOR" ]; then
    echo "错误: 缺少 plan 执行器: $PLAN_EXECUTOR" >&2
    exit 1
fi

exec bash "$PLAN_EXECUTOR" --internal-plan-review "$@"
