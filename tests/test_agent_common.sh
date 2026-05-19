#!/bin/bash
# test_agent_common.sh — agent-common.sh 单元测试

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

echo "=== agent-common.sh 测试 ==="
echo ""

# --- 测试 1: derive_engine_from_name ---
test_derive_engine_codex() {
    source "$SHARED_LIB/agent-common.sh" 2>/dev/null || true
    local result
    result="$(derive_engine_from_name "ai-flow-codex-plan")"
    assert_equal "$result" "codex" "codex 引擎推导"
}

test_derive_engine_claude() {
    local result
    result="$(derive_engine_from_name "ai-flow-claude-plan-review")"
    assert_equal "$result" "claude" "claude 引擎推导"
}

test_derive_engine_unknown() {
    local result
    result="$(derive_engine_from_name "unknown-agent")"
    assert_equal "$result" "" "未知引擎推导为空"
}

# --- 测试 2: derive_flow_role_from_name ---
test_derive_role_coding_review() {
    local result
    result="$(derive_flow_role_from_name "ai-flow-codex-plan-coding-review")"
    assert_equal "$result" "coding_review" "coding_review 角色推导"
}

test_derive_roles_plan_review() {
    local result
    result="$(derive_flow_role_from_name "ai-flow-claude-plan-review")"
    assert_equal "$result" "plan_review" "plan_review 角色推导"
}

test_derive_roles_plan() {
    local result
    result="$(derive_flow_role_from_name "ai-flow-claude-plan")"
    assert_equal "$result" "plan" "plan 角色推导"
}

# --- 测试 3: derive_fallback_agent_from_name ---
test_derive_fallback_codex_to_claude() {
    local result
    result="$(derive_fallback_agent_from_name "ai-flow-codex-plan")"
    assert_equal "$result" "ai-flow-claude-plan" "codex 回退到 claude"
}

test_derive_fallback_claude_none() {
    local result
    result="$(derive_fallback_agent_from_name "ai-flow-claude-plan")"
    assert_equal "$result" "" "claude 无回退"
}

# --- 测试 4: resolve_engine_mode ---
test_engine_mode_auto() {
    local dir
    dir="$(create_temp_project "agent-common-auto")"
    local result
    result="$(
        env -i HOME="$dir" PATH="$PATH" TERM="$TERM" \
            bash -c "
                source '$SHARED_LIB/config-loader.sh'
                source '$SHARED_LIB/agent-common.sh' 2>/dev/null || true
                resolve_engine_mode
            "
    )"
    assert_equal "$result" "" "auto 模式返回空"
    cleanup_temp_project "$dir"
}

# --- 测试 5: display_path ---
test_display_path_relative() {
    local result
    result="$(display_path "/Users/test/project" "/Users/test/project/src/main.py")"
    assert_equal "$result" "src/main.py" "相对路径展示"
}

test_display_path_absolute() {
    local result
    result="$(display_path "/Users/test/project" "/other/path/file.py")"
    assert_equal "$result" "/other/path/file.py" "非子路径展示完整路径"
}

# --- 测试 6: normalize_one_line ---
test_normalize_one_line_empty() {
    local result
    result="$(normalize_one_line "")"
    assert_equal "$result" "" "空字符串归一化"
}

test_normalize_one_line_spaces() {
    local result
    result="$(normalize_one_line "hello   world   test")"
    assert_equal "$result" "hello world test" "多空格归一化"
}

test_normalize_one_line_newlines() {
    local result
    result="$(normalize_one_line "$(printf 'line1\nline2\nline3')")"
    assert_equal "$result" "line1 line2 line3" "换行符归一化为空格"
}

# --- 测试 7: require_file ---
test_require_file_exists() {
    local dir
    dir="$(create_temp_project "agent-common-7")"
    touch "$dir/existing.txt"
    local output
    output="$(require_file "$dir/existing.txt" "测试文件" 2>&1)" || true
    if [[ $? -eq 0 ]]; then
        test_pass "require_file 存在文件时不报错"
    else
        test_fail "require_file 存在文件时不报错" "$output"
    fi
    cleanup_temp_project "$dir"
}

test_require_file_missing() {
    local dir
    dir="$(create_temp_project "agent-common-8")"
    local output exit_code=0
    output="$(require_file "$dir/nonexistent.txt" "测试文件" 2>&1)" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        test_pass "require_file 缺失文件时退出码非零"
    else
        test_fail "require_file 缺失文件时退出码非零" "exit_code=$exit_code"
    fi
    cleanup_temp_project "$dir"
}

# --- 运行 ---
test_derive_engine_codex
test_derive_engine_claude
test_derive_engine_unknown
test_derive_role_coding_review
test_derive_roles_plan_review
test_derive_roles_plan
test_derive_fallback_codex_to_claude
test_derive_fallback_claude_none
test_engine_mode_auto
test_display_path_relative
test_display_path_absolute
test_normalize_one_line_empty
test_normalize_one_line_spaces
test_normalize_one_line_newlines
test_require_file_exists
test_require_file_missing

print_summary
exit "$fail_count"
