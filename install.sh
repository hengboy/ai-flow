#!/bin/bash
# install.sh — install AI Flow skills, runtime, and subagents.

set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBAGENT_SHARED_LIB_DIR="$ROOT_DIR/subagents/shared/lib"
SUBAGENT_SHARED_PLAN_DIR="$ROOT_DIR/subagents/shared/plan"
SUBAGENT_SHARED_PLAN_REVIEW_DIR="$ROOT_DIR/subagents/shared/plan-review"
SUBAGENT_SHARED_CODING_REVIEW_DIR="$ROOT_DIR/subagents/shared/coding-review"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
AI_FLOW_HOME="${AI_FLOW_HOME:-$HOME/.config/ai-flow}"
CLAUDE_SKILLS_DIR="$CLAUDE_HOME/skills"
CLAUDE_AGENTS_DIR="${CLAUDE_AGENTS_DIR:-$CLAUDE_HOME/agents}"
ONSPACE_SKILLS_DIR="${ONSPACE_SKILLS_DIR:-${ONSPACE_DIR:-$HOME/.config/onespace/skills/local_state/models/claude}}"
ONSPACE_SUBAGENTS_CLAUDE_DIR="${ONSPACE_SUBAGENTS_CLAUDE_DIR:-$HOME/.config/onespace/subagents/local_state/models/claude}"
remove_legacy_claude_layout() {
    rm -rf "$CLAUDE_HOME/workflows" "$CLAUDE_HOME/templates"
}

remove_legacy_root_entries() {
    local root="$1"
    local legacy_entry
    for legacy_entry in \
        "codex-plan.sh" \
        "codex-review.sh" \
        "flow-change.sh" \
        "flow-state.sh" \
        "flow-status.sh" \
        "plan-template.md" \
        "review-template.md"
    do
        rm -rf "$root/$legacy_entry"
    done
}

copy_tree() {
    local source_dir="$1"
    local destination_root="$2"
    local name
    local target_dir

    name="$(basename "$source_dir")"
    target_dir="$destination_root/$name"

    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    cp -R "$source_dir"/. "$target_dir"/
    if [ -d "$target_dir/scripts" ]; then
        find "$target_dir/scripts" -type f -name "*.sh" -exec chmod +x {} +
    fi
    if [ -d "$target_dir/bin" ]; then
        find "$target_dir/bin" -type f -name "*.sh" -exec chmod +x {} +
    fi
}

overlay_tree_contents() {
    local source_dir="$1"
    local target_dir="$2"
    local entry
    local name

    [ -d "$source_dir" ] || return 0
    mkdir -p "$target_dir"
    for entry in "$source_dir"/*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        # Shared lib is installed separately as a real directory. Skip overlaying
        # any role-specific lib symlink so macOS cp does not try to replace it.
        [ "$name" = "lib" ] && continue
        cp -R "$entry" "$target_dir"/
    done
    if [ -d "$target_dir/scripts" ]; then
        find "$target_dir/scripts" -type f -name "*.sh" -exec chmod +x {} +
    fi
    if [ -d "$target_dir/bin" ]; then
        find "$target_dir/bin" -type f -name "*.sh" -exec chmod +x {} +
    fi
}

install_skill_dir() {
    local source_dir="$1"
    local destination_root="$2"
    [ -f "$source_dir/SKILL.md" ] || return 0
    copy_tree "$source_dir" "$destination_root"
}

install_subagent_dir() {
    local source_dir="$1"
    local destination_root="$2"
    local target_dir
    local agent_name
    [ -f "$source_dir/AGENT.md" ] || return 0
    copy_tree "$source_dir" "$destination_root"
    target_dir="$destination_root/$(basename "$source_dir")"
    agent_name="$(basename "$source_dir")"
    if [ -d "$SUBAGENT_SHARED_LIB_DIR" ]; then
        mkdir -p "$target_dir/lib"
        cp -R "$SUBAGENT_SHARED_LIB_DIR"/. "$target_dir/lib"/
    fi
    case "$agent_name" in
        ai-flow-*-plan-review)
            overlay_tree_contents "$SUBAGENT_SHARED_PLAN_DIR" "$target_dir"
            overlay_tree_contents "$SUBAGENT_SHARED_PLAN_REVIEW_DIR" "$target_dir"
            ;;
        ai-flow-*-plan-coding-review)
            overlay_tree_contents "$SUBAGENT_SHARED_CODING_REVIEW_DIR" "$target_dir"
            ;;
        ai-flow-*-plan)
            overlay_tree_contents "$SUBAGENT_SHARED_PLAN_DIR" "$target_dir"
            ;;
    esac
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

sync_claude_md() {
    local project_claude_md="$ROOT_DIR/CLAUDE.md"
    local global_claude_md="$CLAUDE_HOME/CLAUDE.md"

    # Skip if project CLAUDE.md doesn't exist
    [ -f "$project_claude_md" ] || return 0

    # If global CLAUDE.md doesn't exist, copy the entire project file
    if [ ! -f "$global_claude_md" ]; then
        mkdir -p "$CLAUDE_HOME"
        cp "$project_claude_md" "$global_claude_md"
        echo "Installed CLAUDE.md to $CLAUDE_HOME"
        return 0
    fi

    # Check if behavior guidelines are already synced (use "# 行为准则" as marker)
    if grep -q "# 行为准则" "$global_claude_md" 2>/dev/null; then
        echo "CLAUDE.md 行为准则已安装，跳过"
        return 0
    fi

    # Append entire project CLAUDE.md content to global file
    # Ensure global file ends with a newline before appending
    if [ -n "$(tail -c 1 "$global_claude_md")" ]; then
        echo "" >> "$global_claude_md"
    fi
    echo "" >> "$global_claude_md"
    cat "$project_claude_md" >> "$global_claude_md"
    echo "已同步行为准则到 $global_claude_md"
}

# --- Phase 1: Remove all previously installed AI Flow files ---

remove_legacy_claude_layout

# Remove all AI Flow skills from all target roots
for skill_dir in "$CLAUDE_SKILLS_DIR"/ai-flow-*; do
    [ -e "$skill_dir" ] || continue
    rm -rf "$skill_dir"
done
for skill_dir in "$ONSPACE_SKILLS_DIR"/ai-flow-*; do
    [ -e "$skill_dir" ] || continue
    rm -rf "$skill_dir"
done

# Remove all AI Flow subagents from all target roots
for agent_dir in "$CLAUDE_AGENTS_DIR"/ai-flow-*; do
    [ -e "$agent_dir" ] || continue
    rm -rf "$agent_dir"
done
for agent_dir in "$ONSPACE_SUBAGENTS_CLAUDE_DIR"/ai-flow-*; do
    [ -e "$agent_dir" ] || continue
    rm -rf "$agent_dir"
done

# Remove legacy root entries
remove_legacy_root_entries "$ONSPACE_SKILLS_DIR"

# Remove old runtime
rm -rf "$AI_FLOW_HOME"

# --- Phase 2: Reinstall from scratch ---

mkdir -p "$CLAUDE_SKILLS_DIR" "$CLAUDE_AGENTS_DIR"

for skill_dir in "$ROOT_DIR"/skills/*; do
    [ -d "$skill_dir" ] || continue
    install_skill_dir "$skill_dir" "$CLAUDE_SKILLS_DIR"
done

echo "Installed AI Flow to $CLAUDE_HOME"

mkdir -p "$ONSPACE_SKILLS_DIR" "$ONSPACE_SUBAGENTS_CLAUDE_DIR"
remove_legacy_root_entries "$ONSPACE_SKILLS_DIR"
for skill_dir in "$ROOT_DIR"/skills/*; do
    [ -d "$skill_dir" ] || continue
    install_skill_dir "$skill_dir" "$ONSPACE_SKILLS_DIR"
done
echo "Synced AI Flow skills to $ONSPACE_SKILLS_DIR"

install_runtime_root "$ROOT_DIR/runtime" "$AI_FLOW_HOME"
echo "Installed AI Flow runtime to $AI_FLOW_HOME"

for agent_dir in "$ROOT_DIR"/subagents/*; do
    [ -d "$agent_dir" ] || continue
    install_subagent_dir "$agent_dir" "$CLAUDE_AGENTS_DIR"
    install_subagent_dir "$agent_dir" "$ONSPACE_SUBAGENTS_CLAUDE_DIR"
done

echo "Installed AI Flow subagents to $CLAUDE_AGENTS_DIR"
echo "Synced AI Flow subagents to $ONSPACE_SUBAGENTS_CLAUDE_DIR"

# --- Phase 3: Sync CLAUDE.md ---

sync_claude_md
