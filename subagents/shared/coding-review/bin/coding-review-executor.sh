#!/bin/bash
# coding-review-executor.sh — 审查计划内编码或独立改动，并输出固定摘要协议

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$AGENT_DIR/lib/agent-common.sh"
exec 3>&1 1>&2

REVIEW_ENGINE_MODE="${ENGINE_MODE_OVERRIDE:-auto}"

ORIGINAL_PROJECT_DIR="$(pwd)"
PROJECT_DIR="$ORIGINAL_PROJECT_DIR"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
REPORTS_DIR="$FLOW_DIR/reports"
TEMPLATE="$AGENT_DIR/templates/review-template.md"
PROMPT_TEMPLATE="$AGENT_DIR/prompts/review-generation.md"
AI_FLOW_HOME="${AI_FLOW_HOME:-$HOME/.config/ai-flow}"
CLAUDE_HOME="$HOME/.claude"
FLOW_STATE_SH="$AI_FLOW_HOME/scripts/flow-state.sh"
IS_PLAN_REPOS_MODE=0
PLAN_REPO_IDS=()
PLAN_REPO_PATHS=()
PLAN_REPO_GIT_ROOTS=()
PLAN_REPO_ROLES=()
PROTOCOL_ARTIFACT="none"
PROTOCOL_STATE="none"
PROTOCOL_NEXT="none"
PROTOCOL_REVIEW_RESULT="failed"
PROTOCOL_SUMMARY=""
PROTOCOL_EMITTED=0

cd "$PROJECT_DIR"

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

resolve_project_path() {
    local path="${1:-}"
    if [ -z "$path" ] || [ "$path" = "none" ]; then
        printf '%s' "$path"
        return 0
    fi
    case "$path" in
        /*)
            printf '%s' "$path"
            ;;
        *)
            printf '%s/%s' "$PROJECT_DIR" "$path"
            ;;
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
    local slug_val="${SLUG:-adhoc}"

    sed \
        -e "s/{需求名称}/$(escape_sed_replacement "$PLAN_TITLE")/g" \
        -e "s/{需求简称}/$(escape_sed_replacement "$slug_val")/g" \
        -e "s/{审查模式}/$(escape_sed_replacement "$REVIEW_MODE")/g" \
        -e "s/{审查轮次}/$(escape_sed_replacement "$CURRENT_ROUND")/g" \
        -e "s#{计划文件}#$(escape_sed_replacement "$PLAN_FILE")#g" \
        -e "s/{YYYY-MM-DD}/$(date +%Y-%m-%d)/g" \
        -e "s/{模型名}/$(escape_sed_replacement "$model_name")/g" \
        -e "s/{推理强度}/$(escape_sed_replacement "$reasoning")/g" \
        -e "s/{审查工具}/$(escape_sed_replacement "$tool_label")/g" \
        "$TEMPLATE"
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

is_codex_unavailable_error() {
    local rc="$1"
    local stderr_file="$2"
    if [ "$rc" -eq 127 ]; then
        return 0
    fi
    grep -qiE 'command not found|codex unavailable|codex 未安装|not installed|No such file|unavailable|model not found|model not available|model .*does not exist|invalid model|quota exceeded|rate limit|429|too many requests|exceeded retry|service unavailable|5\d\d|model error' "$stderr_file"
}

render_prompt_template() {
    local prompt_template="$1"
    local repo_ctx=""
    if [ "$IS_PLAN_REPOS_MODE" -eq 1 ]; then
        repo_ctx=$(cat <<EOF
4. 当前为 plan_repos 模式。owner repo 根目录：\`$PROJECT_DIR\`
5. Plan 参与仓库清单（仅以下 repo 属于本次审查范围）：
EOF
)
        local i
        for i in "${!PLAN_REPO_IDS[@]}"; do
            repo_ctx="${repo_ctx}
   - repo=\`${PLAN_REPO_IDS[$i]}\` path=\`${PLAN_REPO_PATHS[$i]}\` git_root=\`${PLAN_REPO_GIT_ROOTS[$i]}\` role=\`${PLAN_REPO_ROLES[$i]}\`"
        done
        repo_ctx="${repo_ctx}
6. Plan repo 操作要求：
   - 必须逐仓运行 \`git -C <git_root> status --porcelain --untracked-files=all\`
   - 必须逐仓运行 \`git -C <git_root> diff --staged\` 与 \`git -C <git_root> diff\`
   - 对 untracked 文件必须直接读取文件内容，不能只看 diff
   - 报告中的文件路径必须写成 \`repo_id/path/to/file\`
   - \`1.1 审查上下文\` 必须列出全部 dirty repo，\`1.2 定向验证执行证据\` 必须每个 dirty repo 至少一条验证命令"
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
    AI_FLOW_WORKSPACE_CONTEXT="$repo_ctx" \
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

load_state_context() {
    local state_file="$1"
    python3 - "$state_file" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
review_rounds = state.get("review_rounds") or {}
last_review = state.get("last_review") or {}
fields = [
    state.get("current_status", ""),
    state.get("plan_file", ""),
    state.get("title", ""),
    review_rounds.get("regular", 0),
    review_rounds.get("recheck", 0),
    state.get("latest_regular_review_file") or "",
    state.get("latest_recheck_review_file") or "",
    last_review.get("result") or "",
    last_review.get("report_file") or "",
]
for value in fields:
    print(value)
PY
}

load_plan_repo_scope() {
    local state_file="$1"
    local scope_file scope_error
    scope_file="$(mktemp)"
    scope_error="$(mktemp)"
    PLAN_REPO_IDS=()
    PLAN_REPO_PATHS=()
    PLAN_REPO_GIT_ROOTS=()
    PLAN_REPO_ROLES=()
    if ! python3 - "$state_file" "$PROJECT_DIR" >"$scope_file" 2>"$scope_error" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
owner = Path(sys.argv[2]).resolve()
scope = state.get("execution_scope") or {}
if scope.get("mode") != "plan_repos":
    raise SystemExit("state execution_scope.mode 必须是 plan_repos")
repos = scope.get("repos") or []
if not repos:
    raise SystemExit("state execution_scope.repos 不能为空")
owner_count = sum(1 for repo in repos if repo.get("role") == "owner")
if owner_count != 1:
    raise SystemExit("state 必须且只能包含一个 role=owner 仓库")
seen = set()
for repo in repos:
    repo_id = repo.get("id")
    repo_path = repo.get("path")
    git_root = repo.get("git_root")
    role = repo.get("role")
    if not repo_id or repo_id in seen:
        raise SystemExit(f"state repo id 无效或重复: {repo_id}")
    seen.add(repo_id)
    if role not in {"owner", "participant"}:
        raise SystemExit(f"state repo {repo_id} role 非法")
    path = (owner / repo_path).resolve()
    if not path.exists():
        raise SystemExit(f"state repo {repo_id} 路径不存在: {repo_path}")
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise SystemExit(f"state repo {repo_id} 不是有效 Git 仓库: {repo_path}")
    resolved = Path(result.stdout.strip()).resolve()
    if resolved != Path(git_root).resolve():
        raise SystemExit(f"state repo {repo_id} git_root 与 path 解析结果不一致")
    print(json.dumps(dict(id=repo_id, path=repo_path, git_root=str(Path(git_root).resolve()), role=role), ensure_ascii=False))
PY
    then
        local error_text
        error_text="$(cat "$scope_error")"
        rm -f "$scope_file" "$scope_error"
        fail_protocol "${error_text:-读取 state execution_scope.repos 失败}"
    fi
    rm -f "$scope_error"

    while IFS= read -r repo_json; do
        [ -n "$repo_json" ] || continue
        local repo_id repo_path git_root role
        repo_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$repo_json")"
        repo_path="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["path"])' "$repo_json")"
        git_root="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["git_root"])' "$repo_json")"
        role="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["role"])' "$repo_json")"
        PLAN_REPO_IDS+=("$repo_id")
        PLAN_REPO_PATHS+=("$repo_path")
        PLAN_REPO_GIT_ROOTS+=("$git_root")
        PLAN_REPO_ROLES+=("$role")
    done < "$scope_file"
    rm -f "$scope_file"
    IS_PLAN_REPOS_MODE=1
}

find_owner_dir_for_state_keyword() {
    local keyword="$1"
    python3 - "$ORIGINAL_PROJECT_DIR" "$keyword" <<'PY'
import sys
from pathlib import Path

start = Path(sys.argv[1]).resolve()
keyword = sys.argv[2]
matches = []
for current in [start, *start.parents]:
    state_dir = current / ".ai-flow" / "state"
    if not state_dir.is_dir():
        continue
    matches.extend(state_dir.glob(f"*{keyword}*.json"))
if not matches:
    raise SystemExit(1)
owners = sorted({str(path.parent.parent.parent.resolve()) for path in matches})
if len(owners) > 1:
    raise SystemExit("slug 匹配到多个 owner repo，请从 owner repo 运行或使用更精确 slug")
print(owners[0])
PY
}

state_current_status() {
    local state_file="$1"
    python3 - "$state_file" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(state.get("current_status", ""))
PY
}

count_reviewable_git_paths() {
    list_reviewable_git_paths | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
}

list_plan_repo_reviewable_git_paths() {
    local i
    for i in "${!PLAN_REPO_GIT_ROOTS[@]}"; do
        local repo_id="${PLAN_REPO_IDS[$i]}"
        local git_root="${PLAN_REPO_GIT_ROOTS[$i]}"
        git -C "$git_root" status --porcelain --untracked-files=all 2>/dev/null | awk -v prefix="${repo_id}/" -v repo_path="${PLAN_REPO_PATHS[$i]}" -v repo_count="${#PLAN_REPO_IDS[@]}" '
            {
                path = substr($0, 4)
                if (path ~ /^\.ai-flow\//) {
                    next
                }
                if (repo_count > 1 && repo_path == ".") {
                    next
                }
                print prefix path
            }
        '
    done
}

list_plan_repo_dirty_repo_ids() {
    local i
    for i in "${!PLAN_REPO_GIT_ROOTS[@]}"; do
        local repo_id="${PLAN_REPO_IDS[$i]}"
        local git_root="${PLAN_REPO_GIT_ROOTS[$i]}"
        local changes
        changes="$(git -C "$git_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
        if [ -n "$(printf '%s\n' "$changes" | awk -v repo_path="${PLAN_REPO_PATHS[$i]}" -v repo_count="${#PLAN_REPO_IDS[@]}" '
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
        ')" ]; then
            printf '%s\n' "$repo_id"
        fi
    done
}

list_plan_repo_change_summary() {
    local i
    for i in "${!PLAN_REPO_GIT_ROOTS[@]}"; do
        local repo_id="${PLAN_REPO_IDS[$i]}"
        local git_root="${PLAN_REPO_GIT_ROOTS[$i]}"
        local changes
        changes="$(git -C "$git_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
        if [ -z "$changes" ]; then
            continue
        fi
        printf '[repo=%s]\n' "$repo_id"
        printf '%s\n' "$changes" | awk -v prefix="${repo_id}/" -v repo_path="${PLAN_REPO_PATHS[$i]}" -v repo_count="${#PLAN_REPO_IDS[@]}" '
            {
                path = substr($0, 4)
                if (path ~ /^\.ai-flow\//) {
                    next
                }
                if (repo_count > 1 && repo_path == ".") {
                    next
                }
                print substr($0, 1, 3) prefix path
            }
        '
    done
}

plan_repo_report_validation_error() {
    local dirty_repo_file
    dirty_repo_file="$(mktemp)"
    cat > "$dirty_repo_file"
    python3 - "$REPORT_FILE" "$dirty_repo_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
dirty_repos = [line.strip() for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines() if line.strip()]
errors = []

match_context = re.search(r"(?ms)^### 1\.1 .*?(?=^### 1\.2 |\Z)", text)
match_verification = re.search(r"(?ms)^### 1\.2 .*?(?=^## 2\. |\Z)", text)
context = match_context.group(0) if match_context else ""
verification = match_verification.group(0) if match_verification else ""

for repo_id in dirty_repos:
    if repo_id not in context:
        errors.append(f"plan_repos 报告缺少 dirty repo 上下文: {repo_id}")
    repo_prefix = f"{repo_id}/"
    if repo_prefix not in text:
        errors.append(f"plan_repos 报告缺少 repo 前缀文件路径: {repo_prefix}")
    if repo_id not in verification:
        errors.append(f"plan_repos 报告缺少 per-repo 验证证据: {repo_id}")

if errors:
    sys.stderr.write("\n".join(errors) + "\n")
    sys.exit(1)
PY
    local rc=$?
    rm -f "$dirty_repo_file"
    return "$rc"
}

review_reasoning() {
    local reasoning="$REASONING"

    local reviewable_paths="${1:-0}"
    local plan_lines="${2:-0}"
    local current_round="${3:-1}"
    local prev_review_present="${4:-0}"

    if [ "$IS_PLAN_REPOS_MODE" -eq 1 ] \
        || [ "$REVIEW_MODE" = "recheck" ] \
        || [ "$current_round" -ge 2 ] \
        || [ "$prev_review_present" -eq 1 ] \
        || [ "$reviewable_paths" -ge 8 ] \
        || [ "$plan_lines" -ge 220 ]; then
        reasoning="xhigh"
    fi

    echo "$reasoning"
}

ensure_reviewable_git_changes() {
    if [ "$IS_PLAN_REPOS_MODE" -eq 1 ]; then
        local any_changes=0
        local i
        for i in "${!PLAN_REPO_GIT_ROOTS[@]}"; do
            local repo_path="${PLAN_REPO_PATHS[$i]}"
            local repo_id="${PLAN_REPO_IDS[$i]}"
            local git_root="${PLAN_REPO_GIT_ROOTS[$i]}"
            if ! git -C "$git_root" rev-parse --show-toplevel >/dev/null 2>&1; then
                fail_protocol "声明的仓库 '${repo_id}' ($repo_path) 不是有效的 Git 仓库"
            fi
            local changes
            changes="$(git -C "$git_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
            if [ -n "$(printf '%s\n' "$changes" | awk -v repo_path="$repo_path" -v repo_count="${#PLAN_REPO_IDS[@]}" '
                {
                    path = substr($0, 4)
                    if (path ~ /^\.ai-flow\//) {
                        next
                    }
                    if (repo_count > 1 && repo_path == "." && path !~ /^\.ai-flow\//) {
                        next
                    }
                    print path
                }
            ')" ]; then
                any_changes=1
            fi
        done
        if [ "$any_changes" -eq 0 ]; then
            fail_protocol "所有参与仓库均无可审查的 Git 变更"
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
    if [ "$IS_PLAN_REPOS_MODE" -eq 1 ]; then
        list_plan_repo_reviewable_git_paths
    else
        git status --porcelain --untracked-files=all | awk '
            {
                path = substr($0, 4)
                if (path ~ /^\.ai-flow\//) {
                    next
                }
                print path
            }
        '
    fi
}

is_documentation_path() {
    local path="$1"
    local normalized_path="$path"
    if [ "$IS_PLAN_REPOS_MODE" -eq 1 ] && [[ "$normalized_path" == */* ]]; then
        normalized_path="${normalized_path#*/}"
    fi
    case "$normalized_path" in
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
        route = cells[-2] if len(cells) > 2 else ""
        status = cells[-1] if cells else ""
        if severity != "Minor":
            errors.append(f"{issue_id} 作为建议项时严重级别必须是 Minor")
        if route not in {"ai-flow-plan-coding", "ai-flow-code-optimize"}:
            errors.append(f"{issue_id} 的修复流向非法: {route}")
        if status == "[待修复]":
            errors.append(f"{issue_id} 为 Minor 建议，未处理时必须标记为 [可选] 而不是 [待修复]")
    if issue_id.startswith("DEF-"):
        route = cells[-2] if len(cells) > 2 else ""
        if route not in {"ai-flow-plan-coding", "ai-flow-code-optimize"}:
            errors.append(f"{issue_id} 的修复流向非法: {route}")

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

derive_next_from_blocking_routes() {
    local report_file="$1"
    python3 - "$report_file" <<'PY'
import sys
from pathlib import Path


def parse_rows(lines):
    rows = []
    for line in lines:
        if not line.startswith("|"):
            continue
        cells = [part.strip() for part in line.split("|")[1:-1]]
        if not cells or cells[0] in {"#", "缺陷编号"}:
            continue
        if set(cells[0]) == {"-"}:
            continue
        rows.append(cells)
    return rows


text = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
in_defect = False
blocking_routes = set()

for line in text:
    if line.startswith("## 4. 缺陷清单"):
        in_defect = True
        continue
    if line.startswith("## 5. ") and in_defect:
        break
    if not in_defect:
        continue
    for cells in parse_rows([line]):
        issue_id = cells[0]
        severity = cells[1] if len(cells) > 1 else ""
        route = cells[-2] if len(cells) > 2 else ""
        status = cells[-1] if cells else ""
        is_blocking = severity in {"Critical", "Important"} or status == "[待修复]"
        if not is_blocking:
            continue
        if route not in {"ai-flow-plan-coding", "ai-flow-code-optimize"}:
            print("invalid")
            raise SystemExit(0)
        blocking_routes.add(route)

if not blocking_routes:
    print("none")
elif "ai-flow-plan-coding" in blocking_routes:
    print("ai-flow-plan-coding")
else:
    print("ai-flow-code-optimize")
PY
}

require_root_cause_review_loop_record() {
    if [ "$REVIEW_MODE" != "regular" ] || [ "$CURRENT_ROUND" -lt 3 ]; then
        return 0
    fi

    local gate_error=""
    if ! gate_error=$(python3 - "$STATE_FILE_ABS" "$PLAN_FILE_ABS" 2>&1 <<'PY'
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
    [ -n "$PREV_REVIEW_ABS" ] || return 0
    [ -f "$PREV_REVIEW_ABS" ] || return 0

    python3 - "$PREV_REVIEW_ABS" "$REPORT_FILE" <<'PY'
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

IS_ADHOC=0
ADHOC_DATE=""
ADHOC_REPORT_DIR=""
ADHOC_SEQ_NUM=""
PLAN_FILE_ABS="none"
PREV_REVIEW_ABS=""
STATE_FILE_ABS=""
if [ -z "${1:-}" ]; then
    IS_ADHOC=1
    ADHOC_DATE="$(date +%Y%m%d)"
    ADHOC_REPORT_DIR="$REPORTS_DIR/adhoc"
    mkdir -p "$ADHOC_REPORT_DIR"
else
    REQUEST_KEY="$1"
fi
MODEL="$(default_model_for_engine "$AGENT_ENGINE")"
REASONING="$(default_reasoning_for_engine "$AGENT_ENGINE")"
ROUND_OVERRIDE=""
ARG2="${2:-}"
ARG3="${3:-}"
ARG4="${4:-}"
STATE_FILE=""

if [ "$IS_ADHOC" -eq 0 ]; then
    find_owner_err="$(mktemp)"
    owner_dir="$(find_owner_dir_for_state_keyword "$REQUEST_KEY" 2>"$find_owner_err" || true)"
    if [ -z "${owner_dir:-}" ]; then
        if [ -s "$find_owner_err" ]; then
            fail_protocol "$(cat "$find_owner_err")"
        fi
        fail_protocol "找不到匹配 slug '$REQUEST_KEY' 的状态文件"
    fi
    rm -f "$find_owner_err"
    PROJECT_DIR="$owner_dir"
    FLOW_DIR="$PROJECT_DIR/.ai-flow"
    REPORTS_DIR="$FLOW_DIR/reports"
    cd "$PROJECT_DIR"
    MATCHED_STATES=()
    while IFS= read -r -d '' f; do
        MATCHED_STATES+=("$f")
    done < <(find "$FLOW_DIR/state" -name "*${REQUEST_KEY}*.json" -type f -print0 2>/dev/null)

    if [ ${#MATCHED_STATES[@]} -eq 0 ]; then
        fail_protocol "找不到匹配 slug '$REQUEST_KEY' 的状态文件"
    elif [ ${#MATCHED_STATES[@]} -gt 1 ]; then
        fail_protocol "slug '$REQUEST_KEY' 匹配到多个状态文件，请使用精确 slug"
    else
        STATE_FILE="${MATCHED_STATES[0]}"
        STATE_FILE_ABS="$(resolve_project_path "$STATE_FILE")"
        apply_review_arg_compat "$ARG2" "$ARG3" "$ARG4"
        load_plan_repo_scope "$STATE_FILE_ABS"
    fi
fi

if [ "$IS_ADHOC" -eq 1 ]; then
    ADHOC_SEQ_NUM=$(find "$ADHOC_REPORT_DIR" -maxdepth 1 -name '*-adhoc-review*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
    ADHOC_SEQ_NUM=$((ADHOC_SEQ_NUM + 1))
    REPORT_FILE="$ADHOC_REPORT_DIR/${ADHOC_DATE}-adhoc-review-${ADHOC_SEQ_NUM}.md"
    TEMPLATE="$AGENT_DIR/templates/adhoc-review-template.md"
    PROTOCOL_STATE="none"
    PROTOCOL_NEXT="none"
    CURRENT_ROUND=1
    REVIEW_MODE="adhoc"
    PLAN_FILE="none"
    PLAN_FILE_ABS="none"
    PLAN_TITLE="adhoc review"
    PREV_REVIEW=""
    PREV_REVIEW_ABS=""
else
    SLUG=$(basename "$STATE_FILE" .json)
    state_context=$(load_state_context "$STATE_FILE_ABS")
    PLAN_STATUS=$(printf '%s\n' "$state_context" | sed -n '1p')
    PLAN_FILE=$(printf '%s\n' "$state_context" | sed -n '2p')
    PLAN_TITLE=$(printf '%s\n' "$state_context" | sed -n '3p')
    REGULAR_ROUND_COUNT=$(printf '%s\n' "$state_context" | sed -n '4p')
    RECHECK_ROUND_COUNT=$(printf '%s\n' "$state_context" | sed -n '5p')
    LATEST_REGULAR_REVIEW=$(printf '%s\n' "$state_context" | sed -n '6p')
    LATEST_RECHECK_REVIEW=$(printf '%s\n' "$state_context" | sed -n '7p')
    LAST_REVIEW_RESULT=$(printf '%s\n' "$state_context" | sed -n '8p')
    LAST_REVIEW_FILE=$(printf '%s\n' "$state_context" | sed -n '9p')
    PLAN_FILE_ABS="$(resolve_project_path "$PLAN_FILE")"

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
fi

if [ "$IS_ADHOC" -eq 0 ]; then
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
fi
PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$REPORT_FILE")"

if [ -e "$REPORT_FILE" ]; then
    fail_protocol "报告文件已存在，拒绝覆盖: $REPORT_FILE"
fi

if [ "$IS_ADHOC" -eq 0 ]; then
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
    PREV_REVIEW_ABS="$(resolve_project_path "$PREV_REVIEW")"
fi

mkdir -p "$(dirname "$REPORT_FILE")"
ensure_reviewable_git_changes
require_root_cause_review_loop_record

if [ "$IS_ADHOC" -eq 0 ]; then
    PLAN_CONTENT=$(cat "$PLAN_FILE_ABS")
    REASONING=$(review_reasoning "$(count_reviewable_git_paths)" "$(printf '%s\n' "$PLAN_CONTENT" | wc -l | tr -d ' ')" "$CURRENT_ROUND" "$( [ -n "$PREV_REVIEW_ABS" ] && echo 1 || echo 0 )")
else
    REASONING=$(review_reasoning "$(count_reviewable_git_paths)" 0 "$CURRENT_ROUND" 0)
fi

ACTIVE_ENGINE="Codex"
ACTIVE_MODEL="$MODEL"
ACTIVE_REASONING="$REASONING"
if ! command -v codex >/dev/null 2>&1; then
    if [ "$REVIEW_ENGINE_MODE" = "codex" ]; then
        echo "错误: REVIEW_ENGINE_MODE=codex，Codex 不可用，拒绝降级"
        fail_protocol "REVIEW_ENGINE_MODE=codex 模式下 Codex 不可用"
    fi
    ACTIVE_ENGINE="Codex(unavailable)"
fi

if [ "$IS_ADHOC" -eq 1 ]; then
    echo ">>> Adhoc review（未绑定计划）"
else
    echo ">>> 匹配到状态: $SLUG [$PLAN_STATUS]"
    echo "    对比计划: $PLAN_FILE"
fi
echo "    审查模式: $REVIEW_MODE"
echo "    审查轮次: $CURRENT_ROUND"
echo "    审查引擎: $ACTIVE_ENGINE ($ACTIVE_MODEL $ACTIVE_REASONING)"
echo "    输出文件: $REPORT_FILE"
if [ -n "$PREV_REVIEW" ]; then
    echo "    上一轮报告: ${PREV_REVIEW}（用于缺陷正文与追踪）"
fi
echo ""
for required_file in "$FLOW_STATE_SH" "$TEMPLATE"; do
    if [ ! -f "$required_file" ]; then
        fail_protocol "缺少运行时资源: $required_file"
    fi
done
if [ "$IS_ADHOC" -eq 0 ] && [ ! -f "$PROMPT_TEMPLATE" ]; then
    fail_protocol "缺少运行时资源: $PROMPT_TEMPLATE"
fi
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
    adhoc:*)
        REVIEW_SCOPE_GUIDANCE="这是 adhoc review：未绑定任何 AI Flow 计划。请审查当前未提交的 Git 变更，关注代码质量、安全性和正确性。"
        ;;
esac

HISTORY_CONTEXT=""
HISTORY_RULES=""
if [ "$IS_ADHOC" -eq 0 ]; then
    HISTORY_RULES=$'5. 如果本轮发现缺陷，按严重级别写入"4. 缺陷清单"，并同步更新"6. 缺陷修复追踪"。\n6. "3.6 缺陷族覆盖度"至少要覆盖 plan 中与本次变更相关的缺陷族，并说明已覆盖 / 未覆盖 / 需人工验证。'
fi
if [ -n "$PREV_REVIEW_ABS" ] && [ -f "$PREV_REVIEW_ABS" ]; then
    PREV_DEFECTS=$(extract_defect_section "$PREV_REVIEW_ABS")
    PREV_TRACKING=$(extract_tracking_section "$PREV_REVIEW_ABS")
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

if [ "$IS_ADHOC" -eq 1 ]; then
    ADHOC_TODAY="$(date +%Y-%m-%d)"
    ADHOC_CHANGE_SUMMARY="$(list_plan_repo_change_summary 2>/dev/null || true)"
    if [ "$IS_PLAN_REPOS_MODE" -eq 0 ]; then
        ADHOC_CHANGE_SUMMARY=$(
            cat <<EOF
$(git diff --staged --name-only 2>/dev/null || true)
$(git diff --name-only 2>/dev/null || true)
EOF
        )
    fi
    REVIEW_PROMPT=$(cat <<PROMPT
# 审查报告：adhoc review

> 审查日期：${ADHOC_TODAY}
> 需求简称：adhoc
> 审查模式：adhoc
> 审查轮次：1
> 审查结果：passed
> 对比计划：无（未绑定计划）

请审查当前未提交的 Git 变更，使用简化 adhoc 模式生成审查报告。

当前变更摘要（git diff --staged + git diff）：
$ADHOC_CHANGE_SUMMARY

请使用 adhoc-review-template.md 模板生成审查报告。
要求：
1. 报告首行必须以 "# 审查报告：adhoc review" 开头
2. 元数据中的需求简称填写 "adhoc"
3. 审查模式填写 "adhoc"
4. 审查结果必须为 passed、passed_with_notes 或 failed 之一
5. 对比计划填写 "无（未绑定计划）"
6. 重点关注代码质量、安全性和正确性
7. 缺陷编号以 DEF- 和 SUG- 开头
PROMPT
)
else
    REVIEW_PROMPT=$(render_prompt_template "$PROMPT_TEMPLATE")
fi

if [ "$ACTIVE_ENGINE" = "Codex(unavailable)" ]; then
    if [ "$REVIEW_ENGINE_MODE" = "claude" ]; then
        fail_protocol "REVIEW_ENGINE_MODE=claude 模式下不应进入 codex 执行路径"
    fi
    PROTOCOL_ARTIFACT="none"
    PROTOCOL_STATE="$PLAN_STATUS"
    PROTOCOL_REVIEW_RESULT="degraded"
    PROTOCOL_SUMMARY="Codex 不可用，已降级到 ai-flow-claude-plan-coding-review。"
    emit_current_protocol
    exit 0
fi

echo ">>> 调用 codex ($MODEL) 审查中..."
stderr_file=$(mktemp)
set +e
run_codex_review_prompt "$REVIEW_PROMPT" 2>"$stderr_file"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    if is_codex_unavailable_error "$rc" "$stderr_file"; then
        emit_captured_stderr "$stderr_file" "Codex 审查 stderr"
        rm -f "$stderr_file"
        if [ "$REVIEW_ENGINE_MODE" = "codex" ]; then
            fail_protocol "REVIEW_ENGINE_MODE=codex 模式下 Codex 执行失败"
        fi
        PROTOCOL_ARTIFACT="none"
        PROTOCOL_STATE="$PLAN_STATUS"
        PROTOCOL_REVIEW_RESULT="degraded"
        PROTOCOL_SUMMARY="Codex 不可用，已降级到 ai-flow-claude-plan-coding-review。"
        emit_current_protocol
        exit 0
    fi
    emit_captured_stderr "$stderr_file" "Codex 审查 stderr"
    rm -f "$stderr_file"
    fail_protocol "Codex 执行审查失败，且不属于可降级的不可用场景"
fi
rm -f "$stderr_file"

echo ""
echo ">>> 审查报告已生成: $REPORT_FILE"
echo ">>> 校验审查报告结构..."

ERRORS=""
FIRST_LINE=$(head -1 "$REPORT_FILE")
if ! echo "$FIRST_LINE" | grep -qE '^# 审查报告：'; then
    ERRORS="${ERRORS}首行必须是 '# 审查报告：...'\n"
fi

if [ "$IS_ADHOC" -eq 1 ]; then
    for section in "## 1\. " "## 1\.1 " "## 1\.2 " "## 2\. " "## 2\.1 " "## 3\." "## 4\."; do
        if ! grep -qE "$section" "$REPORT_FILE"; then
            section_label=${section//\\/}
            ERRORS="${ERRORS}缺少章节: $section_label\n"
        fi
    done
    ADHOC_PLACEHOLDERS=(
        "{YYYY-MM-DD}"
        "{审查结果}"
        "{审查工具}"
        "{总体通过 / 总体通过（附建议） / 需要修复}"
        "{exact_command}"
        "{为什么执行、结果说明什么}"
    )
    for placeholder in "${ADHOC_PLACEHOLDERS[@]}"; do
        if grep -Fq "$placeholder" "$REPORT_FILE"; then
            ERRORS="${ERRORS}报告中仍有未替换的模板占位符: $placeholder\n"
        fi
    done
else
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
fi

META_SLUG=$(meta_value "需求简称")
META_MODE=$(meta_value "审查模式")
META_ROUND=$(meta_value "审查轮次")
META_RESULT=$(meta_value "审查结果")
META_PLAN_FILE=$(meta_value "对比计划")
if [ "$IS_ADHOC" -eq 0 ]; then
    if [ "$META_SLUG" != "$SLUG" ]; then
        ERRORS="${ERRORS}需求简称与状态文件不一致: 期望 ${SLUG}，实际 ${META_SLUG}\n"
    fi
    if [ "$META_PLAN_FILE" != "$PLAN_FILE" ]; then
        ERRORS="${ERRORS}对比计划路径与状态文件不一致\n"
    fi
fi
if [ "$META_MODE" != "$REVIEW_MODE" ]; then
    ERRORS="${ERRORS}审查模式与预期不一致: 期望 ${REVIEW_MODE}，实际 ${META_MODE}\n"
fi
if [ "$META_ROUND" != "$CURRENT_ROUND" ]; then
    ERRORS="${ERRORS}审查轮次与预期不一致: 期望 ${CURRENT_ROUND}，实际 ${META_ROUND}\n"
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

if [ "$IS_ADHOC" -eq 1 ]; then
    CONCLUSION_SECTION=$(awk '
        /^## 4\./ {in_section=1; next}
        /^## [5-9]\./ && in_section {exit}
        in_section {print}
    ' "$REPORT_FILE")
else
    CONCLUSION_SECTION=$(awk '
        /^## 5\./ {in_section=1; next}
        /^## 6\./ && in_section {exit}
        in_section {print}
    ' "$REPORT_FILE")
fi

if [ -z "$(printf '%s\n' "$VERIFICATION_SECTION" | sed '/^[[:space:]]*$/d')" ]; then
    ERRORS="${ERRORS}1.2 定向验证执行证据不能为空\n"
fi

if [ "$IS_ADHOC" -eq 0 ]; then
    FAMILY_SECTION=$(report_section_between "$REPORT_FILE" '^### 3\.6 ' '^## 4\. ')
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
    if [ "$IS_PLAN_REPOS_MODE" -eq 1 ]; then
        if ! plan_repo_validation_error=$(list_plan_repo_dirty_repo_ids | plan_repo_report_validation_error 2>&1); then
            ERRORS="${ERRORS}${plan_repo_validation_error}\n"
        fi
    fi
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

NEXT_ON_FAILURE="none"
if [ "$RESULT" = "failed" ]; then
    NEXT_ON_FAILURE="$(derive_next_from_blocking_routes "$REPORT_FILE")"
    if [ "$NEXT_ON_FAILURE" = "invalid" ]; then
        fail_protocol "阻塞缺陷的修复流向必须是 ai-flow-plan-coding 或 ai-flow-code-optimize"
    elif [ "$NEXT_ON_FAILURE" = "none" ]; then
        fail_protocol "审查结果为 failed，但未能从阻塞缺陷中推导出修复流向"
    fi
fi

if [ "$IS_ADHOC" -eq 1 ]; then
    echo ">>> Adhoc review 完成，不更新状态文件"
    case "$RESULT" in
        passed)
            PROTOCOL_SUMMARY="adhoc 审查通过，无状态绑定。"
            ;;
        passed_with_notes)
            PROTOCOL_SUMMARY="adhoc 审查通过（附 Minor 建议），无状态绑定。"
            ;;
        failed)
            PROTOCOL_SUMMARY="adhoc 审查未通过，发现问题，无状态绑定。"
            ;;
    esac
    PROTOCOL_REVIEW_RESULT="$RESULT"
else
    echo ">>> 更新状态文件..."
    AI_FLOW_ACTOR="$AGENT_NAME" "$FLOW_STATE_SH" record-review \
        --slug "$SLUG" \
        --mode "$REVIEW_MODE" \
        --result "$RESULT" \
        --report-file "$REPORT_FILE" \
        --engine "$ACTIVE_ENGINE" \
        --model "$ACTIVE_MODEL"
    UPDATED_STATUS=$(state_current_status "$STATE_FILE_ABS")
    echo "    状态已验证为 [$UPDATED_STATUS]"
    PROTOCOL_STATE="$UPDATED_STATUS"
    PROTOCOL_REVIEW_RESULT="$RESULT"

    print_commit_instructions() {
        echo ">>> 状态已进入 [DONE]，现在允许提交已审查的未提交变更"
        echo "    请使用 /ai-flow-git-commit 提交代码"

        if [ "$IS_PLAN_REPOS_MODE" -eq 1 ] && [ ${#PLAN_REPO_IDS[@]} -gt 0 ]; then
            echo ""
            echo ">>> 当前 plan 涉及以下代码仓库，后续应按依赖顺序逐仓、按业务关联性逐组提交："
            local i
            for i in "${!PLAN_REPO_IDS[@]}"; do
                local repo_id="${PLAN_REPO_IDS[$i]}"
                local git_root="${PLAN_REPO_GIT_ROOTS[$i]}"
                local role="${PLAN_REPO_ROLES[$i]}"
                local changes
                changes="$(git -C "$git_root" status --porcelain --untracked-files=all 2>/dev/null | awk -v repo_path="${PLAN_REPO_PATHS[$i]}" -v repo_count="${#PLAN_REPO_IDS[@]}" '
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
                ')"
                if [ -n "$changes" ]; then
                    local change_count
                    change_count="$(printf '%s\n' "$changes" | wc -l | tr -d ' ')"
                    echo "    - [${repo_id}] (${role}) ${git_root} — 有 ${change_count} 个文件待提交"
                else
                    echo "    - [${repo_id}] (${role}) ${git_root} — 无未提交变更"
                fi
            done
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
            PROTOCOL_NEXT="$NEXT_ON_FAILURE"
            ;;
        *)
            fail_protocol "record-review 后出现意外状态 [$UPDATED_STATUS]"
            ;;
    esac
fi

if [ "$ACTIVE_ENGINE" = "Codex(unavailable)" ] && [ "$REVIEW_ENGINE_MODE" = "auto" ]; then
    PROTOCOL_SUMMARY="${PROTOCOL_SUMMARY%?} 已降级到 ai-flow-claude-plan-coding-review。"
fi
emit_current_protocol
