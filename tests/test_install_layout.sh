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
    assert_file_exists "$skills_root/ai-flow-plan/lib/flow_utils.py"
    assert_file_exists "$skills_root/ai-flow-auto-run/SKILL.md"
    assert_file_exists "$skills_root/ai-flow-code-optimize/SKILL.md"
    assert_file_exists "$skills_root/ai-flow-code-optimize/lib/flow_utils.py"
    assert_file_exists "$skills_root/ai-flow-git-commit/SKILL.md"
    assert_contains "$skills_root/ai-flow-auto-run/SKILL.md" '无 slug 必须列出候选并等待用户选择'
    assert_contains "$skills_root/ai-flow-auto-run/SKILL.md" '主 agent 自动循环到 DONE'
    assert_contains "$skills_root/ai-flow-auto-run/SKILL.md" '保留现有分步入口'
    assert_contains "$skills_root/ai-flow-auto-run/SKILL.md" '不自动提交代码'
    assert_contains "$skills_root/ai-flow-plan/SKILL.md" 'plan-review 失败后重新进入 `/ai-flow-plan` 时，不得绕过配置选择逻辑'
    assert_contains "$skills_root/ai-flow-plan/SKILL.md" '禁止因为“修订”语义直接固定指派 `ai-flow-claude-plan`'
    assert_contains "$skills_root/ai-flow-plan/SKILL.md" '先做一次头脑风暴式 intake'
    assert_contains "$skills_root/ai-flow-plan/SKILL.md" '必须先向用户询问，不能直接把假设写进 plan'
    assert_contains "$skills_root/ai-flow-plan/SKILL.md" '询问时必须给出可行性分析、推荐选项和备选项'
    assert_contains "$skills_root/ai-flow-git-commit/SKILL.md" "唯一合法执行入口是："
    assert_contains "$skills_root/ai-flow-git-commit/SKILL.md" "\$HOME/.config/ai-flow/scripts/flow-commit.sh"
    assert_contains "$skills_root/ai-flow-git-commit/SKILL.md" "第一执行动作必须是直接调用上面的 runtime 脚本"
    assert_contains "$skills_root/ai-flow-git-commit/SKILL.md" "不要先自行运行"
    assert_file_not_exists "$skills_root/ai-flow-plan/scripts"
    assert_file_not_exists "$skills_root/ai-flow-plan/prompts"
    assert_file_not_exists "$skills_root/ai-flow-plan/templates"
    assert_file_exists "$skills_root/ai-flow-plan-review/SKILL.md"
    assert_file_not_exists "$skills_root/ai-flow-plan-review/scripts"
    assert_file_exists "$skills_root/ai-flow-plan-coding-review/SKILL.md"
    assert_file_not_exists "$skills_root/ai-flow-plan-coding-review/scripts"
    assert_file_exists "$runtime_root/scripts/flow-state.sh"
    assert_file_exists "$runtime_root/scripts/flow-status.sh"
    assert_file_exists "$runtime_root/scripts/flow-auto-run.sh"
    assert_file_exists "$runtime_root/scripts/flow-change.sh"
    assert_file_exists "$runtime_root/scripts/flow-plan-coding.sh"
    assert_file_exists "$runtime_root/scripts/flow-bug-fix.sh"
    assert_file_exists "$runtime_root/scripts/flow-code-optimize.sh"
    assert_file_exists "$runtime_root/scripts/flow-code-refactor.sh"
    assert_file_exists "$runtime_root/scripts/flow-commit.sh"
    assert_file_exists "$runtime_root/lib/rule-loader.sh"
    assert_file_not_exists "$runtime_root/scripts/flow-plan.sh"
    assert_file_exists "$agents_root/ai-flow-codex-plan/AGENT.md"
    assert_file_exists "$agents_root/ai-flow-claude-plan/AGENT.md"
    assert_file_exists "$agents_root/ai-flow-claude-git-commit/AGENT.md"
    assert_file_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-executor.sh")"
    assert_file_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-review" "plan-review-executor.sh")"
    assert_file_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan-coding-review" "coding-review-executor.sh")"
    assert_file_exists "$(installed_subagent_asset "$temp_root" "ai-flow-codex-plan" "prompts/plan-generation.md")"
    assert_file_exists "$(installed_subagent_asset "$temp_root" "ai-flow-codex-plan" "templates/plan-template.md")"
    assert_file_exists "$(installed_subagent_asset "$temp_root" "ai-flow-codex-plan" "lib/agent-common.sh")"
    assert_file_exists "$(installed_subagent_asset "$temp_root" "ai-flow-codex-plan" "lib/rule-loader.sh")"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "tools: Bash"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "color: purple"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "只允许用 Bash 做两类动作"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "\$HOME/.claude/agents/ai-flow-codex-plan/bin/plan-executor.sh"
    assert_contains "$agents_root/ai-flow-codex-plan/AGENT.md" "不得按用户工作区相对路径解析"
    assert_contains "$agents_root/ai-flow-claude-plan/AGENT.md" "头部元数据必须完整保留以下 12 项"
    assert_contains "$agents_root/ai-flow-claude-plan/AGENT.md" "创建时间"
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
    assert_file_exists "$agents_root/ai-flow-claude-plan-coding-review/AGENT.md"
    assert_contains "$agents_root/ai-flow-claude-plan-coding-review/AGENT.md" "头部元数据必须完整保留以下 9 项"
    assert_contains "$agents_root/ai-flow-claude-plan-coding-review/AGENT.md" "standalone 模式下，审查报告头部元数据至少必须保留以下 6 项"
    assert_contains "$agents_root/ai-flow-claude-git-commit/AGENT.md" "mode=group 或 mode=message"
    assert_contains "$agents_root/ai-flow-claude-git-commit/AGENT.md" "每个文件必须出现且只能出现一次"
    assert_contains "$agents_root/ai-flow-claude-git-commit/AGENT.md" "每个 repo 最多只能返回 5 个 group"
    assert_file_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "plan-review-executor.sh")"
    assert_file_not_exists "$(installed_subagent_executor "$temp_root" "ai-flow-codex-plan" "coding-review-executor.sh")"
    assert_file_not_exists "$agents_root/ai-flow-claude-git-commit/bin"
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
    assert_file_exists "$onespace_skills/ai-flow-auto-run/SKILL.md"
    assert_file_exists "$onespace_skills/ai-flow-code-optimize/SKILL.md"
    assert_file_exists "$onespace_skills/ai-flow-git-commit/SKILL.md"
    assert_contains "$onespace_skills/ai-flow-auto-run/SKILL.md" '无 slug 必须列出候选并等待用户选择'
    assert_contains "$onespace_skills/ai-flow-auto-run/SKILL.md" '主 agent 自动循环到 DONE'
    assert_contains "$onespace_skills/ai-flow-auto-run/SKILL.md" '保留现有分步入口'
    assert_contains "$onespace_skills/ai-flow-auto-run/SKILL.md" '不自动提交代码'
    assert_contains "$onespace_skills/ai-flow-plan/SKILL.md" 'plan-review 失败后重新进入 `/ai-flow-plan` 时，不得绕过配置选择逻辑'
    assert_contains "$onespace_skills/ai-flow-plan/SKILL.md" '禁止因为“修订”语义直接固定指派 `ai-flow-claude-plan`'
    assert_contains "$onespace_skills/ai-flow-plan/SKILL.md" '先做一次头脑风暴式 intake'
    assert_contains "$onespace_skills/ai-flow-plan/SKILL.md" '必须先向用户询问，不能直接把假设写进 plan'
    assert_contains "$onespace_skills/ai-flow-plan/SKILL.md" '询问时必须给出可行性分析、推荐选项和备选项'
    assert_contains "$onespace_skills/ai-flow-git-commit/SKILL.md" "唯一合法执行入口是："
    assert_contains "$onespace_skills/ai-flow-git-commit/SKILL.md" "\$HOME/.config/ai-flow/scripts/flow-commit.sh"
    assert_contains "$onespace_skills/ai-flow-git-commit/SKILL.md" "第一执行动作必须是直接调用上面的 runtime 脚本"
    assert_contains "$onespace_skills/ai-flow-git-commit/SKILL.md" "不要先自行运行"
    assert_file_exists "$runtime_root/scripts/flow-state.sh"
    assert_file_exists "$runtime_root/scripts/flow-plan-coding.sh"
    assert_file_exists "$runtime_root/scripts/flow-auto-run.sh"
    assert_file_exists "$runtime_root/scripts/flow-bug-fix.sh"
    assert_file_exists "$runtime_root/scripts/flow-code-optimize.sh"
    assert_file_exists "$runtime_root/scripts/flow-code-refactor.sh"
    assert_file_exists "$runtime_root/scripts/flow-commit.sh"
    assert_file_exists "$runtime_root/lib/rule-loader.sh"
    assert_file_exists "$claude_agents/ai-flow-codex-plan/AGENT.md"
    assert_file_exists "$claude_agents/ai-flow-claude-git-commit/AGENT.md"
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
    assert_contains "$claude_agents/ai-flow-claude-git-commit/AGENT.md" "mode=group"
    assert_contains "$claude_agents/ai-flow-claude-git-commit/AGENT.md" "SUBJECT:"
    assert_contains "$claude_agents/ai-flow-claude-git-commit/AGENT.md" "每个 repo 最多只能返回 5 个 group"
    assert_file_exists "$claude_agents/ai-flow-codex-plan/bin/plan-review-executor.sh"
    assert_file_not_exists "$claude_agents/ai-flow-codex-plan/bin/coding-review-executor.sh"
    assert_file_not_exists "$claude_agents/ai-flow-claude-git-commit/bin"
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
    assert_file_exists "$agents_root/ai-flow-codex-plan/lib/rule-loader.sh"
    assert_file_exists "$agents_root/ai-flow-codex-plan/bin/plan-executor.sh"
    assert_file_exists "$agents_root/ai-flow-codex-plan/prompts/plan-generation.md"
    rm -rf "$temp_root"
}

test_default_install_layout
test_custom_roots_install
test_reinstall_keeps_real_lib_dir
