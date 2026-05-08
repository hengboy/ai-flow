#!/bin/bash
# coding-review-executor.sh — 审查计划内编码或独立改动，并输出固定摘要协议

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$AGENT_DIR/lib/agent-common.sh"
exec 3>&1 1>&2

PROJECT_DIR="$(pwd)"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
REPORTS_DIR="$FLOW_DIR/reports"
TEMPLATE="$AGENT_DIR/templates/review-template.md"
PROMPT_TEMPLATE="$AGENT_DIR/prompts/review-generation.md"
AI_FLOW_HOME="${AI_FLOW_HOME:-$HOME/.config/ai-flow}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
FLOW_STATE_SH="$AI_FLOW_HOME/scripts/flow-state.sh"
REVIEW_OPENCODE_MODEL="${AI_FLOW_REVIEW_OPENCODE_MODEL:-zhipuai-coding-plan/glm-5.1}"
WORKSPACE_ROOT=""
IS_WORKSPACE_MODE=0
WORKSPACE_REPOS=()    # parallel arrays: _IDS and _PATHS
WORKSPACE_REPO_IDS=()
WORKSPACE_REPO_PATHS=()
PROTOCOL_ARTIFACT="none"
PROTOCOL_STATE="none"
PROTOCOL_NEXT="none"
PROTOCOL_REVIEW_RESULT="failed"
PROTOCOL_SUMMARY=""
PROTOCOL_EMITTED=0

detect_workspace_context() {
    if [ ! -f "$PROJECT_DIR/.ai-flow/workspace.json" ]; then
        return 1
    fi
    IS_WORKSPACE_MODE=1
    WORKSPACE_ROOT="$PROJECT_DIR"
    while IFS=$'\t' read -r repo_id repo_path; do
        WORKSPACE_REPO_IDS+=("$repo_id")
        WORKSPACE_REPO_PATHS+=("$repo_path")
    done < <(python3 - "$PROJECT_DIR/.ai-flow/workspace.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for repo in data.get("repos", []):
    print(f"{repo['id']}\t{repo['path']}")
PY
    )
    return 0
}
detect_workspace_context || true

emit_current_protocol() {
    PROTOCOL_EMITTED=1
    emit_protocol "success" "$PROTOCOL_ARTIFACT" "$PROTOCOL_STATE" "$PROTOCOL_NEXT" "$PROTOCOL_SUMMARY" "$PROTOCOL_REVIEW_RESULT"
}

fail_protocol() {
    local summary="$1"
    PROTOCOL_EMITTED=1
    emit_protocol "failed" "$PROTOCOL_ARTIFACT" "$PROTOCOL_STATE" "$PROTOCOL_NEXT" "$summary" "${2:-$PROTOCOL_REVIEW_RESULT}"
    exit 1
}

trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "$PROTOCOL_EMITTED" -eq 0 ]; then emit_protocol "failed" "$PROTOCOL_ARTIFACT" "$PROTOCOL_STATE" "$PROTOCOL_NEXT" "${PROTOCOL_SUMMARY:-执行失败}" "${PROTOCOL_REVIEW_RESULT:-failed}"; fi' EXIT

require_file() {
    local path="$1"
    local label="$2"
    if [ -f "$path" ]; then
        return 0
    fi
    fail_protocol "缺少${label}: $path"
}

validate_installed_resources() {
    require_file "$FLOW_STATE_SH" "AI Flow runtime 脚本 flow-state.sh"
    require_file "$TEMPLATE" "review 模板"
    require_file "$PROMPT_TEMPLATE" "review prompt"
}

validate_installed_resources

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\/&]/\\&/g'
}

map_reasoning_to_opencode_variant() {
    case "$1" in
        xhigh) echo "max" ;;
        high) echo "high" ;;
        *) echo "minimal" ;;
    esac
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

render_adhoc_template() {
    local engine="$1"
    local model_name="$2"
    local reasoning="$3"
    local tool_label="${engine} (${model_name} ${reasoning})"

    sed \
        -e "s/{需求名称}/独立改动/g" \
        -e "s/{需求简称}/adhoc/g" \
        -e "s/{审查模式}/adhoc/g" \
        -e "s/{审查轮次}/1/g" \
        -e "s/{审查结果}/passed/g" \
        -e "s#{计划文件}#无绑定计划（独立模式）#g" \
        -e "s/{YYYY-MM-DD}/$(date +%Y-%m-%d)/g" \
        -e "s/{模型名}/${model_name}/g" \
        -e "s/{推理强度}/${reasoning}/g" \
        -e "s/{审查工具}/$(escape_sed_replacement "$tool_label")/g" \
        "$TEMPLATE"
}

render_adhoc_prompt() {
    local template_content="$1"
    AI_FLOW_REVIEW_SCOPE_GUIDANCE="这是 adhoc review：没有绑定 slug 和实施计划，只基于当前 Git 未提交改动审查正确性、回归风险、验证证据和范围控制。" \
    AI_FLOW_HISTORY_RULES=$'5. 如果本轮发现缺陷，按严重级别写入"4. 缺陷清单"，并同步更新"6. 缺陷修复追踪"。\n6. 对于独立模式，没有上一轮状态上下文；仅基于当前工作区给出结论。' \
    AI_FLOW_PLAN_CONTENT="独立模式：无绑定 slug，无状态文件，无计划文档。本轮仅审查当前 Git 未提交改动，并在 2.1 中记录真正需要确认或回退的计划外变更。" \
    AI_FLOW_HISTORY_CONTEXT="" \
    AI_FLOW_TEMPLATE_CONTENT="$template_content" \
    AI_FLOW_SLUG="adhoc" \
    AI_FLOW_REVIEW_MODE="adhoc" \
    AI_FLOW_CURRENT_ROUND="1" \
    AI_FLOW_PLAN_TITLE="独立改动" \
    AI_FLOW_WORKSPACE_CONTEXT="" \
    python3 - "$PROMPT_TEMPLATE" <<'PY'
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
    "__AI_FLOW_WORKSPACE_CONTEXT__": os.environ.get("AI_FLOW_WORKSPACE_CONTEXT", ""),
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
sys.stdout.write(text)
PY
}

looks_like_reasoning() {
    case "${1:-}" in
        high|xhigh|medium|low|minimal|max)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

looks_like_model_override() {
    case "${1:-}" in
        gpt-*|o*|glm*|zhipuai-coding-plan/*|qwen*|claude*|gemini*|deepseek*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

apply_review_arg_compat() {
    local first_extra="${1:-}"
    local second_extra="${2:-}"
    local third_extra="${3:-}"

    if [ -z "$first_extra" ]; then
        return 0
    fi

    if looks_like_reasoning "$first_extra"; then
        REASONING="$first_extra"
        ROUND_OVERRIDE="${second_extra:-}"
        return 0
    fi

    if looks_like_model_override "$first_extra"; then
        if looks_like_reasoning "$second_extra"; then
            REASONING="$second_extra"
            ROUND_OVERRIDE="${third_extra:-}"
        else
            ROUND_OVERRIDE="${second_extra:-}"
        fi
        return 0
    fi

    ROUND_OVERRIDE="$first_extra"
}

apply_adhoc_arg_compat() {
    local first_extra="${1:-}"
    local second_extra="${2:-}"

    if looks_like_reasoning "$first_extra"; then
        REASONING="$first_extra"
        return 0
    fi

    if looks_like_model_override "$first_extra" && looks_like_reasoning "$second_extra"; then
        REASONING="$second_extra"
    fi
}

derive_result() {
    local report_file="$1"
    local critical minor todo
    critical=$(grep -cE '^\| (DEF-[0-9]+|SUG-[0-9]+) \| (Critical|Important) ' "$report_file" || true)
    minor=$(grep -cE '^\| (DEF-[0-9]+|SUG-[0-9]+) \| Minor ' "$report_file" || true)
    todo=$(count_issue_status_marker "$report_file" "[待修复]")
    if [ "$critical" -gt 0 ] || [ "$todo" -gt 0 ]; then
        echo "failed"
    elif [ "$minor" -gt 0 ]; then
        echo "passed_with_notes"
    else
        echo "passed"
    fi
}

count_issue_status_marker() {
    local report_file="$1"
    local marker="$2"
    python3 - "$report_file" "$marker" <<'PY'
import re
import sys
from pathlib import Path

pattern = re.compile(r'^\| [A-Z]+[0-9-]+ \|')
marker = sys.argv[2]
count = 0
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if pattern.match(line) and marker in line:
        count += 1
print(count)
PY
}

has_issue_status_marker() {
    local report_file="$1"
    local marker="$2"
    [ "$(count_issue_status_marker "$report_file" "$marker")" -gt 0 ]
}

default_reasoning_for_engine() {
    case "$1" in
        opencode) echo "${AI_FLOW_OPENCODE_DEFAULT_REASONING:-max}" ;;
        *) echo "${AI_FLOW_CODEX_DEFAULT_REASONING:-xhigh}" ;;
    esac
}

run_codex_review_prompt() {
    local prompt="$1"
    if [ -z "${CODEX_SKIP_GIT_REPO_CHECK_SUPPORTED:-}" ]; then
        if codex exec --help 2>/dev/null | grep -q -- '--skip-git-repo-check'; then
            CODEX_SKIP_GIT_REPO_CHECK_SUPPORTED=1
        else
            CODEX_SKIP_GIT_REPO_CHECK_SUPPORTED=0
        fi
    fi

    local -a codex_args
    codex_args=(exec -m "$MODEL" -C "$PROJECT_DIR" -c "model_reasoning_effort=\"$REASONING\"" --sandbox workspace-write -o "$REPORT_FILE")
    if [ "$CODEX_SKIP_GIT_REPO_CHECK_SUPPORTED" = "1" ]; then
        codex_args+=(--skip-git-repo-check)
    fi

    printf '%s\n' "$prompt" | codex "${codex_args[@]}"
}

run_opencode_review_prompt() {
    local prompt="$1"
    local model_name="$2"
    local reasoning="$3"
    opencode run \
        -m "$model_name" \
        --variant "$reasoning" \
        --dangerously-skip-permissions \
        --format default \
        --dir "$PROJECT_DIR" \
        "$prompt" > "$REPORT_FILE"
    trim_report_to_header "$REPORT_FILE"
}

is_codex_unavailable_error() {
    local rc="$1"
    local stderr_file="$2"
    if [ "$rc" -eq 127 ]; then
        return 0
    fi
    grep -qiE 'command not found|codex unavailable|codex 未安装|not installed|No such file|unavailable' "$stderr_file"
}

render_prompt_template() {
    local prompt_template="$1"
    local workspace_ctx=""
    if [ "$IS_WORKSPACE_MODE" -eq 1 ]; then
        workspace_ctx="workspace"
        local i
        for i in "${!WORKSPACE_REPO_IDS[@]}"; do
            workspace_ctx="${workspace_ctx}; repo=${WORKSPACE_REPO_IDS[$i]} path=${WORKSPACE_REPO_PATHS[$i]}"
        done
    fi
    AI_FLOW_REVIEW_SCOPE_GUIDANCE="$REVIEW_SCOPE_GUIDANCE" \
    AI_FLOW_HISTORY_RULES="$HISTORY_RULES" \
    AI_FLOW_PLAN_CONTENT="$PLAN_CONTENT" \
    AI_FLOW_HISTORY_CONTEXT="$HISTORY_CONTEXT" \
    AI_FLOW_TEMPLATE_CONTENT="$TEMPLATE_CONTENT" \
    AI_FLOW_SLUG="$SLUG" \
    AI_FLOW_REVIEW_MODE="$REVIEW_MODE" \
    AI_FLOW_CURRENT_ROUND="$CURRENT_ROUND" \
    AI_FLOW_PLAN_TITLE="$PLAN_TITLE" \
    AI_FLOW_WORKSPACE_CONTEXT="$workspace_ctx" \
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
    "__AI_FLOW_WORKSPACE_CONTEXT__": os.environ.get("AI_FLOW_WORKSPACE_CONTEXT", ""),
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
    if [ "$IS_WORKSPACE_MODE" -eq 1 ]; then
        # Workspace mode: check each declared repo for changes
        local any_changes=0
        local i
        for i in "${!WORKSPACE_REPO_PATHS[@]}"; do
            local repo_path="${WORKSPACE_REPO_PATHS[$i]}"
            local repo_id="${WORKSPACE_REPO_IDS[$i]}"
            if ! git -C "$WORKSPACE_ROOT/$repo_path" rev-parse --show-toplevel >/dev/null 2>&1; then
                fail_protocol "声明的仓库 '${repo_id}' ($repo_path) 不是有效的 Git 仓库"
            fi
            local changes
            changes=$(git -C "$WORKSPACE_ROOT/$repo_path" status --porcelain --untracked-files=all 2>/dev/null || true)
            if [ -n "$changes" ]; then
                any_changes=1
            fi
        done
        if [ "$any_changes" -eq 0 ]; then
            fail_protocol "所有声明的仓库均无可审查的 Git 变更"
        fi
    else
        if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            fail_protocol "当前目录不是 Git 仓库，无法确认审查范围"
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
            fail_protocol "没有可审查的 Git 变更（已忽略 .ai-flow/ 元数据）"
        fi
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

    local gate_error=""
    if ! gate_error=$(python3 - "$STATE_FILE" "$PLAN_FILE" 2>&1 <<'PY'
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
    ); then
        fail_protocol "$(normalize_one_line "$gate_error")"
    fi
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

REQUEST_KEY="${1:-}"
MODEL="$(default_model_for_engine "$AGENT_ENGINE")"
REASONING="$(default_reasoning_for_engine "$AGENT_ENGINE")"
ROUND_OVERRIDE=""
ARG2="${2:-}"
ARG3="${3:-}"
ARG4="${4:-}"
DATE_DIR="$(date +%Y%m%d)"
STATE_FILE=""
ADHOC_MODE=0

if [ -n "$REQUEST_KEY" ]; then
    MATCHED_STATES=()
    while IFS= read -r -d '' f; do
        MATCHED_STATES+=("$f")
    done < <(find "$FLOW_DIR/state" -name "*${REQUEST_KEY}*.json" -type f -print0 2>/dev/null)

    if [ ${#MATCHED_STATES[@]} -eq 0 ]; then
        if looks_like_reasoning "$REQUEST_KEY" || looks_like_model_override "$REQUEST_KEY"; then
            ADHOC_MODE=1
            apply_adhoc_arg_compat "$REQUEST_KEY" "$ARG2"
        else
            fail_protocol "找不到匹配 slug/关键词 '$REQUEST_KEY' 的状态文件"
        fi
    elif [ ${#MATCHED_STATES[@]} -gt 1 ]; then
        fail_protocol "关键词 '$REQUEST_KEY' 匹配到多个状态文件，请使用精确 slug"
    else
        STATE_FILE="${MATCHED_STATES[0]}"
        apply_review_arg_compat "$ARG2" "$ARG3" "$ARG4"
    fi
else
    ADHOC_MODE=1
    MODEL="$(default_model_for_engine "$AGENT_ENGINE")"
    REASONING="$(default_reasoning_for_engine "$AGENT_ENGINE")"
fi

if [ "$ADHOC_MODE" -eq 1 ]; then
    ensure_reviewable_git_changes
    mkdir -p "$REPORTS_DIR/adhoc/$DATE_DIR"
    REPORT_FILE="$REPORTS_DIR/adhoc/$DATE_DIR/adhoc-review-$(date +%H%M%S).md"
    PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$REPORT_FILE")"
    OPENCODE_REASONING=$(map_reasoning_to_opencode_variant "$REASONING")
    ACTIVE_ENGINE="Codex"
    ACTIVE_MODEL="$MODEL"
    ACTIVE_REASONING="$REASONING"
    if [ "$AGENT_ENGINE" = "opencode" ] || [ "${AI_FLOW_REVIEW_FORCE_OPENCODE:-0}" = "1" ] || ! command -v codex >/dev/null 2>&1; then
        ACTIVE_ENGINE="OpenCode"
        ACTIVE_MODEL="${MODEL:-$REVIEW_OPENCODE_MODEL}"
        ACTIVE_REASONING="${REASONING:-$(default_reasoning_for_engine opencode)}"
    fi
    if [ "$ACTIVE_ENGINE" = "OpenCode" ] && ! command -v opencode >/dev/null 2>&1; then
        fail_protocol "OpenCode 不可用，无法执行 adhoc 审查"
    fi

    TEMPLATE_CONTENT=$(render_adhoc_template "$ACTIVE_ENGINE" "$ACTIVE_MODEL" "$ACTIVE_REASONING")
    REVIEW_PROMPT=$(render_adhoc_prompt "$TEMPLATE_CONTENT")

    if [ "$ACTIVE_ENGINE" = "Codex" ]; then
        stderr_file=$(mktemp)
        set +e
        run_codex_review_prompt "$REVIEW_PROMPT" 2>"$stderr_file"
        rc=$?
        set -e
        if [ "$rc" -ne 0 ]; then
            if is_codex_unavailable_error "$rc" "$stderr_file"; then
                if ! command -v opencode >/dev/null 2>&1; then
                    cat "$stderr_file" >&2
                    rm -f "$stderr_file"
                    fail_protocol "Codex 不可用，且 opencode 未安装，无法执行 adhoc 审查"
                fi
                ACTIVE_ENGINE="OpenCode"
                ACTIVE_MODEL="$REVIEW_OPENCODE_MODEL"
                ACTIVE_REASONING="$OPENCODE_REASONING"
                TEMPLATE_CONTENT=$(render_adhoc_template "$ACTIVE_ENGINE" "$ACTIVE_MODEL" "$ACTIVE_REASONING")
                REVIEW_PROMPT=$(render_adhoc_prompt "$TEMPLATE_CONTENT")
                run_opencode_review_prompt "$REVIEW_PROMPT" "$ACTIVE_MODEL" "$ACTIVE_REASONING"
            else
                cat "$stderr_file" >&2
                rm -f "$stderr_file"
                fail_protocol "Codex 执行 adhoc 审查失败，且不属于可降级场景"
            fi
        fi
        rm -f "$stderr_file"
    else
        run_opencode_review_prompt "$REVIEW_PROMPT" "$ACTIVE_MODEL" "$ACTIVE_REASONING"
    fi

    if ! head -1 "$REPORT_FILE" | grep -qE '^# 审查报告：'; then
        fail_protocol "adhoc 审查报告首行非法: $REPORT_FILE"
    fi

    RESULT="$(derive_result "$REPORT_FILE")"
    PROTOCOL_REVIEW_RESULT="$RESULT"
    PROTOCOL_STATE="none"
    PROTOCOL_NEXT="none"
    PROTOCOL_SUMMARY="adhoc 审查完成，结果为 [$RESULT]。"
    if [ "$ACTIVE_ENGINE" = "OpenCode" ] && [ "$AGENT_ENGINE" = "codex" ]; then
        PROTOCOL_SUMMARY="${PROTOCOL_SUMMARY%?} 已降级到 OpenCode。"
    fi
    emit_current_protocol
    exit 0
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
        PROTOCOL_STATE="$PLAN_STATUS"
        fail_protocol "当前状态为 [$PLAN_STATUS]，常规审查只允许 [AWAITING_REVIEW]；再审查只允许 [DONE]"
        ;;
esac

if [ -n "$ROUND_OVERRIDE" ]; then
    if ! [[ "$ROUND_OVERRIDE" =~ ^[0-9]+$ ]] || [ "$ROUND_OVERRIDE" -le 0 ]; then
        fail_protocol "轮次必须是正整数: $ROUND_OVERRIDE"
    fi
    if [ "$ROUND_OVERRIDE" -ne "$CURRENT_ROUND" ]; then
        fail_protocol "轮次以状态文件中的 review_rounds 为准，当前应为第 $CURRENT_ROUND 轮，不能写入第 $ROUND_OVERRIDE 轮"
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
PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$REPORT_FILE")"

if [ -e "$REPORT_FILE" ]; then
    fail_protocol "报告文件已存在，拒绝覆盖: $REPORT_FILE"
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

OPENCODE_REASONING=$(map_reasoning_to_opencode_variant "$REASONING")
ACTIVE_ENGINE="Codex"
ACTIVE_MODEL="$MODEL"
ACTIVE_REASONING="$REASONING"
if [ "$AGENT_ENGINE" = "opencode" ]; then
    ACTIVE_ENGINE="OpenCode"
    ACTIVE_MODEL="${MODEL:-$REVIEW_OPENCODE_MODEL}"
    ACTIVE_REASONING="${REASONING:-$(default_reasoning_for_engine opencode)}"
elif [ "${AI_FLOW_REVIEW_FORCE_OPENCODE:-0}" = "1" ] || ! command -v codex >/dev/null 2>&1; then
    if ! command -v opencode >/dev/null 2>&1; then
        fail_protocol "Codex 不可用，且 opencode 未安装，无法执行审查"
    fi
    ACTIVE_ENGINE="OpenCode"
    ACTIVE_MODEL="$REVIEW_OPENCODE_MODEL"
    ACTIVE_REASONING="$OPENCODE_REASONING"
fi

echo ">>> 匹配到状态: $SLUG [$PLAN_STATUS]"
echo "    对比计划: $PLAN_FILE"
echo "    审查模式: $REVIEW_MODE"
echo "    审查轮次: $CURRENT_ROUND"
echo "    审查引擎: $ACTIVE_ENGINE ($ACTIVE_MODEL $ACTIVE_REASONING)"
echo "    输出文件: $REPORT_FILE"
if [ -n "$PREV_REVIEW" ]; then
    echo "    上一轮报告: ${PREV_REVIEW}（用于缺陷正文与追踪）"
fi
echo ""

PLAN_CONTENT=$(cat "$PLAN_FILE")
for required_file in "$FLOW_STATE_SH" "$TEMPLATE" "$PROMPT_TEMPLATE"; do
    if [ ! -f "$required_file" ]; then
        fail_protocol "缺少运行时资源: $required_file"
    fi
done
TEMPLATE_CONTENT=$(render_template_content "$ACTIVE_ENGINE" "$ACTIVE_MODEL" "$ACTIVE_REASONING")

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
5. 必须同时参考上一轮"4. 缺陷清单"和"6. 缺陷修复追踪"：
   - 已修复项要重新验证；修复无效或不完整时，必须改回 [待修复] 并重新列入缺陷清单
   - Minor 建议未处理时保持 [可选]；只有严重度升级为 Critical/Important 时才改为 [待修复]
   - 上一轮涉及的缺陷族，本轮必须在"3.6 缺陷族覆盖度"中逐项写出已覆盖 / 未覆盖 / 需人工验证及原因
   - 不要只继承 DEF 编号状态，要继承上一轮严重缺陷的正文语义、影响面和修复追踪
6. 仅列出当前仍未修复的缺陷和新增缺陷到"4. 缺陷清单"；"6. 缺陷修复追踪"需要保留并更新历史条目。
EOF
)
fi

REVIEW_PROMPT=$(render_prompt_template "$PROMPT_TEMPLATE")

if [ "$ACTIVE_ENGINE" = "Codex" ]; then
    echo ">>> 调用 codex ($MODEL) 审查中..."
    stderr_file=$(mktemp)
    set +e
    run_codex_review_prompt "$REVIEW_PROMPT" 2>"$stderr_file"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if is_codex_unavailable_error "$rc" "$stderr_file"; then
            if ! command -v opencode >/dev/null 2>&1; then
                cat "$stderr_file" >&2
                rm -f "$stderr_file"
                fail_protocol "Codex 不可用，且 opencode 未安装，无法执行审查"
            fi
            echo ">>> Codex 不可用，降级到 OpenCode ($REVIEW_OPENCODE_MODEL)"
            ACTIVE_ENGINE="OpenCode"
            ACTIVE_MODEL="$REVIEW_OPENCODE_MODEL"
            ACTIVE_REASONING="$OPENCODE_REASONING"
            TEMPLATE_CONTENT=$(render_template_content "$ACTIVE_ENGINE" "$ACTIVE_MODEL" "$ACTIVE_REASONING")
            REVIEW_PROMPT=$(render_prompt_template "$PROMPT_TEMPLATE")
            run_opencode_review_prompt "$REVIEW_PROMPT" "$ACTIVE_MODEL" "$ACTIVE_REASONING"
        else
            cat "$stderr_file" >&2
            rm -f "$stderr_file"
            fail_protocol "Codex 执行审查失败，且不属于可降级的不可用场景"
        fi
    fi
    rm -f "$stderr_file"
else
    echo ">>> 调用 opencode ($ACTIVE_MODEL) 审查中..."
    run_opencode_review_prompt "$REVIEW_PROMPT" "$ACTIVE_MODEL" "$ACTIVE_REASONING"
fi

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
    if has_issue_status_marker "$REPORT_FILE" "[待修复]"; then
        ERRORS="${ERRORS}审查结果为 passed，但报告仍包含 [待修复] 项\n"
    fi
    if has_issue_status_marker "$REPORT_FILE" "[可选]"; then
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
    if has_issue_status_marker "$REPORT_FILE" "[待修复]"; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但报告仍包含 [待修复] 项\n"
    fi
    if ! grep -qE '^\| SUG-[0-9]+ \| Minor ' "$REPORT_FILE"; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但报告缺少 Minor 建议项\n"
    fi
    if ! has_issue_status_marker "$REPORT_FILE" "[可选]"; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但报告缺少 [可选] 的 Minor 状态标记\n"
    fi
    if printf '%s\n' "$CONCLUSION_SECTION" | grep -qE '^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*\*\*需要修复\*\*'; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但审查结论勾选了需要修复\n"
    fi
    if ! printf '%s\n' "$CONCLUSION_SECTION" | grep -qE '^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*\*\*通过（附建议）\*\*'; then
        ERRORS="${ERRORS}审查结果为 passed_with_notes，但审查结论未勾选通过（附建议）\n"
    fi
fi
if [ "$META_RESULT" = "failed" ] && ! grep -qE '^\| [A-Z]+[0-9-]+ \|' "$REPORT_FILE" && ! has_issue_status_marker "$REPORT_FILE" "[待修复]"; then
    ERRORS="${ERRORS}审查结果为 failed，但缺少缺陷或追踪标记\n"
fi

if [ -n "$ERRORS" ]; then
    echo "⚠ 审查报告结构校验失败："
    echo -e "$ERRORS"
    echo "    报告文件已保留但标记为无效: $REPORT_FILE"
    fail_protocol "审查报告结构校验失败: $(normalize_one_line "$ERRORS")"
fi
echo "    结构校验通过"

# --- 严重度推导审查结果 ---
# 由 shell 脚本根据报告内容推导，不依赖 Codex 自评
# 规则：Critical/Important 存在 → failed；任何阻塞 [待修复] → failed；
#       只有 Minor（未处理项为 [可选]）→ passed_with_notes；无任何缺陷 → passed
SEVERITY_CRITICAL=$(grep -cE '^\| (DEF-[0-9]+|SUG-[0-9]+) \| (Critical|Important) ' "$REPORT_FILE" || true)
SEVERITY_MINOR=$(grep -cE '^\| (DEF-[0-9]+|SUG-[0-9]+) \| Minor ' "$REPORT_FILE" || true)
TODO_MARKERS=$(count_issue_status_marker "$REPORT_FILE" "[待修复]")

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

# 校验 Codex 自评结果与推导结果是否一致
if [ "$META_RESULT" != "$DERIVED_RESULT" ]; then
    echo "    警告: 审查引擎自评结果为 ${META_RESULT}，但 shell 推导为 ${DERIVED_RESULT}"
    echo "    以 shell 推导结果为准，将覆盖为 ${DERIVED_RESULT}"
fi
RESULT="$DERIVED_RESULT"

echo ">>> 更新状态文件..."
AI_FLOW_ACTOR="$AGENT_NAME" "$FLOW_STATE_SH" record-review \
    --slug "$SLUG" \
    --mode "$REVIEW_MODE" \
    --result "$RESULT" \
    --report-file "$REPORT_FILE"
UPDATED_STATUS=$(state_field "$SLUG" "current_status")
echo "    状态已验证为 [$UPDATED_STATUS]"
PROTOCOL_STATE="$UPDATED_STATUS"
PROTOCOL_REVIEW_RESULT="$RESULT"

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
            PROTOCOL_SUMMARY="recheck 审查通过，状态保持 [DONE]。"
        elif [ "$RESULT" = "passed_with_notes" ]; then
            echo ">>> 常规审查通过（存在 Minor 建议），状态已更新为 [DONE]"
            PROTOCOL_SUMMARY="常规审查通过（附 Minor 建议），状态进入 [DONE]。"
        else
            echo ">>> 常规审查通过，状态已更新为 [DONE]"
            PROTOCOL_SUMMARY="常规审查通过，状态进入 [DONE]。"
        fi
        PROTOCOL_NEXT="none"
        print_commit_instructions
        ;;
    REVIEW_FAILED)
        echo ">>> 审查发现问题，状态已更新为 [REVIEW_FAILED]"
        PROTOCOL_SUMMARY="审查未通过，状态进入 [REVIEW_FAILED]。"
        PROTOCOL_NEXT="ai-flow-plan-coding"
        ;;
    *)
        fail_protocol "record-review 后出现意外状态 [$UPDATED_STATUS]"
        ;;
esac

if [ "$ACTIVE_ENGINE" = "OpenCode" ] && [ "$AGENT_ENGINE" = "codex" ]; then
    PROTOCOL_SUMMARY="${PROTOCOL_SUMMARY%?} 已降级到 OpenCode。"
fi
emit_current_protocol
