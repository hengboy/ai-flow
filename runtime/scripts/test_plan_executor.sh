#!/bin/bash
# test_plan_executor.sh — plan-executor.sh 集成测试
# 使用临时目录，不影响项目真实状态

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_EXECUTOR="$SCRIPT_DIR/plan-executor.sh"
# AI_FLOW_HOME should point to runtime/ (parent of scripts/)
AI_FLOW_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
TOTAL=0

# ─── helpers ───────────────────────────────────────────────────────────────

setup() {
    local test_dir
    test_dir="$(mktemp -d)"

    # 创建 .ai-flow 目录结构
    mkdir -p "$test_dir/.ai-flow/state"
    mkdir -p "$test_dir/.ai-flow/plans"
    mkdir -p "$test_dir/.ai-flow/plan-groups/state"
    mkdir -p "$test_dir/.ai-flow/plan-groups/reports"

    # 初始化 git repo（plan-executor.sh 需要 git rev-parse）
    cd "$test_dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"

    echo "$test_dir"
}

cleanup() {
    local test_dir="$1"
    if [ -n "$test_dir" ] && [ -d "$test_dir" ]; then
        rm -rf "$test_dir"
    fi
}

run_test() {
    local name="$1"
    local expected_rc="${2:-0}"
    shift 2 || true
    local cmd="$*"

    TOTAL=$((TOTAL + 1))
    local rc=0
    local output
    output="$(eval "$cmd" 2>&1)" || rc=$?

    if [ "$rc" -eq "$expected_rc" ]; then
        echo "PASS [$TOTAL] $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL [$TOTAL] $name (expected rc=$expected_rc, got rc=$rc)"
        echo "  output: $(echo "$output" | head -3)"
        FAIL=$((FAIL + 1))
    fi
}

# ─── tests ─────────────────────────────────────────────────────────────────

# Test 1: --group 与 --no-group 同时传入拒绝
test_dir="$(setup)"
run_test "--group 与 --no-group 互斥" 1 \
    "AI_FLOW_HOME='$AI_FLOW_HOME' bash '$PLAN_EXECUTOR' --group --no-group 'test'"
cleanup "$test_dir"

# Test 2: child 模式与 --group 混用拒绝
test_dir="$(setup)"
run_test "child 模式拒绝 --group" 1 \
    "AI_FLOW_HOME='$AI_FLOW_HOME' bash '$PLAN_EXECUTOR' --child-of-group g1 --child-id child-1 --child-meta-json '{}' --group 'test'"
cleanup "$test_dir"

# Test 3: --no-group 创建普通 plan
test_dir="$(setup)"
run_test "创建普通 plan" 0 \
    "cd '$test_dir' && AI_FLOW_HOME='$AI_FLOW_HOME' bash '$PLAN_EXECUTOR' --no-group 'test demand' test-slug"
# 验证 state 文件创建
if [ -f "$test_dir/.ai-flow/state/*test-slug*.json" ] 2>/dev/null || \
   ls "$test_dir/.ai-flow/state/"*.json >/dev/null 2>&1; then
    echo "PASS [$TOTAL] 普通 plan state 文件已创建"
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
else
    echo "FAIL [$TOTAL] 普通 plan state 文件未创建"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
fi
cleanup "$test_dir"

# Test 4: 自动 group 判断（需求含"长任务"关键词）
test_dir="$(setup)"
# 使用 AI_FLOW_AUTO_CONFIRM=1 跳过交互确认
run_test "自动 group 判断" 0 \
    "cd '$test_dir' && AI_FLOW_HOME='$AI_FLOW_HOME' AI_FLOW_AUTO_CONFIRM=1 bash '$PLAN_EXECUTOR' '这是一个长任务，需要计划组拆分'"
# 验证 group state 文件创建
group_state_file="$(find "$test_dir/.ai-flow/plan-groups/state" -name '*.json' 2>/dev/null | head -1)"
if [ -n "$group_state_file" ] && [ -f "$group_state_file" ]; then
    echo "PASS [$TOTAL] group state 文件已创建"
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
else
    echo "FAIL [$TOTAL] group state 文件未创建"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
fi
cleanup "$test_dir"

# Test 5: 版本备份（连续两次创建同名 slug）
test_dir="$(setup)"
# 第一次创建
(cd "$test_dir" && AI_FLOW_HOME="$AI_FLOW_HOME" bash "$PLAN_EXECUTOR" --no-group 'backup test' backup-slug) >/dev/null 2>&1 || true
# 创建 plan 文件内容（模拟已有 plan）
echo "# Test Plan" > "$test_dir/.ai-flow/plans/backup-slug.md"
# 第二次创建（应触发备份）
(cd "$test_dir" && AI_FLOW_HOME="$AI_FLOW_HOME" bash "$PLAN_EXECUTOR" --no-group 'backup test v2' backup-slug) >/dev/null 2>&1 || true
# 验证 history 目录
if [ -d "$test_dir/.ai-flow/plans/history/backup-slug" ] && \
   [ -f "$test_dir/.ai-flow/plans/history/backup-slug/v1.md" ]; then
    echo "PASS [$TOTAL] 版本备份已创建"
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
else
    echo "FAIL [$TOTAL] 版本备份未创建"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
fi
cleanup "$test_dir"

# ─── summary ───────────────────────────────────────────────────────────────

echo ""
echo "================================"
echo "测试结果: $PASS/$TOTAL 通过, $FAIL 失败"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
