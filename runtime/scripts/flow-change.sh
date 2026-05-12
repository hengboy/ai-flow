#!/bin/bash
# flow-change.sh — 记录执行过程中的需求变更到指定 plan
# 用法: flow-change.sh {slug或唯一关键词} "变更描述"

set -euo pipefail

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "用法: flow-change.sh {slug或唯一关键词} \"变更描述\"" >&2
    exit 1
fi

resolve_flow_root() {
    local start
    local candidate
    start="$(pwd)"
    candidate="$start"

    if [ -f "$candidate/.ai-flow/workspace.json" ]; then
        printf '%s' "$candidate"
        return 0
    fi

    while true; do
        local workspace_file="$candidate/.ai-flow/workspace.json"
        if [ -f "$workspace_file" ]; then
            if python3 - "$workspace_file" "$start" <<'PY'
import json
import sys
from pathlib import Path

workspace_file = Path(sys.argv[1]).resolve()
target = Path(sys.argv[2]).resolve()
workspace_root = workspace_file.parent.parent
try:
    data = json.loads(workspace_file.read_text(encoding="utf-8"))
except json.JSONDecodeError:
    sys.exit(1)
for repo in data.get("repos", []):
    repo_path = repo.get("path")
    if not isinstance(repo_path, str) or not repo_path.strip():
        continue
    try:
        target.relative_to((workspace_root / repo_path).resolve())
        sys.exit(0)
    except ValueError:
        continue
sys.exit(1)
PY
            then
                printf '%s' "$candidate"
                return 0
            fi
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

PLAN_FILE=$(state_field "$STATE_FILE" "plan_file")
case "$PLAN_FILE" in
    /*) ;;
    *) PLAN_FILE="$PROJECT_DIR/$PLAN_FILE" ;;
esac

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
