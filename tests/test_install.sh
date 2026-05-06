#!/bin/bash
set -euo pipefail

# shellcheck source=tests/helpers.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.bash"

test_installs_claude_layout() {
    local temp_root default_onespace default_runtime
    temp_root=$(make_temp_root)
    default_onespace="$temp_root/home/.config/onespace/skills/local_state/models/claude"
    default_runtime="$temp_root/home/.config/ai-flow"

    HOME="$temp_root/home" "$TEST_ROOT/install.sh" > "$temp_root/install.out"

    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-plan/SKILL.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-plan/scripts/codex-plan.sh"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-plan/scripts/flow-status.sh"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-plan/scripts/flow-state.sh"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-plan/templates/plan-template.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-plan/prompts/plan-generation.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-plan/prompts/plan-review.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-plan/prompts/plan-revision.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-change/SKILL.md"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-change/scripts/flow-change.sh"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-execute/SKILL.md"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-execute/scripts/flow-change.sh"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-execute/scripts/flow-status.sh"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-execute/scripts/flow-state.sh"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-review/SKILL.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-review/scripts/codex-review.sh"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-review/scripts/opencode-review.sh"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-review/scripts/flow-status.sh"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-review/scripts/flow-state.sh"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-review/templates/review-template.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-review/prompts/review-generation.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-status/SKILL.md"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-status/scripts/flow-status.sh"
    assert_file_not_exists "$temp_root/home/.claude/skills/ai-flow-status/scripts/flow-state.sh"
    assert_file_exists "$default_onespace/ai-flow-plan/SKILL.md"
    assert_file_exists "$default_onespace/ai-flow-review/scripts/codex-review.sh"
    assert_file_exists "$default_onespace/ai-flow-change/SKILL.md"
    assert_file_not_exists "$default_onespace/ai-flow-plan/scripts/flow-status.sh"
    assert_file_not_exists "$default_onespace/ai-flow-plan/scripts/flow-state.sh"
    assert_file_not_exists "$default_onespace/ai-flow-review/scripts/flow-status.sh"
    assert_file_not_exists "$default_onespace/ai-flow-review/scripts/flow-state.sh"
    assert_file_not_exists "$default_onespace/ai-flow-change/scripts/flow-change.sh"
    assert_file_not_exists "$default_onespace/ai-flow-change/scripts/flow-status.sh"
    assert_file_not_exists "$default_onespace/ai-flow-change/scripts/flow-state.sh"
    assert_file_not_exists "$default_onespace/ai-flow-execute/scripts/flow-change.sh"
    assert_file_not_exists "$default_onespace/ai-flow-execute/scripts/flow-status.sh"
    assert_file_not_exists "$default_onespace/ai-flow-execute/scripts/flow-state.sh"
    assert_file_not_exists "$default_onespace/ai-flow-status/scripts/flow-status.sh"
    assert_file_not_exists "$default_onespace/ai-flow-status/scripts/flow-state.sh"
    assert_file_exists "$default_runtime/scripts/flow-change.sh"
    assert_file_exists "$default_runtime/scripts/flow-state.sh"
    assert_file_exists "$default_runtime/scripts/flow-status.sh"
    [ -x "$default_runtime/scripts/flow-change.sh" ] || fail "Expected runtime flow-change.sh to be executable"
    [ -x "$default_runtime/scripts/flow-state.sh" ] || fail "Expected runtime flow-state.sh to be executable"
    assert_file_not_exists "$temp_root/home/.claude/workflows"
    assert_file_not_exists "$temp_root/home/.claude/templates"
    assert_contains "$temp_root/install.out" "Installed AI Flow"
    assert_contains "$temp_root/install.out" "Installed AI Flow runtime"
    assert_contains "$temp_root/install.out" "Synced AI Flow"
    rm -rf "$temp_root"
}

test_syncs_custom_onespace_and_runtime_directories() {
    local temp_root onespace runtime_home
    temp_root=$(make_temp_root)
    onespace="$temp_root/onespace"
    runtime_home="$temp_root/runtime-home"

    HOME="$temp_root/home" ONSPACE_DIR="$onespace" AI_FLOW_HOME="$runtime_home" "$TEST_ROOT/install.sh" > "$temp_root/install.out"

    assert_file_exists "$onespace/ai-flow-plan/SKILL.md"
    assert_file_exists "$onespace/ai-flow-plan/scripts/codex-plan.sh"
    assert_file_exists "$onespace/ai-flow-plan/templates/plan-template.md"
    assert_file_exists "$onespace/ai-flow-plan/prompts/plan-review.md"
    assert_file_exists "$onespace/ai-flow-plan/prompts/plan-revision.md"
    assert_file_exists "$onespace/ai-flow-review/prompts/review-generation.md"
    assert_file_exists "$onespace/ai-flow-change/SKILL.md"
    assert_file_not_exists "$onespace/ai-flow-change/scripts/flow-change.sh"
    assert_file_not_exists "$onespace/ai-flow-plan/scripts/flow-status.sh"
    assert_file_not_exists "$onespace/ai-flow-plan/scripts/flow-state.sh"
    assert_file_not_exists "$onespace/ai-flow-review/scripts/flow-status.sh"
    assert_file_not_exists "$onespace/ai-flow-review/scripts/flow-state.sh"
    assert_file_not_exists "$onespace/ai-flow-execute/scripts/flow-change.sh"
    assert_file_not_exists "$onespace/ai-flow-status/scripts/flow-status.sh"
    assert_file_not_exists "$onespace/ai-flow-status/scripts/flow-state.sh"
    assert_file_exists "$runtime_home/scripts/flow-change.sh"
    assert_file_exists "$runtime_home/scripts/flow-state.sh"
    assert_file_exists "$runtime_home/scripts/flow-status.sh"
    assert_file_not_exists "$onespace/flow-change.sh"
    assert_file_not_exists "$onespace/flow-state.sh"
    assert_file_not_exists "$onespace/review-template.md"
    [ -x "$runtime_home/scripts/flow-change.sh" ] || fail "Expected runtime flow-change.sh to be executable"
    assert_contains "$temp_root/install.out" "Installed AI Flow runtime"
    assert_contains "$temp_root/install.out" "Synced AI Flow"
    rm -rf "$temp_root"
}

test_installs_claude_layout
test_syncs_custom_onespace_and_runtime_directories
