#!/usr/bin/env bash
# test_suggest_slug.sh — 智能 Slug 建议测试

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUGGEST_SCRIPT="$PROJECT_ROOT/runtime/scripts/flow-suggest-slug.sh"
STATE_DIR="$PROJECT_ROOT/.ai-flow/state"

PASS=0
FAIL=0

test_slug() {
    local desc="$1"
    local expected_pattern="$2"
    local label="$3"

    local result
    result=$("$SUGGEST_SCRIPT" "$desc" 2>/dev/null) || {
        echo "FAIL: [$label] 脚本执行失败"
        ((FAIL++)) || true
        return
    }

    if [[ -z "$result" ]]; then
        echo "FAIL: [$label] slug 为空"
        ((FAIL++)) || true
        return
    fi

    if [[ ${#result} -gt 30 ]]; then
        echo "FAIL: [$label] slug 超长: $result (${#result} > 30)"
        ((FAIL++)) || true
        return
    fi

    # 验证只包含合法字符（小写字母、数字、连字符、中文）
    local invalid_chars
    invalid_chars=$(python3 -c "
import re, sys
s = sys.argv[1]
if re.search(r'[^a-z0-9\-一-鿿]', s):
    print('found')
else:
    print('ok')
" "$result" 2>/dev/null) || invalid_chars="ok"
    if [[ "$invalid_chars" == "found" ]]; then
        echo "FAIL: [$label] 包含非法字符: $result"
        ((FAIL++)) || true
        return
    fi

    if [[ -n "$expected_pattern" ]] && ! echo "$result" | grep -qE "$expected_pattern"; then
        echo "FAIL: [$label] 不匹配模式 '$expected_pattern': $result"
        ((FAIL++)) || true
        return
    fi

    echo "PASS: [$label] -> $result"
    ((PASS++)) || true
}

test_slug_empty() {
    local result
    result=$(bash "$SUGGEST_SCRIPT" "" 2>/dev/null || true)
    if [[ -z "$result" ]]; then
        echo "PASS: [空描述] -> 脚本报错退出"
        ((PASS++)) || true
    else
        echo "FAIL: [空描述] -> 应报错退出但返回了: $result"
        ((FAIL++)) || true
    fi
}

test_slug_conflict() {
    local test_slug_name="test-conflict-slug"
    local test_state_file="$STATE_DIR/${test_slug_name}.json"

    mkdir -p "$STATE_DIR"
    echo '{"current_status":"DONE"}' > "$test_state_file"

    local result
    result=$("$SUGGEST_SCRIPT" "test conflict slug" 2>/dev/null) || true

    rm -f "$test_state_file"

    if [[ "$result" == "${test_slug_name}-1" ]]; then
        echo "PASS: [冲突检测] -> $result"
        ((PASS++)) || true
    else
        echo "FAIL: [冲突检测] -> 期望 ${test_slug_name}-1，实际: $result"
        ((FAIL++)) || true
    fi
}

# 测试用例
test_slug "Add user login validation" "user.*login" "英文需求"
test_slug "添加用户登录验证功能" "" "中文需求"
test_slug "Fix authentication bug in API" "fix.*auth.*api" "英文含停用词"
test_slug "The best way to create a new feature" "" "英文多停用词"
test_slug "Implement RESTful API for user management with OAuth2 authentication" "" "长描述截断"
test_slug "123" "" "纯数字"
test_slug "API v2 endpoint for /users" "api" "含特殊字符"
test_slug "添加 user login 功能" "" "中英文混合"

# 空输入测试
test_slug_empty

# 冲突检测测试
test_slug_conflict

echo ""
echo "=== Slug 建议测试结果: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
