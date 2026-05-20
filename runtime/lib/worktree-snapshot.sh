#!/bin/bash
# worktree-snapshot.sh — shared helpers for normalizing reviewed worktree state.

ai_flow_status_lines_for_repo() {
    local git_root="$1"
    local repo_path="$2"
    local repo_count="$3"

    git -C "$git_root" status --porcelain --untracked-files=all 2>/dev/null | awk -v repo_path="$repo_path" -v repo_count="$repo_count" '
        {
            path = substr($0, 4)
            if (path ~ /^\.ai-flow\//) {
                next
            }
            if (repo_count > 1 && repo_path == ".") {
                next
            }
            print
        }
    '
}

ai_flow_collect_worktree_snapshot_json() {
    if [ $# -lt 3 ] || [ $(( $# % 3 )) -ne 0 ]; then
        echo "ai_flow_collect_worktree_snapshot_json 需要按 <repo_id> <repo_path> <git_root> 三元组传参" >&2
        return 1
    fi

    local repo_count=$(( $# / 3 ))
    local snapshot_rows=""
    local repo_id repo_path git_root raw_lines

    while [ $# -gt 0 ]; do
        repo_id="$1"
        repo_path="$2"
        git_root="$3"
        shift 3

        raw_lines="$(ai_flow_status_lines_for_repo "$git_root" "$repo_path" "$repo_count")"
        if [ -n "$raw_lines" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                snapshot_rows="${snapshot_rows}${repo_id}"$'\t'"${line}"$'\n'
            done <<<"$raw_lines"
        else
            snapshot_rows="${snapshot_rows}${repo_id}"$'\n'
        fi
    done

    SNAPSHOT_ROWS="$snapshot_rows" python3 - <<'PY'
import json
import os

rows = os.environ.get("SNAPSHOT_ROWS", "").splitlines()
repos: dict[str, list[dict[str, object]]] = {}

for row in rows:
    if not row:
        continue
    if "\t" not in row:
        repos.setdefault(row, [])
        continue
    repo_id, status_line = row.split("\t", 1)
    repos.setdefault(repo_id, [])
    if len(status_line) < 4:
        continue
    status = status_line[:2]
    path = status_line[3:]
    normalized_status = status.strip()
    tokens = [normalized_status] if normalized_status else []
    repos[repo_id].append({"path": path, "tokens": tokens or [status.strip()]})

payload = {
    "repos": [
        {
            "repo_id": repo_id,
            "entries": sorted(entries, key=lambda item: item["path"]),
        }
        for repo_id, entries in sorted(repos.items(), key=lambda item: item[0])
    ]
}
json.dump(payload, os.sys.stdout, ensure_ascii=False, separators=(",", ":"))
PY
}
