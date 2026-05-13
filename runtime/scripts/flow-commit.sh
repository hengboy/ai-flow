#!/bin/bash
# flow-commit.sh — 按 AI Flow 约束提交代码

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
用法:
  flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] [--prepare-json]
                 [--message-map-json '<json>']

说明:
  --slug            绑定 AI Flow 状态；仅允许状态为 DONE
  --conflict-mode   冲突处理方式，默认 manual
  --prepare-json    只输出业务提交组与 diff 的 JSON，不执行提交
  --message-map-json
                    为每个 repo_id/group_id 提供外部生成的 commit message
EOF
}

resolve_flow_root() {
    local start
    local candidate
    start="$(pwd)"
    candidate="$start"
    local local_flow_root=""

    while true; do
        if [ -d "$candidate/.ai-flow/state" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        if [ -z "$local_flow_root" ] && [ -d "$candidate/.ai-flow" ]; then
            local_flow_root="$candidate"
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
    if [ -n "$local_flow_root" ]; then
        printf '%s' "$local_flow_root"
        return 0
    fi
    printf '%s' "$start"
    return 1
}

say() {
    [ "${PREPARE_JSON:-0}" -eq 1 ] && return 0
    echo ">>> $*"
}

current_git_root() {
    git rev-parse --show-toplevel 2>/dev/null || true
}

list_changed_paths() {
    local git_root="$1"
    git -C "$git_root" status --porcelain --untracked-files=all 2>/dev/null | awk '
        {
            path = substr($0, 4)
            if (path ~ /^\.ai-flow\//) {
                next
            }
            print path
        }
    ' | sed '/^$/d' | sort -u
}

has_changed_paths() {
    local git_root="$1"
    [ -n "$(list_changed_paths "$git_root")" ]
}

repo_has_conflicts() {
    local git_root="$1"
    [ -n "$(git -C "$git_root" diff --name-only --diff-filter=U 2>/dev/null || true)" ]
}

repo_has_rebase_in_progress() {
    local git_root="$1"
    [ -d "$git_root/.git/rebase-merge" ] || [ -d "$git_root/.git/rebase-apply" ]
}

default_verify_command() {
    printf 'git diff --check'
}

build_group_diff() {
    local git_root="$1"
    local files="$2"
    python3 - "$git_root" "$files" <<'PY'
import subprocess
import sys
from pathlib import Path

git_root = Path(sys.argv[1]).resolve()
files = [line.strip() for line in sys.argv[2].splitlines() if line.strip()]
chunks = []

def run_git(args, allow_statuses=(0,)):
    result = subprocess.run(
        ["git", "-C", str(git_root), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if result.returncode not in allow_statuses:
        raise SystemExit(result.stderr.strip() or "git diff 执行失败")
    return result.stdout

for path in files:
    tracked = subprocess.run(
        ["git", "-C", str(git_root), "ls-files", "--error-unmatch", "--", path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0
    if tracked:
        diff = run_git(["diff", "--no-color", "--unified=0", "--", path])
    else:
        abs_path = git_root / path
        diff = run_git(
            ["diff", "--no-index", "--no-color", "--unified=0", "--", "/dev/null", str(abs_path)],
            allow_statuses=(0, 1),
        )
    if diff.strip():
        chunks.append(diff.rstrip())

print("\n".join(chunks))
PY
}

resolve_conflicted_file_preserve_both() {
    local file_path="$1"
    python3 - "$file_path" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
out = []
i = 0
changed = False

while i < len(lines):
    line = lines[i]
    if not line.startswith("<<<<<<< "):
        out.append(line)
        i += 1
        continue

    changed = True
    ours = []
    theirs = []
    i += 1
    while i < len(lines) and not lines[i].startswith("======="):
        ours.append(lines[i])
        i += 1
    if i >= len(lines):
        raise SystemExit("冲突块缺少 ======= 分隔符")
    i += 1
    while i < len(lines) and not lines[i].startswith(">>>>>>> "):
        theirs.append(lines[i])
        i += 1
    if i >= len(lines):
        raise SystemExit("冲突块缺少 >>>>>>> 结束符")
    i += 1

    ours_text = "".join(ours)
    theirs_text = "".join(theirs)
    if ours_text == theirs_text:
        merged = ours_text
    else:
        merged = ours_text
        if merged and not merged.endswith("\n"):
            merged += "\n"
        if theirs_text:
            merged += theirs_text
    out.append(merged)

if changed:
    path.write_text("".join(out), encoding="utf-8")
PY
}

auto_resolve_conflicts() {
    local git_root="$1"
    local phase="$2"
    local files
    files="$(git -C "$git_root" diff --name-only --diff-filter=U 2>/dev/null || true)"
    [ -n "$files" ] || return 0

    say "[$git_root] 检测到冲突，按 auto 模式尝试保留本地与远程改动"
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        resolve_conflicted_file_preserve_both "$git_root/$file"
        git -C "$git_root" add -- "$file"
        say "[$git_root] 冲突文件已自动合并: $file (phase=$phase)"
    done <<< "$files"

    if repo_has_rebase_in_progress "$git_root"; then
        local attempts=0
        while repo_has_rebase_in_progress "$git_root"; do
            attempts=$((attempts + 1))
            if [ "$attempts" -gt 20 ]; then
                echo "自动解决冲突失败：rebase 轮次过多" >&2
                return 1
            fi
            set +e
            GIT_EDITOR=true git -C "$git_root" rebase --continue >/dev/null 2>&1
            local rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then
                continue
            fi
            if repo_has_conflicts "$git_root"; then
                files="$(git -C "$git_root" diff --name-only --diff-filter=U 2>/dev/null || true)"
                while IFS= read -r file; do
                    [ -n "$file" ] || continue
                    resolve_conflicted_file_preserve_both "$git_root/$file"
                    git -C "$git_root" add -- "$file"
                    say "[$git_root] 冲突文件已自动合并: $file (phase=$phase)"
                done <<< "$files"
                continue
            fi
            echo "自动解决冲突失败：无法继续 rebase" >&2
            return 1
        done
    fi
}

print_conflict_failure() {
    local git_root="$1"
    local phase="$2"
    local files
    files="$(git -C "$git_root" diff --name-only --diff-filter=U 2>/dev/null || true)"
    echo "[$git_root] ${phase} 阶段发生冲突，请用户选择手动解决或改用 --conflict-mode auto" >&2
    if [ -n "$files" ]; then
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            echo "  conflict: $file" >&2
        done <<< "$files"
    fi
}

run_repo_sync() {
    local git_root="$1"
    local conflict_mode="$2"
    local upstream=""
    local stash_name="ai-flow-commit-$(date +%s%N)"
    local stashed=0

    if has_changed_paths "$git_root"; then
        say "[$git_root] 暂存本地变更"
        git -C "$git_root" stash push -u -m "$stash_name" >/dev/null
        stashed=1
    fi

    upstream="$(git -C "$git_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [ -n "$upstream" ]; then
        local remote_name="${upstream%%/*}"
        say "[$git_root] 同步远程最新代码: $upstream"
        git -C "$git_root" fetch --quiet "$remote_name"
        set +e
        git -C "$git_root" rebase --quiet "$upstream" >/dev/null 2>&1
        local rebase_rc=$?
        set -e
        if [ "$rebase_rc" -ne 0 ]; then
            if repo_has_conflicts "$git_root"; then
                if [ "$conflict_mode" = "auto" ]; then
                    auto_resolve_conflicts "$git_root" "rebase" || return 1
                else
                    print_conflict_failure "$git_root" "rebase"
                    return 1
                fi
            else
                echo "[$git_root] rebase 失败" >&2
                return 1
            fi
        fi
    else
        say "[$git_root] 无上游分支，跳过远程同步"
    fi

    if [ "$stashed" -eq 1 ]; then
        say "[$git_root] 恢复本地暂存变更"
        set +e
        git -C "$git_root" stash pop --index >/dev/null 2>&1
        local stash_rc=$?
        set -e
        if [ "$stash_rc" -ne 0 ]; then
            if repo_has_conflicts "$git_root"; then
                if [ "$conflict_mode" = "auto" ]; then
                    auto_resolve_conflicts "$git_root" "stash-pop" || return 1
                else
                    print_conflict_failure "$git_root" "stash-pop"
                    return 1
                fi
            else
                echo "[$git_root] 恢复 stash 失败" >&2
                return 1
            fi
        fi
    fi

    git -C "$git_root" reset >/dev/null 2>&1 || true
}

write_commit_message_from_map() {
    local map_json="$1"
    local repo_id="$2"
    local group_id="$3"
    local output_file="$4"
    python3 - "$map_json" "$repo_id" "$group_id" "$output_file" <<'PY'
import json
import re
import sys
from pathlib import Path

map_json = sys.argv[1]
repo_id = sys.argv[2]
group_id = sys.argv[3]
output_file = Path(sys.argv[4])

try:
    payload = json.loads(map_json)
except json.JSONDecodeError as exc:
    raise SystemExit(f"message-map-json 不是合法 JSON: {exc}")

if not isinstance(payload, dict):
    raise SystemExit("message-map-json 顶层必须是对象")

repo_payload = payload.get(repo_id)
if not isinstance(repo_payload, dict):
    raise SystemExit(f"message-map-json 缺少 repo_id={repo_id} 的 message")

group_payload = repo_payload.get(group_id)
if not isinstance(group_payload, dict):
    raise SystemExit(f"message-map-json 缺少 repo_id={repo_id} group_id={group_id} 的 message")

subject = group_payload.get("subject")
body = group_payload.get("body", [])
footer = group_payload.get("footer", [])

if not isinstance(subject, str) or not subject.strip():
    raise SystemExit(f"{repo_id}/{group_id} 的 subject 不能为空")
subject = subject.strip()

subject_pattern = re.compile(
    r"^:(sparkles|bug|memo|art|recycle|zap|white_check_mark|package|construction_worker|wrench|rewind): "
    r"(添加|修复|更新|调整|重构|优化|补充|回滚).+"
)
if "完成" in subject:
    raise SystemExit(f"{repo_id}/{group_id} 的 subject 禁止包含“完成”")
if len(subject) > 50:
    raise SystemExit(f"{repo_id}/{group_id} 的 subject 超过 50 个字符")
if not subject_pattern.match(subject):
    raise SystemExit(
        f"{repo_id}/{group_id} 的 subject 格式不合法；动词只允许："
        "添加/修复/更新/调整/重构/优化/补充/回滚"
    )

if isinstance(body, str):
    body = [line.strip() for line in body.splitlines() if line.strip()]
if not isinstance(body, list) or any(not isinstance(line, str) for line in body):
    raise SystemExit(f"{repo_id}/{group_id} 的 body 必须是字符串数组")
body = [line.strip() for line in body if line.strip()]
if len(body) > 2:
    raise SystemExit(f"{repo_id}/{group_id} 的 body 最多 2 行")
if any(len(line) > 30 for line in body):
    raise SystemExit(f"{repo_id}/{group_id} 的 body 单行不能超过 30 个字符")

if isinstance(footer, str):
    footer = [line.strip() for line in footer.splitlines() if line.strip()]
if not isinstance(footer, list) or any(not isinstance(line, str) for line in footer):
    raise SystemExit(f"{repo_id}/{group_id} 的 footer 必须是字符串数组")
footer = [line.strip() for line in footer if line.strip()]
footer_pattern = re.compile(r"^(Refs|Fixes) #\d+$")
if any(not footer_pattern.match(line) for line in footer):
    raise SystemExit(f"{repo_id}/{group_id} 的 footer 存在非法格式")

parts = [subject]
if body:
    parts.append("")
    parts.extend(body)
if footer:
    parts.append("")
    parts.extend(footer)

output_file.write_text("\n".join(parts) + "\n", encoding="utf-8")
PY
}

print_commit_list() {
    local lines="$1"
    [ -n "$lines" ] || return 0
    echo ""
    echo ">>> 本次提交结果："
    while IFS=$'\t' read -r repo_id commit_hash subject; do
        [ -n "$repo_id" ] || continue
        echo "    - [$repo_id] $commit_hash $subject"
    done <<< "$lines"
}

run_verify_command() {
    local git_root="$1"
    local command="$2"
    say "[$git_root] 运行验证: $command"
    (
        cd "$git_root"
        bash -lc "$command"
    )
}

STATE_SLUG=""
CONFLICT_MODE="manual"
PREPARE_JSON=0
MESSAGE_MAP_JSON=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --slug)
            [ $# -ge 2 ] || { usage >&2; exit 1; }
            STATE_SLUG="$2"
            shift 2
            ;;
        --conflict-mode)
            [ $# -ge 2 ] || { usage >&2; exit 1; }
            CONFLICT_MODE="$2"
            shift 2
            ;;
        --prepare-json)
            PREPARE_JSON=1
            shift
            ;;
        --message-map-json)
            [ $# -ge 2 ] || { usage >&2; exit 1; }
            MESSAGE_MAP_JSON="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

case "$CONFLICT_MODE" in
    manual|auto) ;;
    *)
        echo "--conflict-mode 只允许 manual 或 auto" >&2
        exit 1
        ;;
esac

FLOW_ROOT="$(resolve_flow_root)" || true
PROJECT_DIR="$FLOW_ROOT"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
CURRENT_GIT_ROOT="$(current_git_root)"

PROTOCOL_RESULT="failed"
PROTOCOL_SCOPE="standalone"
PROTOCOL_SLUG="none"
PROTOCOL_REPOS="0"
PROTOCOL_COMMITS="0"
PROTOCOL_NEXT="none"
PROTOCOL_SUMMARY=""
PROTOCOL_FAILED_REPO=""
PROTOCOL_FAILED_GROUP=""
PROTOCOL_CONFLICT_MODE="$CONFLICT_MODE"
PROTOCOL_DETAIL=""
COMMIT_LOG_LINES=""
MESSAGE_FILES_TO_CLEAN=()

finish_protocol() {
    echo "RESULT: $PROTOCOL_RESULT"
    echo "AGENT: ai-flow-git-commit"
    echo "SCOPE: $PROTOCOL_SCOPE"
    echo "SLUG: $PROTOCOL_SLUG"
    echo "REPOS: $PROTOCOL_REPOS"
    echo "COMMITS: $PROTOCOL_COMMITS"
    echo "NEXT: $PROTOCOL_NEXT"
    echo "SUMMARY: $PROTOCOL_SUMMARY"
    [ -n "$PROTOCOL_FAILED_REPO" ] && echo "FAILED_REPO: $PROTOCOL_FAILED_REPO"
    [ -n "$PROTOCOL_FAILED_GROUP" ] && echo "FAILED_GROUP: $PROTOCOL_FAILED_GROUP"
    [ -n "$PROTOCOL_CONFLICT_MODE" ] && echo "CONFLICT_MODE: $PROTOCOL_CONFLICT_MODE"
    [ -n "$PROTOCOL_DETAIL" ] && echo "DETAIL: $PROTOCOL_DETAIL"
    return 0
}

fail_protocol() {
    local summary="$1"
    PROTOCOL_RESULT="failed"
    PROTOCOL_SUMMARY="$summary"
    finish_protocol
    exit 1
}

if [ -z "$CURRENT_GIT_ROOT" ]; then
    fail_protocol "当前目录不在 Git 仓库内，无法提交代码。"
fi

CONTEXT_FILE="$(mktemp)"
cleanup() {
    rm -f "$CONTEXT_FILE"
    if [ "${#MESSAGE_FILES_TO_CLEAN[@]}" -gt 0 ]; then
        local message_file
        for message_file in "${MESSAGE_FILES_TO_CLEAN[@]}"; do
            [ -n "$message_file" ] && rm -f "$message_file"
        done
    fi
}
trap cleanup EXIT

if [ -n "$STATE_SLUG" ]; then
    PROTOCOL_SCOPE="bound"
    PROTOCOL_SLUG="$STATE_SLUG"
    STATE_FILE="$FLOW_DIR/state/$STATE_SLUG.json"
    [ -f "$STATE_FILE" ] || fail_protocol "找不到 slug=$STATE_SLUG 对应的状态文件。"
    PLAN_FILE_REL="$(python3 - "$STATE_FILE" <<'PY'
import json
import sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(state.get("plan_file", ""))
print(state.get("current_status", ""))
PY
)"
    PLAN_FILE="$(printf '%s\n' "$PLAN_FILE_REL" | sed -n '1p')"
    PLAN_STATUS="$(printf '%s\n' "$PLAN_FILE_REL" | sed -n '2p')"
    [ "$PLAN_STATUS" = "DONE" ] || fail_protocol "当前状态为 [$PLAN_STATUS]，只有 DONE 允许提交。"
    case "$PLAN_FILE" in
        /*) ;;
        *) PLAN_FILE="$PROJECT_DIR/$PLAN_FILE" ;;
    esac
    [ -f "$PLAN_FILE" ] || fail_protocol "找不到 plan 文件：$PLAN_FILE"

    python3 - "$STATE_FILE" "$PLAN_FILE" >"$CONTEXT_FILE" <<'PY'
import json
import re
import sys
from collections import defaultdict, deque
from pathlib import Path

state_file = Path(sys.argv[1])
plan_file = Path(sys.argv[2])
state = json.loads(state_file.read_text(encoding="utf-8"))
plan = plan_file.read_text(encoding="utf-8")
repos = state.get("execution_scope", {}).get("repos", [])
if not repos:
    raise SystemExit("state execution_scope.repos 为空")

repo_by_id = {item["id"]: item for item in repos}
repo_order = [item["id"] for item in repos]

def extract_section_table(text: str, needle: str):
    lines = text.splitlines()
    in_section = False
    table = []
    for line in lines:
        if line.startswith("##") or line.startswith("###"):
            if needle in line:
                in_section = True
                table = []
                continue
            if in_section:
                break
        if in_section and line.startswith("|"):
            table.append(line)
    if len(table) < 3:
        return None
    rows = []
    for raw in table[2:]:
        cells = [cell.strip() for cell in raw.strip().strip("|").split("|")]
        if len(cells) >= 2 and any(cells):
            rows.append(cells)
    return rows

dependency_rows = extract_section_table(plan, "跨仓依赖表")
edges = []
if dependency_rows:
    for row in dependency_rows:
        if len(row) < 2:
            continue
        before, after = row[0], row[1]
        if before in repo_by_id and after in repo_by_id and before != after:
            edges.append((before, after))

if edges:
    graph = defaultdict(list)
    indegree = {repo_id: 0 for repo_id in repo_order}
    for before, after in edges:
        graph[before].append(after)
        indegree[after] += 1
    queue = deque([repo_id for repo_id in repo_order if indegree[repo_id] == 0])
    sorted_ids = []
    while queue:
        current = queue.popleft()
        sorted_ids.append(current)
        for nxt in graph[current]:
            indegree[nxt] -= 1
            if indegree[nxt] == 0:
                queue.append(nxt)
    if len(sorted_ids) != len(repo_order):
        raise SystemExit("跨仓依赖存在环，无法自动决定提交顺序")
    repo_order = sorted_ids

file_boundary_rows = extract_section_table(plan, "文件边界总览") or []
path_to_repo = {}
path_to_steps = defaultdict(set)
for row in file_boundary_rows:
    if len(row) < 5:
        continue
    path = row[0].strip().strip("`")
    repo_id = row[1].strip()
    step_ref = row[4].strip()
    if path:
        path_to_repo[path] = repo_id if repo_id in repo_by_id else "owner"
    if path and step_ref:
        path_to_steps[path].add(step_ref)

step_pattern = re.compile(r"^### Step (\d+): (.+)$", re.M)
matches = list(step_pattern.finditer(plan))
groups_by_repo = defaultdict(list)
for idx, match in enumerate(matches):
    step_no = match.group(1)
    title = match.group(2).strip()
    start = match.end()
    end = matches[idx + 1].start() if idx + 1 < len(matches) else len(plan)
    section = plan[start:end]
    files = []
    for file_match in re.finditer(r"^- (?:Create|Modify|Test): `([^`]+)`", section, re.M):
        files.append(file_match.group(1).strip())
    verify_match = re.search(r"命令：`([^`]+)`", section)
    verify = verify_match.group(1).strip() if verify_match else ""
    repo_files = defaultdict(list)
    for path in files:
        if path.startswith("tests/") or "/tests/" in path:
            continue
        repo_id = path_to_repo.get(path, "owner")
        repo_files[repo_id].append(path)
    for repo_id, repo_files_list in repo_files.items():
        groups_by_repo[repo_id].append({
            "id": f"step-{step_no}",
            "title": title,
            "verify_command": verify,
            "files": sorted(dict.fromkeys(repo_files_list)),
        })

payload = {
    "repo_order": repo_order,
    "used_dependency_table": bool(edges),
    "repos": [{
        **repo_by_id[repo_id],
        "groups": groups_by_repo.get(repo_id, []),
    } for repo_id in repo_order],
}
print(json.dumps(payload, ensure_ascii=False))
PY
else
    PROTOCOL_SCOPE="standalone"
    python3 - "$CURRENT_GIT_ROOT" >"$CONTEXT_FILE" <<'PY'
import json
import sys
from pathlib import Path

git_root = Path(sys.argv[1]).resolve()
payload = {
    "repo_order": ["owner"],
    "used_dependency_table": False,
    "repos": [{
        "id": "owner",
        "path": ".",
        "git_root": str(git_root),
        "role": "owner",
        "groups": [],
    }],
}
print(json.dumps(payload, ensure_ascii=False))
PY
fi

REPO_IDS=()
REPO_PATHS=()
REPO_GIT_ROOTS=()
REPO_ROLES=()
USED_DEP_TABLE="0"
while IFS=$'\t' read -r repo_id repo_path repo_git_root repo_role used_dep; do
    [ -n "$repo_id" ] || continue
    REPO_IDS+=("$repo_id")
    REPO_PATHS+=("$repo_path")
    REPO_GIT_ROOTS+=("$repo_git_root")
    REPO_ROLES+=("$repo_role")
    USED_DEP_TABLE="$used_dep"
done < <(
    python3 - "$CONTEXT_FILE" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
used_dep = "1" if payload.get("used_dependency_table") else "0"
for repo in payload.get("repos", []):
    print("\t".join([
        repo.get("id", ""),
        repo.get("path", ""),
        repo.get("git_root", ""),
        repo.get("role", ""),
        used_dep,
    ]))
PY
)

[ ${#REPO_IDS[@]} -gt 0 ] || fail_protocol "未解析到可提交的仓库。"
PROTOCOL_REPOS="${#REPO_IDS[@]}"

if [ "$PREPARE_JSON" -eq 0 ] && [ -z "$MESSAGE_MAP_JSON" ]; then
    fail_protocol "缺少 --message-map-json，无法执行提交。"
fi

if [ "$PROTOCOL_SCOPE" = "bound" ]; then
    if [ "$USED_DEP_TABLE" = "1" ]; then
        say "按跨仓依赖顺序提交涉及仓库"
    else
        say "plan 未声明跨仓依赖表，按 execution_scope.repos 顺序提交"
    fi
fi

COMMIT_COUNT=0
PREPARED_GROUPS_JSON=""
for repo_index in "${!REPO_IDS[@]}"; do
    repo_id="${REPO_IDS[$repo_index]}"
    repo_git_root="${REPO_GIT_ROOTS[$repo_index]}"
    repo_role="${REPO_ROLES[$repo_index]}"

    [ -d "$repo_git_root/.git" ] || fail_protocol "仓库不存在或不是有效 Git 仓库：$repo_git_root"
    say "处理仓库 [$repo_id] ($repo_role): $repo_git_root"

    run_repo_sync "$repo_git_root" "$CONFLICT_MODE" || {
        PROTOCOL_FAILED_REPO="$repo_id"
        PROTOCOL_DETAIL="同步远程或恢复 stash 时发生冲突"
        fail_protocol "仓库 [$repo_id] 同步远程失败。"
    }

    changed_paths="$(list_changed_paths "$repo_git_root")"
    if [ -z "$changed_paths" ]; then
        say "[$repo_id] 无待提交变更，跳过"
        continue
    fi

    GROUPS_FILE="$(mktemp)"
    GROUPS_ERR_FILE="$(mktemp)"
    set +e
    python3 - "$CONTEXT_FILE" "$repo_id" "$PROTOCOL_SCOPE" "$repo_git_root" >"$GROUPS_FILE" 2>"$GROUPS_ERR_FILE" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

payload = json.load(open(sys.argv[1], encoding="utf-8"))
repo_id = sys.argv[2]
scope = sys.argv[3]
git_root = Path(sys.argv[4]).resolve()
repo = None
for item in payload.get("repos", []):
    if item.get("id") == repo_id:
        repo = item
        break
if repo is None:
    raise SystemExit("repo not found")

result = subprocess.run(
    ["git", "-C", str(git_root), "status", "--porcelain", "--untracked-files=all"],
    capture_output=True,
    text=True,
    timeout=10,
    check=False,
)
changed = []
for line in result.stdout.splitlines():
    if len(line) < 4:
        continue
    path = line[3:].strip()
    if not path or path.startswith(".ai-flow/"):
        continue
    changed.append(path)
changed = sorted(dict.fromkeys(changed))

if scope == "bound" and repo.get("path") == ".":
    participant_paths = []
    for item in payload.get("repos", []):
        item_path = (item.get("path") or "").strip()
        if not item_path or item_path == ".":
            continue
        participant_paths.append(item_path.rstrip("/"))
    if participant_paths:
        filtered = []
        for path in changed:
            skip = False
            for prefix in participant_paths:
                if path == prefix or path.startswith(prefix + "/"):
                    skip = True
                    break
            if not skip:
                filtered.append(path)
        changed = filtered

groups = []
if scope == "bound":
    parsed_groups = repo.get("groups", [])
    if not parsed_groups:
        non_ai_flow_changed = [path for path in changed if not path.startswith(".ai-flow/")]
        if not non_ai_flow_changed:
            print(json.dumps([], ensure_ascii=False))
            raise SystemExit(0)
        raise SystemExit("计划无法映射当前仓库变更到业务分组")
    if len(parsed_groups) == 1:
        only = dict(parsed_groups[0])
        only["files"] = changed
        if not only.get("verify_command"):
            only["verify_command"] = ""
        groups.append(only)
    else:
        used_files = set()
        for group in parsed_groups:
            group_files = sorted([path for path in changed if path in set(group.get("files", []))])
            if group_files:
                current = dict(group)
                current["files"] = group_files
                groups.append(current)
                overlap = used_files.intersection(group_files)
                if overlap:
                    raise SystemExit(f"文件被多个业务分组命中: {sorted(overlap)[0]}")
                used_files.update(group_files)
        unknown = sorted(set(changed) - used_files)
        if unknown:
            raise SystemExit(f"存在无法映射到业务分组的变更: {unknown[0]}")
else:
    structural_roots = {
        "src", "lib", "app", "apps", "pkg", "packages", "scripts", "script",
        "tests", "test", "docs", "doc", ".github", "config", "configs",
        "bin", "cmd", "internal"
    }
    support_roots = {"tests", "test", "docs", "doc", ".github"}
    support_extensions = (".md", ".json", ".yaml", ".yml", ".toml", ".lock")
    generic_tokens = {
        "src", "lib", "app", "apps", "pkg", "packages", "scripts", "script",
        "tests", "test", "doc", "docs", "github", "workflow", "workflows",
        "readme", "changelog", "ci", "config", "configs", "internal", "cmd", "bin"
    }

    def classify_path(path):
        parts = Path(path).parts
        top = parts[0] if parts else path
        is_support = top in support_roots or (len(parts) == 1 and top.endswith(support_extensions))
        return top, parts, is_support

    def tokens_for_path(path):
        tokens = []
        for part in Path(path).parts:
            source = part
            if "." in part and not part.startswith("."):
                source = Path(part).stem
            normalized = source.replace(".", "-").replace("_", "-")
            for token in normalized.split("-"):
                token = token.strip().lower()
                if not token or token in generic_tokens:
                    continue
                if token.isdigit():
                    continue
                tokens.append(token)
        return set(tokens)

    def primary_token(path):
        top, parts, _ = classify_path(path)
        tokens = tokens_for_path(path)
        preferred_parts = []
        if top in structural_roots and len(parts) > 1:
            preferred_parts.append(parts[1])
        preferred_parts.extend(parts[2:])
        preferred_parts.append(Path(path).stem)
        for part in preferred_parts:
            source = part
            if "." in part and not part.startswith("."):
                source = Path(part).stem
            normalized = source.replace(".", "-").replace("_", "-")
            for token in normalized.split("-"):
                token = token.strip().lower()
                if token and token not in generic_tokens and not token.isdigit():
                    return token
        if tokens:
            return sorted(tokens)[0]
        if top in structural_roots and len(parts) > 1:
            return Path(parts[1]).stem.lower()
        return top.lower()

    def is_related(left, right):
        left_top, _, left_support = classify_path(left)
        right_top, _, right_support = classify_path(right)
        left_tokens = tokens_for_path(left)
        right_tokens = tokens_for_path(right)
        shared_tokens = left_tokens.intersection(right_tokens)
        if shared_tokens:
            return True
        if left_support and right_support:
            return True
        if left_top == right_top and left_top not in structural_roots:
            return True
        return False

    primary_files = []
    support_files = []
    for path in changed:
        _, _, is_support = classify_path(path)
        if is_support:
            support_files.append(path)
        else:
            primary_files.append(path)

    if not primary_files:
        title = changed[0].split("/", 1)[0]
        groups.append({
            "id": "standalone-1",
            "title": title,
            "verify_command": "",
            "files": changed,
        })
        print(json.dumps(groups, ensure_ascii=False))
        raise SystemExit(0)

    primary_tops = {classify_path(path)[0] for path in primary_files}
    if primary_tops and all(top in structural_roots for top in primary_tops):
        files = sorted(dict.fromkeys(primary_files + support_files))
        titles = []
        for path in primary_files:
            token = primary_token(path)
            if token and token not in titles:
                titles.append(token)
        title = " + ".join(titles[:3]) if titles else primary_files[0].split("/", 1)[0]
        groups.append({
            "id": "standalone-1",
            "title": title,
            "verify_command": "",
            "files": files,
        })
        print(json.dumps(groups, ensure_ascii=False))
        raise SystemExit(0)

    parent = list(range(len(primary_files)))

    def find(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(left, right):
        left_root = find(left)
        right_root = find(right)
        if left_root != right_root:
            parent[right_root] = left_root

    for left in range(len(primary_files)):
        for right in range(left + 1, len(primary_files)):
            if is_related(primary_files[left], primary_files[right]):
                union(left, right)

    component_map = {}
    for index, path in enumerate(primary_files):
        component_map.setdefault(find(index), []).append(path)

    ordered_components = []
    for index, path in enumerate(primary_files):
        root = find(index)
        if root not in ordered_components and root in component_map:
            ordered_components.append(root)

    component_meta = []
    for component_root in ordered_components:
        files = sorted(dict.fromkeys(component_map[component_root]))
        component_tokens = set()
        for path in files:
            component_tokens.update(tokens_for_path(path))
        component_meta.append({
            "root": component_root,
            "files": files,
            "tokens": component_tokens,
        })

    for path in support_files:
        path_tokens = tokens_for_path(path)
        if len(component_meta) == 1:
            component_meta[0]["files"].append(path)
            continue
        scored = []
        for item in component_meta:
            score = len(item["tokens"].intersection(path_tokens))
            scored.append((score, len(item["files"]), item))
        scored.sort(key=lambda item: (-item[0], -item[1]))
        if scored and scored[0][0] > 0:
            scored[0][2]["files"].append(path)
        else:
            component_meta[0]["files"].append(path)

    for item in component_meta:
        files = sorted(dict.fromkeys(item["files"]))
        title_files = []
        for path in files:
            _, _, is_support = classify_path(path)
            if not is_support:
                title_files.append(path)
        if not title_files:
            title_files = files
        titles = []
        for path in title_files:
            token = primary_token(path)
            if token and token not in titles:
                titles.append(token)
        title = " + ".join(titles[:3]) if titles else files[0].split("/", 1)[0]
        groups.append({
            "id": f"standalone-{len(groups) + 1}",
            "title": title,
            "verify_command": "",
            "files": files,
        })

print(json.dumps(groups, ensure_ascii=False))
PY
    group_rc=$?
    set -e
    if [ "$group_rc" -ne 0 ]; then
        group_error="$(tr '\n' ' ' < "$GROUPS_ERR_FILE" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
        [ -n "$group_error" ] || group_error="仓库 [$repo_id] 无法生成业务分组。"
        rm -f "$GROUPS_FILE" "$GROUPS_ERR_FILE"
        PROTOCOL_FAILED_REPO="$repo_id"
        PROTOCOL_DETAIL="$group_error"
        fail_protocol "仓库 [$repo_id] 无法生成业务分组。"
    fi
    rm -f "$GROUPS_ERR_FILE"
    if [ ! -s "$GROUPS_FILE" ]; then
        rm -f "$GROUPS_FILE"
        PROTOCOL_FAILED_REPO="$repo_id"
        fail_protocol "仓库 [$repo_id] 无法生成业务分组。"
    fi

    if ! python3 - "$GROUPS_FILE" >/dev/null 2>&1 <<'PY'
import json
import sys
groups = json.load(open(sys.argv[1], encoding="utf-8"))
if groups is None:
    raise SystemExit(1)
PY
    then
        rm -f "$GROUPS_FILE"
        PROTOCOL_FAILED_REPO="$repo_id"
        fail_protocol "仓库 [$repo_id] 无法生成业务分组。"
    fi

    GROUP_COUNT="$(python3 - "$GROUPS_FILE" <<'PY'
import json
import sys
groups = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(groups))
PY
)"
    if [ "$GROUP_COUNT" = "0" ]; then
        say "[$repo_id] 无可提交业务分组，跳过"
        rm -f "$GROUPS_FILE"
        continue
    fi
    say "[$repo_id] 识别到 ${GROUP_COUNT} 个业务提交组"

    while IFS= read -r group_json; do
        [ -n "$group_json" ] || continue
        group_id="$(python3 - "$group_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("id", ""))
PY
)"
        [ -n "$group_id" ] || continue
        group_title="$(python3 - "$group_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("title", ""))
PY
)"
        verify_command="$(python3 - "$group_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("verify_command", ""))
PY
)"
        group_files="$(python3 - "$group_json" <<'PY'
import json
import sys
print("\n".join(json.loads(sys.argv[1]).get("files", [])))
PY
)"
        if [ -z "$group_files" ]; then
            continue
        fi
        group_diff="$(build_group_diff "$repo_git_root" "$group_files")"

        if [ "$PREPARE_JSON" -eq 1 ]; then
            entry_json="$(python3 - "$repo_id" "$repo_git_root" "$group_id" "$group_title" "$group_files" "$group_diff" <<'PY'
import json
import sys

repo_id = sys.argv[1]
repo_git_root = sys.argv[2]
group_id = sys.argv[3]
group_title = sys.argv[4]
files = [line for line in sys.argv[5].splitlines() if line]
group_diff = sys.argv[6]
print(json.dumps({
    "repo_id": repo_id,
    "repo_git_root": repo_git_root,
    "group_id": group_id,
    "group_title": group_title,
    "files": files,
    "staged_diff": group_diff,
}, ensure_ascii=False))
PY
)"
            PREPARED_GROUPS_JSON="${PREPARED_GROUPS_JSON}${entry_json}"$'\n'
            continue
        fi
        say "[$repo_id] 提交组 $group_id: $group_title"
        printf '%s\n' "$group_files" | sed 's/^/    file: /'
        verify_command="$(default_verify_command "$repo_git_root")"
        echo "    verify: $verify_command"

        git -C "$repo_git_root" reset >/dev/null 2>&1 || true
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            git -C "$repo_git_root" add -- "$file"
        done <<< "$group_files"

        run_verify_command "$repo_git_root" "$verify_command" || {
            rm -f "$GROUPS_FILE"
            PROTOCOL_FAILED_REPO="$repo_id"
            PROTOCOL_FAILED_GROUP="$group_id"
            PROTOCOL_DETAIL="验证失败"
            fail_protocol "提交组 [$group_title] 验证失败，已停止提交。"
        }

        message_file="$(mktemp)"
        MESSAGE_FILES_TO_CLEAN+=("$message_file")
        if ! write_commit_message_from_map "$MESSAGE_MAP_JSON" "$repo_id" "$group_id" "$message_file"; then
            rm -f "$message_file" "$GROUPS_FILE"
            PROTOCOL_FAILED_REPO="$repo_id"
            PROTOCOL_FAILED_GROUP="$group_id"
            PROTOCOL_DETAIL="commit message 无效或缺失"
            fail_protocol "提交组 [$group_title] 缺少合法的 commit message。"
        fi
        subject="$(sed -n '1p' "$message_file")"
        (
            cd "$repo_git_root"
            git commit -F "$message_file" >/dev/null
        ) || {
            rm -f "$message_file" "$GROUPS_FILE"
            PROTOCOL_FAILED_REPO="$repo_id"
            PROTOCOL_FAILED_GROUP="$group_id"
            PROTOCOL_DETAIL="git commit 失败"
            fail_protocol "提交组 [$group_title] 提交失败。"
        }
        rm -f "$message_file"
        if [ "${#MESSAGE_FILES_TO_CLEAN[@]}" -gt 0 ]; then
            filtered_message_files=()
            for existing_message_file in "${MESSAGE_FILES_TO_CLEAN[@]}"; do
                [ "$existing_message_file" = "$message_file" ] && continue
                filtered_message_files+=("$existing_message_file")
            done
            if [ "${#filtered_message_files[@]}" -gt 0 ]; then
                MESSAGE_FILES_TO_CLEAN=("${filtered_message_files[@]}")
            else
                MESSAGE_FILES_TO_CLEAN=()
            fi
        fi
        commit_hash="$(git -C "$repo_git_root" rev-parse --short HEAD)"
        echo "    committed: $commit_hash $subject"
        COMMIT_LOG_LINES="${COMMIT_LOG_LINES}${repo_id}"$'\t'"${commit_hash}"$'\t'"${subject}"$'\n'
        COMMIT_COUNT=$((COMMIT_COUNT + 1))
    done < <(
        python3 - "$GROUPS_FILE" <<'PY'
import json
import sys

groups = json.load(open(sys.argv[1], encoding="utf-8"))
for group in groups:
    print(json.dumps(group, ensure_ascii=False))
PY
    )

    rm -f "$GROUPS_FILE"
done

[ "$PREPARE_JSON" -eq 0 ] || {
    python3 - "$PREPARED_GROUPS_JSON" <<'PY'
import json
import sys

lines = [line for line in sys.argv[1].splitlines() if line.strip()]
print(json.dumps([json.loads(line) for line in lines], ensure_ascii=False))
PY
    exit 0
}

[ "$COMMIT_COUNT" -gt 0 ] || fail_protocol "没有可提交的业务分组变更。"

PROTOCOL_RESULT="success"
PROTOCOL_COMMITS="$COMMIT_COUNT"
if [ "$PROTOCOL_SCOPE" = "bound" ]; then
    PROTOCOL_SUMMARY="已按 AI Flow 提交 ${COMMIT_COUNT} 个业务提交组。"
else
    PROTOCOL_SUMMARY="已提交 ${COMMIT_COUNT} 个业务提交组。"
fi
print_commit_list "$COMMIT_LOG_LINES"
finish_protocol
