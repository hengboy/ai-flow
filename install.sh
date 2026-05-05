#!/bin/bash
# install.sh — install AI Flow skills, workflows, and templates.

set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
ONSPACE_DIR="${ONSPACE_DIR:-$HOME/.config/onespace/skills/local_state/models/claude}"

install_skill() {
    local name="$1"
    local source="$ROOT_DIR/skills/${name}.md"
    local target_dir="$CLAUDE_HOME/skills/$name"
    mkdir -p "$target_dir"
    cp "$source" "$target_dir/SKILL.md"
}

mkdir -p "$CLAUDE_HOME/workflows" "$CLAUDE_HOME/templates"

install_skill "ai-flow-plan"
install_skill "ai-flow-execute"
install_skill "ai-flow-review"
install_skill "ai-flow-status"
install_skill "ai-flow-change"

cp "$ROOT_DIR"/workflows/*.sh "$CLAUDE_HOME/workflows/"
chmod +x "$CLAUDE_HOME"/workflows/*.sh
cp "$ROOT_DIR"/templates/*.md "$CLAUDE_HOME/templates/"

echo "Installed AI Flow to $CLAUDE_HOME"

if [ -d "$ONSPACE_DIR" ]; then
    mkdir -p "$ONSPACE_DIR/ai-flow-plan" "$ONSPACE_DIR/ai-flow-execute" "$ONSPACE_DIR/ai-flow-review" "$ONSPACE_DIR/ai-flow-status" "$ONSPACE_DIR/ai-flow-change"
    cp "$ROOT_DIR/skills/ai-flow-plan.md" "$ONSPACE_DIR/ai-flow-plan/SKILL.md"
    cp "$ROOT_DIR/skills/ai-flow-execute.md" "$ONSPACE_DIR/ai-flow-execute/SKILL.md"
    cp "$ROOT_DIR/skills/ai-flow-review.md" "$ONSPACE_DIR/ai-flow-review/SKILL.md"
    cp "$ROOT_DIR/skills/ai-flow-status.md" "$ONSPACE_DIR/ai-flow-status/SKILL.md"
    cp "$ROOT_DIR/skills/ai-flow-change.md" "$ONSPACE_DIR/ai-flow-change/SKILL.md"
    cp "$ROOT_DIR"/workflows/*.sh "$ONSPACE_DIR/"
    chmod +x "$ONSPACE_DIR"/*.sh
    cp "$ROOT_DIR"/templates/*.md "$ONSPACE_DIR/"
    echo "Synced AI Flow to $ONSPACE_DIR"
else
    echo "OneSpace directory not found, skipped sync: $ONSPACE_DIR"
fi
