#!/bin/bash
# test_install_layout.sh — install.sh 安装布局回归测试
# 验证 runtime/lib 会完整安装，并保留 flow-root-helper.sh / worktree-snapshot.sh。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

INSTALL_SH="$PROJECT_ROOT/install.sh"

echo "=== install.sh 布局测试 ==="
echo ""

test_runtime_lib_is_preserved() {
    local sandbox_root
    local claude_home
    local ai_flow_home
    local onespace_dir
    local output exit_code=0

    sandbox_root="$(mktemp -d "$PROJECT_ROOT/.ai-flow-tests/install-layout.XXXXXX")"
    claude_home="$sandbox_root/.claude"
    ai_flow_home="$sandbox_root/.config/ai-flow"
    onespace_dir="$sandbox_root/.config/onespace"

    output="$(
        CLAUDE_HOME="$claude_home" \
        AI_FLOW_HOME="$ai_flow_home" \
        ONSPACE_DIR="$onespace_dir" \
        ONSPACE_SKILLS_DIR="$onespace_dir/skills/local_state/models/claude" \
        ONSPACE_SUBAGENTS_CLAUDE_DIR="$onespace_dir/subagents/local_state/models/claude" \
        bash "$INSTALL_SH" 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "隔离环境安装成功"
    assert_contains "$output" "Installed AI Flow runtime" "安装输出包含 runtime 安装提示"

    if [ -f "$ai_flow_home/lib/flow-root-helper.sh" ]; then
        test_pass "安装后保留 flow-root-helper.sh"
    else
        test_fail "安装后保留 flow-root-helper.sh" "缺少 $ai_flow_home/lib/flow-root-helper.sh"
    fi

    if [ -f "$ai_flow_home/lib/worktree-snapshot.sh" ]; then
        test_pass "安装后保留 worktree-snapshot.sh"
    else
        test_fail "安装后保留 worktree-snapshot.sh" "缺少 $ai_flow_home/lib/worktree-snapshot.sh"
    fi

    if [ -f "$ai_flow_home/lib/rule-loader.sh" ]; then
        test_pass "安装后保留 shared lib"
    else
        test_fail "安装后保留 shared lib" "缺少 $ai_flow_home/lib/rule-loader.sh"
    fi

    rm -rf "$sandbox_root"
}

test_runtime_script_uses_installed_helper() {
    local sandbox_root
    local claude_home
    local ai_flow_home
    local onespace_dir
    local project_dir
    local slug
    local output exit_code=0

    sandbox_root="$(mktemp -d "$PROJECT_ROOT/.ai-flow-tests/install-runtime.XXXXXX")"
    claude_home="$sandbox_root/.claude"
    ai_flow_home="$sandbox_root/.config/ai-flow"
    onespace_dir="$sandbox_root/.config/onespace"
    project_dir="$(create_temp_project "install-layout-project")"
    slug="20260519-install-layout"

    CLAUDE_HOME="$claude_home" \
    AI_FLOW_HOME="$ai_flow_home" \
    ONSPACE_DIR="$onespace_dir" \
    ONSPACE_SKILLS_DIR="$onespace_dir/skills/local_state/models/claude" \
    ONSPACE_SUBAGENTS_CLAUDE_DIR="$onespace_dir/subagents/local_state/models/claude" \
    bash "$INSTALL_SH" >/dev/null 2>&1

    mkdir -p "$project_dir/.ai-flow/plans"
    cat > "$project_dir/.ai-flow/plans/test.md" <<'EOF'
# Test Plan
## 1. 概述
## 7. 需求变更记录
EOF
    create_minimal_state "$project_dir" "$slug"

    cat > "$project_dir/.ai-flow/rule.yaml" <<'EOF'
version: 1
shared_context: []
required_reads: []
test_policy:
  require_tests_for_code_change: false
  allow_testless_paths: []
EOF

    (
        cd "$project_dir" && \
        AI_FLOW_HOME="$ai_flow_home" \
        bash "$ai_flow_home/scripts/flow-state.sh" transition --slug "$slug" \
            --event plan_review_passed --result passed --engine test-engine --model test-model >/dev/null 2>&1
    )

    output="$(
        cd "$project_dir" && \
        AI_FLOW_HOME="$ai_flow_home" \
        bash "$ai_flow_home/scripts/flow-plan-coding.sh" "$slug" 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "已安装 flow-plan-coding.sh 可正常运行"
    assert_not_contains "$output" "flow-root-helper.sh: No such file or directory" "不再报 helper 缺失"
    assert_contains "$output" "RESULT: success" "门禁脚本返回成功协议"

    cleanup_temp_project "$project_dir"
    rm -rf "$sandbox_root"
}

test_installed_status_without_ai_flow_home() {
    local sandbox_root
    local claude_home
    local ai_flow_home
    local onespace_dir
    local project_dir
    local output exit_code=0

    sandbox_root="$(mktemp -d "$PROJECT_ROOT/.ai-flow-tests/install-status.XXXXXX")"
    claude_home="$sandbox_root/.claude"
    ai_flow_home="$sandbox_root/.config/ai-flow"
    onespace_dir="$sandbox_root/.config/onespace"
    project_dir="$(create_temp_project "install-status-project")"

    CLAUDE_HOME="$claude_home" \
    AI_FLOW_HOME="$ai_flow_home" \
    ONSPACE_DIR="$onespace_dir" \
    ONSPACE_SKILLS_DIR="$onespace_dir/skills/local_state/models/claude" \
    ONSPACE_SUBAGENTS_CLAUDE_DIR="$onespace_dir/subagents/local_state/models/claude" \
    bash "$INSTALL_SH" >/dev/null 2>&1

    output="$(
        cd "$project_dir" && \
        env -u AI_FLOW_HOME bash "$ai_flow_home/scripts/flow-status.sh" 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "未设置 AI_FLOW_HOME 时已安装 flow-status.sh 可正常运行"
    assert_not_contains "$output" "flow-root-helper.sh: No such file or directory" "flow-status.sh 不再走错误 helper 路径"
    assert_contains "$output" "AI Flow" "flow-status.sh 正常输出状态视图"

    cleanup_temp_project "$project_dir"
    rm -rf "$sandbox_root"
}

test_runtime_lib_is_preserved
test_runtime_script_uses_installed_helper
test_installed_status_without_ai_flow_home

print_summary
exit "$fail_count"
