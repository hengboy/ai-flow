#!/bin/bash
# test_runtime_html.sh — HTML 功能集成测试

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$PROJECT_DIR/runtime}"
TEST_FLOW_PROJECT="$(mktemp -d "$PROJECT_DIR/.ai-flow-tests/runtime-html.XXXXXX")"
mkdir -p "$TEST_FLOW_PROJECT/.ai-flow/state"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# --- 1. 文件存在性 ---
echo ">>> 文件存在性测试"
[ -f "$AI_FLOW_HOME/scripts/flow-html.sh" ] && pass "flow-html.sh 已安装" || fail "flow-html.sh 未安装"
[ -f "$AI_FLOW_HOME/lib/flow_config.py" ] && pass "flow_config.py 已安装" || fail "flow_config.py 未安装"
[ -f "$AI_FLOW_HOME/lib/flow_html.py" ] && pass "flow_html.py 已安装" || fail "flow_html.py 未安装"
[ -d "$AI_FLOW_HOME/templates/html/" ] && pass "templates/html/ 目录存在" || fail "templates/html/ 目录不存在"
[ -f "$AI_FLOW_HOME/templates/html/plan.html" ] && pass "plan.html 模板存在" || fail "plan.html 模板不存在"
[ -f "$AI_FLOW_HOME/templates/html/review.html" ] && pass "review.html 模板存在" || fail "review.html 模板不存在"
[ -f "$AI_FLOW_HOME/templates/html/status.html" ] && pass "status.html 模板存在" || fail "status.html 模板不存在"
[ -f "$AI_FLOW_HOME/templates/html/common.css" ] && pass "common.css 存在" || fail "common.css 不存在"
[ -f "$AI_FLOW_HOME/templates/html/common.js" ] && pass "common.js 存在" || fail "common.js 不存在"

# --- 2. 配置默认关闭 ---
echo ">>> 配置默认关闭测试"
val=$(get_setting "html.enabled" 2>/dev/null || echo "")
if [ -z "$val" ] || [ "$val" = "false" ]; then
    pass "html.enabled 默认为 false/未设置"
else
    fail "html.enabled 默认不为 false: $val"
fi

# --- 3. flow-html.sh 关闭模式返回非 0 ---
echo ">>> 关闭模式测试"
if ! (cd "$TEST_FLOW_PROJECT" && AI_FLOW_HOME="$AI_FLOW_HOME" bash "$AI_FLOW_HOME/scripts/flow-html.sh" status >/dev/null 2>&1); then
    pass "关闭配置下 status 返回非 0"
else
    fail "关闭配置下 status 应返回非 0"
fi

# --- 3.1 flow-html.sh 开启模式可读取配置 ---
echo ">>> 开启模式测试"
tmp_home="$(mktemp -d)"
cp -R "$AI_FLOW_HOME/." "$tmp_home/"
cat > "$tmp_home/setting.json" <<'EOF'
{"html":{"enabled":true}}
EOF
tmp_project="$(mktemp -d "$PROJECT_DIR/.ai-flow-tests/runtime-html-enabled.XXXXXX")"
mkdir -p "$tmp_project/.ai-flow/state"
if (cd "$tmp_project" && AI_FLOW_HOME="$tmp_home" bash "$tmp_home/scripts/flow-html.sh" status >/dev/null 2>&1); then
    if [ -f "$tmp_project/.ai-flow/html/index.html" ]; then
        pass "开启配置下 status 生成 HTML"
    else
        fail "开启配置下 status 应生成 HTML"
    fi
else
    fail "开启配置下 status 不应失败"
fi
rm -rf "$tmp_home" "$tmp_project"

# --- 4. flow-html.sh --help ---
echo ">>> --help 测试"
if bash "$AI_FLOW_HOME/scripts/flow-html.sh" --help >/dev/null 2>&1; then
    pass "--help 正常退出"
else
    fail "--help 应正常退出"
fi

# --- 5. Python 模块导入 ---
echo ">>> Python 模块导入测试"
if python3 -c "import sys; sys.path.insert(0, '${AI_FLOW_HOME}/lib'); from flow_config import load_config; from flow_html import MarkdownParser; print('OK')" >/dev/null 2>&1; then
    pass "flow_config + flow_html 导入成功"
else
    fail "模块导入失败"
fi

# --- 6. 路径映射 ---
echo ">>> 路径映射测试"
result=$(python3 -c "
import sys; sys.path.insert(0, '${AI_FLOW_HOME}/lib')
from flow_html import map_source_to_html
print(map_source_to_html('.ai-flow/plans/test.md', '.ai-flow/html'))
")
if [ "$result" = ".ai-flow/html/plans/test.html" ]; then
    pass "plans 路径映射正确"
else
    fail "plans 路径映射错误: $result"
fi

# --- 7. MarkdownParser 基本解析 ---
echo ">>> MarkdownParser 解析测试"
if python3 -c "
import sys; sys.path.insert(0, '${AI_FLOW_HOME}/lib')
from flow_html import MarkdownParser
p = MarkdownParser()
blocks = p.parse('# Title\n\nSome para\n\n- [x] done\n\n\`\`\`\ncode\n\`\`\`')
assert len(blocks) >= 3, f'Expected >= 3 blocks, got {len(blocks)}'
print('OK')
" >/dev/null 2>&1; then
    pass "MarkdownParser 解析基本结构"
else
    fail "MarkdownParser 解析失败"
fi

# --- 8. Git exclude 幂等 ---
echo ">>> Git exclude 幂等测试"
if [ -d "$PROJECT_DIR/.git" ]; then
    exclude_file="$PROJECT_DIR/.git/info/exclude"
    mkdir -p "$(dirname "$exclude_file")"
    # Clear previous test
    grep -v ".ai-flow/html/" "$exclude_file" > "${exclude_file}.tmp" 2>/dev/null || true
    mv "${exclude_file}.tmp" "$exclude_file"

    python3 -c "
import sys; sys.path.insert(0, '${AI_FLOW_HOME}/lib')
from flow_html import ensure_git_exclude
from pathlib import Path
ensure_git_exclude(Path('$PROJECT_DIR'))
ensure_git_exclude(Path('$PROJECT_DIR'))
"
    count=$(grep -c ".ai-flow/html/" "$exclude_file" 2>/dev/null || echo "0")
    if [ "$count" -eq 1 ]; then
        pass "git exclude 幂等（只有 1 行）"
    else
        fail "git exclude 不幂等：有 $count 行"
    fi
else
    pass "无 .git 目录，跳过 git exclude 测试"
fi

# --- 9. Status HTML 生成（开启模式） ---
echo ">>> Status HTML 生成测试（临时开启）"
tmp_setting=$(mktemp)
echo '{"html": {"enabled": true}}' > "$tmp_setting"

if AI_FLOW_HOME="$AI_FLOW_HOME" python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, '${AI_FLOW_HOME}/lib')
os.environ['AI_FLOW_HOME'] = '${AI_FLOW_HOME}'
from flow_html import render_status
from pathlib import Path
render_status(Path('$PROJECT_DIR'), Path('/tmp/test_status_html_out.html'))
" 2>/dev/null && [ -f /tmp/test_status_html_out.html ]; then
    if grep -q "状态总览" /tmp/test_status_html_out.html; then
        pass "status HTML 包含标题"
    else
        fail "status HTML 缺少标题"
    fi
    rm -f /tmp/test_status_html_out.html
else
    fail "status HTML 生成失败"
fi
rm -f "$tmp_setting"

# --- Summary ---
echo ""
echo "==============================="
echo "  $PASS passed, $FAIL failed"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    rm -rf "$TEST_FLOW_PROJECT"
    exit 1
fi
rm -rf "$TEST_FLOW_PROJECT"
