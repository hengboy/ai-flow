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

# --- 测试 7: 项目级覆盖用户级 ---
test_project_override_user() {
    local dir home_dir
    dir="$(create_temp_project "config-7")"
    home_dir="$(mktemp -d)"
    write_user_setting "$home_dir" '{
        "engine_mode": "claude",
        "state": { "actor": "user-actor" }
    }'
    write_project_setting "$dir" '{
        "engine_mode": "codex",
        "state": { "actor": "project-actor" }
    }'
    local mode actor
    mode="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "engine_mode" "auto"
    )"
    actor="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "state.actor" "default-actor"
    )"
    if [[ "$mode" == "codex" ]] && [[ "$actor" == "project-actor" ]]; then
        test_pass "项目级覆盖用户级配置"
    else
        test_fail "项目级覆盖用户级配置" "期望 engine_mode=codex,state.actor=project-actor 实际 engine_mode=$mode,state.actor=$actor"
    fi
    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 7.1: 字段来源标记 ---
test_setting_source_label() {
    local dir home_dir
    dir="$(create_temp_project "config-7-source")"
    home_dir="$(mktemp -d)"
    write_user_setting "$home_dir" '{
        "engine_mode": "claude",
        "state": { "actor": "user-actor" }
    }'
    write_project_setting "$dir" '{
        "state": { "actor": "project-actor" }
    }'
    local mode_source actor_source missing_source
    mode_source="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting_source_label "engine_mode"
    )"
    actor_source="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting_source_label "state.actor"
    )"
    missing_source="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting_source_label "plan.codex.model"
    )"
    if [[ "$mode_source" == "用户级配置" ]] && [[ "$actor_source" == "项目级配置" ]] && [[ "$missing_source" == "默认值" ]]; then
        test_pass "字段来源标记正确"
    else
        test_fail "字段来源标记正确" "期望 mode=用户级配置 actor=项目级配置 missing=默认值 实际 mode=$mode_source actor=$actor_source missing=$missing_source"
    fi
    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 8: 嵌套字段部分覆盖 ---
test_partial_nested_override() {
    local dir home_dir
    dir="$(create_temp_project "config-8")"
    home_dir="$(mktemp -d)"
    write_user_setting "$home_dir" '{
        "plan": { "claude": { "model": "opus", "reasoning": "high" } }
    }'
    write_project_setting "$dir" '{
        "plan": { "claude": { "reasoning": "low" } }
    }'
    local model reasoning
    model="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "plan.claude.model" "default-model"
    )"
    reasoning="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "plan.claude.reasoning" "default-reasoning"
    )"
    if [[ "$model" == "opus" ]] && [[ "$reasoning" == "low" ]]; then
        test_pass "嵌套字段部分覆盖：继承未覆盖字段"
    else
        test_fail "嵌套字段部分覆盖" "期望 model=opus,reasoning=low 实际 model=$model,reasoning=$reasoning"
    fi
    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 9: 数组整体替换 ---
test_array_replacement() {
    local dir home_dir
    dir="$(create_temp_project "config-9")"
    home_dir="$(mktemp -d)"
    write_user_setting "$home_dir" '{
        "tags": ["a", "b"]
    }'
    write_project_setting "$dir" '{
        "tags": ["c"]
    }'
    # 数组在 flatten 后会被转成字符串，这里验证项目级覆盖用户级
    local result
    result="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "tags" "none"
    )"
    # 数组被 Python flatten 后变成 "['c']" 形式的字符串
    if [[ "$result" == *"c"* ]] && [[ "$result" != *"a"* ]]; then
        test_pass "数组整体替换：项目级替换用户级"
    else
        test_fail "数组整体替换" "期望包含 c 不包含 a 实际=$result"
    fi
    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 10: null 值不覆盖用户级 ---
test_null_does_not_override_user() {
    local dir home_dir
    dir="$(create_temp_project "config-10")"
    home_dir="$(mktemp -d)"
    write_user_setting "$home_dir" '{
        "engine_mode": "claude",
        "state": { "actor": "user-actor" }
    }'
    write_project_setting "$dir" '{
        "engine_mode": null
    }'
    local mode actor
    mode="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "engine_mode" "auto"
    )"
    actor="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "state.actor" "default-actor"
    )"
    if [[ "$mode" == "claude" ]] && [[ "$actor" == "user-actor" ]]; then
        test_pass "null 值不覆盖用户级字段"
    else
        test_fail "null 值不覆盖用户级字段" "期望 engine_mode=claude,state.actor=user-actor 实际 engine_mode=$mode,state.actor=$actor"
    fi
    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

# --- 测试 11: 无 state 目录时仍加载项目级配置 ---
test_project_setting_without_state_dir() {
    local dir home_dir
    dir="$(mktemp -d "${PROJECT_ROOT}/.ai-flow-tests/config-11.XXXXXX")"
    home_dir="$(mktemp -d)"
    mkdir -p "$dir/.ai-flow"
    write_user_setting "$home_dir" '{
        "engine_mode": "claude",
        "state": { "actor": "user-actor" }
    }'
    printf '%s' '{
        "engine_mode": "codex",
        "state": { "actor": "project-actor" }
    }' > "$dir/.ai-flow/setting.json"

    local mode actor mode_source actor_source
    mode="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "engine_mode" "auto"
    )"
    actor="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting "state.actor" "default-actor"
    )"
    mode_source="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting_source_label "engine_mode"
    )"
    actor_source="$(
        cd "$dir" || exit 1
        export AI_FLOW_HOME="$home_dir"
        unset _ai_flow_config_loaded
        source "$CONFIG_LOADER"
        load_all_settings
        get_setting_source_label "state.actor"
    )"

    if [[ "$mode" == "codex" ]] && [[ "$actor" == "project-actor" ]] && \
       [[ "$mode_source" == "项目级配置" ]] && [[ "$actor_source" == "项目级配置" ]]; then
        test_pass "无 state 目录时仍应用项目级配置"
    else
        test_fail "无 state 目录时仍应用项目级配置" \
            "期望 engine_mode=codex,state.actor=project-actor,来源均为项目级；实际 engine_mode=$mode,state.actor=$actor,mode_source=$mode_source,actor_source=$actor_source"
    fi

    rm -rf "$dir" "$home_dir"
}

# --- 运行 ---
test_user_level_setting
test_no_setting_fallback
test_nested_setting
test_null_not_loaded
test_load_idempotent
test_expand_tilde
test_project_override_user
test_setting_source_label
test_partial_nested_override
test_array_replacement
test_null_does_not_override_user
test_project_setting_without_state_dir

print_summary
exit "$fail_count"
