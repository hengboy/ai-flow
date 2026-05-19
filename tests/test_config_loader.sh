#!/bin/bash
# test_config_loader.sh — config-loader.sh 单元测试
# 测试 setting.json 的加载和 get_setting。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

CONFIG_LOADER="$SHARED_LIB/config-loader.sh"

echo "=== config-loader.sh 测试 ==="
echo ""

# --- 测试 1: 用户级配置加载 ---
test_user_level_setting() {
    local dir home_dir
    dir="$(create_temp_project "config-1")"
    home_dir="$(mktemp -d)"
    # AI_FLOW_HOME 直接包含 setting.json
    cat > "$home_dir/setting.json" <<'EOF'
{
    "state": { "actor": "user-actor" },
    "engine_mode": "claude"
}
EOF
    local result
    result="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "state.actor" "default-actor"
    )"
    if [[ "$result" == "user-actor" ]]; then
        test_pass "用户级 state.actor 加载"
    else
        test_fail "用户级 state.actor 加载" "期望=user-actor 实际=$result"
    fi

    local mode
    mode="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "engine_mode" "auto"
    )"
    if [[ "$mode" == "claude" ]]; then
        test_pass "用户级 engine_mode 加载"
    else
        test_fail "用户级 engine_mode 加载" "期望=claude 实际=$mode"
    fi

    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 2: 无配置时使用 fallback ---
test_no_setting_fallback() {
    local dir home_dir
    dir="$(create_temp_project "config-2")"
    home_dir="$(mktemp -d)"
    local result
    result="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "state.actor" "fallback-default"
    )"
    if [[ "$result" == "fallback-default" ]]; then
        test_pass "无配置时使用 fallback 值"
    else
        test_fail "无配置时使用 fallback 值" "期望=fallback-default 实际=$result"
    fi
    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 3: 嵌套配置加载 ---
test_nested_setting() {
    local dir home_dir
    dir="$(create_temp_project "config-3")"
    home_dir="$(mktemp -d)"
    cat > "$home_dir/setting.json" <<'EOF'
{
    "plan": { "claude": { "model": "qwen3.6-plus", "reasoning": "high" } }
}
EOF
    local result
    result="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "plan.claude.model" "default-model"
    )"
    if [[ "$result" == "qwen3.6-plus" ]]; then
        test_pass "嵌套配置 plan.claude.model 加载"
    else
        test_fail "嵌套配置 plan.claude.model 加载" "期望=qwen3.6-plus 实际=$result"
    fi

    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 4: null 值不加载 ---
test_null_not_loaded() {
    local dir home_dir
    dir="$(create_temp_project "config-4")"
    home_dir="$(mktemp -d)"
    cat > "$home_dir/setting.json" <<'EOF'
{
    "disabled_feature": null,
    "enabled_feature": "yes"
}
EOF
    local result
    result="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "disabled_feature" "null-fallback"
    )"
    if [[ "$result" == "null-fallback" ]]; then
        test_pass "null 值不被加载为环境变量"
    else
        test_fail "null 值不被加载为环境变量" "实际=$result"
    fi
    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 5: 重复加载幂等 ---
test_load_idempotent() {
    local dir home_dir
    dir="$(create_temp_project "config-5")"
    home_dir="$(mktemp -d)"
    cat > "$home_dir/setting.json" <<'EOF'
{ "engine_mode": "test-mode" }
EOF
    local result
    result="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        source "$CONFIG_LOADER"
        load_all_settings
        local first
        first="$(get_setting "engine_mode" "auto")"
        # 再次调用不应改变结果
        load_all_settings
        local second
        second="$(get_setting "engine_mode" "auto")"
        echo "$first|$second"
    )"
    if [[ "$result" == "test-mode|test-mode" ]]; then
        test_pass "重复加载幂等"
    else
        test_fail "重复加载幂等" "实际=$result"
    fi
    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 6: expand_tilde ---
test_expand_tilde() {
    local result
    result="$(
        source "$CONFIG_LOADER"
        expand_tilde "~/test/path"
    )"
    if [[ "$result" == "$HOME/test/path" ]]; then
        test_pass "expand_tilde 展开 ~"
    else
        test_fail "expand_tilde 展开 ~" "期望=$HOME/test/path 实际=$result"
    fi
}

# --- 运行 ---
test_user_level_setting
test_no_setting_fallback
test_nested_setting
test_null_not_loaded
test_load_idempotent
test_expand_tilde

print_summary
exit "$fail_count"
