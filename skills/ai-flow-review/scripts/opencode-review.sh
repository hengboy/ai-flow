#!/bin/bash
# opencode-review.sh — 调用 OpenCode 审查代码变更并生成报告
# 用法: opencode-review.sh {slug或唯一关键词} [模型名] [推理强度] [轮次]

set -euo pipefail

PROJECT_DIR="$(pwd)"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
REPORTS_DIR="$FLOW_DIR/reports"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SKILL_DIR/templates/review-template.md"
PROMPT_TEMPLATE="$SKILL_DIR/prompts/review-generation.md"
AI_FLOW_HOME="${AI_FLOW_HOME:-$HOME/.config/ai-flow}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
FLOW_STATE_SH="$AI_FLOW_HOME/scripts/flow-state.sh"

display_path() {
    local base="$1"
    local path="$2"
    case "$path" in
        "$base"/*) echo "${path#"$base"/}" ;;
        *) echo "$path" ;;
    esac
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\/&]/\\&/g'
}

trim_report_to_header() {
    local file="$1"
    python3 - "$file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "# 审查报告："
index = text.find(marker)
if index > 0:
    path.write_text(text[index:], encoding="utf-8")
PY
}

render_template_content() {
    local engine="$1"
    local model_name="$2"
    local reasoning="$3"
    local tool_label="${engine} (${model_name} ${reasoning})"

    sed \
        -e "s/{需求名称}/$(escape_sed_replacement "$PLAN_TITLE")/g" \
        -e "s/{需求简称}/$(escape_sed_replacement "$SLUG")/g" \
        -e "s/{审查模式}/$(escape_sed_replacement "$REVIEW_MODE")/g" \
        -e "s/{审查轮次}/$(escape_sed_replacement "$CURRENT_ROUND")/g" \
        -e "s#{计划文件}#$(escape_sed_replacement "$PLAN_FILE")#g" \
        -e "s/{YYYY-MM-DD}/$(date +%Y-%m-%d)/g" \
        -e "s/{模型名}/$(escape_sed_replacement "$model_name")/g" \
        -e "s/{推理强度}/$(escape_sed_replacement "$reasoning")/g" \
        -e "s/{审查工具}/$(escape_sed_replacement "$tool_label")/g" \
        "$TEMPLATE"
}

render_prompt_template() {
    local prompt_template="$1"
    AI_FLOW_REVIEW_SCOPE_GUIDANCE="$REVIEW_SCOPE_GUIDANCE" \
    AI_FLOW_HISTORY_RULES="$HISTORY_RULES" \
    AI_FLOW_PLAN_CONTENT="$PLAN_CONTENT" \
    AI_FLOW_HISTORY_CONTEXT="$HISTORY_CONTEXT" \
    AI_FLOW_TEMPLATE_CONTENT="$TEMPLATE_CONTENT" \
    AI_FLOW_SLUG="$SLUG" \
    AI_FLOW_REVIEW_MODE="$REVIEW_MODE" \
    AI_FLOW_CURRENT_ROUND="$CURRENT_ROUND" \
    AI_FLOW_PLAN_TITLE="$PLAN_TITLE" \
    python3 - "$prompt_template" <<'PY'
import os
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
replacements = {
    "__AI_FLOW_REVIEW_SCOPE_GUIDANCE__": os.environ["AI_FLOW_REVIEW_SCOPE_GUIDANCE"],
    "__AI_FLOW_HISTORY_RULES__": os.environ["AI_FLOW_HISTORY_RULES"],
    "__AI_FLOW_PLAN_CONTENT__": os.environ["AI_FLOW_PLAN_CONTENT"],
    "__AI_FLOW_HISTORY_CONTEXT__": os.environ["AI_FLOW_HISTORY_CONTEXT"],
    "__AI_FLOW_TEMPLATE_CONTENT__": os.environ["AI_FLOW_TEMPLATE_CONTENT"],
    "__AI_FLOW_SLUG__": os.environ["AI_FLOW_SLUG"],
    "__AI_FLOW_REVIEW_MODE__": os.environ["AI_FLOW_REVIEW_MODE"],
    "__AI_FLOW_CURRENT_ROUND__": os.environ["AI_FLOW_CURRENT_ROUND"],
    "__AI_FLOW_PLAN_TITLE__": os.environ["AI_FLOW_PLAN_TITLE"],
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
sys.stdout.write(text)
PY
}

state_field() {
    local slug="$1"
    local field="$2"
    python3 - "$FLOW_DIR/state/${slug}.json" "$field" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = state
for part in sys.argv[2].split("."):
    if value is None:
        value = None
        break
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    sys.exit(1)
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

state_field_optional() {
    state_field "$1" "$2" 2>/dev/null || true
}

ensure_reviewable_git_changes() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "错误: 当前目录不是 Git 仓库，无法确认审查范围"
        exit 1
    fi

    local relevant_changes
    relevant_changes=$(git status --porcelain --untracked-files=all | awk '
        {
            path = substr($0, 4)
            if (path ~ /^\.ai-flow\//) {
                next
            }
            print
        }
    ')
    if [ -z "$relevant_changes" ]; then
        echo "错误: 没有可审查的 Git 变更（已忽略 .ai-flow/ 元数据）"
        exit 1
    fi
}

meta_value() {
    local key="$1"
    sed -n "s/^> ${key}：//p" "$REPORT_FILE" | head -1 | sed 's/^`//;s/`$//'
}

extract_tracking_section() {
    local report_file="$1"
    awk '
        /^## 6\./ {in_section=1}
        in_section {print}
    ' "$report_file"
}

extract_defect_section() {
    local report_file="$1"
    awk '
        /^## 4\./ {in_section=1}
        /^## 5\./ && in_section {exit}
        in_section {print}
    ' "$report_file"
}

extract_family_coverage_section() {
    local report_file="$1"
    awk '
        /^### 3\.6 / {in_section=1}
        /^## 4\./ && in_section {exit}
        in_section {print}
    ' "$report_file"
}

list_reviewable_git_paths() {
    git status --porcelain --untracked-files=all | awk '
        {
            path = substr($0, 4)
            if (path ~ /^\.ai-flow\//) {
                next
            }
            print path
        }
    '
}

is_documentation_path() {
    local path="$1"
    case "$path" in
        docs/*|doc/*|README|README.*|CHANGELOG|CHANGELOG.*|*.md|*.markdown|*.rst|*.adoc)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

has_non_doc_git_changes() {
    local path
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if ! is_documentation_path "$path"; then
            return 0
        fi
    done < <(list_reviewable_git_paths)
    return 1
}

report_section_between() {
    local report_file="$1"
    local start_pattern="$2"
    local end_pattern="$3"
    awk -v start="$start_pattern" -v end="$end_pattern" '
        $0 ~ start {in_section=1; next}
        $0 ~ end && in_section {exit}
        in_section {print}
    ' "$report_file"
}

validate_optional_markers() {
    python3 - "$REPORT_FILE" <<'PY'
import sys
from pathlib import Path


def parse_rows(lines):
    rows = []
    for line in lines:
        if not line.startswith("|"):
            continue
        cells = [part.strip() for part in line.split("|")[1:-1]]
        if not cells:
            continue
        if cells[0] in {"#", "缺陷编号"}:
            continue
        if set(cells[0]) == {"-"}:
            continue
        rows.append(cells)
    return rows


text = Path(sys.argv[1]).read_text(encoding="utf-8")
lines = text.splitlines()
errors = []
section = None
current = []
tracking = []

for line in lines:
    if line.startswith("## 4. 缺陷清单"):
        section = "current"
        continue
    if line.startswith("## 5. 审查结论"):
        section = None
    if line.startswith("## 6. 缺陷修复追踪"):
        section = "tracking"
        continue
    if section == "current":
        current.append(line)
    elif section == "tracking":
        tracking.append(line)

for cells in parse_rows(current):
    issue_id = cells[0]
    if issue_id.startswith("DEF-") and "[可选]" in cells:
        errors.append(f"{issue_id} 为阻塞缺陷，不能标记为 [可选]")
    if issue_id.startswith("SUG-"):
        severity = cells[1] if len(cells) > 1 else ""
        status = cells[-1] if cells else ""
        if severity != "Minor":
            errors.append(f"{issue_id} 作为建议项时严重级别必须是 Minor")
        if status == "[待修复]":
            errors.append(f"{issue_id} 为 Minor 建议，未处理时必须标记为 [可选] 而不是 [待修复]")

for cells in parse_rows(tracking):
    issue_id = cells[0]
    status = cells[2] if len(cells) > 2 else ""
    if issue_id.startswith("DEF-") and status == "[可选]":
        errors.append(f"{issue_id} 为阻塞缺陷追踪项，不能标记为 [可选]")
    if issue_id.startswith("SUG-") and status == "[待修复]":
        errors.append(f"{issue_id} 为 Minor 建议追踪项，未处理时必须标记为 [可选]")

if errors:
    sys.stderr.write("\n".join(errors) + "\n")
    sys.exit(1)
PY
}

require_root_cause_review_loop_record() {
    if [ "$REVIEW_MODE" != "regular" ] || [ "$CURRENT_ROUND" -lt 3 ]; then
        return 0
    fi

    python3 - "$STATE_FILE" "$PLAN_FILE" <<'PY'
import json
import re
import sys
from datetime import datetime
from pathlib import Path


def parse_change_time(raw: str):
    raw = raw.strip()
    if not raw:
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            naive = datetime.strptime(raw, fmt)
            return naive.astimezone()
        except ValueError:
            continue
    return None


state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
plan_text = Path(sys.argv[2]).read_text(encoding="utf-8")

round2_failure_at = None
for transition in state.get("transitions", []):
    artifacts = transition.get("artifacts") or {}
    if (
        transition.get("event") == "review_failed"
        and artifacts.get("mode") == "regular"
        and artifacts.get("round") == 2
    ):
        round2_failure_at = datetime.fromisoformat(transition["at"])
        break

if round2_failure_at is None:
    sys.exit(0)

lines = plan_text.splitlines()
in_section = False
for line in lines:
    if line.startswith("## 7. "):
        in_section = True
        continue
    if in_section and line.startswith("## "):
        break
    if not in_section or not line.startswith("|"):
        continue
    cells = [part.strip() for part in line.strip().split("|")[1:-1]]
    if len(cells) < 3:
        continue
    timestamp, description = cells[0], cells[1]
    if description.startswith("[root-cause-review-loop]"):
        parsed = parse_change_time(timestamp)
        if parsed and parsed >= round2_failure_at:
            sys.exit(0)

sys.stderr.write(
    "错误: regular 第 3 轮 review 前缺少晚于第 2 轮失败时间的 [root-cause-review-loop] 变更记录\n"
)
sys.exit(1)
PY
}

validate_previous_family_coverage() {
    [ -n "$PREV_REVIEW" ] || return 0
    [ -f "$PREV_REVIEW" ] || return 0

    python3 - "$PREV_REVIEW" "$REPORT_FILE" <<'PY'
import re
import sys
from pathlib import Path


def section(text: str, start: str, end: str):
    pattern = rf"(?ms)^{re.escape(start)}\n(.*?)(?=^{re.escape(end)}|\Z)"
    match = re.search(pattern, text)
    return match.group(1) if match else ""


def has_severe_defect(defect_section: str) -> bool:
    return bool(re.search(r"^\| DEF-\d+ \| (Critical|Important) \|", defect_section, re.M))


def family_names(family_section: str):
    names = []
    for line in family_section.splitlines():
        if not line.startswith("|"):
            continue
        cells = [part.strip() for part in line.split("|")[1:-1]]
        if len(cells) < 3:
            continue
        if cells[0] in {"缺陷族", "--------"}:
            continue
        if set(cells[0]) == {"-"}:
            continue
        names.append(cells[0])
    return names


prev_text = Path(sys.argv[1]).read_text(encoding="utf-8")
curr_text = Path(sys.argv[2]).read_text(encoding="utf-8")
prev_defects = section(prev_text, "## 4. 缺陷清单", "## 5. 审查结论")
if not has_severe_defect(prev_defects):
    sys.exit(0)

prev_families = family_names(section(prev_text, "### 3.6 缺陷族覆盖度", "## 4. 缺陷清单"))
if not prev_families:
    sys.exit(0)

curr_section = section(curr_text, "### 3.6 缺陷族覆盖度", "## 4. 缺陷清单")
missing = [name for name in prev_families if name not in curr_section]
if missing:
    sys.stderr.write("缺少上一轮严重缺陷对应的缺陷族覆盖状态: " + ", ".join(missing) + "\n")
    sys.exit(1)
PY
}

if [ -z "${1:-}" ]; then
    echo "用法: opencode-review.sh {slug或唯一关键词} [模型名] [推理强度] [轮次]"
    echo ""
    echo "  默认模型: zhipuai-coding-plan/glm-5.1"
    echo "  默认推理: max"
    echo ""
    echo "可用状态："
    if [ -d "$FLOW_DIR/state" ]; then
        find "$FLOW_DIR/state" -name "*.json" -type f | sort | while read -r f; do
            slug=$(basename "$f" .json)
            status=$(python3 - "$f" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(state["current_status"])
PY
)
            plan_file=$(python3 - "$f" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(state["plan_file"])
PY
)
            printf "  %s [%s] (%s)\n" "$slug" "$status" "$plan_file"
        done
    else
        echo "  (无)"
    fi
    exit 1
fi

MODEL="${2:-zhipuai-coding-plan/glm-5.1}"
REASONING="${3:-max}"
ROUND_OVERRIDE="${4:-}"

MATCHED_STATES=()
while IFS= read -r -d '' f; do
    MATCHED_STATES+=("$f")
done < <(find "$FLOW_DIR/state" -name "*${1}*.json" -type f -print0 2>/dev/null)

if [ ${#MATCHED_STATES[@]} -eq 0 ]; then
    echo "错误: 找不到包含关键词 '$1' 的状态文件"
    exit 1
elif [ ${#MATCHED_STATES[@]} -gt 1 ]; then
    echo "匹配到多个状态，请选择："
    for i in "${!MATCHED_STATES[@]}"; do
        slug=$(basename "${MATCHED_STATES[$i]}" .json)
        status=$(state_field "$slug" "current_status")
        plan_file=$(state_field "$slug" "plan_file")
        echo "  $((i + 1)). $slug [$status] ($(display_path "$PROJECT_DIR" "$plan_file"))"
    done
    read -rp "请选择编号 [1-${#MATCHED_STATES[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MATCHED_STATES[@]}" ]; then
        STATE_FILE="${MATCHED_STATES[$((choice - 1))]}"
    else
        echo "错误: 无效编号"
        exit 1
    fi
else
    STATE_FILE="${MATCHED_STATES[0]}"
fi

SLUG=$(basename "$STATE_FILE" .json)
PLAN_STATUS=$(state_field "$SLUG" "current_status")
PLAN_FILE=$(state_field "$SLUG" "plan_file")
PLAN_TITLE=$(state_field "$SLUG" "title")
REGULAR_ROUND_COUNT=$(state_field "$SLUG" "review_rounds.regular")
RECHECK_ROUND_COUNT=$(state_field "$SLUG" "review_rounds.recheck")
LATEST_REGULAR_REVIEW=$(state_field_optional "$SLUG" "latest_regular_review_file")
LATEST_RECHECK_REVIEW=$(state_field_optional "$SLUG" "latest_recheck_review_file")
LAST_REVIEW_RESULT=$(state_field_optional "$SLUG" "last_review.result")
LAST_REVIEW_FILE=$(state_field_optional "$SLUG" "last_review.report_file")

case "$PLAN_STATUS" in
    AWAITING_REVIEW)
        REVIEW_MODE="regular"
        CURRENT_ROUND=$((REGULAR_ROUND_COUNT + 1))
        BASE_NAME="${SLUG}-review"
        ;;
    DONE)
        REVIEW_MODE="recheck"
        CURRENT_ROUND=$((RECHECK_ROUND_COUNT + 1))
        BASE_NAME="${SLUG}-review-recheck"
        ;;
    *)
        echo "错误: 当前状态为 [$PLAN_STATUS]，不能执行审查"
        echo "    常规审查只允许 [AWAITING_REVIEW]；再审查只允许 [DONE]"
        exit 1
        ;;
esac

if [ -n "$ROUND_OVERRIDE" ]; then
    if ! [[ "$ROUND_OVERRIDE" =~ ^[0-9]+$ ]] || [ "$ROUND_OVERRIDE" -le 0 ]; then
        echo "错误: 轮次必须是正整数: $ROUND_OVERRIDE"
        exit 1
    fi
    if [ "$ROUND_OVERRIDE" -ne "$CURRENT_ROUND" ]; then
        echo "错误: 轮次以状态文件中的 review_rounds 为准，当前应为第 $CURRENT_ROUND 轮，不能写入第 $ROUND_OVERRIDE 轮"
        exit 1
    fi
fi

if [ "$CURRENT_ROUND" -eq 1 ]; then
    REPORT_FILE="$(dirname "$PLAN_FILE" | sed 's#^\.ai-flow/plans#'"$REPORTS_DIR"'#')/${BASE_NAME}.md"
else
    REPORT_FILE="$(dirname "$PLAN_FILE" | sed 's#^\.ai-flow/plans#'"$REPORTS_DIR"'#')/${BASE_NAME}-v${CURRENT_ROUND}.md"
fi
REPORT_FILE=$(python3 - "$REPORT_FILE" <<'PY'
import os, sys
print(os.path.normpath(sys.argv[1]))
PY
)

if [ -e "$REPORT_FILE" ]; then
    echo "错误: 报告文件已存在，拒绝覆盖: $REPORT_FILE"
    echo "    请删除旧报告或修正状态文件轮次后重试"
    exit 1
fi

PREV_REVIEW=""
if [ "$LAST_REVIEW_RESULT" = "failed" ] && [ -n "$LAST_REVIEW_FILE" ]; then
    PREV_REVIEW="$LAST_REVIEW_FILE"
elif [ "$REVIEW_MODE" = "recheck" ]; then
    PREV_REVIEW="${LATEST_RECHECK_REVIEW:-}"
    if [ -z "$PREV_REVIEW" ]; then
        PREV_REVIEW="${LATEST_REGULAR_REVIEW:-}"
    fi
else
    PREV_REVIEW="${LATEST_REGULAR_REVIEW:-}"
fi

mkdir -p "$(dirname "$REPORT_FILE")"
ensure_reviewable_git_changes
require_root_cause_review_loop_record

# --- 检查 OpenCode 可用性 ---
if ! command -v opencode >/dev/null 2>&1; then
    echo "错误: opencode 未安装，无法执行审查"
    exit 1
fi

echo ">>> 匹配到状态: $SLUG [$PLAN_STATUS]"
echo "    对比计划: $PLAN_FILE"
echo "    审查模式: $REVIEW_MODE"
echo "    审查轮次: $CURRENT_ROUND"
echo "    审查引擎: opencode ($MODEL)"
echo "    输出文件: $REPORT_FILE"
if [ -n "$PREV_REVIEW" ]; then
    echo "    上一轮报告: ${PREV_REVIEW}（用于缺陷正文与追踪）"
fi
echo ""

PLAN_CONTENT=$(cat "$PLAN_FILE")
for required_file in "$FLOW_STATE_SH" "$TEMPLATE" "$PROMPT_TEMPLATE"; do
    if [ ! -f "$required_file" ]; then
        echo "错误: 缺少运行时资源: $required_file"
        exit 1
    fi
done
TEMPLATE_CONTENT=$(render_template_content "OpenCode" "$MODEL" "$REASONING")

case "$REVIEW_MODE:$CURRENT_ROUND" in
    regular:1)
        REVIEW_SCOPE_GUIDANCE="这是第 1 轮 regular review：目标是做全量缺陷盘点，按缺陷族尽量一次打全，不允许只列最容易看出来的几个点。"
        ;;
    regular:2)
        REVIEW_SCOPE_GUIDANCE="这是第 2 轮 regular review：既要验证上一轮已修复项是否真正关闭，也要重新扫一遍所有上一轮受影响缺陷族及其相邻回归面。"
        ;;
    regular:*)
        REVIEW_SCOPE_GUIDANCE="这是第 ${CURRENT_ROUND} 轮 regular review：先验证根因补录后的修复是否闭环，再对历史缺陷族和相邻回归面做复核，避免继续按单点症状放行。"
        ;;
    recheck:*)
        REVIEW_SCOPE_GUIDANCE="这是 recheck review：确认 DONE 后新增变更没有引入回归，同时复核与本次变更直接相关的缺陷族和关键路径。"
        ;;
esac

HISTORY_CONTEXT=""
HISTORY_RULES=$'5. 如果本轮发现缺陷，按严重级别写入"4. 缺陷清单"，并同步更新"6. 缺陷修复追踪"。\n6. "3.6 缺陷族覆盖度"至少要覆盖 plan 中与本次变更相关的缺陷族，并说明已覆盖 / 未覆盖 / 需人工验证。'
if [ -n "$PREV_REVIEW" ] && [ -f "$PREV_REVIEW" ]; then
    PREV_DEFECTS=$(extract_defect_section "$PREV_REVIEW")
    PREV_TRACKING=$(extract_tracking_section "$PREV_REVIEW")
    [ -z "$PREV_DEFECTS" ] && PREV_DEFECTS=$'## 4. 缺陷清单\n\n（上一轮报告缺少该章节，请按空缺陷清单处理）'
    [ -z "$PREV_TRACKING" ] && PREV_TRACKING=$'## 6. 缺陷修复追踪\n\n（上一轮报告缺少该章节，请按空追踪表处理）'
    HISTORY_CONTEXT=$(cat <<EOF

上一轮严重缺陷正文（必须全文参考，而不是只看缺陷编号）：
$PREV_DEFECTS

上一轮缺陷修复追踪：
$PREV_TRACKING
EOF
)
    HISTORY_RULES=$(cat <<'EOF'
5. 必须同时参考上一轮“4. 缺陷清单”和“6. 缺陷修复追踪”：
   - 已修复项要重新验证；修复无效或不完整时，必须改回 [待修复] 并重新列入缺陷清单
   - Minor 建议未处理时保持 [可选]；只有严重度升级为 Critical/Important 时才改为 [待修复]
   - 上一轮涉及的缺陷族，本轮必须在“3.6 缺陷族覆盖度”中逐项写出已覆盖 / 未覆盖 / 需人工验证及原因
   - 不要只继承 DEF 编号状态，要继承上一轮严重缺陷的正文语义、影响面和修复追踪
6. 仅列出当前仍未修复的缺陷和新增缺陷到“4. 缺陷清单”；“6. 缺陷修复追踪”需要保留并更新历史条目。
EOF
)
fi

REVIEW_PROMPT=$(render_prompt_template "$PROMPT_TEMPLATE")

echo ">>> 调用 opencode ($MODEL) 审查中..."
opencode run \
    -m "$MODEL" \
    --variant "$REASONING" \
    --dangerously-skip-permissions \
    --format default \
    --dir "$PROJECT_DIR" \
    "$REVIEW_PROMPT" > "$REPORT_FILE"

# --- 截掉思考过程（opencode --format default 可能在报告前输出思考文字） ---
trim_report_to_header "$REPORT_FILE"

echo ""
echo ">>> 审查报告已生成: $REPORT_FILE"
echo ">>> 校验审查报告结构..."

ERRORS=""
FIRST_LINE=$(head -1 "$REPORT_FILE")
if ! echo "$FIRST_LINE" | grep -qE '^# 审查报告：'; then
    ERRORS="${ERRORS}首行必须是 '# 审查报告：...'\n"
fi
for section in "## 1\. " "## 2\. " "## 2\.1 " "## 3\." "## 4\." "## 5\." "## 6\."; do
    if ! grep -qE "$section" "$REPORT_FILE"; then
        section_label=${section//\\/}
        ERRORS="${ERRORS}缺少章节: $section_label\n"
    fi
done
for subsection in "### 1\.2 " "### 3\.6 "; do
    if ! grep -qE "$subsection" "$REPORT_FILE"; then
        subsection_label=${subsection//\\/}
        ERRORS="${ERRORS}缺少强制子节: $subsection_label\n"
    fi
done

REPORT_PLACEHOLDERS=(
    "{需求名称}"
    "{YYYY-MM-DD}"
    "{需求简称}"
    "{审查模式}"
    "{审查轮次}"
    "{审查结果}"
    "{计划文件}"
    "{模型名}"
    "{推理强度}"
    "{总体通过 / 需要修复 / 存在风险}"
    "{无 / xxx-review-vN.md}"
    "{审查中读取的测试输出、报告状态或需人工验证项}"
    "{exact_command}"
    "{为什么执行、结果说明什么、是否需要人工补充验证}"
    "{标题}"
    "{说明}"
    "{X}"
    "{文件}"
    "{改了什么}"
    "{架构是否合理、是否符合项目分层规范}"
    "{命名规范、注释规范、提交规范等}"
    "{SQL 注入、XSS、越权、敏感信息泄露等}"
    "{查询效率、N+1、内存泄漏、缓存策略等}"
    "{空集合、空字符串、null、最大值、分页边界等}"
    "{Optional 是否正确使用、判空是否完整、链式调用是否可能 NPE}"
    "{try-catch 是否吞掉异常、异常后事务状态是否正确、错误码返回是否合理}"
    "{事务边界是否正确、并发修改是否有乐观锁、关联查询是否遗漏条件}"
    "{强类型 ID 与字符串的转换、枚举值的映射、数据库字段与 DTO 的映射}"
    "{接口是否有 @PreAuthorize、数据权限注解是否生效、越权访问是否阻止}"
    "{Controller 参数是否有 @Validated、自定义校验器是否覆盖所有必填项}"
    "{GET 接口是否有修改操作、循环中是否有 DB 查询、静态变量是否有并发风险}"
    "{缺陷族名称}"
    "{本轮复查了什么、未覆盖原因或人工验证边界}"
)
for placeholder in "${REPORT_PLACEHOLDERS[@]}"; do
    if grep -Fq "$placeholder" "$REPORT_FILE"; then
        ERRORS="${ERRORS}报告中仍有未替换的模板占位符: $placeholder\n"
    fi
done

META_SLUG=$(meta_value "需求简称")
META_MODE=$(meta_value "审查模式")
META_ROUND=$(meta_value "审查轮次")
META_RESULT=$(meta_value "审查结果")
META_PLAN_FILE=$(meta_value "对比计划")
if [ "$META_SLUG" != "$SLUG" ]; then
    ERRORS="${ERRORS}需求简称与状态文件不一致: 期望 ${SLUG}，实际 ${META_SLUG}\n"
fi
if [ "$META_MODE" != "$REVIEW_MODE" ]; then
    ERRORS="${ERRORS}审查模式与预期不一致: 期望 ${REVIEW_MODE}，实际 ${META_MODE}\n"
fi
if [ "$META_ROUND" != "$CURRENT_ROUND" ]; then
    ERRORS="${ERRORS}审查轮次与预期不一致: 期望 ${CURRENT_ROUND}，实际 ${META_ROUND}\n"
fi
if [ "$META_PLAN_FILE" != "$PLAN_FILE" ]; then
    ERRORS="${ERRORS}对比计划路径与状态文件不一致\n"
fi
if [ "$META_RESULT" != "passed" ] && [ "$META_RESULT" != "failed" ] && [ "$META_RESULT" != "passed_with_notes" ]; then
    ERRORS="${ERRORS}审查结果必须是 passed、passed_with_notes 或 failed\n"
fi

OVERALL_SECTION=$(awk '
    /^## 1\./ {in_section=1; next}
    /^## 2\./ && in_section {exit}
    in_section {print}
' "$REPORT_FILE")
VERIFICATION_SECTION=$(report_section_between "$REPORT_FILE" '^### 1\.2 ' '^## 2\. ')
CONCLUSION_SECTION=$(awk '
    /^## 5\./ {in_section=1; next}
    /^## 6\./ && in_section {exit}
    in_section {print}
' "$REPORT_FILE")
FAMILY_SECTION=$(report_section_between "$REPORT_FILE" '^### 3\.6 ' '^## 4\. ')

if [ -z "$(printf '%s\n' "$VERIFICATION_SECTION" | sed '/^[[:space:]]*$/d')" ]; then
    ERRORS="${ERRORS}1.2 定向验证执行证据不能为空\n"
fi
if [ -z "$(printf '%s\n' "$FAMILY_SECTION" | sed '/^[[:space:]]*$/d')" ]; then
    ERRORS="${ERRORS}3.6 缺陷族覆盖度不能为空\n"
fi
if has_non_doc_git_changes; then
    if ! printf '%s\n' "$VERIFICATION_SECTION" | awk '
        /^\|/ {count++}
        END {exit(count >= 3 ? 0 : 1)}
    '; then
        ERRORS="${ERRORS}非文档代码变更的 review 报告必须在 1.2 提供定向验证执行证据\n"
    fi
fi
if ! printf '%s\n' "$FAMILY_SECTION" | awk '
    /^\|/ {count++}
    END {exit(count >= 3 ? 0 : 1)}
'; then
    ERRORS="${ERRORS}3.6 缺陷族覆盖度缺少有效表格内容\n"
fi
if ! previous_family_error=$(validate_previous_family_coverage 2>&1); then
    ERRORS="${ERRORS}${previous_family_error}\n"
fi
if ! optional_marker_error=$(validate_optional_markers 2>&1); then
    ERRORS="${ERRORS}${optional_marker_error}\n"
fi

if [ "$META_RESULT" = "passed" ]; then
    if grep -q '\[待修复\]' "$REPORT_FILE"; then
        ERRORS="${ERRORS}审查结果为 passed，但报告仍包含 [待修复] 项\n"
    fi
    if grep -q '\[可选\]' "$REPORT_FILE"; then
        ERRORS="${ERRORS}审查结果为 passed，但报告仍包含 [可选] 的 Minor 建议\n"
    fi
    if printf '%s\n' "$CONCLUSION_SECTION" | grep -qE '^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*\*\*需要修复\*\*'; then
        ERRORS="${ERRORS}审查结果为 passed，但审查结论勾选了需要修复\n"
    fi
    if printf '%s\n' "$CONCLUSION_SECTION" | grep -qE '^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*\*\*通过（附建议）\*\*'; then
        ERRORS="${ERRORS}审查结果为 passed，但审查结论勾选了通过（附建议）\n"
    fi
    if printf '%s\n' "$OVERALL_SECTION" | grep -qE '^[[:space:]]*(需要修复|存在风险)([[:space:]]|[。；;，,、.]|$)'; then
        ERRORS="${ERRORS}审查结果为 passed，但总体评价描述为需要修复或存在风险\n"
    fi
fi
if [ "$META_RESULT" = "passed_with_notes" ]; then
    if grep -qE '\| (DEF-[0-9]+|SUG-[0-9]+) \| (Critical|Important)' "$REPORT_FILE"; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但报告仍存在 Critical/Important 缺陷\n"
    fi
    if grep -q '\[待修复\]' "$REPORT_FILE"; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但报告仍包含 [待修复] 项\n"
    fi
    if ! grep -qE '^\| SUG-[0-9]+ \| Minor ' "$REPORT_FILE"; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但报告缺少 Minor 建议项\n"
    fi
    if ! grep -q '\[可选\]' "$REPORT_FILE"; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但报告缺少 [可选] 的 Minor 状态标记\n"
    fi
    if printf '%s\n' "$CONCLUSION_SECTION" | grep -qE '^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*\*\*需要修复\*\*'; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但审查结论勾选了需要修复\n"
    fi
    if ! printf '%s\n' "$CONCLUSION_SECTION" | grep -qE '^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*\*\*通过（附建议）\*\*'; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但审查结论未勾选通过（附建议）\n"
    fi
fi
if [ "$META_RESULT" = "failed" ] && ! grep -qE '\[待修复\]|DEF-[0-9]+|SUG-[0-9]+' "$REPORT_FILE"; then
    ERRORS="${ERRORS}审查结果为 failed，但缺少缺陷或追踪标记\n"
fi

if [ -n "$ERRORS" ]; then
    echo "⚠ 审查报告结构校验失败："
    echo -e "$ERRORS"
    echo "    报告文件已保留但标记为无效: $REPORT_FILE"
    exit 1
fi
echo "    结构校验通过"

# --- 严重度推导审查结果 ---
# 由 shell 脚本根据报告内容推导
# 规则：Critical/Important 存在 → failed；任何阻塞 [待修复] → failed；
#       只有 Minor（未处理项为 [可选]）→ passed_with_notes；无任何缺陷 → passed
SEVERITY_CRITICAL=$(grep -cE '^\| (DEF-[0-9]+|SUG-[0-9]+) \| (Critical|Important) ' "$REPORT_FILE" || true)
SEVERITY_MINOR=$(grep -cE '^\| (DEF-[0-9]+|SUG-[0-9]+) \| Minor ' "$REPORT_FILE" || true)
TODO_MARKERS=$(grep -c '\[待修复\]' "$REPORT_FILE" || true)

if [ "$SEVERITY_CRITICAL" -gt 0 ] || [ "$TODO_MARKERS" -gt 0 ]; then
    DERIVED_RESULT="failed"
elif [ "$SEVERITY_MINOR" -gt 0 ]; then
    DERIVED_RESULT="passed_with_notes"
else
    DERIVED_RESULT="passed"
fi

echo ""
echo ">>> 严重度推导: Critical/Important=${SEVERITY_CRITICAL}, Minor=${SEVERITY_MINOR}, 待修复=${TODO_MARKERS}"
echo "    推导结果: ${DERIVED_RESULT}"

if [ "$META_RESULT" != "$DERIVED_RESULT" ]; then
    echo "    警告: 审查引擎自评结果为 ${META_RESULT}，但 shell 推导为 ${DERIVED_RESULT}"
    echo "    以 shell 推导结果为准，将覆盖为 ${DERIVED_RESULT}"
fi
RESULT="$DERIVED_RESULT"

echo ">>> 更新状态文件..."
"$FLOW_STATE_SH" record-review --slug "$SLUG" --mode "$REVIEW_MODE" --result "$RESULT" --report-file "$REPORT_FILE"
UPDATED_STATUS=$(state_field "$SLUG" "current_status")
echo "    状态已验证为 [$UPDATED_STATUS]"

print_commit_instructions() {
    echo ">>> 状态已进入 [DONE]，现在允许提交已审查的未提交变更"
    if [ -f "$CLAUDE_HOME/skills/git-commit/SKILL.md" ]; then
        echo "    检测到 git-commit 技能：请使用 /git-commit 提交代码"
    else
        echo "    未检测到 git-commit 技能：请按项目提交规范提交；若项目无明确规范，使用 Gitmoji + Conventional Commits"
    fi
}

case "$UPDATED_STATUS" in
    DONE)
        if [ "$REVIEW_MODE" = "recheck" ]; then
            echo ">>> 再审查通过，状态保持 [DONE]"
        elif [ "$RESULT" = "passed_with_notes" ]; then
            echo ">>> 常规审查通过（存在 Minor 建议），状态已更新为 [DONE]"
        else
            echo ">>> 常规审查通过，状态已更新为 [DONE]"
        fi
        print_commit_instructions
        ;;
    REVIEW_FAILED)
        echo ">>> 审查发现问题，状态已更新为 [REVIEW_FAILED]"
        ;;
    *)
        echo "错误: record-review 后出现意外状态 [$UPDATED_STATUS]"
        exit 1
        ;;
esac
