#!/bin/bash
# flow-code-refactor.sh — code-refactor 绑定 slug 时复用 plan-coding runtime 门禁
# 用法: flow-code-refactor.sh {slug或唯一关键词}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/flow-plan-coding.sh"

if [ ! -f "$TARGET" ]; then
    echo "错误: 缺少 flow-plan-coding 脚本: $TARGET" >&2
    exit 1
fi

exec bash "$TARGET" "$@"
