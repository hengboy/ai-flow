#!/bin/bash
set -euo pipefail

# shellcheck source=tests/helpers.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.bash"

test_installs_claude_layout() {
    local temp_root
    temp_root=$(make_temp_root)

    HOME="$temp_root/home" "$TEST_ROOT/install.sh" > "$temp_root/install.out"

    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-plan/SKILL.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-execute/SKILL.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-review/SKILL.md"
    assert_file_exists "$temp_root/home/.claude/skills/ai-flow-status/SKILL.md"
    assert_file_exists "$temp_root/home/.claude/workflows/codex-plan.sh"
    assert_file_exists "$temp_root/home/.claude/workflows/codex-review.sh"
    assert_file_exists "$temp_root/home/.claude/workflows/flow-change.sh"
    assert_file_exists "$temp_root/home/.claude/workflows/flow-state.sh"
    assert_file_exists "$temp_root/home/.claude/workflows/flow-status.sh"
    assert_file_exists "$temp_root/home/.claude/templates/plan-template.md"
    assert_file_exists "$temp_root/home/.claude/templates/review-template.md"
    [ -x "$temp_root/home/.claude/workflows/flow-change.sh" ] || fail "Expected flow-change.sh to be executable"
    assert_contains "$temp_root/install.out" "Installed AI Flow"
    assert_contains "$temp_root/install.out" "skipped sync"
    rm -rf "$temp_root"
}

test_syncs_onespace_when_directory_exists() {
    local temp_root onespace
    temp_root=$(make_temp_root)
    onespace="$temp_root/onespace"
    mkdir -p "$onespace"

    HOME="$temp_root/home" ONSPACE_DIR="$onespace" "$TEST_ROOT/install.sh" > "$temp_root/install.out"

    assert_file_exists "$onespace/ai-flow-plan/SKILL.md"
    assert_file_exists "$onespace/flow-change.sh"
    assert_file_exists "$onespace/flow-state.sh"
    assert_file_exists "$onespace/review-template.md"
    [ -x "$onespace/flow-change.sh" ] || fail "Expected OneSpace flow-change.sh to be executable"
    assert_contains "$temp_root/install.out" "Synced AI Flow"
    rm -rf "$temp_root"
}

test_installs_claude_layout
test_syncs_onespace_when_directory_exists
