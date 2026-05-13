#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

test_default_install_layout() {
    local temp_root skills_root runtime_root agents_root
    temp_root=$(make_temp_root)
    skills_root="$temp_root/home/.claude/skills"
    runtime_root="$temp_root/home/.config/ai-flow"
    agents_root="$temp_root/home/.claude/agents"

    mkdir -p "$temp_root/home/.claude/workflows" "$temp_root/home/.claude/templates"
    printf 'legacy\n' > "$temp_root/home/.claude/workflows/codex-plan.sh"
    printf 'legacy\n' > "$temp_root/home/.claude/templates/plan-template.md"

    install_ai_flow "$temp_root"

    assert_file_exists "$skills_root/ai-flow-plan/SKILL.md"
    assert_file_exists "$skills_root/ai-flow-code-optimize/SKILL.md"
    assert_file_exists "$skills_root/ai-flow-git-commit/SKILL.md"
    assert_file_not_exists "$skills_root/ai-flow-plan/scripts"
    assert_file_not_exists "$skills_root/ai-flow-plan/prompts"
    assert_file_not_exists "$skills_root/ai-flow-plan/templates"
    assert_file_exists "$skills_root/ai-flow-plan-review/SKILL.md"
    assert_file_not_exists "$skills_root/ai-flow-plan-review/scripts"
    assert_file_exists "$skills_root/ai-flow-plan-coding-review/SKILL.md"
    assert_file_not_exists "$skills_root/ai-flow-plan-coding-review/scripts"
    assert_file_exists "$runtime_root/scripts/flow-state.sh"
    assert_file_exists "$runtime_root/scripts/flow-status.sh"
    assert_file_exists "$runtime_root/scripts/flow-change.sh"
    assert_file_exists "$runtime_root/scripts/flow-commit.sh"
    assert_file_not_exists "$runtime_root/scripts/flow-plan.sh"
    assert_file_exists "$agents_root/ai-flow-codex-plan/AGENT.md"
    assert_file_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    assert_file_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-review" "plan-review-executor.sh")"
    assert_file_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    assert_file_exists "$(installed_subagent_asset "$temp_root" "ai-flow-codex-plan" "prompts/plan-generation.md")"
    assert_file_exists "$(installed_subagent_asset "$temp_root" "ai-flow-codex-plan" "templates/plan-template.md")"
    assert_file_exists "$(installed_subagent_asset "$temp_root" "ai-flow-codex-plan" "lib/agent-common.sh")"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "tools: Bash"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "color: purple"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "只允许用 Bash 做两类动作"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "\$HOME/.claude/agents/ai-flow-codex-plan/bin/plan-executor.sh"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "不得按用户工作区相对路径解析"
    assert_contains "$agents_root/ai-flow-codex-plan-review/AGENT.md" "tools: Bash"
    assert_contains "$agents_root/ai-flow-codex-plan-review/AGENT.md" "唯一合法执行路径"
    assert_contains "$agents_root/ai-flow-codex-plan-review/AGENT.md" "只允许用 Bash 做两类动作"
    assert_contains "$agents_root/ai-flow-codex-plan-review/AGENT.md" "\$HOME/.claude/agents/ai-flow-codex-plan-review/bin/plan-review-executor.sh"
    assert_contains "$agents_root/ai-flow-codex-plan-review/AGENT.md" "不得按用户工作区相对路径解析"
    assert_contains "$agents_root/ai-flow-codex-plan-coding-review/AGENT.md" "tools: Bash"
    assert_contains "$agents_root/ai-flow-codex-plan-coding-review/AGENT.md" "唯一合法执行路径"
    assert_contains "$agents_root/ai-flow-codex-plan-coding-review/AGENT.md" "只允许用 Bash 做两类动作"
    assert_contains "$agents_root/ai-flow-codex-plan-coding-review/AGENT.md" "\$HOME/.claude/agents/ai-flow-codex-plan-coding-review/bin/coding-review-executor.sh"
    assert_contains "$agents_root/ai-flow-codex-plan-coding-review/AGENT.md" "不得按用户工作区相对路径解析"
    assert_file_not_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-review-executor.sh")"
    assert_file_not_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "coding-review-executor.sh")"
    assert_file_not_exists "$(installed_subagent_asset "$temp_root" "ai-flow-codex-plan" "templates/review-template.md")"
    assert_file_not_exists "$(installed_subagent_asset "$temp_root" "ai-flow-codex-plan-coding-review" "prompts/plan-generation.md")"
    assert_file_not_exists "$agents_root/index.yaml"
    assert_file_not_exists "$agents_root/ai-flow-codex-plan/meta.yaml"
    assert_file_not_exists "$temp_root/home/.claude/workflows"
    assert_file_not_exists "$temp_root/home/.claude/templates"
    set +e
    rg -n "ai-flow-plan-coding-fix" "$skills_root" "$runtime_root" "$agents_root" >"$temp_root/legacy-skill.out"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "Expected no legacy repair skill references in installed assets"
    set +e
    rg -n "coding_review_failed" "$skills_root" "$agents_root" >"$temp_root/legacy-event.out"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "Expected no legacy review event references in installed user-facing assets"
    assert_contains "$runtime_root/scripts/flow-state.sh" "\"coding_review_failed\": \"review_failed\""
    assert_contains "$temp_root/install.out" "Installed AI Flow runtime"
    rm -rf "$temp_root"
}

test_custom_roots_install() {
    local temp_root runtime_root onespace_skills claude_agents onespace_claude
    temp_root=$(make_temp_root)
    runtime_root="$temp_root/runtime-home"
    onespace_skills="$temp_root/onespace-skills"
    claude_agents="$temp_root/claude-agents"
    onespace_claude="$temp_root/onespace-claude"

    HOME="$temp_root/home" \
        AI_FLOW_HOME="$runtime_root" \
        ONSPACE_SKILLS_DIR="$onespace_skills" \
        CLAUDE_AGENTS_DIR="$claude_agents" \
        ONSPACE_SUBAGENTS_CLAUDE_DIR="$onespace_claude" \
        bash "$TEST_ROOT/install.sh" >"$temp_root/install-custom.out"

    assert_file_exists "$onespace_skills/ai-flow-plan/SKILL.md"
    assert_file_exists "$onespace_skills/ai-flow-code-optimize/SKILL.md"
    assert_file_exists "$onespace_skills/ai-flow-git-commit/SKILL.md"
    assert_file_exists "$runtime_root/scripts/flow-state.sh"
    assert_file_exists "$runtime_root/scripts/flow-commit.sh"
    assert_file_exists "$claude_agents/ai-flow-codex-plan/AGENT.md"
    assert_file_exists "$claude_agents/ai-flow-codex-plan/bin/plan-executor.sh"
    assert_file_exists "$claude_agents/ai-flow-codex-plan-review/bin/plan-review-executor.sh"
    assert_file_exists "$onespace_claude/ai-flow-codex-plan-coding-review/templates/review-template.md"
    assert_contains "$claude_agents/ai-flow-codex-plan/AGENT.md" "tools: Bash"
    assert_contains "$claude_agents/ai-flow-codex-plan/AGENT.md" "color: purple"
    assert_contains "$claude_agents/ai-flow-codex-plan/AGENT.md" "只允许用 Bash 做两类动作"
    assert_contains "$claude_agents/ai-flow-codex-plan/AGENT.md" "不得按用户工作区相对路径解析"
    assert_contains "$claude_agents/ai-flow-codex-plan-review/AGENT.md" "tools: Bash"
    assert_contains "$claude_agents/ai-flow-codex-plan-review/AGENT.md" "不得按用户工作区相对路径解析"
    assert_contains "$claude_agents/ai-flow-codex-plan-coding-review/AGENT.md" "tools: Bash"
    assert_contains "$claude_agents/ai-flow-codex-plan-coding-review/AGENT.md" "不得按用户工作区相对路径解析"
    assert_file_not_exists "$claude_agents/ai-flow-codex-plan/bin/plan-review-executor.sh"
    assert_file_not_exists "$claude_agents/ai-flow-codex-plan/bin/coding-review-executor.sh"
    assert_file_not_exists "$claude_agents/index.yaml"
    rm -rf "$temp_root"
}

test_reinstall_keeps_real_lib_dir() {
    local temp_root agents_root
    temp_root=$(make_temp_root)
    agents_root="$temp_root/home/.claude/agents"

    install_ai_flow "$temp_root"
    install_ai_flow "$temp_root"

    assert_dir_exists "$agents_root/ai-flow-codex-plan/lib"
    [ ! -L "$agents_root/ai-flow-codex-plan/lib" ] || fail "Expected installed lib to remain a real directory"
    assert_file_exists "$agents_root/ai-flow-codex-plan/lib/agent-common.sh"
    assert_file_exists "$agents_root/ai-flow-codex-plan/bin/plan-executor.sh"
    assert_file_exists "$agents_root/ai-flow-codex-plan/prompts/plan-generation.md"
    rm -rf "$temp_root"
}

test_default_install_layout
test_custom_roots_install
test_reinstall_keeps_real_lib_dir
