#!/bin/bash
# test_flow_suggest_slug.sh — flow-suggest-slug.sh 单元测试
# 测试 slug 生成的中英文处理和冲突解决。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

SUGGEST_SH="$SCRIPTS_DIR/flow-suggest-slug.sh"

echo "=== flow-suggest-slug.sh 测试 ==="
echo ""

# --- 测试 1: 纯英文描述 ---
test_english_simple() {
    local output exit_code=0
    output="$(bash "$SUGGEST_SH" "Add user login authentication" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "英文描述正常退出"
    # 输出应包含英文关键词且不含中文
    assert_not_contains "$output" "$(printf '[一-龥]')" "英文slug不含中文字符"
    test_info "英文描述输出: $output"
}

# --- 测试 2: 英文停用词过滤 ---
test_english_stop_words() {
    local output exit_code=0
    output="$(bash "$SUGGEST_SH" "the user for login" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "英文停用词过滤"
    assert_not_contains "$output" "the" "过滤停用词 the"
    assert_not_contains "$output" "for" "过滤停用词 for"
    test_info "停用词过滤输出: $output"
}

# --- 测试 3: 中文描述 ---
test_chinese_simple() {
    local output exit_code=0
    output="$(bash "$SUGGEST_SH" "添加用户登录验证" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "中文描述正常退出"
    test_info "中文描述输出: $output"
}

# --- 测试 4: 缺失参数 ---
test_missing_description() {
    local output exit_code=0
    output="$(bash "$SUGGEST_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "缺失描述时退出码为1"
    assert_contains "$output" "ERROR" "缺失描述时输出错误信息"
}

# --- 测试 5: 长度限制 ---
test_length_limit() {
    local output exit_code=0
    output="$(bash "$SUGGEST_SH" "this is a very very very very very long description with many words" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "长描述正常退出"
    # slug 长度不应超过 30 (YYYYMMDD- + 语义部分)
    local len=${#output}
    if [[ $len -le 30 ]]; then
        test_pass "长描述截断到最大长度"
    else
        test_fail "长描述截断到最大长度" "期望<=30 实际=$len"
    fi
    test_info "长描述输出: $output"
}

# --- 测试 6: 日期前缀格式 ---
test_date_prefix_format() {
    local output exit_code=0
    output="$(bash "$SUGGEST_SH" "test slug" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "slug 生成"
    # 验证以 YYYYMMDD- 开头
    if [[ "$output" =~ ^[0-9]{8}- ]]; then
        test_pass "slug 以 YYYYMMDD- 开头"
    else
        test_fail "slug 以 YYYYMMDD- 开头" "实际=$output"
    fi
}

# --- 测试 7: 空描述 ---
test_empty_description() {
    local output exit_code=0
    output="$(bash "$SUGGEST_SH" "" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "空描述时退出码为1"
}

# --- 运行 ---
test_english_simple
test_english_stop_words
test_chinese_simple
test_missing_description
test_length_limit
test_date_prefix_format
test_empty_description

print_summary
exit "$fail_count"
