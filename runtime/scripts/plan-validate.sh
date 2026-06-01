#!/bin/bash
# plan-validate.sh — Plan 验证门禁入口
# 验证文件名格式和模板内容匹配，支持自动修复。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_UTILS="$SCRIPT_DIR/../../subagents/shared/lib/flow_utils.py"

usage() {
    cat << 'USAGE'
用法:
  plan-validate.sh validate-filename <filename>
      验证 plan 文件名是否符合 YYYYMMDD-slug.md 格式

  plan-validate.sh validate-template <plan-file> [--auto-fix]
      验证 plan 文件内容是否与模板匹配；传 --auto-fix 时自动修复结构问题

  plan-validate.sh auto-fix <plan-file>
      仅执行自动修复，不输出验证结果

退出码:
  0  验证通过 / 无需修复
  1  验证失败 / 存在不可修复错误
  2  存在可修复的结构问题（未传 --auto-fix 时）
USAGE
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

case "$1" in
    validate-filename)
        if [ $# -lt 2 ]; then
            echo "ERROR: validate-filename 需要 filename 参数" >&2
            exit 1
        fi
        python3 "$FLOW_UTILS" validate-plan-filename "$2"
        ;;
    validate-template)
        if [ $# -lt 2 ]; then
            echo "ERROR: validate-template 需要 plan-file 参数" >&2
            exit 1
        fi
        shift
        python3 "$FLOW_UTILS" validate-plan-template "$@"
        ;;
    auto-fix)
        if [ $# -lt 2 ]; then
            echo "ERROR: auto-fix 需要 plan-file 参数" >&2
            exit 1
        fi
        python3 "$FLOW_UTILS" auto-fix-plan-template "$2"
        ;;
    *)
        echo "ERROR: 未知子命令: $1" >&2
        usage
        exit 1
        ;;
esac
