#!/bin/bash
# install.sh — install AI Flow skills plus shared runtime scripts/resources for Claude, OneSpace, and AI_FLOW_HOME.

set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
ONSPACE_DIR="${ONSPACE_DIR:-$HOME/.config/onespace/skills/local_state/models/claude}"
AI_FLOW_HOME="${AI_FLOW_HOME:-$HOME/.config/ai-flow}"

remove_legacy_claude_layout() {
    rm -rf "$CLAUDE_HOME/workflows" "$CLAUDE_HOME/templates"
}

remove_legacy_onespace_root_entries() {
    local legacy_entry
    for legacy_entry in \
        "codex-plan.sh" \
        "codex-review.sh" \
        "opencode-review.sh" \
        "flow-change.sh" \
        "flow-state.sh" \
        "flow-status.sh" \
        "plan-template.md" \
        "review-template.md"
    do
        rm -rf "$ONSPACE_DIR/$legacy_entry"
    done
}

install_skill_dir() {
    local source_dir="$1"
    local destination_root="$2"
    local name
    local target_dir

    name="$(basename "$source_dir")"
    target_dir="$destination_root/$name"
    [ -f "$source_dir/SKILL.md" ] || return 0

    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    cp -R "$source_dir"/. "$target_dir"/
    if [ -d "$target_dir/scripts" ]; then
        find "$target_dir/scripts" -type f -name "*.sh" -exec chmod +x {} +
    fi
}

install_runtime_root() {
    local source_root="$1"
    local destination_root="$2"
    local entry
    local name

    [ -d "$source_root" ] || return 0
    mkdir -p "$destination_root"

    for entry in "$source_root"/*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        rm -rf "$destination_root/$name"
        mkdir -p "$destination_root/$name"
        cp -R "$entry"/. "$destination_root/$name"/
    done

    if [ -d "$destination_root/scripts" ]; then
        find "$destination_root/scripts" -type f -name "*.sh" -exec chmod +x {} +
    fi
}

mkdir -p "$CLAUDE_HOME/skills"
remove_legacy_claude_layout

for skill_dir in "$ROOT_DIR"/skills/*; do
    [ -d "$skill_dir" ] || continue
    install_skill_dir "$skill_dir" "$CLAUDE_HOME/skills"
done

echo "Installed AI Flow to $CLAUDE_HOME"

mkdir -p "$ONSPACE_DIR"
remove_legacy_onespace_root_entries
for skill_dir in "$ROOT_DIR"/skills/*; do
    [ -d "$skill_dir" ] || continue
    install_skill_dir "$skill_dir" "$ONSPACE_DIR"
done
echo "Synced AI Flow to $ONSPACE_DIR"

install_runtime_root "$ROOT_DIR/runtime" "$AI_FLOW_HOME"
echo "Installed AI Flow runtime to $AI_FLOW_HOME"
