#!/bin/bash
# flow-html.sh — HTML 渲染 shell 入口，提供 plan/review/status/all 子命令。
#
# 用法:
#   flow-html.sh plan --input <path>
#   flow-html.sh review --input <path>
#   flow-html.sh status
#   flow-html.sh all --slug <slug>
#
# 手动调用失败时返回非 0；内部 best-effort 调用不检查返回码。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$HOME/.config/ai-flow}"

source "${AI_FLOW_HOME}/lib/flow-root-helper.sh" || true
PROJECT_DIR="$(resolve_flow_root)" || PROJECT_DIR="$(pwd)"

# 读取配置
html_enabled="$("${AI_FLOW_HOME}/lib/flow_config.py" 2>/dev/null | grep "^AI_FLOW_SETTING_HTML_ENABLED=" | head -1 | cut -d"'" -f2 || echo "false")"

check_enabled() {
    if [ "$html_enabled" != "true" ]; then
        echo "HTML 渲染未启用（html.enabled 不为 true）" >&2
        return 1
    fi
}

ensure_flow_html_py() {
    if [ ! -f "${AI_FLOW_HOME}/lib/flow_html.py" ]; then
        echo "flow_html.py 未找到: ${AI_FLOW_HOME}/lib/flow_html.py" >&2
        return 1
    fi
}

do_plan() {
    check_enabled
    local input_path=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --input) input_path="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [ -z "$input_path" ]; then
        echo "plan 需要提供 --input <path>" >&2
        return 1
    fi
    ensure_flow_html_py
    local output_path
    output_path="$("${AI_FLOW_HOME}/lib/flow_html.py" 2>/dev/null <<'PYEOF'
import sys; sys.path.insert(0, '${AI_FLOW_HOME}/lib')
from flow_html import map_source_to_html
print(map_source_to_html('${input_path}', '${PROJECT_DIR}/.ai-flow/html'))
PYEOF
)" 2>/dev/null || output_path="${PROJECT_DIR}/.ai-flow/html/$(basename "$input_path" .md).html"
    mkdir -p "$(dirname "$output_path")"
    python3 "${AI_FLOW_HOME}/lib/flow_html.py" plan --input "$input_path" --output "$output_path"
    echo "plan HTML: $output_path"
}

do_review() {
    check_enabled
    local input_path=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --input) input_path="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [ -z "$input_path" ]; then
        echo "review 需要提供 --input <path>" >&2
        return 1
    fi
    ensure_flow_html_py
    local output_path
    output_path="$("${AI_FLOW_HOME}/lib/flow_html.py" 2>/dev/null <<'PYEOF'
import sys; sys.path.insert(0, '${AI_FLOW_HOME}/lib')
from flow_html import map_source_to_html
print(map_source_to_html('${input_path}', '${PROJECT_DIR}/.ai-flow/html'))
PYEOF
)" 2>/dev/null || output_path="${PROJECT_DIR}/.ai-flow/html/$(basename "$input_path" .md).html"
    mkdir -p "$(dirname "$output_path")"
    python3 "${AI_FLOW_HOME}/lib/flow_html.py" review --input "$input_path" --output "$output_path"
    echo "review HTML: $output_path"
}

do_status() {
    check_enabled
    ensure_flow_html_py
    local output_path="${PROJECT_DIR}/.ai-flow/html/index.html"
    mkdir -p "$(dirname "$output_path")"
    python3 "${AI_FLOW_HOME}/lib/flow_html.py" status --project-dir "$PROJECT_DIR" --output "$output_path"
    echo "status HTML: $output_path"
}

do_all() {
    check_enabled
    local slug=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug) slug="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [ -z "$slug" ]; then
        echo "all 需要提供 --slug <slug>" >&2
        return 1
    fi
    ensure_flow_html_py
    # 从状态文件获取 plan_file
    local state_file="${PROJECT_DIR}/.ai-flow/state/${slug}.json"
    if [ ! -f "$state_file" ]; then
        echo "状态文件不存在: $state_file" >&2
        return 1
    fi
    local plan_file
    plan_file="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('plan_file', ''))
" "$state_file")"
    if [ -n "$plan_file" ] && [ -f "$plan_file" ]; then
        do_plan --input "$plan_file" || true
    fi
    do_status || true
}

# 确保 git exclude
ensure_git_exclude() {
    if [ -d "${PROJECT_DIR}/.git" ]; then
        local exclude_file="${PROJECT_DIR}/.git/info/exclude"
        mkdir -p "$(dirname "$exclude_file")"
        if ! grep -q ".ai-flow/html/" "$exclude_file" 2>/dev/null; then
            echo ".ai-flow/html/" >> "$exclude_file"
        fi
    fi
}

# 主入口
case "${1:-}" in
    plan)
        shift
        do_plan "$@"
        ;;
    review)
        shift
        do_review "$@"
        ;;
    status)
        shift
        do_status
        ;;
    all)
        shift
        do_all "$@"
        ;;
    --help|-h)
        echo "用法: flow-html.sh <command> [options]"
        echo ""
        echo "子命令:"
        echo "  plan --input <path>       渲染 plan Markdown 为 HTML"
        echo "  review --input <path>     渲染 review Markdown 为 HTML"
        echo "  status                    渲染状态总览 HTML"
        echo "  all --slug <slug>         渲染指定 slug 的 plan + status HTML"
        echo ""
        echo "配置: 在 setting.json 中设置 html.enabled=true 启用"
        exit 0
        ;;
    *)
        echo "未知命令: ${1:-}" >&2
        echo "运行 flow-html.sh --help 查看使用说明" >&2
        exit 1
        ;;
esac

ensure_git_exclude
