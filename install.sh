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
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_AGENTS_DIR="${CODEX_AGENTS_DIR:-$CODEX_HOME/agents}"
CODEX_SKILLS_DIR="${CODEX_SKILLS_DIR:-$HOME/.agents/skills}"
CODEX_LEGACY_SKILLS_DIR="${CODEX_LEGACY_SKILLS_DIR:-$CODEX_HOME/skills}"
ONSPACE_ROOT="${ONSPACE_DIR:-$HOME/.config/onespace}"
ONSPACE_SKILLS_DIR="${ONSPACE_SKILLS_DIR:-$ONSPACE_ROOT/skills/local_state/models/claude}"
ONSPACE_SUBAGENTS_CLAUDE_DIR="${ONSPACE_SUBAGENTS_CLAUDE_DIR:-$ONSPACE_ROOT/subagents/local_state/models/claude}"
ONSPACE_SKILLS_CODEX_DIR="${ONSPACE_SKILLS_CODEX_DIR:-$ONSPACE_ROOT/skills/local_state/models/codex}"
ONSPACE_SUBAGENTS_CODEX_DIR="${ONSPACE_SUBAGENTS_CODEX_DIR:-$ONSPACE_ROOT/subagents/local_state/models/codex}"
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
    local target_dir
    [ -f "$source_dir/SKILL.md" ] || return 0
    copy_tree "$source_dir" "$destination_root"
    target_dir="$destination_root/$(basename "$source_dir")"
    if [ -d "$SUBAGENT_SHARED_LIB_DIR" ]; then
        mkdir -p "$target_dir/lib"
        cp -R "$SUBAGENT_SHARED_LIB_DIR"/. "$target_dir/lib"/
    fi
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

install_codex_agent_file() {
    local source_file="$1"
    local destination_root="$2"
    local target_file
    [ -f "$source_file" ] || return 0
    mkdir -p "$destination_root"
    target_file="$destination_root/$(basename "$source_file")"
    cp "$source_file" "$target_file"
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

    if [ -d "$SUBAGENT_SHARED_LIB_DIR" ]; then
        mkdir -p "$destination_root/lib"
        cp -R "$SUBAGENT_SHARED_LIB_DIR"/. "$destination_root/lib"/
    fi

    if [ -d "$destination_root/scripts" ]; then
        find "$destination_root/scripts" -type f -name "*.sh" -exec chmod +x {} +
    fi
    if [ -d "$destination_root/lib" ]; then
        find "$destination_root/lib" -type f -name "*.sh" -exec chmod +x {} +
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

append_marked_guidance() {
    local source_file="$1"
    local target_file="$2"
    local marker_begin="$3"
    local marker_end="$4"
    local target_label="$5"

    [ -f "$source_file" ] || return 0
    mkdir -p "$(dirname "$target_file")"

    if [ ! -f "$target_file" ]; then
        {
            echo "$marker_begin"
            cat "$source_file"
            echo "$marker_end"
        } > "$target_file"
        echo "Installed AI Flow guidance to $target_label"
        return 0
    fi

    if grep -qF "$marker_begin" "$target_file" 2>/dev/null; then
        echo "AI Flow guidance already installed in $target_label, skipped"
        return 0
    fi

    if [ -s "$target_file" ] && [ -n "$(tail -c 1 "$target_file")" ]; then
        echo "" >> "$target_file"
    fi
    {
        echo ""
        echo "$marker_begin"
        cat "$source_file"
        echo "$marker_end"
    } >> "$target_file"
    echo "Synced AI Flow guidance to $target_label"
}

sync_codex_agents_md() {
    append_marked_guidance \
        "$ROOT_DIR/CLAUDE.md" \
        "$CODEX_HOME/AGENTS.md" \
        "<!-- AI-FLOW-GUIDANCE:BEGIN -->" \
        "<!-- AI-FLOW-GUIDANCE:END -->" \
        "$CODEX_HOME/AGENTS.md"
}

# --- Phase 1: Remove all previously installed AI Flow files ---

# Backup existing setting.json before wiping AI_FLOW_HOME
_ai_flow_setting_backup=""
if [ -f "$AI_FLOW_HOME/setting.json" ]; then
    _ai_flow_setting_backup="$(mktemp)"
    cp "$AI_FLOW_HOME/setting.json" "$_ai_flow_setting_backup"
fi

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
for skill_dir in "$CODEX_SKILLS_DIR"/ai-flow-*; do
    [ -e "$skill_dir" ] || continue
    rm -rf "$skill_dir"
done
for skill_dir in "$CODEX_LEGACY_SKILLS_DIR"/ai-flow-*; do
    [ -e "$skill_dir" ] || continue
    rm -rf "$skill_dir"
done
for skill_dir in "$ONSPACE_SKILLS_CODEX_DIR"/ai-flow-*; do
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
for agent_file in "$CODEX_AGENTS_DIR"/ai-flow-*.toml; do
    [ -e "$agent_file" ] || continue
    rm -f "$agent_file"
done
for agent_file in "$ONSPACE_SUBAGENTS_CODEX_DIR"/ai-flow-*.toml; do
    [ -e "$agent_file" ] || continue
    rm -f "$agent_file"
done

# Remove legacy root entries
remove_legacy_root_entries "$ONSPACE_SKILLS_DIR"

# Remove old runtime
rm -rf "$AI_FLOW_HOME"

# --- Phase 2: Reinstall from scratch ---

mkdir -p "$CLAUDE_SKILLS_DIR" "$CLAUDE_AGENTS_DIR" "$CODEX_SKILLS_DIR" "$CODEX_LEGACY_SKILLS_DIR" "$CODEX_AGENTS_DIR"

for skill_dir in "$ROOT_DIR"/skills/*; do
    [ -d "$skill_dir" ] || continue
    install_skill_dir "$skill_dir" "$CLAUDE_SKILLS_DIR"
    install_skill_dir "$skill_dir" "$CODEX_SKILLS_DIR"
    install_skill_dir "$skill_dir" "$CODEX_LEGACY_SKILLS_DIR"
done

echo "Installed AI Flow to $CLAUDE_HOME"
echo "Installed AI Flow Codex skills to $CODEX_SKILLS_DIR and $CODEX_LEGACY_SKILLS_DIR"

mkdir -p "$ONSPACE_SKILLS_DIR" "$ONSPACE_SUBAGENTS_CLAUDE_DIR" "$ONSPACE_SKILLS_CODEX_DIR" "$ONSPACE_SUBAGENTS_CODEX_DIR"
remove_legacy_root_entries "$ONSPACE_SKILLS_DIR"
for skill_dir in "$ROOT_DIR"/skills/*; do
    [ -d "$skill_dir" ] || continue
    install_skill_dir "$skill_dir" "$ONSPACE_SKILLS_DIR"
    install_skill_dir "$skill_dir" "$ONSPACE_SKILLS_CODEX_DIR"
done
echo "Synced AI Flow skills to $ONSPACE_SKILLS_DIR"
echo "Synced AI Flow Codex skills to $ONSPACE_SKILLS_CODEX_DIR"

install_runtime_root "$ROOT_DIR/runtime" "$AI_FLOW_HOME"
echo "Installed AI Flow runtime to $AI_FLOW_HOME"

# Restore or create setting.json
if [ -n "$_ai_flow_setting_backup" ] && [ -f "$_ai_flow_setting_backup" ]; then
    cp "$_ai_flow_setting_backup" "$AI_FLOW_HOME/setting.json"
    rm -f "$_ai_flow_setting_backup"
    echo "Restored setting.json to $AI_FLOW_HOME"
elif [ ! -f "$AI_FLOW_HOME/setting.json" ]; then
    mkdir -p "$AI_FLOW_HOME"
    cp "$ROOT_DIR/subagents/shared/setting.json.template" "$AI_FLOW_HOME/setting.json"
    echo "Created default setting.json at $AI_FLOW_HOME"
fi

# Install rule.yaml template for user reference
if [ ! -f "$AI_FLOW_HOME/rule.yaml" ]; then
    mkdir -p "$AI_FLOW_HOME"
    cp "$ROOT_DIR/subagents/shared/rule.yaml.template" "$AI_FLOW_HOME/rule.yaml"
    echo "Created default rule.yaml at $AI_FLOW_HOME"
fi

for agent_dir in "$ROOT_DIR"/subagents/*; do
    [ -d "$agent_dir" ] || continue
    install_subagent_dir "$agent_dir" "$CLAUDE_AGENTS_DIR"
    install_subagent_dir "$agent_dir" "$ONSPACE_SUBAGENTS_CLAUDE_DIR"
done

for agent_file in "$ROOT_DIR"/codex/agents/*.toml; do
    [ -f "$agent_file" ] || continue
    install_codex_agent_file "$agent_file" "$CODEX_AGENTS_DIR"
    install_codex_agent_file "$agent_file" "$ONSPACE_SUBAGENTS_CODEX_DIR"
done

echo "Installed AI Flow subagents to $CLAUDE_AGENTS_DIR"
echo "Synced AI Flow subagents to $ONSPACE_SUBAGENTS_CLAUDE_DIR"
echo "Installed AI Flow Codex agents to $CODEX_AGENTS_DIR"
echo "Synced AI Flow Codex agents to $ONSPACE_SUBAGENTS_CODEX_DIR"

# --- Phase 3: Sync CLAUDE.md ---

sync_claude_md
sync_codex_agents_md
