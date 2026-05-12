#!/bin/bash
# workspace-common.sh — shared workspace helpers for subagent executors
# Source this file: source "$AGENT_DIR/lib/workspace-common.sh"
# Depends on: agent-common.sh (for emit_protocol, display_path, etc.)

# ─── Workspace root resolution ───

resolve_workspace_root() {
    local start="${1:-$(pwd)}"
    local candidate
    candidate="$start"
    while [ ! -d "$candidate" ]; do
        candidate="${candidate%/*}"
        [ -n "$candidate" ] || return 1
    done
    while true; do
        if [ -f "$candidate/.ai-flow/workspace.json" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        local parent
        parent="${candidate%/*}"
        if [ -z "$parent" ]; then
            parent="/"
        fi
        if [ "$parent" = "$candidate" ]; then
            break
        fi
        candidate="$parent"
    done
    return 1
}

resolve_workspace_repo_membership() {
    local workspace_root="$1"
    local target_path="${2:-$(pwd)}"
    local manifest="$workspace_root/.ai-flow/workspace.json"
    if [ ! -f "$manifest" ]; then
        return 1
    fi

    python3 - "$manifest" "$workspace_root" "$target_path" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1]).resolve()
workspace_root = Path(sys.argv[2]).resolve()
target_path = Path(sys.argv[3]).resolve()
data = json.loads(manifest_path.read_text(encoding="utf-8"))

for repo in data.get("repos", []):
    repo_id = repo.get("id")
    repo_path = repo.get("path")
    if not repo_id or not repo_path:
        continue
    repo_root = (workspace_root / repo_path).resolve()
    try:
        target_path.relative_to(repo_root)
    except ValueError:
        continue
    print(f"{repo_id}\t{repo_path}")
    sys.exit(0)

sys.exit(1)
PY
}

is_workspace_mode() {
    [ -f "$(pwd)/.ai-flow/workspace.json" ]
}

has_workspace_manifest() {
    local workspace_root="${1:-$(pwd)}"
    [ -f "$workspace_root/.ai-flow/workspace.json" ]
}

# ─── Manifest loading ───

load_workspace_manifest() {
    local workspace_root="${1:-$(pwd)}"
    local manifest="$workspace_root/.ai-flow/workspace.json"
    if [ ! -f "$manifest" ]; then
        return 1
    fi
    cat "$manifest"
}

workspace_manifest_field() {
    local manifest_json="$1"
    local field="$2"
    python3 - "$field" "$manifest_json" <<'PY'
import json, sys
data = json.loads(sys.argv[2])
value = data
for part in sys.argv[1].split("."):
    if isinstance(value, dict):
        value = value.get(part)
    elif isinstance(value, list) and part.isdigit():
        value = value[int(part)] if 0 <= int(part) < len(value) else None
    else:
        value = None
        break
if value is None:
    sys.exit(1)
if isinstance(value, str):
    print(value)
else:
    print(json.dumps(value, ensure_ascii=False))
PY
}

# ─── Repo enumeration ───

list_scope_repos() {
    local workspace_root="${1:-$(pwd)}"
    local manifest="$workspace_root/.ai-flow/workspace.json"
    [ -f "$manifest" ] || return 1
    python3 - "$manifest" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for repo in data.get("repos", []):
    print(f"{repo['id']}\t{repo['path']}")
PY
}

# ─── Per-repo Git operations ───

git_in_scope_repo() {
    local workspace_root="$1"
    local repo_path="$2"
    shift 2
    git -C "$workspace_root/$repo_path" "$@"
}

validate_scope_repo_git() {
    local workspace_root="$1"
    local repo_path="$2"
    if ! git -C "$workspace_root/$repo_path" rev-parse --show-toplevel >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

collect_repo_changes() {
    local workspace_root="$1"
    local repo_path="$2"
    git_in_scope_repo "$workspace_root" "$repo_path" status --porcelain --untracked-files=all
}
