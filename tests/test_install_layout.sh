#!/bin/bash
# test_install_layout.sh — install.sh 安装布局回归测试
# 验证 runtime/lib 会完整安装，并保留 flow-root-helper.sh / worktree-snapshot.sh。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

INSTALL_SH="$PROJECT_ROOT/install.sh"
THIN_SKILLS="ai-flow-plan ai-flow-plan-review ai-flow-plan-coding-review ai-flow-plan-orchestrate"
CODEX_NATIVE_AGENTS="ai-flow-codex-plan ai-flow-codex-plan-review ai-flow-codex-plan-coding-review"
CLAUDE_AGENT_BUNDLES="ai-flow-codex-plan ai-flow-codex-plan-review ai-flow-codex-plan-coding-review ai-flow-claude-plan ai-flow-claude-plan-review ai-flow-claude-plan-coding-review"

echo "=== install.sh 布局测试 ==="
echo ""

assert_skill_set_installed() {
    local destination_root="$1"
    local label="$2"
    local skill_name

    for skill_name in $THIN_SKILLS; do
        if [ -f "$destination_root/$skill_name/SKILL.md" ]; then
            test_pass "$label 安装 $skill_name"
        else
            test_fail "$label 安装 $skill_name" "缺少 $destination_root/$skill_name/SKILL.md"
        fi
    done
}

assert_claude_agent_set_installed() {
    local destination_root="$1"
    local label="$2"
    local agent_name

    for agent_name in $CLAUDE_AGENT_BUNDLES; do
        if [ -f "$destination_root/$agent_name/AGENT.md" ]; then
            test_pass "$label 安装 $agent_name"
        else
            test_fail "$label 安装 $agent_name" "缺少 $destination_root/$agent_name/AGENT.md"
        fi
    done
}

assert_codex_agent_set_installed() {
    local destination_root="$1"
    local label="$2"
    local agent_name

    for agent_name in $CODEX_NATIVE_AGENTS; do
        if [ -f "$destination_root/$agent_name.toml" ]; then
            test_pass "$label 安装 $agent_name"
        else
            test_fail "$label 安装 $agent_name" "缺少 $destination_root/$agent_name.toml"
        fi
    done
}

test_runtime_lib_is_preserved() {
    local sandbox_root
    local claude_home
    local ai_flow_home
    local codex_home
    local codex_skills_dir
    local codex_legacy_skills_dir
    local onespace_dir
    local onespace_claude_skills_dir
    local onespace_claude_agents_dir
    local onespace_codex_skills_dir
    local onespace_codex_agents_dir
    local output exit_code=0

    sandbox_root="$(mktemp -d "$PROJECT_ROOT/.ai-flow-tests/install-layout.XXXXXX")"
    claude_home="$sandbox_root/.claude"
    ai_flow_home="$sandbox_root/.config/ai-flow"
    codex_home="$sandbox_root/.codex"
    codex_skills_dir="$sandbox_root/.agents/skills"
    codex_legacy_skills_dir="$codex_home/skills"
    onespace_dir="$sandbox_root/.config/onespace"
    onespace_claude_skills_dir="$onespace_dir/skills/local_state/models/claude"
    onespace_claude_agents_dir="$onespace_dir/subagents/local_state/models/claude"
    onespace_codex_skills_dir="$onespace_dir/skills/local_state/models/codex"
    onespace_codex_agents_dir="$onespace_dir/subagents/local_state/models/codex"

    output="$(
        CLAUDE_HOME="$claude_home" \
        AI_FLOW_HOME="$ai_flow_home" \
        CODEX_HOME="$codex_home" \
        CODEX_SKILLS_DIR="$codex_skills_dir" \
        CODEX_LEGACY_SKILLS_DIR="$codex_legacy_skills_dir" \
        ONSPACE_DIR="$onespace_dir" \
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

    if [ -f "$ai_flow_home/scripts/flow-plan-orchestrate.sh" ] && [ -x "$ai_flow_home/scripts/flow-plan-orchestrate-launch.sh" ]; then
        test_pass "安装后包含 plan orchestrate runtime"
    else
        test_fail "安装后包含 plan orchestrate runtime" "缺少 orchestrate runtime 脚本"
    fi

    assert_skill_set_installed "$claude_home/skills" "Claude skill"
    assert_claude_agent_set_installed "$claude_home/agents" "Claude agent"
    assert_skill_set_installed "$codex_skills_dir" "Codex official skill"
    assert_skill_set_installed "$codex_legacy_skills_dir" "Codex compatibility skill"
    assert_codex_agent_set_installed "$codex_home/agents" "Codex native agent"
    assert_skill_set_installed "$onespace_claude_skills_dir" "OneSpace Claude skill"
    assert_claude_agent_set_installed "$onespace_claude_agents_dir" "OneSpace Claude agent"
    assert_skill_set_installed "$onespace_codex_skills_dir" "OneSpace Codex skill"
    assert_codex_agent_set_installed "$onespace_codex_agents_dir" "OneSpace Codex agent"

    if grep -qF "<!-- AI-FLOW-GUIDANCE:BEGIN -->" "$codex_home/AGENTS.md" 2>/dev/null; then
        test_pass "同步 Codex AGENTS.md 行为准则"
    else
        test_fail "同步 Codex AGENTS.md 行为准则" "缺少 $codex_home/AGENTS.md marker"
    fi

    rm -rf "$sandbox_root"
}

test_runtime_script_uses_installed_helper() {
    local sandbox_root
    local claude_home
    local ai_flow_home
    local codex_home
    local onespace_dir
    local project_dir
    local slug
    local output exit_code=0

    sandbox_root="$(mktemp -d "$PROJECT_ROOT/.ai-flow-tests/install-runtime.XXXXXX")"
    claude_home="$sandbox_root/.claude"
    ai_flow_home="$sandbox_root/.config/ai-flow"
    codex_home="$sandbox_root/.codex"
    onespace_dir="$sandbox_root/.config/onespace"
    project_dir="$(create_temp_project "install-layout-project")"
    slug="20260519-install-layout"

    CLAUDE_HOME="$claude_home" \
    AI_FLOW_HOME="$ai_flow_home" \
    CODEX_HOME="$codex_home" \
    CODEX_SKILLS_DIR="$sandbox_root/.agents/skills" \
    CODEX_LEGACY_SKILLS_DIR="$codex_home/skills" \
    ONSPACE_DIR="$onespace_dir" \
    ONSPACE_SKILLS_DIR="$onespace_dir/skills/local_state/models/claude" \
    ONSPACE_SUBAGENTS_CLAUDE_DIR="$onespace_dir/subagents/local_state/models/claude" \
    ONSPACE_SKILLS_CODEX_DIR="$onespace_dir/skills/local_state/models/codex" \
    ONSPACE_SUBAGENTS_CODEX_DIR="$onespace_dir/subagents/local_state/models/codex" \
    bash "$INSTALL_SH" >/dev/null 2>&1

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
    local codex_home
    local onespace_dir
    local project_dir
    local output exit_code=0

    sandbox_root="$(mktemp -d "$PROJECT_ROOT/.ai-flow-tests/install-status.XXXXXX")"
    claude_home="$sandbox_root/.claude"
    ai_flow_home="$sandbox_root/.config/ai-flow"
    codex_home="$sandbox_root/.codex"
    onespace_dir="$sandbox_root/.config/onespace"
    project_dir="$(create_temp_project "install-status-project")"

    CLAUDE_HOME="$claude_home" \
    AI_FLOW_HOME="$ai_flow_home" \
    CODEX_HOME="$codex_home" \
    CODEX_SKILLS_DIR="$sandbox_root/.agents/skills" \
    CODEX_LEGACY_SKILLS_DIR="$codex_home/skills" \
    ONSPACE_DIR="$onespace_dir" \
    ONSPACE_SKILLS_DIR="$onespace_dir/skills/local_state/models/claude" \
    ONSPACE_SUBAGENTS_CLAUDE_DIR="$onespace_dir/subagents/local_state/models/claude" \
    ONSPACE_SKILLS_CODEX_DIR="$onespace_dir/skills/local_state/models/codex" \
    ONSPACE_SUBAGENTS_CODEX_DIR="$onespace_dir/subagents/local_state/models/codex" \
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
