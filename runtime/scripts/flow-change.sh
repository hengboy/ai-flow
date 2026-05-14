#!/bin/bash
# flow-change.sh — 记录执行过程中的需求变更到指定 plan
# 用法: flow-change.sh {slug或唯一关键词} "变更描述"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RULE_LOADER_SH="$AI_FLOW_HOME/lib/rule-loader.sh"
if [ ! -f "$RULE_LOADER_SH" ]; then
    RULE_LOADER_SH="$(cd "$SCRIPT_DIR/../.." && pwd)/subagents/shared/lib/rule-loader.sh"
fi

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "用法: flow-change.sh {slug或唯一关键词} \"变更描述\"" >&2
    exit 1
fi

if [ ! -f "$RULE_LOADER_SH" ]; then
    echo "错误: 缺少 rule loader: $RULE_LOADER_SH" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$RULE_LOADER_SH"

resolve_flow_root() {
    local start
    local candidate
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

    printf '%s' "$start"
}

PROJECT_DIR="$(resolve_flow_root)"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
CHANGE_TEXT="$2"

state_field() {
    local state_file="$1"
    local field="$2"
    python3 - "$state_file" "$field" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = state
for part in sys.argv[2].split("."):
    if value is None:
        break
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    sys.exit(1)
print(value)
PY
}

collect_rule_repo_args() {
    local state_file="$1"
    python3 - "$state_file" "$PROJECT_DIR" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
owner = Path(sys.argv[2]).resolve()
scope = state.get("execution_scope") or {}
repos = scope.get("repos") or []
for repo in repos:
    repo_id = str(repo.get("id") or "").strip()
    repo_path = str(repo.get("path") or "").strip()
    if not repo_id or not repo_path:
        continue
    repo_root = (owner / repo_path).resolve()
    print(f"{repo_id}::{repo_root}")
PY
}

MATCHED_STATES=()
while IFS= read -r -d '' f; do
    MATCHED_STATES+=("$f")
done < <(find "$FLOW_DIR/state" -name "*${1}*.json" -type f -print0 2>/dev/null)

if [ ${#MATCHED_STATES[@]} -eq 0 ]; then
    echo "错误: 找不到包含关键词 '$1' 的状态文件" >&2
    exit 1
elif [ ${#MATCHED_STATES[@]} -gt 1 ]; then
    echo "匹配到多个状态，请选择："
    for i in "${!MATCHED_STATES[@]}"; do
        slug=$(basename "${MATCHED_STATES[$i]}" .json)
        status=$(state_field "${MATCHED_STATES[$i]}" "current_status")
        echo "  $((i + 1)). $slug [$status] (${MATCHED_STATES[$i]})"
    done
    read -rp "请选择编号 [1-${#MATCHED_STATES[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MATCHED_STATES[@]}" ]; then
        STATE_FILE="${MATCHED_STATES[$((choice - 1))]}"
    else
        echo "错误: 无效编号" >&2
        exit 1
    fi
else
    STATE_FILE="${MATCHED_STATES[0]}"
fi

RULE_REPO_ARGS=()
while IFS= read -r repo_arg; do
    [ -n "$repo_arg" ] || continue
    RULE_REPO_ARGS+=("$repo_arg")
done < <(collect_rule_repo_args "$STATE_FILE")

if [ ${#RULE_REPO_ARGS[@]} -eq 0 ]; then
    RULE_REPO_ARGS=("owner::${PROJECT_DIR}")
fi

if ! RULE_BUNDLE_JSON="$(load_rule_bundle_json "change_runtime" "ai-flow-change" "" "${RULE_REPO_ARGS[@]}" 2>&1)"; then
    echo "错误: $(extract_rule_loader_error "$RULE_BUNDLE_JSON")" >&2
    exit 1
fi

REQUIRED_READS_OUTPUT=""
if ! REQUIRED_READS_OUTPUT="$(render_required_reads_block "$RULE_BUNDLE_JSON" 2>&1)"; then
    echo "错误: $(extract_rule_loader_error "$REQUIRED_READS_OUTPUT")" >&2
    exit 1
fi

PLAN_FILE=$(state_field "$STATE_FILE" "plan_file")
case "$PLAN_FILE" in
    /*) ;;
    *) PLAN_FILE="$PROJECT_DIR/$PLAN_FILE" ;;
esac

PLAN_RELATIVE_PATH="$(python3 - "$PLAN_FILE" "$PROJECT_DIR" <<'PY'
import sys
from pathlib import Path

target = Path(sys.argv[1]).resolve()
owner = Path(sys.argv[2]).resolve()
print(target.relative_to(owner).as_posix())
PY
)"

RULE_PATH_ERROR="$(python3 - "$RULE_BUNDLE_JSON" "$PLAN_FILE" "$PROJECT_DIR" <<'PY'
import json
import sys
from pathlib import Path

bundle = json.loads(sys.argv[1])
target = Path(sys.argv[2]).resolve()
owner = Path(sys.argv[3]).resolve()

candidate_repo_id = "owner"
candidate_rel = target.relative_to(owner).as_posix()
for repo in bundle.get("repos", []):
    repo_id = str(repo.get("repo_id") or "").strip()
    repo_root_raw = str(repo.get("repo_root") or "").strip()
    if not repo_id or not repo_root_raw:
        continue
    repo_root = Path(repo_root_raw).resolve()
    try:
        rel = target.relative_to(repo_root).as_posix()
    except ValueError:
        continue
    candidate_repo_id = repo_id
    candidate_rel = rel
    break

def matches(pattern: str) -> bool:
    import fnmatch
    return fnmatch.fnmatch(candidate_rel, pattern.strip().replace("\\", "/"))

for item in bundle["merged"].get("protected_paths", []):
    pattern = str(item.get("path") or "").strip()
    if item.get("repo_id") == candidate_repo_id and pattern and matches(pattern):
        print(f"命中 protected_paths，禁止修改计划文件: [{item.get('repo_id')}] {pattern}")
        raise SystemExit(0)

for item in bundle["merged"].get("forbidden_changes", []):
    pattern = str(item.get("path") or "").strip()
    if item.get("repo_id") == candidate_repo_id and pattern and matches(pattern):
        reason = str(item.get("reason") or "").strip()
        suffix = f"：{reason}" if reason else ""
        print(f"命中 forbidden_changes，禁止修改计划文件: [{item.get('repo_id')}] {pattern}{suffix}")
        raise SystemExit(0)

print("")
PY
)"

if [ -n "$RULE_PATH_ERROR" ]; then
    echo "错误: $RULE_PATH_ERROR" >&2
    exit 1
fi

if ! grep -q '^## 7\. 需求变更记录' "$PLAN_FILE"; then
    {
        printf '\n## 7. 需求变更记录\n\n'
        printf '| 时间 | 变更描述 | 确认方式 |\n'
        printf '|------|----------|----------|\n'
    } >> "$PLAN_FILE"
fi

timestamp=$(date '+%Y-%m-%d %H:%M:%S')
escaped_change=$(printf '%s' "$CHANGE_TEXT" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//;s/|/\\|/g')
python3 - "$PLAN_FILE" "$timestamp" "$escaped_change" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
timestamp = sys.argv[2]
change = sys.argv[3]
new_row = f"| {timestamp} | {change} | 用户确认 |"
placeholder = "| {YYYY-MM-DD HH:MM} | {执行过程中新增或调整的需求；无则保留空表} | {用户确认/文档同步/其他} |"

lines = path.read_text(encoding="utf-8").splitlines()
output = []
in_section = False
inserted = False

for line in lines:
    if line == placeholder:
        continue
    if line.startswith("## 7. 需求变更记录"):
        in_section = True
        output.append(line)
        continue
    if in_section and line.startswith("## "):
        if not inserted:
            output.append(new_row)
            inserted = True
        in_section = False
    output.append(line)

if in_section and not inserted:
    output.append(new_row)
    inserted = True

if not inserted:
    output.extend([
        "",
        "## 7. 需求变更记录",
        "",
        "| 时间 | 变更描述 | 确认方式 |",
        "|------|----------|----------|",
        new_row,
    ])

path.write_text("\n".join(output) + "\n", encoding="utf-8")
PY

echo ">>> 已记录需求变更: $PLAN_FILE"
