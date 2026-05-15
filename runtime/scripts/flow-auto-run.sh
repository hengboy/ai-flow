#!/bin/bash
# flow-auto-run.sh — ai-flow-auto-run 的只读辅助脚本
# 用法:
#   flow-auto-run.sh list
#   flow-auto-run.sh resolve <slug或唯一关键词>
#   flow-auto-run.sh dirty <dated-slug>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_STATE_SH="$SCRIPT_DIR/flow-state.sh"

AUTO_RUN_ALLOWED_STATUSES=(
    "PLANNED"
    "IMPLEMENTING"
    "AWAITING_REVIEW"
    "REVIEW_FAILED"
    "FIXING_REVIEW"
    "DONE"
)

usage() {
    cat >&2 <<'EOF'
用法:
  flow-auto-run.sh list
  flow-auto-run.sh resolve <slug或唯一关键词>
  flow-auto-run.sh dirty <dated-slug>
EOF
    exit 1
}

fail() {
    echo "$1" >&2
    exit 1
}

resolve_flow_root() {
    local start candidate
    start="$(pwd)"
    candidate="$start"
    while true; do
        if [ -d "$candidate/.ai-flow/state" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        if [ "$candidate" = "/" ] || [ "$candidate" = "//" ]; then
            break
        fi
        local parent
        parent="$(cd "$candidate/.." 2>/dev/null && pwd)" || break
        if [ -z "$parent" ] || [ "$parent" = "$candidate" ]; then
            break
        fi
        candidate="$parent"
    done
    return 1
}

validate_dependencies() {
    [ -x "$FLOW_STATE_SH" ] || fail "错误: 缺少 flow-state 脚本: $FLOW_STATE_SH"
}

candidate_state_tsv() {
    local valid_list error_file warning slug path
    valid_list="$(mktemp)"
    trap 'rm -f "$valid_list"' RETURN

    shopt -s nullglob
    for path in "$STATE_DIR"/*.json; do
        slug="$(basename "$path" .json)"
        error_file="$(mktemp)"
        if bash "$FLOW_STATE_SH" validate "$slug" >/dev/null 2>"$error_file"; then
            printf '%s\n' "$path" >>"$valid_list"
        else
            warning="$(tr '\n' ' ' <"$error_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
            echo "跳过无效状态文件 ${slug}: ${warning:-validate 失败}" >&2
        fi
        rm -f "$error_file"
    done
    shopt -u nullglob

    python3 - "$valid_list" <<'PY'
import json
import sys
from pathlib import Path

allowed = {
    "PLANNED",
    "IMPLEMENTING",
    "AWAITING_REVIEW",
    "REVIEW_FAILED",
    "FIXING_REVIEW",
    "DONE",
}

paths = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
items = []
for raw_path in paths:
    state = json.loads(Path(raw_path).read_text(encoding="utf-8"))
    status = str(state.get("current_status") or "")
    if status not in allowed:
        continue
    items.append(
        {
            "slug": str(state.get("slug") or Path(raw_path).stem),
            "status": status,
            "title": str(state.get("title") or ""),
            "updated_at": str(state.get("updated_at") or ""),
            "plan_file": str(state.get("plan_file") or ""),
        }
    )

items.sort(key=lambda item: item["updated_at"], reverse=True)
for item in items:
    print(
        "\t".join(
            [
                item["slug"],
                item["status"],
                item["title"],
                item["updated_at"],
                item["plan_file"],
            ]
        )
    )
PY
}

resolve_candidate_slug() {
    local query="$1"
    local candidate_tsv candidate_file
    candidate_tsv="$(candidate_state_tsv)"
    [ -n "$candidate_tsv" ] || fail "当前项目没有可自动编排的 flow 候选。"
    candidate_file="$(mktemp)"
    printf '%s\n' "$candidate_tsv" >"$candidate_file"
    trap 'rm -f "$candidate_file"' RETURN

    python3 - "$query" "$candidate_file" <<'PY'
import sys
from pathlib import Path

query = sys.argv[1].strip()
if not query:
    raise SystemExit("resolve 需要提供 slug 或唯一关键词")

rows = []
for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    slug, status, title, updated_at, plan_file = line.split("\t", 4)
    rows.append(
        {
            "slug": slug,
            "status": status,
            "title": title,
            "updated_at": updated_at,
            "plan_file": plan_file,
        }
    )

exact = [row for row in rows if row["slug"] == query]
if len(exact) == 1:
    print(exact[0]["slug"])
    raise SystemExit(0)

needle = query.lower()
matched = [
    row for row in rows
    if needle in row["slug"].lower()
    or needle in row["title"].lower()
    or needle in row["plan_file"].lower()
]

if not matched:
    raise SystemExit(f"找不到匹配 '{query}' 的可自动编排 flow。")
if len(matched) > 1:
    details = "、".join(f"{row['slug']}[{row['status']}]" for row in matched)
    raise SystemExit(f"匹配到多个 flow，请改用更精确的 slug: {details}")

print(matched[0]["slug"])
PY
}

state_scope_tsv() {
    local state_file="$1"
    python3 - "$state_file" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
scope = state.get("execution_scope") or {}
repos = scope.get("repos") or []
for repo in repos:
    print(
        "\t".join(
            [
                str(repo.get("id") or ""),
                str(repo.get("path") or ""),
                str(repo.get("git_root") or ""),
                str(repo.get("role") or ""),
            ]
        )
    )
PY
}

dirty_check() {
    local slug="$1"
    local state_file="$STATE_DIR/$slug.json"
    local error_file repo_count=0 dirty_lines="" repo_id repo_path git_root role changes filtered_count

    [ -f "$state_file" ] || fail "找不到状态文件: $state_file"

    error_file="$(mktemp)"
    if ! bash "$FLOW_STATE_SH" validate "$slug" >/dev/null 2>"$error_file"; then
        local warning
        warning="$(tr '\n' ' ' <"$error_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
        rm -f "$error_file"
        fail "状态文件无效: ${warning:-$slug}"
    fi
    rm -f "$error_file"

    while IFS=$'\t' read -r repo_id repo_path git_root role; do
        [ -n "$repo_id" ] || continue
        repo_count=$((repo_count + 1))
        REPO_IDS+=("$repo_id")
        REPO_PATHS+=("$repo_path")
        REPO_GIT_ROOTS+=("$git_root")
    done < <(state_scope_tsv "$state_file")

    [ "$repo_count" -gt 0 ] || fail "状态文件缺少 execution_scope.repos"

    local i
    for i in "${!REPO_IDS[@]}"; do
        repo_id="${REPO_IDS[$i]}"
        repo_path="${REPO_PATHS[$i]}"
        git_root="${REPO_GIT_ROOTS[$i]}"
        changes="$(git -C "$git_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
        filtered_count="$(printf '%s\n' "$changes" | awk -v repo_path="$repo_path" -v repo_count="$repo_count" '
            {
                path = substr($0, 4)
                if (path ~ /^\.ai-flow\//) {
                    next
                }
                if (repo_count > 1 && repo_path == ".") {
                    next
                }
                print path
            }
        ' | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
        if [ "${filtered_count:-0}" -gt 0 ]; then
            dirty_lines="${dirty_lines}${repo_id}\t${git_root}\t${filtered_count}\n"
        fi
    done

    if [ -n "$dirty_lines" ]; then
        printf 'dirty\n'
        printf '%b' "$dirty_lines"
    else
        printf 'clean\n'
    fi
}

validate_dependencies
PROJECT_DIR="$(resolve_flow_root)" || fail "当前目录不在包含 .ai-flow/state 的 flow root 内。"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
STATE_DIR="$FLOW_DIR/state"
[ -d "$STATE_DIR" ] || fail "当前项目缺少 .ai-flow/state 目录。"

declare -a REPO_IDS=()
declare -a REPO_PATHS=()
declare -a REPO_GIT_ROOTS=()

case "${1:-}" in
    list)
        [ $# -eq 1 ] || usage
        candidate_state_tsv
        ;;
    resolve)
        [ $# -eq 2 ] || usage
        resolve_candidate_slug "$2"
        ;;
    dirty)
        [ $# -eq 2 ] || usage
        dirty_check "$2"
        ;;
    *)
        usage
        ;;
esac
