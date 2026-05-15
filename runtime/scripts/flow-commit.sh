#!/bin/bash
# flow-commit.sh — 按 AI Flow 约束提交代码

set -euo pipefail

PREPARE_CONTEXT_CHAR_BUDGET=120000
MAX_GROUPS_PER_REPO=5

usage() {
    cat <<'EOF'
用法:
  flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --prepare-json
  flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --validate-groups-json '<json>'
  flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --groups-json '<json>' --message-map-json '<json>'

说明:
  --slug                  绑定 AI Flow 状态；仅允许状态为 DONE
  --conflict-mode         冲突处理方式，默认 manual
  --prepare-json          输出 repo 级分组上下文，不执行提交
  --validate-groups-json  校验模型返回的分组并补全 group_id/staged_diff
  --groups-json           提供已校验分组结果
  --message-map-json      为每个 repo_id/group_id 提供外部生成的 commit message
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
    [ "${QUIET_STDOUT:-0}" -eq 1 ] && return 0
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

build_repo_file_diffs_json() {
    local git_root="$1"
    local files="$2"
    python3 - "$git_root" "$files" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

git_root = Path(sys.argv[1]).resolve()
files = [line.strip() for line in sys.argv[2].splitlines() if line.strip()]

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

items = []
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
    items.append({
        "path": path,
        "diff": diff.rstrip(),
    })

print(json.dumps(items, ensure_ascii=False))
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
            set +e
            git -C "$git_root" stash pop >/dev/null 2>&1
            stash_rc=$?
            set -e
        fi

        if [ "$stash_rc" -ne 0 ]; then
            if repo_has_conflicts "$git_root"; then
                if [ "$conflict_mode" = "auto" ]; then
                    auto_resolve_conflicts "$git_root" "stash-pop" || return 1
                    git -C "$git_root" stash drop >/dev/null 2>&1 || true
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

session_store_dir() {
    printf '%s' "${AI_FLOW_SESSION_DIR:-$HOME/.config/ai-flow/tmp/flow-commit-sessions}"
}

ensure_session_store_dir() {
    mkdir -p "$(session_store_dir)"
}

generate_session_id() {
    python3 - <<'PY'
import uuid
print(uuid.uuid4().hex)
PY
}

json_sha256() {
    local json_payload="$1"
    python3 - "$json_payload" <<'PY'
import hashlib
import json
import sys

payload = json.loads(sys.argv[1])
canonical = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
PY
}

session_file_path() {
    local session_id="$1"
    printf '%s/%s.json' "$(session_store_dir)" "$session_id"
}

extract_json_field() {
    local json_payload="$1"
    local field_name="$2"
    python3 - "$json_payload" "$field_name" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
value = payload.get(sys.argv[2], "")
if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

persist_prepare_session_record() {
    local session_id="$1"
    local prepare_payload_json="$2"
    local repo_state_json="$3"
    local context_hash="$4"
    local output_json="$5"
    local session_file
    session_file="$(session_file_path "$session_id")"
    python3 - "$session_file" "$session_id" "$prepare_payload_json" "$repo_state_json" "$context_hash" "$output_json" <<'PY'
import json
import sys
from pathlib import Path

session_file = Path(sys.argv[1])
session_id = sys.argv[2]
prepare_payload = json.loads(sys.argv[3])
repo_state = json.loads(sys.argv[4])
context_hash = sys.argv[5]
output_payload = json.loads(sys.argv[6])

record = {
    "session_id": session_id,
    "prepare_context_hash": context_hash,
    "prepare_payload": prepare_payload,
    "repo_state": repo_state,
    "validated_payload": None,
    "validated_groups_hash": "",
}
session_file.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
print(json.dumps(output_payload, ensure_ascii=False))
PY
}

load_session_record_json() {
    local session_id="$1"
    local session_file
    session_file="$(session_file_path "$session_id")"
    [ -f "$session_file" ] || return 1
    cat "$session_file"
}

store_validated_session_payload() {
    local session_id="$1"
    local validated_payload_json="$2"
    local validated_groups_hash="$3"
    local output_json="$4"
    local session_file
    session_file="$(session_file_path "$session_id")"
    python3 - "$session_file" "$validated_payload_json" "$validated_groups_hash" "$output_json" <<'PY'
import json
import sys
from pathlib import Path

session_file = Path(sys.argv[1])
if not session_file.is_file():
    raise SystemExit("prepare session 不存在或已过期")
record = json.loads(session_file.read_text(encoding="utf-8"))
validated_payload = json.loads(sys.argv[2])
validated_groups_hash = sys.argv[3]
output_payload = json.loads(sys.argv[4])
record["validated_payload"] = validated_payload
record["validated_groups_hash"] = validated_groups_hash
session_file.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
print(json.dumps(output_payload, ensure_ascii=False))
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

filter_changed_paths_for_repo() {
    local context_file="$1"
    local repo_id="$2"
    local paths="$3"
    python3 - "$context_file" "$repo_id" "$paths" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
repo_id = sys.argv[2]
paths = [line.strip() for line in sys.argv[3].splitlines() if line.strip()]

repo = None
for item in payload.get("repos", []):
    if item.get("id") == repo_id:
        repo = item
        break

if repo is None:
    raise SystemExit("repo not found")

scope = payload.get("scope")
if scope == "bound" and (repo.get("path") or "").strip() == ".":
    participant_paths = []
    for item in payload.get("repos", []):
        path = (item.get("path") or "").strip()
        if not path or path == ".":
            continue
        participant_paths.append(path.rstrip("/"))
    if participant_paths:
        filtered = []
        for path in paths:
            skip = False
            for prefix in participant_paths:
                if path == prefix or path.startswith(prefix + "/"):
                    skip = True
                    break
            if not skip:
                filtered.append(path)
        paths = filtered

for path in paths:
    print(path)
PY
}

repo_plan_context_json() {
    local context_file="$1"
    local repo_id="$2"
    python3 - "$context_file" "$repo_id" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
repo_id = sys.argv[2]
for repo in payload.get("repos", []):
    if repo.get("id") == repo_id:
        print(json.dumps(repo.get("plan_context", {}), ensure_ascii=False))
        raise SystemExit(0)
print("{}")
PY
}

collect_repo_change_state() {
    local context_file="$1"
    local sync_mode="$2"
    local output_file="$3"
    local repo_entries=""

    while IFS=$'\t' read -r repo_id repo_path repo_git_root repo_role; do
        [ -n "$repo_id" ] || continue
        if [ ! -d "$repo_git_root/.git" ]; then
            if [ "$repo_role" = "owner" ]; then
                say "[$repo_id] 根目录非 Git 仓库，跳过该仓库的 Git 操作"
                continue
            fi
            echo "仓库不存在或不是有效 Git 仓库：$repo_git_root" >&2
            return 1
        fi

        if [ "$sync_mode" = "1" ]; then
            say "处理仓库 [$repo_id] ($repo_role): $repo_git_root"
            run_repo_sync "$repo_git_root" "$CONFLICT_MODE" || return 1
        fi

        local changed_paths
        changed_paths="$(list_changed_paths "$repo_git_root")"
        changed_paths="$(filter_changed_paths_for_repo "$context_file" "$repo_id" "$changed_paths")"
        if [ -z "$changed_paths" ]; then
            if [ "$sync_mode" = "1" ]; then
                say "[$repo_id] 无待提交变更，跳过"
            fi
            continue
        fi

        local repo_entry_json
        repo_entry_json="$(python3 - "$repo_id" "$repo_git_root" "$repo_role" "$changed_paths" <<'PY'
import json
import sys

repo_id = sys.argv[1]
repo_git_root = sys.argv[2]
repo_role = sys.argv[3]
changed_files = [line for line in sys.argv[4].splitlines() if line]
print(json.dumps({
    "repo_id": repo_id,
    "repo_git_root": repo_git_root,
    "role": repo_role,
    "changed_files": changed_files,
}, ensure_ascii=False))
PY
)"
        repo_entries="${repo_entries}${repo_entry_json}"$'\n'
    done < <(
        python3 - "$context_file" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
for repo in payload.get("repos", []):
    print("\t".join([
        repo.get("id", ""),
        repo.get("path", ""),
        repo.get("git_root", ""),
        repo.get("role", ""),
    ]))
PY
    )

    python3 - "$context_file" "$repo_entries" >"$output_file" <<'PY'
import json
import sys

context = json.load(open(sys.argv[1], encoding="utf-8"))
entries = [json.loads(line) for line in sys.argv[2].splitlines() if line.strip()]
print(json.dumps({
    "scope": context.get("scope"),
    "slug": context.get("slug"),
    "used_dependency_table": context.get("used_dependency_table", False),
    "repos": entries,
}, ensure_ascii=False))
PY
}

prepare_repo_context_json() {
    local context_file="$1"
    local repo_state_file="$2"
    python3 - "$context_file" "$repo_state_file" "$PREPARE_CONTEXT_CHAR_BUDGET" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

context = json.load(open(sys.argv[1], encoding="utf-8"))
repo_state = json.load(open(sys.argv[2], encoding="utf-8"))
budget = int(sys.argv[3])

repo_state_map = {item["repo_id"]: item for item in repo_state.get("repos", [])}

def run_git(git_root: Path, args, allow_statuses=(0,)):
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

def diff_for_path(git_root: Path, path: str) -> str:
    tracked = subprocess.run(
        ["git", "-C", str(git_root), "ls-files", "--error-unmatch", "--", path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0
    if tracked:
        diff = run_git(git_root, ["diff", "--no-color", "--unified=0", "--", path])
    else:
        diff = run_git(
            git_root,
            ["diff", "--no-index", "--no-color", "--unified=0", "--", "/dev/null", str(git_root / path)],
            allow_statuses=(0, 1),
        )
    return diff.rstrip()

repos = []
for repo in context.get("repos", []):
    repo_id = repo.get("id")
    current = repo_state_map.get(repo_id)
    if not current:
        continue
    git_root = Path(current["repo_git_root"]).resolve()
    changed_files = current.get("changed_files", [])
    file_diffs = []
    total_chars = 0
    for path in changed_files:
        diff = diff_for_path(git_root, path)
        total_chars += len(diff)
        file_diffs.append({
            "path": path,
            "diff": diff,
        })
    if total_chars > budget:
        raise SystemExit(f"repo_id={repo_id} 分组上下文过大，请先缩小本次提交范围。")
    repos.append({
        "repo_id": repo_id,
        "repo_git_root": current["repo_git_root"],
        "role": current["role"],
        "changed_files": changed_files,
        "file_diffs": file_diffs,
        "plan_context": repo.get("plan_context", {}),
    })

print(json.dumps({
    "scope": context.get("scope"),
    "slug": context.get("slug"),
    "used_dependency_table": context.get("used_dependency_table", False),
    "repos": repos,
}, ensure_ascii=False))
PY
}

validate_groups_json_payload() {
    local repo_state_file="$1"
    local groups_json="$2"
    python3 - "$repo_state_file" "$groups_json" "$MAX_GROUPS_PER_REPO" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

repo_state = json.load(open(sys.argv[1], encoding="utf-8"))
raw_groups_json = sys.argv[2]
max_groups = int(sys.argv[3])

def fail(message: str):
    raise SystemExit(message)

def parse_repo_list(raw: str):
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"groups-json 不是合法 JSON: {exc}")
    if isinstance(payload, dict):
        repos = payload.get("repos")
    elif isinstance(payload, list):
        repos = payload
    else:
        fail("groups-json 顶层必须是数组或包含 repos 的对象")
    if not isinstance(repos, list):
        fail("groups-json.repos 必须是数组")
    return repos

def run_git(git_root: Path, args, allow_statuses=(0,)):
    result = subprocess.run(
        ["git", "-C", str(git_root), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if result.returncode not in allow_statuses:
        fail(result.stderr.strip() or "git diff 执行失败")
    return result.stdout

def build_group_diff(git_root: Path, files):
    chunks = []
    for path in files:
        tracked = subprocess.run(
            ["git", "-C", str(git_root), "ls-files", "--error-unmatch", "--", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode == 0
        if tracked:
            diff = run_git(git_root, ["diff", "--no-color", "--unified=0", "--", path])
        else:
            diff = run_git(
                git_root,
                ["diff", "--no-index", "--no-color", "--unified=0", "--", "/dev/null", str(git_root / path)],
                allow_statuses=(0, 1),
            )
        if diff.strip():
            chunks.append(diff.rstrip())
    return "\n".join(chunks)

repo_order = [item["repo_id"] for item in repo_state.get("repos", [])]
repo_map = {item["repo_id"]: item for item in repo_state.get("repos", [])}
proposal_repos = parse_repo_list(raw_groups_json)
proposal_map = {}
for repo_entry in proposal_repos:
    if not isinstance(repo_entry, dict):
        fail("groups-json 的 repo 条目必须是对象")
    repo_id = repo_entry.get("repo_id")
    if not isinstance(repo_id, str) or not repo_id.strip():
        fail("groups-json 的 repo_id 不能为空")
    repo_id = repo_id.strip()
    if repo_id in proposal_map:
        fail(f"groups-json 存在重复 repo_id: {repo_id}")
    if repo_id not in repo_map:
        fail(f"分组结果包含未知 repo_id: {repo_id}")
    proposal_map[repo_id] = repo_entry

normalized_repos = []
for repo_id in repo_order:
    repo = repo_map[repo_id]
    changed_files = repo.get("changed_files", [])
    if not changed_files:
        if repo_id in proposal_map and proposal_map[repo_id].get("groups"):
            fail(f"repo_id={repo_id} 当前无变更，不应返回 group")
        continue

    repo_entry = proposal_map.get(repo_id)
    if repo_entry is None:
        fail(f"repo_id={repo_id} 至少需要 1 个 group")

    groups = repo_entry.get("groups")
    if not isinstance(groups, list):
        fail(f"repo_id={repo_id} 的 groups 必须是数组")
    if not groups:
        fail(f"repo_id={repo_id} 至少需要 1 个 group")
    if len(groups) > max_groups:
        fail(f"repo_id={repo_id} 分组数量超过上限 {max_groups}")

    changed_set = set(changed_files)
    assigned = set()
    normalized_groups = []
    for idx, group in enumerate(groups, start=1):
        if not isinstance(group, dict):
            fail(f"repo_id={repo_id} group[{idx}] 必须是对象")
        title = group.get("group_title")
        reason = group.get("reason")
        files = group.get("files")
        if not isinstance(title, str) or not title.strip():
            fail(f"repo_id={repo_id} group[{idx}] 缺少 group_title")
        if not isinstance(reason, str) or not reason.strip():
            fail(f"repo_id={repo_id} group[{idx}] 缺少 reason")
        if not isinstance(files, list) or not files:
            fail(f"repo_id={repo_id} group[{idx}] files 不能为空")
        current_files = []
        current_seen = set()
        for path in files:
            if not isinstance(path, str) or not path.strip():
                fail(f"repo_id={repo_id} group[{idx}] 含有非法文件路径")
            path = path.strip()
            if path not in changed_set:
                fail(f"repo_id={repo_id} 包含不属于当前仓库的文件: {path}")
            if path in current_seen:
                fail(f"repo_id={repo_id} group[{idx}] 内文件重复: {path}")
            if path in assigned:
                fail(f"repo_id={repo_id} 文件重复归组: {path}")
            current_seen.add(path)
            assigned.add(path)
            current_files.append(path)
        normalized_groups.append({
            "group_id": f"{repo_id}-{idx}",
            "group_title": title.strip(),
            "reason": reason.strip(),
            "files": current_files,
        })

    missing = [path for path in changed_files if path not in assigned]
    if missing:
        fail(f"repo_id={repo_id} 存在未分组文件: {missing[0]}")

    git_root = Path(repo["repo_git_root"]).resolve()
    enriched_groups = []
    for group in normalized_groups:
        group = dict(group)
        group["staged_diff"] = build_group_diff(git_root, group["files"])
        enriched_groups.append(group)

    normalized_repos.append({
        "repo_id": repo_id,
        "repo_git_root": repo["repo_git_root"],
        "role": repo["role"],
        "groups": enriched_groups,
    })

print(json.dumps({"repos": normalized_repos}, ensure_ascii=False))
PY
}

prepare_payload_with_session() {
    local session_id="$1"
    local prepare_payload_json="$2"
    python3 - "$session_id" "$prepare_payload_json" <<'PY'
import json
import sys

session_id = sys.argv[1]
payload = json.loads(sys.argv[2])
repos = []
for repo in payload.get("repos", []):
    repos.append({
        "repo_id": repo["repo_id"],
        "repo_git_root": repo["repo_git_root"],
        "role": repo["role"],
        "changed_files": repo["changed_files"],
        "file_diffs": repo["file_diffs"],
        "plan_context": repo.get("plan_context", {}),
        "group_agent_input": {
            "mode": "group",
            "session_id": session_id,
            "repo_id": repo["repo_id"],
            "repo_git_root": repo["repo_git_root"],
            "role": repo["role"],
            "changed_files": repo["changed_files"],
            "file_diffs": repo["file_diffs"],
            "plan_context": repo.get("plan_context", {}),
        },
    })
print(json.dumps({
    "session_id": session_id,
    "scope": payload.get("scope"),
    "slug": payload.get("slug"),
    "used_dependency_table": payload.get("used_dependency_table", False),
    "repos": repos,
}, ensure_ascii=False))
PY
}

validated_payload_with_session() {
    local session_id="$1"
    local validated_payload_json="$2"
    python3 - "$session_id" "$validated_payload_json" <<'PY'
import json
import sys

session_id = sys.argv[1]
payload = json.loads(sys.argv[2])
repos = []
for repo in payload.get("repos", []):
    groups = []
    for group in repo.get("groups", []):
        groups.append({
            "group_id": group["group_id"],
            "group_title": group["group_title"],
            "reason": group["reason"],
            "files": group["files"],
            "staged_diff": group["staged_diff"],
            "message_agent_input": {
                "mode": "message",
                "session_id": session_id,
                "repo_id": repo["repo_id"],
                "group_id": group["group_id"],
                "group_title": group["group_title"],
                "reason": group["reason"],
                "files": group["files"],
                "staged_diff": group["staged_diff"],
            },
        })
    repos.append({
        "repo_id": repo["repo_id"],
        "repo_git_root": repo["repo_git_root"],
        "role": repo["role"],
        "groups": groups,
    })
print(json.dumps({
    "session_id": session_id,
    "repos": repos,
}, ensure_ascii=False))
PY
}

validate_groups_json_for_session() {
    local session_json="$1"
    local groups_json="$2"
    local current_repo_state_json="$3"
    python3 - "$session_json" "$groups_json" "$current_repo_state_json" <<'PY'
import json
import sys

session = json.loads(sys.argv[1])
groups_payload = json.loads(sys.argv[2])
current_repo_state = json.loads(sys.argv[3])

saved_state = session.get("repo_state", {})
if saved_state != current_repo_state:
    raise SystemExit("prepare 之后工作区已变化，请重新执行 --prepare-json")

session_id = groups_payload.get("session_id")
if not isinstance(session_id, str) or not session_id.strip():
    raise SystemExit("groups-json 缺少 session_id")
if session_id != session.get("session_id"):
    raise SystemExit("groups-json 的 session_id 与 prepare 阶段不匹配")

repos = groups_payload.get("repos")
if not isinstance(repos, list):
    raise SystemExit("groups-json 顶层必须包含 repos 数组")

normalized = []
for repo in repos:
    if not isinstance(repo, dict):
        raise SystemExit("groups-json 的 repo 条目必须是对象")
    allowed_repo_keys = {"repo_id", "groups"}
    extra_keys = sorted(set(repo.keys()) - allowed_repo_keys)
    if extra_keys:
        raise SystemExit(f"groups-json repo 条目存在非法字段: {extra_keys[0]}")
    groups = repo.get("groups")
    if not isinstance(groups, list):
        raise SystemExit(f"repo_id={repo.get('repo_id', '')} 的 groups 必须是数组")
    clean_groups = []
    for idx, group in enumerate(groups, start=1):
        if not isinstance(group, dict):
            raise SystemExit(f"repo_id={repo.get('repo_id', '')} group[{idx}] 必须是对象")
        allowed_group_keys = {"group_title", "reason", "files"}
        extra_group_keys = sorted(set(group.keys()) - allowed_group_keys)
        if extra_group_keys:
            raise SystemExit(f"repo_id={repo.get('repo_id', '')} group[{idx}] 存在非法字段: {extra_group_keys[0]}")
        clean_groups.append({
            "group_title": group.get("group_title"),
            "reason": group.get("reason"),
            "files": group.get("files"),
        })
    normalized.append({
        "repo_id": repo.get("repo_id"),
        "groups": clean_groups,
    })

print(json.dumps({"repos": normalized}, ensure_ascii=False))
PY
}

normalize_commit_groups_json_for_session() {
    local session_json="$1"
    local groups_json="$2"
    local current_repo_state_json="$3"
    python3 - "$session_json" "$groups_json" "$current_repo_state_json" <<'PY'
import json
import sys

session = json.loads(sys.argv[1])
groups_payload = json.loads(sys.argv[2])
current_repo_state = json.loads(sys.argv[3])

saved_state = session.get("repo_state", {})
if saved_state != current_repo_state:
    raise SystemExit("prepare 之后工作区已变化，请重新执行 --prepare-json")

session_id = groups_payload.get("session_id")
if not isinstance(session_id, str) or not session_id.strip():
    raise SystemExit("groups-json 缺少 session_id")
if session_id != session.get("session_id"):
    raise SystemExit("groups-json 的 session_id 与 prepare 阶段不匹配")

saved_validated = session.get("validated_payload")
if not isinstance(saved_validated, dict):
    raise SystemExit("当前 session 尚未完成分组校验，请先执行 --validate-groups-json")

saved_repos = saved_validated.get("repos")
repos = groups_payload.get("repos")
if saved_repos != repos:
    raise SystemExit("groups-json 必须使用 runtime 最近一次校验后的原样输出")

print(json.dumps(groups_payload, ensure_ascii=False))
PY
}

normalize_commit_groups_json() {
    local repo_state_file="$1"
    local groups_json="$2"
    python3 - "$repo_state_file" "$groups_json" <<'PY'
import json
import sys

repo_state = json.load(open(sys.argv[1], encoding="utf-8"))
raw_groups_json = sys.argv[2]

def fail(message: str):
    raise SystemExit(message)

try:
    payload = json.loads(raw_groups_json)
except json.JSONDecodeError as exc:
    fail(f"groups-json 不是合法 JSON: {exc}")

repos = payload.get("repos") if isinstance(payload, dict) else None
if not isinstance(repos, list):
    fail("groups-json 顶层必须是包含 repos 的对象")

repo_order = [item["repo_id"] for item in repo_state.get("repos", [])]
repo_map = {item["repo_id"]: item for item in repo_state.get("repos", [])}
input_map = {}
for repo in repos:
    if not isinstance(repo, dict):
        fail("groups-json 的 repo 条目必须是对象")
    repo_id = repo.get("repo_id")
    if not isinstance(repo_id, str) or not repo_id.strip():
        fail("groups-json 的 repo_id 不能为空")
    repo_id = repo_id.strip()
    if repo_id in input_map:
        fail(f"groups-json 存在重复 repo_id: {repo_id}")
    if repo_id not in repo_map:
        fail(f"groups-json 包含未知 repo_id: {repo_id}")
    input_map[repo_id] = repo

normalized = []
for repo_id in repo_order:
    expected = repo_map[repo_id]
    changed_files = expected.get("changed_files", [])
    if not changed_files:
        if repo_id in input_map and input_map[repo_id].get("groups"):
            fail(f"repo_id={repo_id} 当前无变更，不应执行 commit")
        continue

    repo = input_map.get(repo_id)
    if repo is None:
        fail(f"groups-json 缺少 repo_id={repo_id}")
    groups = repo.get("groups")
    if not isinstance(groups, list) or not groups:
        fail(f"groups-json 缺少 repo_id={repo_id} 的 groups")

    assigned = set()
    ordered_groups = []
    for idx, group in enumerate(groups, start=1):
        if not isinstance(group, dict):
            fail(f"repo_id={repo_id} group[{idx}] 必须是对象")
        group_id = group.get("group_id")
        title = group.get("group_title")
        reason = group.get("reason")
        files = group.get("files")
        staged_diff = group.get("staged_diff")
        if not isinstance(group_id, str) or not group_id.strip():
            fail(f"repo_id={repo_id} group[{idx}] 缺少 group_id")
        if not isinstance(title, str) or not title.strip():
            fail(f"repo_id={repo_id} group[{idx}] 缺少 group_title")
        if not isinstance(reason, str) or not reason.strip():
            fail(f"repo_id={repo_id} group[{idx}] 缺少 reason")
        if not isinstance(staged_diff, str):
            fail(f"repo_id={repo_id} group[{idx}] 缺少 staged_diff")
        if not isinstance(files, list) or not files:
            fail(f"repo_id={repo_id} group[{idx}] files 不能为空")
        ordered_files = []
        seen = set()
        for path in files:
            if not isinstance(path, str) or not path.strip():
                fail(f"repo_id={repo_id} group[{idx}] 含有非法文件路径")
            path = path.strip()
            if path not in changed_files:
                fail(f"repo_id={repo_id} 包含不属于当前仓库的文件: {path}")
            if path in seen:
                fail(f"repo_id={repo_id} group[{idx}] 内文件重复: {path}")
            if path in assigned:
                fail(f"repo_id={repo_id} 文件重复归组: {path}")
            seen.add(path)
            assigned.add(path)
            ordered_files.append(path)
        ordered_groups.append({
            "group_id": group_id.strip(),
            "group_title": title.strip(),
            "reason": reason.strip(),
            "files": ordered_files,
            "staged_diff": staged_diff,
        })

    missing = [path for path in changed_files if path not in assigned]
    if missing:
        fail(f"repo_id={repo_id} 存在未覆盖文件: {missing[0]}")

    normalized.append({
        "repo_id": repo_id,
        "repo_git_root": expected["repo_git_root"],
        "role": expected["role"],
        "groups": ordered_groups,
    })

print(json.dumps({"repos": normalized}, ensure_ascii=False))
PY
}

STATE_SLUG=""
CONFLICT_MODE="manual"
PREPARE_JSON=0
VALIDATE_GROUPS_JSON=""
GROUPS_JSON=""
MESSAGE_MAP_JSON=""
MODE_COUNT=0

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
            MODE_COUNT=$((MODE_COUNT + 1))
            shift
            ;;
        --validate-groups-json)
            [ $# -ge 2 ] || { usage >&2; exit 1; }
            VALIDATE_GROUPS_JSON="$2"
            MODE_COUNT=$((MODE_COUNT + 1))
            shift 2
            ;;
        --groups-json)
            [ $# -ge 2 ] || { usage >&2; exit 1; }
            GROUPS_JSON="$2"
            shift 2
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

if [ "$MODE_COUNT" -ne 1 ] && [ -z "$GROUPS_JSON" ]; then
    usage >&2
    exit 1
fi

if [ "$MODE_COUNT" -gt 1 ]; then
    usage >&2
    exit 1
fi

if [ -n "$GROUPS_JSON" ] && [ -z "$MESSAGE_MAP_JSON" ]; then
    echo "缺少 --message-map-json，无法执行提交。" >&2
    exit 1
fi

FLOW_ROOT="$(resolve_flow_root)" || true
PROJECT_DIR="$FLOW_ROOT"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
CURRENT_GIT_ROOT="$(current_git_root)"
QUIET_STDOUT=0
if [ "$PREPARE_JSON" -eq 1 ] || [ -n "$VALIDATE_GROUPS_JSON" ]; then
    QUIET_STDOUT=1
fi

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
COMMIT_COUNT=0
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
    if [ "$COMMIT_COUNT" -gt 0 ]; then
        PROTOCOL_RESULT="partial"
        PROTOCOL_COMMITS="$COMMIT_COUNT"
    else
        PROTOCOL_RESULT="failed"
    fi
    PROTOCOL_SUMMARY="$summary"
    finish_protocol
    exit 1
}

if [ -z "$CURRENT_GIT_ROOT" ] && [ -z "$STATE_SLUG" ]; then
    if [ "$PREPARE_JSON" -eq 1 ] || [ -n "$GROUPS_JSON" ]; then
        fail_protocol "当前目录不在 Git 仓库内，无法提交代码。"
    fi
    echo "当前目录不在 Git 仓库内，无法提交代码。" >&2
    exit 1
fi

CONTEXT_FILE="$(mktemp)"
REPO_STATE_FILE="$(mktemp)"
NORMALIZED_GROUPS_FILE="$(mktemp)"
cleanup() {
    rm -f "$CONTEXT_FILE" "$REPO_STATE_FILE" "$NORMALIZED_GROUPS_FILE"
    if [ "${#MESSAGE_FILES_TO_CLEAN[@]}" -gt 0 ]; then
        local message_file
        for message_file in "${MESSAGE_FILES_TO_CLEAN[@]}"; do
            [ -n "$message_file" ] && rm -f "$message_file"
        done
    fi
}
trap cleanup EXIT
ensure_session_store_dir

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
print(json.dumps(state.get("execution_scope", {}), ensure_ascii=False))
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
plan_text = plan_file.read_text(encoding="utf-8")
scope = state.get("execution_scope", {})
repos = scope.get("repos", [])
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

dependency_rows = extract_section_table(plan_text, "跨仓依赖表") or []
edges = []
for row in dependency_rows:
    if len(row) < 2:
        continue
    before = row[0]
    after = row[1]
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

plan_title = ""
for line in plan_text.splitlines():
    if line.startswith("# "):
        plan_title = line[2:].strip()
        break

step_pattern = re.compile(r"^### Step (\d+): (.+)$", re.M)
step_matches = list(step_pattern.finditer(plan_text))
step_titles = {}
for match in step_matches:
    step_no = match.group(1)
    step_titles[f"Step {step_no}"] = match.group(2).strip()

file_boundary_rows = extract_section_table(plan_text, "文件边界总览") or []
repo_file_boundaries = defaultdict(list)
repo_step_titles = defaultdict(list)
seen_step_titles = defaultdict(set)

for row in file_boundary_rows:
    if len(row) < 5:
        continue
    path = row[0].strip().strip("`")
    repo_id = row[1].strip()
    step_ref = row[4].strip()
    if repo_id not in repo_by_id:
        repo_id = "owner"
    if path:
        repo_file_boundaries[repo_id].append({
            "path": path,
            "step": step_ref,
        })
    step_title = step_titles.get(step_ref)
    if step_title and step_title not in seen_step_titles[repo_id]:
        repo_step_titles[repo_id].append(step_title)
        seen_step_titles[repo_id].add(step_title)

payload = {
    "scope": "bound",
    "slug": state_file.stem,
    "used_dependency_table": bool(edges),
    "repos": [],
}

for repo_id in repo_order:
    repo = dict(repo_by_id[repo_id])
    repo["plan_context"] = {
        "slug": state_file.stem,
        "plan_title": plan_title,
        "repo_step_titles": repo_step_titles.get(repo_id, []),
        "repo_file_boundaries": repo_file_boundaries.get(repo_id, []),
    }
    payload["repos"].append(repo)

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
    "scope": "standalone",
    "slug": "none",
    "used_dependency_table": False,
    "repos": [{
        "id": "owner",
        "path": ".",
        "git_root": str(git_root),
        "role": "owner",
        "plan_context": {},
    }],
}
print(json.dumps(payload, ensure_ascii=False))
PY
fi

PROTOCOL_REPOS="$(python3 - "$CONTEXT_FILE" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(payload.get("repos", [])))
PY
)"

if [ "$PREPARE_JSON" -eq 1 ]; then
    if [ "$PROTOCOL_SCOPE" = "bound" ]; then
        USED_DEP_TABLE="$(python3 - "$CONTEXT_FILE" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
print("1" if payload.get("used_dependency_table") else "0")
PY
)"
        if [ "$USED_DEP_TABLE" = "1" ]; then
            say "按跨仓依赖顺序提交涉及仓库"
        else
            say "plan 未声明跨仓依赖表，按 execution_scope.repos 顺序提交"
        fi
    fi
    collect_repo_change_state "$CONTEXT_FILE" "1" "$REPO_STATE_FILE" || {
        PROTOCOL_DETAIL="同步远程或恢复 stash 时发生冲突"
        fail_protocol "仓库同步远程失败。"
    }
    PREPARE_PAYLOAD_JSON="$(prepare_repo_context_json "$CONTEXT_FILE" "$REPO_STATE_FILE")"
    SESSION_ID="$(generate_session_id)"
    PREPARE_CONTEXT_HASH="$(json_sha256 "$PREPARE_PAYLOAD_JSON")"
    PREPARE_OUTPUT_JSON="$(prepare_payload_with_session "$SESSION_ID" "$PREPARE_PAYLOAD_JSON")"
    REPO_STATE_JSON="$(cat "$REPO_STATE_FILE")"
    persist_prepare_session_record "$SESSION_ID" "$PREPARE_PAYLOAD_JSON" "$REPO_STATE_JSON" "$PREPARE_CONTEXT_HASH" "$PREPARE_OUTPUT_JSON"
    exit 0
fi

if [ -n "$VALIDATE_GROUPS_JSON" ]; then
    collect_repo_change_state "$CONTEXT_FILE" "0" "$REPO_STATE_FILE" >/dev/null 2>&1 || {
        echo "无法读取当前仓库变更状态。" >&2
        exit 1
    }
    SESSION_ID="$(extract_json_field "$VALIDATE_GROUPS_JSON" "session_id")"
    [ -n "$SESSION_ID" ] || { echo "groups-json 缺少 session_id" >&2; exit 1; }
    SESSION_JSON="$(load_session_record_json "$SESSION_ID")" || { echo "prepare session 不存在或已过期" >&2; exit 1; }
    NORMALIZED_GROUPS_JSON="$(validate_groups_json_for_session "$SESSION_JSON" "$VALIDATE_GROUPS_JSON" "$(cat "$REPO_STATE_FILE")")"
    VALIDATED_PAYLOAD_JSON="$(validate_groups_json_payload "$REPO_STATE_FILE" "$NORMALIZED_GROUPS_JSON")"
    VALIDATED_OUTPUT_JSON="$(validated_payload_with_session "$SESSION_ID" "$VALIDATED_PAYLOAD_JSON")"
    VALIDATED_GROUPS_HASH="$(json_sha256 "$VALIDATED_OUTPUT_JSON")"
    store_validated_session_payload "$SESSION_ID" "$VALIDATED_OUTPUT_JSON" "$VALIDATED_GROUPS_HASH" "$VALIDATED_OUTPUT_JSON"
    exit 0
fi

collect_repo_change_state "$CONTEXT_FILE" "0" "$REPO_STATE_FILE" >/dev/null 2>&1 || {
    PROTOCOL_DETAIL="无法读取当前仓库变更状态"
    fail_protocol "无法读取当前仓库变更状态。"
}

SESSION_ID="$(extract_json_field "$GROUPS_JSON" "session_id")"
[ -n "$SESSION_ID" ] || fail_protocol "groups-json 缺少 session_id。"
SESSION_JSON="$(load_session_record_json "$SESSION_ID")" || fail_protocol "prepare session 不存在或已过期。"

if [ "$PROTOCOL_SCOPE" = "bound" ]; then
    USED_DEP_TABLE="$(python3 - "$CONTEXT_FILE" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
print("1" if payload.get("used_dependency_table") else "0")
PY
)"
    if [ "$USED_DEP_TABLE" = "1" ]; then
        say "按跨仓依赖顺序提交涉及仓库"
    else
        say "plan 未声明跨仓依赖表，按 execution_scope.repos 顺序提交"
    fi
fi

SESSION_COMMIT_GROUPS_JSON="$(normalize_commit_groups_json_for_session "$SESSION_JSON" "$GROUPS_JSON" "$(cat "$REPO_STATE_FILE")")" || {
    PROTOCOL_DETAIL="groups-json 无效"
    fail_protocol "已校验分组与当前工作区不匹配。"
}

if ! normalize_commit_groups_json "$REPO_STATE_FILE" "$SESSION_COMMIT_GROUPS_JSON" >"$NORMALIZED_GROUPS_FILE"; then
    PROTOCOL_DETAIL="groups-json 无效"
    fail_protocol "已校验分组与当前工作区不匹配。"
fi

TOTAL_GROUP_COUNT="$(python3 - "$NORMALIZED_GROUPS_FILE" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
print(sum(len(repo.get("groups", [])) for repo in payload.get("repos", [])))
PY
)"
[ "$TOTAL_GROUP_COUNT" -gt 0 ] || fail_protocol "没有可提交的业务分组变更。"

while IFS= read -r repo_json; do
    [ -n "$repo_json" ] || continue
    repo_id="$(python3 - "$repo_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("repo_id", ""))
PY
)"
    repo_git_root="$(python3 - "$repo_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("repo_git_root", ""))
PY
)"
    repo_role="$(python3 - "$repo_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("role", ""))
PY
)"
    group_count="$(python3 - "$repo_json" <<'PY'
import json
import sys
print(len(json.loads(sys.argv[1]).get("groups", [])))
PY
)"
    [ "$group_count" -gt 0 ] || continue

    say "处理仓库 [$repo_id] ($repo_role): $repo_git_root"
    say "[$repo_id] 准备提交 ${group_count} 个业务提交组"

    while IFS= read -r group_json; do
        [ -n "$group_json" ] || continue
        group_id="$(python3 - "$group_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("group_id", ""))
PY
)"
        group_title="$(python3 - "$group_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("group_title", ""))
PY
)"
        group_files="$(python3 - "$group_json" <<'PY'
import json
import sys
print("\n".join(json.loads(sys.argv[1]).get("files", [])))
PY
)"
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
            PROTOCOL_FAILED_REPO="$repo_id"
            PROTOCOL_FAILED_GROUP="$group_id"
            PROTOCOL_DETAIL="验证失败"
            fail_protocol "提交组 [$group_title] 验证失败，已停止提交。"
        }

        message_file="$(mktemp)"
        MESSAGE_FILES_TO_CLEAN+=("$message_file")
        if ! write_commit_message_from_map "$MESSAGE_MAP_JSON" "$repo_id" "$group_id" "$message_file"; then
            rm -f "$message_file"
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
            rm -f "$message_file"
            PROTOCOL_FAILED_REPO="$repo_id"
            PROTOCOL_FAILED_GROUP="$group_id"
            PROTOCOL_DETAIL="git commit 失败"
            fail_protocol "提交组 [$group_title] 提交失败。"
        }
        rm -f "$message_file"
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

        commit_hash="$(git -C "$repo_git_root" rev-parse --short HEAD)"
        echo "    committed: $commit_hash $subject"
        COMMIT_LOG_LINES="${COMMIT_LOG_LINES}${repo_id}"$'\t'"${commit_hash}"$'\t'"${subject}"$'\n'
        COMMIT_COUNT=$((COMMIT_COUNT + 1))
    done < <(
        python3 - "$repo_json" <<'PY'
import json
import sys
repo = json.loads(sys.argv[1])
for group in repo.get("groups", []):
    print(json.dumps(group, ensure_ascii=False))
PY
    )
done < <(
    python3 - "$NORMALIZED_GROUPS_FILE" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
for repo in payload.get("repos", []):
    print(json.dumps(repo, ensure_ascii=False))
PY
)

PROTOCOL_RESULT="success"
PROTOCOL_COMMITS="$COMMIT_COUNT"
if [ "$PROTOCOL_SCOPE" = "bound" ]; then
    PROTOCOL_SUMMARY="已按 AI Flow 提交 ${COMMIT_COUNT} 个业务提交组。"
else
    PROTOCOL_SUMMARY="已提交 ${COMMIT_COUNT} 个业务提交组。"
fi
print_commit_list "$COMMIT_LOG_LINES"
finish_protocol
