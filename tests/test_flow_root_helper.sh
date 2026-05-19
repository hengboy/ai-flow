#!/bin/bash
# test_flow_root_helper.sh — flow-root-helper.sh 单元测试
# 测试 resolve_flow_root 函数的目录查找逻辑。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

HELPER_FILE="$RUNTIME_LIB/flow-root-helper.sh"

echo "=== flow-root-helper.sh 测试 ==="
echo ""

# --- 测试 1: 当前目录有 .ai-flow/state ---
test_flow_root_exact_match() {
    local dir
    dir="$(create_temp_project "flow-root-1")"
    cd "$dir"
    source "$HELPER_FILE"
    local result
    result="$(resolve_flow_root)"
    if [[ "$result" == "$dir" ]]; then
        test_pass "找到 .ai-flow/state 时返回当前目录"
    else
        test_fail "找到 .ai-flow/state 时返回当前目录" "期望=$dir 实际=$result"
    fi
    cleanup_temp_project "$dir"
}

# --- 测试 2: 在子目录中向上查找 ---
test_flow_root_find_parent() {
    local dir
    dir="$(create_temp_project "flow-root-2")"
    mkdir -p "$dir/src/components"
    cd "$dir/src/components"
    source "$HELPER_FILE"
    local result
    result="$(resolve_flow_root)"
    if [[ "$result" == "$dir" ]]; then
        test_pass "从子目录向上找到 .ai-flow/state"
    else
        test_fail "从子目录向上找到 .ai-flow/state" "期望=$dir 实际=$result"
    fi
    cleanup_temp_project "$dir"
}

# --- 测试 3: 没有 .ai-flow 时返回 cwd 且返回码 1 ---
test_flow_root_no_ai_flow() {
    local dir
    dir="$(mktemp -d)"
    cd "$dir"
    source "$HELPER_FILE"
    local result
    result="$(resolve_flow_root)" || true
    if [[ "$result" == "$dir" ]]; then
        test_pass "没有 .ai-flow 时返回当前目录"
    else
        test_fail "没有 .ai-flow 时返回当前目录" "期望=$dir 实际=$result"
    fi
    rm -rf "$dir"
}

# --- 测试 4: 只有 .ai-flow 但无 state ---
test_flow_root_no_state() {
    local dir
    dir="$(mktemp -d)"
    mkdir -p "$dir/.ai-flow"
    cd "$dir"
    source "$HELPER_FILE"
    local result
    result="$(resolve_flow_root)" || true
    if [[ "$result" == "$dir" ]]; then
        test_pass "有 .ai-flow 但无 state 时返回当前目录"
    else
        test_fail "有 .ai-flow 但无 state 时返回当前目录" "期望=$dir 实际=$result"
    fi
    rm -rf "$dir"
}

# --- 测试 5: 从嵌套子目录查找 ---
test_flow_root_deep_nesting() {
    local dir
    dir="$(create_temp_project "flow-root-5")"
    mkdir -p "$dir/a/b/c/d/e"
    cd "$dir/a/b/c/d/e"
    source "$HELPER_FILE"
    local result
    result="$(resolve_flow_root)"
    if [[ "$result" == "$dir" ]]; then
        test_pass "从 5 层嵌套子目录找到 .ai-flow/state"
    else
        test_fail "从 5 层嵌套子目录找到 .ai-flow/state" "期望=$dir 实际=$result"
    fi
    cleanup_temp_project "$dir"
}

# --- 运行 ---
test_flow_root_exact_match
test_flow_root_find_parent
test_flow_root_no_ai_flow
test_flow_root_no_state
test_flow_root_deep_nesting

print_summary
exit "$fail_count"
