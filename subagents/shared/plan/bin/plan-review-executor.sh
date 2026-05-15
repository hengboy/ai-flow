#!/bin/bash
# plan-executor.sh — 生成或修订 draft plan；内部也承载 plan review 实现

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$AGENT_DIR/lib/agent-common.sh"
source "$AGENT_DIR/lib/rule-loader.sh"
exec 3>&1 1>&2

AI_FLOW_HOME="${AI_FLOW_HOME:-$HOME/.config/ai-flow}"
FLOW_STATE_SH="$AI_FLOW_HOME/scripts/flow-state.sh"
ORIGINAL_PROJECT_DIR="$(pwd)"
PROJECT_DIR="$ORIGINAL_PROJECT_DIR"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
STATE_DIR="$FLOW_DIR/state"

# 解析 slug（必选）
INTERNAL_PLAN_REVIEW=0
SLUG=""
MATCH_KEYWORD=""
if [ "${1:-}" = "--internal-plan-review" ]; then
    INTERNAL_PLAN_REVIEW=1
    MATCH_KEYWORD="${2:-}"
    SLUG="$MATCH_KEYWORD"
else
    SLUG="${2:-}"
fi

DATE_PREFIX="$(date +%Y%m%d)"
PLANS_DIR="$FLOW_DIR/plans"
OWNER_GIT_ROOT=""
REPO_SCOPE_JSON=""
PLAN_REPO_IDS=()
PLAN_REPO_PATHS=()
PLAN_REPO_GIT_ROOTS=()
TEMPLATE="$AGENT_DIR/templates/plan-template.md"
PLAN_PROMPT_TEMPLATE="$AGENT_DIR/prompts/plan-generation.md"
PLAN_REVIEW_PROMPT_TEMPLATE="$AGENT_DIR/prompts/plan-review.md"
PLAN_REVISION_PROMPT_TEMPLATE="$AGENT_DIR/prompts/plan-revision.md"
PLAN_REASONING="$(default_reasoning_for_engine "$AGENT_ENGINE")"
PLAN_REVIEW_REASONING="$(get_setting "plan_review.$AGENT_ENGINE.reasoning" "high")"
PLAN_ENGINE_MODE="${ENGINE_MODE_OVERRIDE:-auto}"
PLAN_ENGINE_NAME=""
PLAN_ENGINE_MODEL=""
REQUIREMENT=""
MODEL="$(default_model_for_engine "$AGENT_ENGINE")"
RULE_BUNDLE_JSON=""
RULE_PROMPT_BLOCK=""
RULE_REQUIRED_READS_BLOCK=""
PROTOCOL_ARTIFACT="none"
PROTOCOL_STATE="none"
PROTOCOL_NEXT="none"
PROTOCOL_REVIEW_RESULT="failed"
PROTOCOL_SUMMARY=""
PROTOCOL_EMITTED=0

emit_current_protocol() {
    PROTOCOL_EMITTED=1
    emit_protocol "success" "$PROTOCOL_ARTIFACT" "$PROTOCOL_STATE" "$PROTOCOL_NEXT" "$PROTOCOL_SUMMARY" "${1:-}"
}

fail_protocol() {
    local summary="$1"
    PROTOCOL_EMITTED=1
    emit_protocol "failed" "$PROTOCOL_ARTIFACT" "$PROTOCOL_STATE" "$PROTOCOL_NEXT" "$summary" "${2:-}"
    exit 1
}

trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "$PROTOCOL_EMITTED" -eq 0 ]; then emit_protocol "failed" "$PROTOCOL_ARTIFACT" "$PROTOCOL_STATE" "$PROTOCOL_NEXT" "${PROTOCOL_SUMMARY:-执行失败}" "${PROTOCOL_REVIEW_RESULT:-}"; fi' EXIT

# 模型选择由执行器内部默认值和降级逻辑统一决定；不再接受调用方显式覆盖。
if [ "$INTERNAL_PLAN_REVIEW" -eq 1 ]; then
    MODEL="$(default_model_for_engine "$AGENT_ENGINE")"
else
    if [ -z "${1:-}" ]; then
        fail_protocol "用法: plan-executor.sh \"需求描述\" <slug>" ""
    fi
    REQUIREMENT="$1"
    MODEL="$(default_model_for_engine "$AGENT_ENGINE")"
fi

require_file() {
    local path="$1"
    local label="$2"
    if [ -f "$path" ]; then
        return 0
    fi
    fail_protocol "缺少${label}: $path" "${PROTOCOL_REVIEW_RESULT:-}"
}

validate_installed_resources() {
    require_file "$FLOW_STATE_SH" "AI Flow runtime 脚本 flow-state.sh"
    require_file "$TEMPLATE" "plan 模板"
    require_file "$PLAN_PROMPT_TEMPLATE" "plan 生成 prompt"
    require_file "$PLAN_REVIEW_PROMPT_TEMPLATE" "plan 审核 prompt"
    require_file "$PLAN_REVISION_PROMPT_TEMPLATE" "plan 修订 prompt"
}

has_project_root_marker() {
    local dir="$1"
    local marker
    for marker in \
        .git \
        pom.xml \
        package.json \
        pyproject.toml \
        requirements.txt \
        go.mod \
        Cargo.toml \
        Gemfile \
        composer.json \
        build.gradle \
        build.gradle.kts \
        settings.gradle \
        settings.gradle.kts \
        Makefile
    do
        if [ -e "$dir/$marker" ]; then
            return 0
        fi
    done
    if [ -d "$dir/src" ] || [ -d "$dir/src/main" ]; then
        return 0
    fi
    # Multi-repo workspace container: owner itself isn't a git repo
    # but has independent git subdirectories (e.g., isp/ containing isp-auth/, isp-build/, etc.)
    local sub
    for sub in "$dir"/*/; do
        [ -d "$sub" ] || continue
        sub="${sub%/}"
        if [ -d "$sub/.git" ]; then
            return 0
        fi
    done
    return 1
}

discover_project_root_candidates() {
    local base_dir="$1"
    local depth candidate rel
    local -a candidates=()

    for depth in 1 2; do
        while IFS= read -r candidate; do
            [ -z "$candidate" ] && continue
            if has_project_root_marker "$candidate"; then
                rel="${candidate#"$base_dir"/}"
                candidates+=("$rel")
            fi
        done < <(find "$base_dir" -mindepth "$depth" -maxdepth "$depth" -type d ! -path '*/.ai-flow*' 2>/dev/null | sort)
    done

    if [ "${#candidates[@]}" -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++'
}

discover_scope_repos() {
    # Scan immediate subdirectories for git repos; returns "id\tpath" lines.
    local dir="$1"
    local sub
    while IFS= read -r sub; do
        [ -z "$sub" ] && continue
        if git -C "$dir/$sub" rev-parse --show-toplevel >/dev/null 2>&1; then
            printf '%s\t%s\n' "$sub" "$sub"
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -path '*/.ai-flow*' ! -path '*/.*' 2>/dev/null | while IFS= read -r full; do basename "$full"; done | sort)
}

ensure_project_root_context() {
    local git_root
    git_root="$(git -C "$ORIGINAL_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$git_root" ]; then
        OWNER_GIT_ROOT="$git_root"
        PROJECT_DIR="$OWNER_GIT_ROOT"
        FLOW_DIR="$PROJECT_DIR/.ai-flow"
        STATE_DIR="$FLOW_DIR/state"
        PLANS_DIR="$FLOW_DIR/plans"
        cd "$PROJECT_DIR"
        return 0
    fi

    local candidate
    local -a candidates=()

    while IFS= read -r candidate; do
        [ -n "$candidate" ] && candidates+=("$candidate")
    done < <(discover_project_root_candidates "$ORIGINAL_PROJECT_DIR")

    local message
    message="当前目录不在 Git 仓库内，无法确定 owner repo: $ORIGINAL_PROJECT_DIR"
    if [ "${#candidates[@]}" -eq 1 ]; then
        message="${message}；检测到候选项目根目录: $ORIGINAL_PROJECT_DIR/${candidates[0]}"
    elif [ "${#candidates[@]}" -gt 1 ]; then
        message="${message}；检测到多个候选项目根目录，请进入目标 Git 仓库后重新运行 /ai-flow-plan"
    else
        message="${message}；请在 owner Git 仓库内运行 /ai-flow-plan"
    fi
    fail_protocol "$message" "${PROTOCOL_REVIEW_RESULT:-}"
}

validate_installed_resources

render_plan_template_content() {
    local requirement_name="$1"
    local requirement_text="$2"
    local exec_scope_label="plan_repos"
    local repo_list="owner (path: ., role: owner)"
    AI_FLOW_TEMPLATE_REQUIREMENT_NAME="$requirement_name" \
    AI_FLOW_TEMPLATE_SLUG="$SLUG" \
    AI_FLOW_TEMPLATE_DATE="$(date +%Y-%m-%d)" \
    AI_FLOW_TEMPLATE_TIME="$(date +%H:%M:%S)" \
    AI_FLOW_TEMPLATE_DATE_PREFIX="$DATE_PREFIX" \
    AI_FLOW_TEMPLATE_REQUIREMENT_SOURCE_LABEL="需求描述" \
    AI_FLOW_TEMPLATE_REQUIREMENT_TEXT="$requirement_text" \
    AI_FLOW_TEMPLATE_EXEC_SCOPE="$exec_scope_label" \
    AI_FLOW_TEMPLATE_REPO_LIST="$repo_list" \
    python3 - "$TEMPLATE" <<'PY'
import os
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
replacements = {
    "{需求名称}": os.environ["AI_FLOW_TEMPLATE_REQUIREMENT_NAME"],
    "{需求简称}": os.environ["AI_FLOW_TEMPLATE_SLUG"],
    "{YYYY-MM-DD}": os.environ["AI_FLOW_TEMPLATE_DATE"],
    "{HH:MM:SS}": os.environ["AI_FLOW_TEMPLATE_TIME"],
    "{YYYYMMDD}": os.environ["AI_FLOW_TEMPLATE_DATE_PREFIX"],
    "{需求文档/口头描述/Jira 等}": os.environ["AI_FLOW_TEMPLATE_REQUIREMENT_SOURCE_LABEL"],
    "{原始需求原文}": os.environ["AI_FLOW_TEMPLATE_REQUIREMENT_TEXT"],
    "执行范围：plan_repos": f"执行范围：{os.environ['AI_FLOW_TEMPLATE_EXEC_SCOPE']}",
    "Plan 参与仓库：owner (path: ., role: owner)": f"Plan 参与仓库：{os.environ['AI_FLOW_TEMPLATE_REPO_LIST']}",
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
sys.stdout.write(text)
PY
}

render_prompt_template() {
    local prompt_template="$1"
    local repo_ctx="当前 owner repo 根目录：${PROJECT_DIR}。默认 Plan 参与仓库为 owner (path: ., role: owner)。如需求明确涉及其他本地 Git 仓库，请在 2.1 和 2.5 的 仓库 列使用稳定 repo id；跨仓文件路径写成 repo_id/path/to/file，owner 仓库可写 owner/path/to/file 或项目内相对路径。"
    AI_FLOW_TEMPLATE_CONTENT="${TEMPLATE_CONTENT:-}" \
    AI_FLOW_DETECT_STACK="${DETECT_STACK:-}" \
    AI_FLOW_REQUIREMENT="$REQUIREMENT" \
    AI_FLOW_SLUG="$SLUG" \
    AI_FLOW_PLAN_CONTENT="${PLAN_CONTENT_FOR_PROMPT:-}" \
    AI_FLOW_REVIEW_ITEMS="${PLAN_REVIEW_ITEMS_FOR_PROMPT:-}" \
    AI_FLOW_REPO_SCOPE_CONTEXT="$repo_ctx" \
    AI_FLOW_RULE_PROMPT_BLOCK="${RULE_PROMPT_BLOCK:-}" \
    AI_FLOW_RULE_REQUIRED_READS_BLOCK="${RULE_REQUIRED_READS_BLOCK:-}" \
    python3 - "$prompt_template" <<'PY'
import os
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
replacements = {
    "__AI_FLOW_TEMPLATE_CONTENT__": os.environ.get("AI_FLOW_TEMPLATE_CONTENT", ""),
    "__AI_FLOW_DETECT_STACK__": os.environ.get("AI_FLOW_DETECT_STACK", ""),
    "__AI_FLOW_REQUIREMENT__": os.environ["AI_FLOW_REQUIREMENT"],
    "__AI_FLOW_SLUG__": os.environ["AI_FLOW_SLUG"],
    "__AI_FLOW_PLAN_CONTENT__": os.environ.get("AI_FLOW_PLAN_CONTENT", ""),
    "__AI_FLOW_REVIEW_ITEMS__": os.environ.get("AI_FLOW_REVIEW_ITEMS", ""),
    "__AI_FLOW_REPO_SCOPE_CONTEXT__": os.environ.get("AI_FLOW_REPO_SCOPE_CONTEXT", ""),
    "__AI_FLOW_RULE_PROMPT_BLOCK__": os.environ.get("AI_FLOW_RULE_PROMPT_BLOCK", ""),
    "__AI_FLOW_RULE_REQUIRED_READS_BLOCK__": os.environ.get("AI_FLOW_RULE_REQUIRED_READS_BLOCK", ""),
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
sys.stdout.write(text)
PY
}

append_rule_context_to_prompt_template() {
    local template_file="$1"
    local output_file="$2"
    python3 - "$template_file" "$output_file" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_text(encoding="utf-8")
dst = Path(sys.argv[2])
appendix = "\n\n__AI_FLOW_RULE_PROMPT_BLOCK__\n\n__AI_FLOW_RULE_REQUIRED_READS_BLOCK__\n"
dst.write_text(src.rstrip() + appendix, encoding="utf-8")
PY
}

render_core_decisions() {
    local plan_file="$1"
    python3 - "$plan_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
lines = text.splitlines()
steps = []
current = None
in_file_boundary = False

for line in lines:
    if line.startswith("### Step "):
        if current:
            steps.append(current)
        current = {
            "title": line.replace("### ", "", 1).strip(),
            "goal": "",
            "files": [],
            "commands": [],
        }
        in_file_boundary = False
        continue

    if current is None:
        continue

    if line.startswith("**目标**："):
        current["goal"] = line.replace("**目标**：", "", 1).strip()
        continue

    if line.startswith("**文件边界**："):
        in_file_boundary = True
        continue

    if line.startswith("**") and not line.startswith("**文件边界**："):
        in_file_boundary = False

    if in_file_boundary:
        match = re.match(r"-\s*(Create|Modify|Test):\s*`?([^`]+?)`?\s*[—-]\s*(.+)", line.strip())
        if match:
            current["files"].append({
                "action": match.group(1),
                "path": match.group(2).strip(),
                "desc": match.group(3).strip(),
            })
        continue

    command_match = re.search(r"命令：`?([^`]+)`?", line)
    if command_match:
        command = command_match.group(1).strip()
        if command not in current["commands"]:
            current["commands"].append(command)

if current:
    steps.append(current)

if not steps:
    print("- 未提取到可结构化的修改项，请以实施步骤中的文件边界和执行动作为准。")
    sys.exit(0)

for step in steps:
    parts = []
    if step["goal"]:
        parts.append(f"目标是{step['goal']}")
    if step["files"]:
        file_summary = "；".join(
            f"{item['action']} {item['path']}（{item['desc']}）"
            for item in step["files"]
        )
        parts.append(f"修改项包括 {file_summary}")
    if step["commands"]:
        parts.append(f"关键验证命令：{step['commands'][0]}")
    summary = "；".join(parts) if parts else "请按该 Step 的文件边界和执行动作执行。"
    print(f"- {step['title']}：{summary}")
PY
}

slug_exists() {
    local candidate="$1"
    if [ -f "$STATE_DIR/${candidate}.json" ]; then
        return 0
    fi
    find "$FLOW_DIR/plans" -name "*-${candidate}.md" -type f 2>/dev/null | grep -q .
}

file_line_count() {
    local target="$1"
    if [ ! -f "$target" ]; then
        echo 0
        return 0
    fi
    wc -l < "$target" | tr -d ' '
}

plan_authoring_reasoning() {
    local reasoning="$PLAN_REASONING"

    local requirement_length stack_count
    requirement_length=$(printf '%s' "$REQUIREMENT" | wc -m | tr -d ' ')
    stack_count=$(printf '%s' "$DETECT_STACK" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')

    if [ "$requirement_length" -ge 120 ] \
        || [ "$stack_count" -ge 4 ] \
        || { [ "${SLUG_EXPLICIT:-false}" = true ] && [ -f "${EXISTING_STATE_FILE:-}" ]; }; then
        reasoning="xhigh"
    fi

    echo "$reasoning"
}

plan_review_reasoning() {
    local reasoning="$PLAN_REVIEW_REASONING"

    local plan_lines="${1:-0}"
    local review_round="${2:-1}"
    if [ "$plan_lines" -ge 220 ] || [ "$review_round" -ge 2 ]; then
        reasoning="xhigh"
    fi

    echo "$reasoning"
}

trim_generated_file_to_marker() {
    local file="$1"
    local marker="$2"
    local slug="${3:-}"
    python3 - "$file" "$marker" "$slug" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
marker = sys.argv[2]
slug = sys.argv[3]
text = path.read_text(encoding="utf-8")
lines = text.splitlines()
for index, line in enumerate(lines):
    if line.startswith(marker):
        trimmed = "\n".join(lines[index:])
        if text.endswith("\n"):
            trimmed += "\n"
        path.write_text(trimmed, encoding="utf-8")
        sys.exit(0)

# Fallback: if primary marker not found, look for common plan headers
for fallback in ["## 1. 需求概述", "## 1\. 需求概述", "## 需求概述"]:
    for index, line in enumerate(lines):
        if line.startswith(fallback) or fallback.replace("\\", "") in line:
            # Walk backwards to find the nearest h1 heading before this
            start = index
            for j in range(index, -1, -1):
                if lines[j].startswith("# "):
                    start = j
                    break
            if start == index:
                # No h1 heading found — prepend one so plan validation passes
                title = f"# 实施计划：{slug}" if slug else "# 实施计划"
                lines.insert(index, title)
                start = index
            trimmed = "\n".join(lines[start:])
            if text.endswith("\n"):
                trimmed += "\n"
            path.write_text(trimmed, encoding="utf-8")
            sys.exit(0)
sys.exit(0)
PY
}

ensure_requirement_literal() {
    local plan_file="$1"
    python3 - "$plan_file" "$REQUIREMENT" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
requirement = sys.argv[2].strip()
text = path.read_text(encoding="utf-8")
requirement_block = f"**原始需求（原文）**：\n{requirement}\n"
pattern = re.compile(
    r"(?ms)(\*\*原始需求（原文）\*\*：\n)(.*?)(?=\n\*\*[^*]+\*\*：|\n## |\Z)"
)
if pattern.search(text):
    text = pattern.sub(requirement_block, text, count=1)
else:
    section_pattern = re.compile(r"(?ms)(## 1\. 需求概述\n\n.*?)(?=\n## 2\. )")
    match = section_pattern.search(text)
    if not match:
        raise SystemExit("plan 缺少 ## 1. 需求概述，无法写入原始需求原文")
    section = match.group(1)
    non_goal = section.find("\n**非目标**：")
    if non_goal != -1:
        updated = section[:non_goal].rstrip() + "\n\n" + requirement_block + "\n" + section[non_goal + 1:]
    else:
        updated = section.rstrip() + "\n\n" + requirement_block
    text = text[:match.start(1)] + updated + text[match.end(1):]
path.write_text(text, encoding="utf-8")
PY
}

save_plan_review_record_section() {
    local plan_file="$1"
    local output_file="$2"
    python3 - "$plan_file" "$output_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"(?ms)^## 8\. 计划审核记录\n.*\Z", text)
content = match.group(0) if match else ""
Path(sys.argv[2]).write_text(content, encoding="utf-8")
PY
}

restore_plan_review_record_section() {
    local plan_file="$1"
    local review_section_file="$2"
    python3 - "$plan_file" "$review_section_file" <<'PY'
import re
import sys
from pathlib import Path

plan_path = Path(sys.argv[1])
section_text = Path(sys.argv[2]).read_text(encoding="utf-8").strip()
if not section_text:
    sys.exit(0)
text = plan_path.read_text(encoding="utf-8").rstrip() + "\n"
if re.search(r"(?m)^## 8\. 计划审核记录$", text):
    text = re.sub(r"(?ms)^## 8\. 计划审核记录\n.*\Z", section_text + "\n", text, count=1)
else:
    text = text.rstrip() + "\n\n" + section_text + "\n"
plan_path.write_text(text, encoding="utf-8")
PY
}

validate_plan_structure() {
    local plan_file="$1"
    local phase="${2:-draft}"
    local errors=""

    if [ ! -s "$plan_file" ]; then
        errors="${errors}计划文件为空或未生成\n"
    else
        local first_line
        first_line=$(head -1 "$plan_file")
        if ! echo "$first_line" | grep -qE '^# 实施计划：'; then
            errors="${errors}首行必须是 '# 实施计划：...'\n"
        fi
        if ! head -20 "$plan_file" | grep -q '^> '; then
            errors="${errors}文件头部元数据必须使用 '> ' 引用块格式\n"
        fi
        local -a required_metadata_fields=(
            "创建日期"
            "创建时间"
            "需求简称"
            "需求来源"
            "执行范围"
            "Plan 参与仓库"
            "状态文件"
            "文档角色"
            "状态文件约束"
            "执行约定"
            "验证约定"
            "规则标识"
        )
        local metadata_field
        for metadata_field in "${required_metadata_fields[@]}"; do
            if ! grep -q "^> ${metadata_field}：" "$plan_file"; then
                errors="${errors}缺少头部元数据字段: ${metadata_field}\n"
            fi
        done
        for section in \
            "## 1. 需求概述" \
            "## 2. 技术分析" \
            "## 3. 实施步骤" \
            "## 4. 测试计划" \
            "## 5. 风险与注意事项" \
            "## 6. 验收标准" \
            "## 7. 需求变更记录" \
            "## 8. 计划审核记录"; do
            if ! grep -Fq "$section" "$plan_file"; then
                errors="${errors}缺少章节: $section\n"
            fi
        done
        for section in \
            "### 2.1 涉及模块" \
            "### 2.2 数据模型变更" \
            "### 2.3 API 变更" \
            "### 2.4 依赖影响" \
            "### 2.5 文件边界总览" \
            "### 2.6 高风险路径与缺陷族" \
            "### 4.1 单元测试" \
            "### 4.2 集成测试" \
            "### 4.3 回归验证" \
            "### 4.4 定向验证矩阵" \
            "### 8.1 当前审核结论" \
            "### 8.2 偏差与建议" \
            "### 8.3 审核历史"; do
            if ! grep -Fq "$section" "$plan_file"; then
                errors="${errors}缺少强制小节: $section\n"
            fi
        done
        for field in \
            '**目标**' \
            '**背景**' \
            '**原始需求（原文）**' \
            '**非目标**'; do
            if ! grep -Fq "$field" "$plan_file"; then
                errors="${errors}## 1. 需求概述缺少强制字段: $field\n"
            fi
        done
        if ! grep -q '^### Step ' "$plan_file"; then
            errors="${errors}缺少可执行 Step\n"
        fi
        if ! grep -q '^- \[ \]' "$plan_file"; then
            errors="${errors}缺少待执行复选框动作\n"
        fi
        if ! grep -q '命令：' "$plan_file"; then
            errors="${errors}缺少验证命令\n"
        fi
        if ! grep -q '预期：' "$plan_file"; then
            errors="${errors}缺少验证预期\n"
        fi
        if ! grep -q '\*\*本轮 review 预期关注面\*\*' "$plan_file"; then
            errors="${errors}缺少 Step 级别的本轮 review 预期关注面\n"
        fi
        if ! grep -q '\*\*本步关闭条件\*\*' "$plan_file"; then
            errors="${errors}缺少 Step 级别的本步关闭条件\n"
        fi
        if ! grep -q '\*\*阻塞条件\*\*' "$plan_file"; then
            errors="${errors}缺少 Step 级别的阻塞条件\n"
        fi
        # Per-step sub-field validation: each Step must have all 9 required fields
        if ! python3 - "$plan_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
# Split into sections between ### Step headers and the next ### Step or ##
step_sections = re.split(r'(?=^### Step )', text, flags=re.M)
step_sections = [s for s in step_sections if s.startswith('### Step ')]

required_fields = [
    '**目标**',
    '**文件边界**',
    '**本轮 review 预期关注面**',
    '**执行动作**',
    '**本步验收**',
    '**本步关闭条件**',
    '**阻塞条件**',
]

all_ok = True
for section in step_sections:
    title_match = re.match(r'### Step (\d+): (.+)', section)
    title = title_match.group(0) if title_match else 'unknown step'
    # Check for Create/Modify/Test in file boundary area
    if '**文件边界**' in section:
        boundary_part = section.split('**文件边界**')[1].split('**')[0] if '**文件边界**' in section else ''
        if not re.search(r'(Create|Modify|Test):', section):
            print(f"Step 缺少 Create/Modify/Test 文件边界行")
            all_ok = False
    for field in required_fields:
        if field not in section:
            print(f"{title} 缺少字段: {field}")
            all_ok = False
    # 前置阅读 is optional (整段删除是允许的)

sys.exit(0 if all_ok else 1)
PY
        then
            local step_errors
            step_errors=$(python3 - "$plan_file" <<'PY'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
step_sections = re.split(r'(?=^### Step )', text, flags=re.M)
step_sections = [s for s in step_sections if s.startswith('### Step ')]
required_fields = ['**目标**', '**文件边界**', '**本轮 review 预期关注面**', '**执行动作**', '**本步验收**', '**本步关闭条件**', '**阻塞条件**']
msgs = []
for section in step_sections:
    title_match = re.match(r'### Step (\d+): (.+)', section)
    title = title_match.group(0) if title_match else 'unknown step'
    if '**文件边界**' in section and not re.search(r'(Create|Modify|Test):', section):
        msgs.append(f"{title}: 文件边界缺少 Create/Modify/Test")
    for field in required_fields:
        if field not in section:
            msgs.append(f"{title}: 缺少 {field}")
print("; ".join(msgs))
PY
)
            errors="${errors}Step 子字段校验失败: ${step_errors}\n"
        fi
        if ! awk '
            /^### 2\.6 高风险路径与缺陷族/ {in_section=1; next}
            /^## / && in_section {exit}
            in_section && /^\| .* \|/ {count++}
            END {exit(count >= 2 ? 0 : 1)}
        ' "$plan_file"; then
            errors="${errors}2.6 高风险路径与缺陷族缺少有效表格内容\n"
        fi
        if ! awk '
            /^### 4\.4 定向验证矩阵/ {in_section=1; next}
            /^## / && in_section {exit}
            in_section && /^\| .* \|/ {count++}
            END {exit(count >= 2 ? 0 : 1)}
        ' "$plan_file"; then
            errors="${errors}4.4 定向验证矩阵缺少有效表格内容\n"
        fi
        if ! awk '
            /^### 4\.4 定向验证矩阵/ {in_section=1; next}
            /^## / && in_section {exit}
            in_section && /`[^`]+`/ {found=1}
            END {exit(found ? 0 : 1)}
        ' "$plan_file"; then
            errors="${errors}4.4 定向验证矩阵缺少确切命令\n"
        fi
        if grep -qE '^\# \[[^]]+\]' "$plan_file"; then
            errors="${errors}plan 首行不允许再携带状态码\n"
        fi

        local -a plan_placeholders=(
            "{需求名称}"
            "{需求简称}"
            "{YYYY-MM-DD}"
            "{YYYYMMDD}"
            "{HH:MM:SS}"
            "{需求文档/口头描述/Jira 等}"
            "{一句话说明要交付什么能力}"
            "{简要描述业务背景、目标用户、预期效果}"
            "{原始需求原文}"
            "{明确本次不做什么，避免执行阶段扩范围}"
            "{module}"
            "{做什么}"
            "{新增/修改的表结构、字段、索引等}"
            "{是否引入新依赖、是否影响现有接口}"
            "{file_path}"
            "{这个文件负责什么}"
            "{例如：SQL 查询链路}"
            "{影响哪些接口/流程/数据}"
            "{例如：条件遗漏、映射错误、结果集偏差}"
            "{缺陷族名称}"
            "{test-compile / 单测 / Mapper / 集成 / build / 人工验证}"
            "{步骤标题}"
            "{这一步完成后系统具备什么能力}"
            "{新文件职责；没有则删除本行}"
            "{修改点；没有则删除本行}"
            "{测试覆盖什么；没有则删除本行}"
            "{本步完成后 review 必须重点检查的缺陷族、关键路径和回归面}"
            "{为什么读，了解什么；仅在需要参考现有代码范式、接口调用方或配置约束时保留}"
            "{test_path}"
            "{输入、操作、断言点}"
            "{明确失败原因}"
            "{exact_test_command}"
            "{expected_failure_message}"
            "{source_path}"
            "{具体函数、类型、配置、分支逻辑、错误处理和边界条件}"
            "{兼容性、权限、事务、性能或回退要求}"
            "{changed_paths}"
            "{可观察验收条件 1}"
            "{可观察验收条件 2}"
            "{修复/实现完成前必须通过的验证与证据，例如 test-compile、目标单测、Mapper 验证、报告补录}"
            "{具体阻塞条件}"
            "{需要测试的类/方法}"
            "{需要覆盖的边界场景}"
            "{按项目现有测试框架补充测试，例如 JUnit、pytest、Vitest 等}"
            "{需要测试的接口/流程}"
            "{完整回归命令，例如 npm test、pytest、go test ./...、bash tests/run.sh}"
            "{必要的手工验证步骤；没有则删除}"
            "{对应能力/链路}"
            "{exact_command}"
            "{如何判定关闭}"
            "{可能的坑、需要特别注意的边界情况}"
            "{可验证的验收条件 1}"
            "{可验证的验收条件 2}"
            "{YYYY-MM-DD HH:MM}"
            "{执行过程中新增或调整的需求；无则保留空表}"
            "{用户确认/文档同步/其他}"
            '{repo_id，单仓 plan 写 owner}'
            '{repo_id，单仓 plan 写 `owner`}'
        )
        local -a disallowed_state_schema_fields=(
            '`requirement_key`:'
            '`status`:'
            '`steps`:'
            '`verification_results`:'
            '`change_register`:'
        )
        local placeholder
        for placeholder in "${plan_placeholders[@]}"; do
            if grep -Fq "$placeholder" "$plan_file"; then
                errors="${errors}未替换的模板占位符: $placeholder\n"
            fi
        done
        local field_marker
        for field_marker in "${disallowed_state_schema_fields[@]}"; do
            if grep -Fq "$field_marker" "$plan_file"; then
                errors="${errors}计划中不得为状态文件设计自定义 schema 字段: $field_marker\n"
            fi
        done
        if plan_contains_disallowed_text "$plan_file"; then
            errors="${errors}包含不可执行描述或临时标记\n"
        fi
        if ! python3 - "$plan_file" "$REQUIREMENT" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
requirement = sys.argv[2].strip()
match = re.search(
    r"(?ms)\*\*原始需求（原文）\*\*：\n(.*?)(?=\n\*\*[^*]+\*\*：|\n## |\Z)",
    text,
)
if not match:
    sys.exit(1)
actual = match.group(1).strip()
sys.exit(0 if actual == requirement else 1)
PY
        then
            errors="${errors}原始需求（原文）字段必须与输入需求原文完全一致\n"
        fi
        if [ "$phase" = "reviewed" ]; then
            if ! grep -Fq '是否允许进入 `/ai-flow-plan-coding`' "$plan_file"; then
                errors="${errors}计划审核记录缺少 execute 门禁结论\n"
            fi
        fi
    fi

    # Check: no custom top-level sections beyond ## 1. - ## 8.
    if ! python3 - "$plan_file" <<'PY'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
allowed = {"## 1. 需求概述", "## 2. 技术分析", "## 3. 实施步骤", "## 4. 测试计划", "## 5. 风险与注意事项", "## 6. 验收标准", "## 7. 需求变更记录", "## 8. 计划审核记录"}
found = set(re.findall(r"(?m)^## .+$", text))
unexpected = found - allowed
sys.exit(1 if unexpected else 0)
PY
    then
        local extra_sections
        extra_sections=$(python3 - "$plan_file" <<'PY'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
allowed = {"## 1. 需求概述", "## 2. 技术分析", "## 3. 实施步骤", "## 4. 测试计划", "## 5. 风险与注意事项", "## 6. 验收标准", "## 7. 需求变更记录", "## 8. 计划审核记录"}
found = set(re.findall(r"(?m)^## .+$", text))
unexpected = found - allowed
print("; ".join(sorted(unexpected)))
PY
)
        errors="${errors}存在模板未定义的顶级章节: $extra_sections\n"
    fi

    if [ -n "$errors" ]; then
        echo "⚠ 计划结构校验失败："
        echo -e "$errors"
        echo "    计划文件已保留但标记为无效: $plan_file"
        PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$plan_file")"
        fail_protocol "计划结构校验失败: $(normalize_one_line "$errors")" "${PROTOCOL_REVIEW_RESULT:-}"
    fi
}

validate_plan_review_record() {
    local plan_file="$1"
    local expected_result="$2"
    local expected_execute="$3"
    python3 - "$plan_file" "$expected_result" "$expected_execute" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
expected_result = sys.argv[2]
expected_execute = sys.argv[3]
match = re.search(r"(?ms)^## 8\. 计划审核记录\n(.*)\Z", text)
if not match:
    raise SystemExit("缺少 ## 8. 计划审核记录")
section = match.group(1)

def subsection(title: str, next_titles):
    pattern = rf"(?ms)^### {re.escape(title)}\n\n(.*?)(?=^### {'|^### '.join(map(re.escape, next_titles))}|\Z)"
    found = re.search(pattern, section)
    if not found:
        raise SystemExit(f"缺少 {title}")
    return found.group(1).strip()

current = subsection("8.1 当前审核结论", ["8.2 偏差与建议", "8.3 审核历史"])
items = subsection("8.2 偏差与建议", ["8.3 审核历史"])
history = subsection("8.3 审核历史", [])

status_match = re.search(r"^- 审核状态：(.+)$", current, re.M)
execute_match = re.search(r"^- 是否允许进入 `/ai-flow-plan-coding`：(.+)$", current, re.M)
if not status_match or not execute_match:
    raise SystemExit("8.1 当前审核结论缺少审核状态或 execute 结论")

status = status_match.group(1).strip()
execute = execute_match.group(1).strip()
if status != expected_result:
    raise SystemExit(f"8.1 当前审核状态与预期不一致: {status} != {expected_result}")
if execute != expected_execute:
    raise SystemExit(f"8.1 execute 门禁与预期不一致: {execute} != {expected_execute}")
if not history.strip():
    raise SystemExit("8.3 审核历史不能为空")

item_lines = [line.strip() for line in items.splitlines() if line.strip()]
if expected_result == "passed":
    if item_lines != ["- 无"]:
        raise SystemExit("passed 时 8.2 只能为 - 无")
if expected_result == "passed_with_notes":
    if not item_lines or item_lines == ["- 无"]:
        raise SystemExit("passed_with_notes 时必须保留 Minor/[可选] 建议项")
    for line in item_lines:
        if "[待修订]" in line:
            raise SystemExit("passed_with_notes 不能保留 [待修订] 项")
        if "[可选][Minor]" not in line:
            raise SystemExit("passed_with_notes 的建议项必须全部是 [可选][Minor]")
if expected_result == "failed":
    if not any("[待修订]" in line for line in item_lines):
        raise SystemExit("failed 时至少要有一条 [待修订] 阻断项")
PY
}

parse_plan_review_response() {
    local response_file="$1"
    local items_file="$2"
    python3 - "$response_file" "$items_file" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
items_out = Path(sys.argv[2])
lines = [line.rstrip() for line in text.splitlines() if line.strip()]
data = {}
items = []
in_items = False
for line in lines:
    if line.startswith("ITEMS:"):
        in_items = True
        continue
    if in_items:
        if line.startswith("- "):
            items.append(line)
        continue
    if ":" in line:
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip()

required = {"RESULT", "ALIGNMENT", "EXECUTE_READY", "SUMMARY"}
missing = sorted(required - set(data.keys()))
if missing:
    raise SystemExit(f"计划审核输出缺少字段: {', '.join(missing)}")
if data["RESULT"] not in {"passed", "passed_with_notes", "failed"}:
    raise SystemExit("计划审核 RESULT 非法")
if data["EXECUTE_READY"] not in {"yes", "no"}:
    raise SystemExit("计划审核 EXECUTE_READY 非法")
if not items:
    raise SystemExit("计划审核 ITEMS 不能为空")

if data["RESULT"] == "passed":
    if items != ["- 无"]:
        raise SystemExit("计划审核 passed 时 ITEMS 只能为 - 无")
    if data["EXECUTE_READY"] != "yes":
        raise SystemExit("计划审核 passed 时 EXECUTE_READY 必须为 yes")
elif data["RESULT"] == "passed_with_notes":
    if data["EXECUTE_READY"] != "yes":
        raise SystemExit("计划审核 passed_with_notes 时 EXECUTE_READY 必须为 yes")
    for item in items:
        if "[待修订]" in item:
            raise SystemExit("计划审核 passed_with_notes 不允许包含 [待修订]")
        if "[可选][Minor]" not in item:
            raise SystemExit("计划审核 passed_with_notes 只允许 [可选][Minor] 建议")
elif data["RESULT"] == "failed":
    if data["EXECUTE_READY"] != "no":
        raise SystemExit("计划审核 failed 时 EXECUTE_READY 必须为 no")
    if not any("[待修订]" in item for item in items):
        raise SystemExit("计划审核 failed 时必须至少包含一条 [待修订]")

items_out.write_text("\n".join(items) + "\n", encoding="utf-8")
print(data["RESULT"])
print(data["ALIGNMENT"])
print(data["EXECUTE_READY"])
print(data["SUMMARY"])
PY
}

write_plan_review_record() {
    local plan_file="$1"
    local round="$2"
    local result="$3"
    local alignment="$4"
    local execute_ready="$5"
    local summary="$6"
    local engine="$7"
    local model="$8"
    local items_file="$9"
    python3 - "$plan_file" "$round" "$result" "$alignment" "$execute_ready" "$summary" "$engine" "$model" "$items_file" <<'PY'
import re
import sys
from pathlib import Path

plan_path = Path(sys.argv[1])
round_no = sys.argv[2]
result = sys.argv[3]
alignment = sys.argv[4]
execute_ready = "是" if sys.argv[5] == "yes" else "否"
summary = sys.argv[6]
engine = sys.argv[7]
model = sys.argv[8]
items = [line.rstrip() for line in Path(sys.argv[9]).read_text(encoding="utf-8").splitlines() if line.strip()]
if not items:
    items = ["- 无"]

text = plan_path.read_text(encoding="utf-8").rstrip() + "\n"
history_body = ""
section_match = re.search(r"(?ms)^## 8\. 计划审核记录\n(.*)\Z", text)
if section_match:
    history_match = re.search(r"(?ms)^### 8\.3 审核历史\n\n(.*)\Z", section_match.group(1))
    if history_match:
        history_body = history_match.group(1).strip()
if "第 0 轮：初始化 draft，待审核。" in history_body:
    history_body = ""

history_parts = []
if history_body:
    history_parts.append(history_body)
item_history = "\n".join(f"  {line}" for line in items)
history_parts.append(
    f"#### 第 {round_no} 轮\n"
    f"- 结果：{result}\n"
    f"- 与原始需求一致性：{alignment}\n"
    f"- 是否允许进入 `/ai-flow-plan-coding`：{execute_ready}\n"
    f"- 审核引擎/模型：{engine} / {model}\n"
    f"- 结论摘要：{summary}\n"
    f"- 条目：\n"
    f"{item_history}"
)
history_text = "\n\n".join(history_parts).strip()
items_text = "\n".join(items)

review_section = (
    "## 8. 计划审核记录\n\n"
    "### 8.1 当前审核结论\n\n"
    f"- 审核状态：{result}\n"
    f"- 与原始需求一致性：{alignment}\n"
    "- 是否允许进入 `/ai-flow-plan-coding`："
    f"{execute_ready}\n"
    f"- 当前审核轮次：{round_no}\n"
    f"- 审核引擎/模型：{engine} / {model}\n"
    f"- 结论摘要：{summary}\n\n"
    "### 8.2 偏差与建议\n\n"
    f"{items_text}\n\n"
    "### 8.3 审核历史\n\n"
    f"{history_text}\n"
)

if re.search(r"(?m)^## 8\. 计划审核记录$", text):
    text = re.sub(r"(?ms)^## 8\. 计划审核记录\n.*\Z", review_section, text, count=1)
else:
    text = text.rstrip() + "\n\n" + review_section
plan_path.write_text(text, encoding="utf-8")
PY
}

run_codex_prompt() {
    local prompt="$1"
    local output_file="$2"
    local reasoning="$3"
    local skip_git_repo_check_arg=""
    local -a codex_args

    if [ -z "${CODEX_SKIP_GIT_REPO_CHECK_SUPPORTED:-}" ]; then
        if codex exec --help 2>/dev/null | grep -q -- '--skip-git-repo-check'; then
            CODEX_SKIP_GIT_REPO_CHECK_SUPPORTED=1
        else
            CODEX_SKIP_GIT_REPO_CHECK_SUPPORTED=0
        fi
    fi
    if [ "$CODEX_SKIP_GIT_REPO_CHECK_SUPPORTED" = "1" ]; then
        skip_git_repo_check_arg="--skip-git-repo-check"
    fi

    codex_args=(exec -m "$MODEL" -C "$PROJECT_DIR" --sandbox workspace-write -o "$output_file")
    if [ -n "$skip_git_repo_check_arg" ]; then
        codex_args+=("$skip_git_repo_check_arg")
    fi
    if [ -n "$reasoning" ]; then
        codex_args+=(-c "model_reasoning_effort=\"$reasoning\"")
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

run_review_phase_prompt() {
    local prompt="$1"
    local output_file="$2"
    local marker="$3"
    local reasoning="${4:-$PLAN_REVIEW_REASONING}"

    if ! command -v codex >/dev/null 2>&1; then
        if [ "$PLAN_ENGINE_MODE" = "codex" ]; then
            echo "错误: PLAN_ENGINE_MODE=codex，Codex 不可用，拒绝降级"
            fail_protocol "PLAN_ENGINE_MODE=codex 模式下 Codex 不可用" "failed"
        fi
        PLAN_ENGINE_NAME="Codex(unavailable)"
        echo ">>> 计划审核阶段 Codex 不可用，将输出 degraded 协议"
        return 1
    fi

    local stderr_file rc
    stderr_file=$(mktemp)
    set +e
    run_codex_prompt "$prompt" "$output_file" "$reasoning" 2>"$stderr_file"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        PLAN_ENGINE_NAME="Codex"
        PLAN_ENGINE_MODEL="$MODEL"
        trim_generated_file_to_marker "$output_file" "$marker" "$SLUG"
        rm -f "$stderr_file"
        return 0
    fi
    if is_codex_unavailable_error "$rc" "$stderr_file"; then
        emit_captured_stderr "$stderr_file" "Codex 计划审核 stderr"
        rm -f "$stderr_file"
        if [ "$PLAN_ENGINE_MODE" = "codex" ]; then
            echo "错误: PLAN_ENGINE_MODE=codex，Codex 不可用，拒绝降级"
            fail_protocol "PLAN_ENGINE_MODE=codex 模式下 Codex 执行失败" "failed"
        fi
        PLAN_ENGINE_NAME="Codex(unavailable)"
        echo ">>> 计划审核阶段 Codex 不可用，将输出 degraded 协议"
        return 1
    fi
    emit_captured_stderr "$stderr_file" "Codex 计划审核 stderr"
    rm -f "$stderr_file"
    echo "错误: Codex 执行计划审核阶段失败，且不属于可降级的不可用场景"
    fail_protocol "Codex 执行计划审核阶段失败，且不属于可降级的不可用场景" "failed"
}

revise_plan_from_failed_review() {
    local round="$1"
    local review_items_file="$2"
    local revision_prompt revision_output review_section_backup
    review_section_backup=$(mktemp)
    save_plan_review_record_section "$PLAN_FILE" "$review_section_backup"

    PLAN_CONTENT_FOR_PROMPT=$(cat "$PLAN_FILE")
    PLAN_REVIEW_ITEMS_FOR_PROMPT=$(cat "$review_items_file")
    revision_prompt=$(render_prompt_template "$PLAN_REVISION_PROMPT_TEMPLATE")
    revision_output=$(mktemp)

    echo ">>> 基于现有 draft plan 与审核意见修订 plan..."
    local revision_reasoning
    revision_reasoning=$(plan_authoring_reasoning)
    echo "    推理强度: $revision_reasoning"
    if ! run_plan_authoring_prompt "$revision_prompt" "$revision_output" "# 实施计划：" "$revision_reasoning"; then
        if [ "$PLAN_ENGINE_NAME" = "Codex(unavailable)" ]; then
            rm -f "$revision_output" "$review_section_backup"
            return 1
        fi
    fi
    mv "$revision_output" "$PLAN_FILE"
    restore_plan_review_record_section "$PLAN_FILE" "$review_section_backup"
    rm -f "$review_section_backup"

    ensure_requirement_literal "$PLAN_FILE"
    validate_plan_structure "$PLAN_FILE" "draft"
}

run_plan_authoring_prompt() {
    local prompt="$1"
    local output_file="$2"
    local marker="$3"
    local reasoning="${4:-$PLAN_REASONING}"

    if ! command -v codex >/dev/null 2>&1; then
        if [ "$PLAN_ENGINE_MODE" = "codex" ]; then
            echo "错误: PLAN_ENGINE_MODE=codex，Codex 不可用，拒绝降级"
            fail_protocol "PLAN_ENGINE_MODE=codex 模式下 Codex 不可用"
        fi
        PLAN_ENGINE_NAME="Codex(unavailable)"
        echo ">>> Plan 阶段 Codex 不可用，将输出 degraded 协议"
        return 1
    fi

    local stderr_file rc
    stderr_file=$(mktemp)
    set +e
    run_codex_prompt "$prompt" "$output_file" "$reasoning" 2>"$stderr_file"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        PLAN_ENGINE_NAME="Codex"
        PLAN_ENGINE_MODEL="$MODEL"
        trim_generated_file_to_marker "$output_file" "$marker" "$SLUG"
        rm -f "$stderr_file"
        return 0
    fi
    if is_codex_unavailable_error "$rc" "$stderr_file"; then
        emit_captured_stderr "$stderr_file" "Codex plan 生成 stderr"
        rm -f "$stderr_file"
        if [ "$PLAN_ENGINE_MODE" = "codex" ]; then
            echo "错误: PLAN_ENGINE_MODE=codex，Codex 不可用，拒绝降级"
            fail_protocol "PLAN_ENGINE_MODE=codex 模式下 Codex 执行失败"
        fi
        PLAN_ENGINE_NAME="Codex(unavailable)"
        echo ">>> Plan 阶段 Codex 不可用，将输出 degraded 协议"
        return 1
    fi
    emit_captured_stderr "$stderr_file" "Codex plan 生成 stderr"
    rm -f "$stderr_file"
    echo "错误: Codex 执行 plan 生成/修订失败，且不属于可降级的不可用场景"
    fail_protocol "Codex 执行 plan 生成/修订失败，且不属于可降级的不可用场景"
}

state_json_value() {
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
        sys.exit(1)
    if isinstance(value, dict):
        value = value.get(part)
    else:
        sys.exit(1)
if value is None:
    sys.exit(1)
print(value)
PY
}

state_json_value_optional() {
    state_json_value "$1" "$2" 2>/dev/null || true
}

load_state_context() {
    local state_file="$1"
    python3 - "$state_file" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(state.get("current_status", ""))
print(state.get("plan_file", ""))
print(state.get("title", ""))
PY
}

find_state_file_by_keyword() {
    local keyword="$1"
    local -a matched=()
    while IFS= read -r -d '' file; do
        matched+=("$file")
    done < <(find "$STATE_DIR" -name "*${keyword}*.json" -type f -print0 2>/dev/null)

    if [ "${#matched[@]}" -eq 0 ]; then
        fail_protocol "找不到包含关键词 '$keyword' 的状态文件" "failed"
    fi
    if [ "${#matched[@]}" -gt 1 ]; then
        fail_protocol "关键词 '$keyword' 匹配到多个状态文件，请使用精确 slug" "failed"
    fi
    printf '%s\n' "${matched[0]}"
}

extract_requirement_from_plan() {
    local plan_file="$1"
    python3 - "$plan_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"(?ms)\*\*原始需求（原文）\*\*：\n(.*?)(?=\n\*\*[^*]+\*\*：|\n## |\Z)",
    text,
)
if not match:
    raise SystemExit("plan 缺少 **原始需求（原文）** 字段")
print(match.group(1).strip())
PY
}

extract_plan_review_items() {
    local plan_file="$1"
    python3 - "$plan_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"(?ms)^### 8\.2 偏差与建议\n\n(.*?)(?=^### 8\.3 |\Z)", text)
if not match:
    print("- 待审核")
    raise SystemExit(0)
items = match.group(1).strip()
print(items or "- 待审核")
PY
}

extract_plan_repo_ids() {
    local plan_file="$1"
    python3 - "$plan_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
repo_ids = []

def add_repo(candidate: str):
    if candidate in {"", "-", "仓库"}:
        return
    if re.fullmatch(r"[a-z0-9][a-z0-9-]*", candidate) and candidate not in repo_ids:
        repo_ids.append(candidate)

for line in text.splitlines():
    if not line.startswith("|"):
        for match in re.findall(r"(?<![A-Za-z0-9./-])([a-z0-9][a-z0-9-]*)/[^`\s|]+", line):
            add_repo(match)
        continue
    cells = [cell.strip().strip("`") for cell in line.strip().split("|")[1:-1]]
    if len(cells) < 2:
        continue
    if cells[0] in {"模块", "文件"}:
        continue
    if set(cells[0]) <= {"-"}:
        continue
    add_repo(cells[1])
    if cells[0] == "文件":
        continue
    if len(cells) >= 1:
        for match in re.findall(r"(?<![A-Za-z0-9./-])([a-z0-9][a-z0-9-]*)/[^`\s|]+", cells[0]):
            add_repo(match)

for repo_id in repo_ids:
    print(repo_id)
PY
}

build_repo_scope_json() {
    local plan_file="$1"
    python3 - "$PROJECT_DIR" "$plan_file" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional
from typing import Optional

owner = Path(sys.argv[1]).resolve()
plan = Path(sys.argv[2])
text = plan.read_text(encoding="utf-8")
repo_ids = []
path_candidate_pattern = re.compile(r"(?<![A-Za-z0-9./-])([a-z0-9][a-z0-9-]*)/[^`\s|]+")

def add_repo(candidate: str):
    if candidate in {"", "-", "仓库"}:
        return
    if re.fullmatch(r"[a-z0-9][a-z0-9-]*", candidate) and candidate not in repo_ids:
        repo_ids.append(candidate)

if "owner" not in repo_ids:
    repo_ids.insert(0, "owner")

def git_root_for(path: Path) -> Path:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise SystemExit(f"路径不是有效 Git 仓库: {path}")
    return Path(result.stdout.strip()).resolve()

discovered = {"owner": {"path": ".", "git_root": git_root_for(owner)}}
for child in sorted(owner.iterdir(), key=lambda item: item.name):
    if not child.is_dir() or child.name.startswith(".") or child.name == ".ai-flow":
        continue
    try:
        git_root = git_root_for(child)
    except SystemExit:
        continue
    try:
        rel_path = git_root.relative_to(owner).as_posix()
    except ValueError:
        continue
    if rel_path == "." or "/" in rel_path:
        continue
    discovered.setdefault(child.name, {"path": rel_path, "git_root": git_root})

for line in text.splitlines():
    if not line.startswith("|"):
        for match in path_candidate_pattern.findall(line):
            if match in discovered:
                add_repo(match)
        continue
    cells = [cell.strip().strip("`") for cell in line.strip().split("|")[1:-1]]
    if len(cells) < 2 or cells[0] in {"模块", "文件"} or set(cells[0]) <= {"-"}:
        continue
    add_repo(cells[1])
    for cell in cells:
        for match in path_candidate_pattern.findall(cell):
            if match in discovered:
                add_repo(match)

repos = []
for repo_id in repo_ids:
    repo_meta = discovered.get(repo_id)
    if repo_meta is None:
        available = ", ".join(sorted(discovered.keys()))
        raise SystemExit(
            f"plan 声明仓库 {repo_id}，但未在 owner 根目录下发现同名一级 Git 仓库；可用仓库: {available}"
        )
    rel_path = repo_meta["path"]
    git_root = repo_meta["git_root"]
    repos.append({
        "id": repo_id,
        "path": rel_path,
        "git_root": str(git_root),
        "role": "owner" if repo_id == "owner" else "participant",
    })

print(json.dumps({"mode": "plan_repos", "repos": repos}, ensure_ascii=False))
PY
}

load_rule_bundle_for_repos() {
    local stage="$1"
    local skill_name="$2"
    local subagent_name="$3"
    shift 3 || true
    local bundle_json
    if ! bundle_json="$(load_rule_bundle_json "$stage" "$skill_name" "$subagent_name" "$@")"; then
        local error_text
        error_text="$(extract_rule_loader_error "$bundle_json")"
        fail_protocol "$error_text" "${PROTOCOL_REVIEW_RESULT:-}"
    fi
    RULE_BUNDLE_JSON="$bundle_json"
    RULE_PROMPT_BLOCK="$(render_rule_prompt_block "$RULE_BUNDLE_JSON" || true)"
    local required_reads_output
    if ! required_reads_output="$(render_required_reads_block "$RULE_BUNDLE_JSON" 2>&1)"; then
        local error_text
        error_text="$(extract_rule_loader_error "$required_reads_output")"
        fail_protocol "$error_text" "${PROTOCOL_REVIEW_RESULT:-}"
    fi
    RULE_REQUIRED_READS_BLOCK="$required_reads_output"
}

owner_rule_repo_arg() {
    printf 'owner::%s\n' "$PROJECT_DIR"
}

collect_repo_args_from_scope_json() {
    local scope_json="$1"
    python3 - "$scope_json" <<'PY'
import json
import sys

scope = json.loads(sys.argv[1])
repos = scope.get("repos") or []
for repo in repos:
    print(f"{repo['id']}::{repo['git_root']}")
PY
}

validate_plan_repos_match_state() {
    local plan_file="$1"
    local state_file="$2"
    python3 - "$plan_file" "$state_file" "$PROJECT_DIR" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

plan = Path(sys.argv[1])
state = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
owner = Path(sys.argv[3]).resolve()
text = plan.read_text(encoding="utf-8")
plan_repos = set()
path_candidate_pattern = re.compile(r"(?<![A-Za-z0-9./-])([a-z0-9][a-z0-9-]*)/[^`\s|]+")

def add_repo(candidate: str):
    if candidate in {"", "-", "仓库"}:
        return
    if re.fullmatch(r"[a-z0-9][a-z0-9-]*", candidate):
        plan_repos.add(candidate)

def git_root_for(path: Path) -> Optional[Path]:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    return Path(result.stdout.strip()).resolve()

discovered_repo_ids = {"owner"}
for child in sorted(owner.iterdir(), key=lambda item: item.name):
    if not child.is_dir() or child.name.startswith(".") or child.name == ".ai-flow":
        continue
    git_root = git_root_for(child)
    if git_root is None:
        continue
    try:
        rel_path = git_root.relative_to(owner).as_posix()
    except ValueError:
        continue
    if rel_path == child.name:
        discovered_repo_ids.add(child.name)

for line in text.splitlines():
    if not line.startswith("|"):
        for match in path_candidate_pattern.findall(line):
            if match in discovered_repo_ids:
                add_repo(match)
        continue
    cells = [cell.strip().strip("`") for cell in line.strip().split("|")[1:-1]]
    if len(cells) < 2 or cells[0] in {"模块", "文件"} or set(cells[0]) <= {"-"}:
        continue
    add_repo(cells[1])
    for cell in cells:
        for match in path_candidate_pattern.findall(cell):
            if match in discovered_repo_ids:
                add_repo(match)
if not plan_repos:
    plan_repos.add("owner")

scope = state.get("execution_scope") or {}
repos = scope.get("repos") or []
state_repos = {repo.get("id") for repo in repos}
missing = sorted(plan_repos - state_repos)
if missing:
    raise SystemExit("plan 中出现未写入 state 的仓库: " + ", ".join(missing))
if scope.get("mode") != "plan_repos":
    raise SystemExit("state execution_scope.mode 必须是 plan_repos")

owners = [repo for repo in repos if repo.get("role") == "owner"]
if len(owners) != 1:
    raise SystemExit("state 必须且只能包含一个 role=owner 仓库")

for repo in repos:
    repo_id = repo.get("id")
    repo_path = repo.get("path")
    git_root = repo.get("git_root")
    if repo.get("role") != "owner":
        path = owner / repo_path
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
        if Path(result.stdout.strip()).resolve() != Path(git_root).resolve():
            raise SystemExit(f"state repo {repo_id} git_root 与 path 解析结果不一致")
PY
}

plan_contains_disallowed_text() {
    local plan_file="$1"
    python3 - "$plan_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
text = re.sub(r"```.*?```", "", text, flags=re.S)
text = re.sub(r"`[^`\n]*`", "", text)
patterns = (
    r"\bTBD\b",
    r"\bTODO\b",
    "后续补充",
    "类似上一步",
    "适当处理异常",
    "根据情况处理",
)
raise SystemExit(0 if any(re.search(pattern, text) for pattern in patterns) else 1)
PY
}

ensure_project_root_context
mkdir -p "$PLANS_DIR" "$FLOW_DIR/reports" "$STATE_DIR"

PLAN_PROMPT_TEMPLATE_RENDERED="$(mktemp)"
PLAN_REVIEW_PROMPT_TEMPLATE_RENDERED="$(mktemp)"
PLAN_REVISION_PROMPT_TEMPLATE_RENDERED="$(mktemp)"
append_rule_context_to_prompt_template "$PLAN_PROMPT_TEMPLATE" "$PLAN_PROMPT_TEMPLATE_RENDERED"
append_rule_context_to_prompt_template "$PLAN_REVIEW_PROMPT_TEMPLATE" "$PLAN_REVIEW_PROMPT_TEMPLATE_RENDERED"
append_rule_context_to_prompt_template "$PLAN_REVISION_PROMPT_TEMPLATE" "$PLAN_REVISION_PROMPT_TEMPLATE_RENDERED"
PLAN_PROMPT_TEMPLATE="$PLAN_PROMPT_TEMPLATE_RENDERED"
PLAN_REVIEW_PROMPT_TEMPLATE="$PLAN_REVIEW_PROMPT_TEMPLATE_RENDERED"
PLAN_REVISION_PROMPT_TEMPLATE="$PLAN_REVISION_PROMPT_TEMPLATE_RENDERED"

if [ "$INTERNAL_PLAN_REVIEW" -eq 1 ]; then
    STATE_FILE=$(find_state_file_by_keyword "$MATCH_KEYWORD")
    SLUG=$(basename "$STATE_FILE" .json)
    state_context=$(load_state_context "$STATE_FILE")
    PLAN_STATUS=$(printf '%s\n' "$state_context" | sed -n '1p')
    PLAN_FILE=$(printf '%s\n' "$state_context" | sed -n '2p')
    PLAN_TITLE=$(printf '%s\n' "$state_context" | sed -n '3p')

    case "$PLAN_STATUS" in
        AWAITING_PLAN_REVIEW|PLAN_REVIEW_FAILED)
            ;;
        *)
            PROTOCOL_STATE="$PLAN_STATUS"
            fail_protocol "当前状态为 [$PLAN_STATUS]，计划审核只允许 [AWAITING_PLAN_REVIEW] 或 [PLAN_REVIEW_FAILED]" "failed"
            ;;
    esac

    [ -f "$PLAN_FILE" ] || {
        PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$PLAN_FILE")"
        fail_protocol "关联计划文件不存在: $PLAN_FILE" "failed"
    }
    STATE_SCOPE_JSON="$(python3 - "$STATE_FILE" <<'PY'
import json
import sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(json.dumps(state.get("execution_scope") or {}, ensure_ascii=False))
PY
)"
    rule_repo_args=()
    while IFS= read -r repo_arg; do
        [ -n "$repo_arg" ] && rule_repo_args+=("$repo_arg")
    done < <(collect_repo_args_from_scope_json "$STATE_SCOPE_JSON")
    load_rule_bundle_for_repos "plan_review" "ai-flow-plan-review" "$AGENT_NAME" "${rule_repo_args[@]}"
    REQUIREMENT=$(extract_requirement_from_plan "$PLAN_FILE")
    TEMPLATE_CONTENT=$(render_plan_template_content "$PLAN_TITLE" "$REQUIREMENT")
    PLAN_CONTENT_FOR_PROMPT=$(cat "$PLAN_FILE")
    PLAN_REVIEW_ITEMS_FOR_PROMPT=""
    REVIEW_PROMPT=$(render_prompt_template "$PLAN_REVIEW_PROMPT_TEMPLATE")
    REVIEW_ROUND=$(python3 - "$STATE_FILE" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rounds = sum(1 for item in state["transitions"] if item["event"] in {"plan_review_passed", "plan_review_failed"})
print(rounds + 1)
PY
)

    local_review_output=$(mktemp)
    local_review_items=$(mktemp)
    REVIEW_REASONING_EFFECTIVE=$(plan_review_reasoning "$(file_line_count "$PLAN_FILE")" "$REVIEW_ROUND")
    echo ">>> 执行第 ${REVIEW_ROUND} 轮计划审核..."
    echo "    目标需求: $SLUG [$PLAN_STATUS]"
    echo "    推理强度: $REVIEW_REASONING_EFFECTIVE"
    if ! run_review_phase_prompt "$REVIEW_PROMPT" "$local_review_output" "RESULT:" "$REVIEW_REASONING_EFFECTIVE"; then
        if [ "$PLAN_ENGINE_NAME" = "Codex(unavailable)" ]; then
            if [ "$PLAN_ENGINE_MODE" = "claude" ]; then
                fail_protocol "PLAN_ENGINE_MODE=claude 模式下不应进入 codex 执行路径" "failed"
            fi
            PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$PLAN_FILE")"
            PROTOCOL_STATE="$PLAN_STATUS"
            PROTOCOL_SUMMARY="Codex 不可用，已降级到 ai-flow-claude-plan-review。"
            emit_current_protocol "degraded"
            exit 0
        fi
    fi

    review_meta_output=$(parse_plan_review_response "$local_review_output" "$local_review_items")
    REVIEW_RESULT=$(printf '%s\n' "$review_meta_output" | sed -n '1p')
    REVIEW_ALIGNMENT=$(printf '%s\n' "$review_meta_output" | sed -n '2p')
    REVIEW_EXECUTE_READY=$(printf '%s\n' "$review_meta_output" | sed -n '3p')
    REVIEW_SUMMARY=$(printf '%s\n' "$review_meta_output" | sed -n '4p')

    write_plan_review_record \
        "$PLAN_FILE" \
        "$REVIEW_ROUND" \
        "$REVIEW_RESULT" \
        "$REVIEW_ALIGNMENT" \
        "$REVIEW_EXECUTE_READY" \
        "$REVIEW_SUMMARY" \
        "$PLAN_ENGINE_NAME" \
        "$PLAN_ENGINE_MODEL" \
        "$local_review_items"
    validate_plan_structure "$PLAN_FILE" "reviewed"
    validate_plan_review_record \
        "$PLAN_FILE" \
        "$REVIEW_RESULT" \
        "$( [ "$REVIEW_EXECUTE_READY" = "yes" ] && echo "是" || echo "否" )"
    validate_plan_repos_match_state "$PLAN_FILE" "$STATE_FILE"

    AI_FLOW_ACTOR="$AGENT_NAME" "$FLOW_STATE_SH" record-plan-review \
        --slug "$SLUG" \
        --result "$REVIEW_RESULT" \
        --engine "$PLAN_ENGINE_NAME" \
        --model "$PLAN_ENGINE_MODEL" >/dev/null
    CURRENT_STATUS=$("$FLOW_STATE_SH" show "$SLUG" --field current_status)
    PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$PLAN_FILE")"
    PROTOCOL_STATE="$CURRENT_STATUS"
    PROTOCOL_REVIEW_RESULT="$REVIEW_RESULT"

    if [ "$REVIEW_RESULT" = "passed" ] || [ "$REVIEW_RESULT" = "passed_with_notes" ]; then
        EXPECTED_STATUS="PLANNED"
    else
        EXPECTED_STATUS="PLAN_REVIEW_FAILED"
    fi
    if [ "$CURRENT_STATUS" != "$EXPECTED_STATUS" ]; then
        fail_protocol \
            "计划审核状态异常：期望 [$EXPECTED_STATUS]，实际 [$CURRENT_STATUS]。计划审核通过后必须进入 [PLANNED]；失败时必须进入 [PLAN_REVIEW_FAILED]。" \
            "$REVIEW_RESULT"
    fi

    echo "    状态已验证为 [$CURRENT_STATUS]"
    rm -f "$local_review_output" "$local_review_items"

    if [ "$REVIEW_RESULT" = "passed" ] || [ "$REVIEW_RESULT" = "passed_with_notes" ]; then
        PROTOCOL_NEXT="ai-flow-plan-coding"
        PROTOCOL_SUMMARY="计划审核已通过，状态进入 [$CURRENT_STATUS]。"
    else
        PROTOCOL_NEXT="ai-flow-plan"
        PROTOCOL_SUMMARY="计划审核未通过，状态进入 [$CURRENT_STATUS]，请先修订 draft plan。"
    fi
    if [ "$PLAN_ENGINE_NAME" = "Codex(unavailable)" ] && [ "$PLAN_ENGINE_MODE" = "auto" ]; then
        PROTOCOL_SUMMARY="${PROTOCOL_SUMMARY%?} 已降级到 ai-flow-claude-plan-review。"
    fi
    emit_current_protocol "$REVIEW_RESULT"
    exit 0
fi

SLUG_EXPLICIT=false
SLUG_AUTO=false
if [ -n "$SLUG" ]; then
    SLUG_EXPLICIT=true
else
    SLUG_AUTO=true
    ENG_WORDS=$(echo "$REQUIREMENT" | grep -oE '[A-Za-z]+' | head -3 | tr '\n' '-' | sed 's/-$//' || true)
    if [ -n "$ENG_WORDS" ]; then
        SLUG=$(echo "$ENG_WORDS" | tr '[:upper:]' '[:lower:]')
    else
        SLUG="plan-$DATE_PREFIX"
    fi
fi

if ! echo "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
    fail_protocol "英文简称 '$SLUG' 包含非法字符，只允许小写字母、数字和连字符（-）"
fi

EXISTING_STATE_FILE="$STATE_DIR/${DATE_PREFIX}-${SLUG}.json"
if [ "$SLUG_EXPLICIT" = true ] && [ -f "$EXISTING_STATE_FILE" ]; then
    PLAN_STATUS=$(state_json_value "$EXISTING_STATE_FILE" "current_status")
    PLAN_FILE=$(state_json_value "$EXISTING_STATE_FILE" "plan_file")
    case "$PLAN_STATUS" in
        AWAITING_PLAN_REVIEW|PLAN_REVIEW_FAILED)
            ;;
        *)
            PROTOCOL_STATE="$PLAN_STATUS"
            fail_protocol "slug [$SLUG] 当前状态为 [$PLAN_STATUS]，只有 [AWAITING_PLAN_REVIEW] 或 [PLAN_REVIEW_FAILED] 可以修订 draft plan"
            ;;
    esac
    [ -f "$PLAN_FILE" ] || {
        PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$PLAN_FILE")"
        fail_protocol "关联计划文件不存在: $PLAN_FILE"
    }
    STATE_SCOPE_JSON="$(python3 - "$EXISTING_STATE_FILE" <<'PY'
import json
import sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(json.dumps(state.get("execution_scope") or {}, ensure_ascii=False))
PY
)"
    rule_repo_args=()
    while IFS= read -r repo_arg; do
        [ -n "$repo_arg" ] && rule_repo_args+=("$repo_arg")
    done < <(collect_repo_args_from_scope_json "$STATE_SCOPE_JSON")
    load_rule_bundle_for_repos "plan_revision" "ai-flow-plan" "$AGENT_NAME" "${rule_repo_args[@]}"

    FRAMEWORKS=""
else
    if slug_exists "$SLUG" && [ "$SLUG_AUTO" = true ]; then
        BASE_SLUG="$SLUG"
        SUFFIX=2
        while slug_exists "$SLUG"; do
            SLUG="${BASE_SLUG}-${SUFFIX}"
            SUFFIX=$((SUFFIX + 1))
        done
    fi

    if slug_exists "$SLUG"; then
        fail_protocol "同名计划或状态已存在: $SLUG；如需重新生成，请先清理对应的 .ai-flow/state/${SLUG}.json 和计划文件，或更换简称"
    fi
    PLAN_FILE="$PLANS_DIR/${DATE_PREFIX}-${SLUG}.md"
fi
PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$PLAN_FILE")"

if [ -z "$RULE_BUNDLE_JSON" ]; then
    load_rule_bundle_for_repos "plan_generation" "ai-flow-plan" "$AGENT_NAME" "$(owner_rule_repo_arg)"
fi

FRAMEWORKS=""
if [ -f "$PROJECT_DIR/package.json" ]; then
    grep -q '"next"' "$PROJECT_DIR/package.json" 2>/dev/null && FRAMEWORKS="${FRAMEWORKS}Next.js, "
    grep -q '"react"' "$PROJECT_DIR/package.json" 2>/dev/null && FRAMEWORKS="${FRAMEWORKS}React, "
    grep -q '"vue"' "$PROJECT_DIR/package.json" 2>/dev/null && FRAMEWORKS="${FRAMEWORKS}Vue, "
    grep -q '"@angular/core"' "$PROJECT_DIR/package.json" 2>/dev/null && FRAMEWORKS="${FRAMEWORKS}Angular, "
    grep -q '"electron"' "$PROJECT_DIR/package.json" 2>/dev/null && FRAMEWORKS="${FRAMEWORKS}Electron, "
    grep -q '"tailwindcss"' "$PROJECT_DIR/package.json" 2>/dev/null && FRAMEWORKS="${FRAMEWORKS}TailwindCSS, "
fi
if [ -d "$PROJECT_DIR/src-tauri" ]; then
    FRAMEWORKS="${FRAMEWORKS}Tauri(Rust), "
fi
if [ -d "$PROJECT_DIR/src-electron" ]; then
    FRAMEWORKS="${FRAMEWORKS}Electron(Node.js), "
fi
POM_FILE=""
if [ -f "$PROJECT_DIR/pom.xml" ]; then
    POM_FILE="$PROJECT_DIR/pom.xml"
else
    POM_FILE=$(find "$PROJECT_DIR" -maxdepth 2 -name "pom.xml" -type f 2>/dev/null | head -1 || true)
fi
if [ -n "$POM_FILE" ] || [ -d "$PROJECT_DIR/src/main/java" ]; then
    FRAMEWORKS="${FRAMEWORKS}Java"
    if [ -n "$POM_FILE" ]; then
        grep -q "spring-boot" "$POM_FILE" 2>/dev/null && FRAMEWORKS="${FRAMEWORKS}/Spring Boot"
        grep -q "mybatis" "$POM_FILE" 2>/dev/null && FRAMEWORKS="${FRAMEWORKS}/MyBatis"
        grep -q "postgresql" "$POM_FILE" 2>/dev/null && FRAMEWORKS="${FRAMEWORKS}/PostgreSQL"
    fi
    FRAMEWORKS="${FRAMEWORKS}, "
fi
if [ -f "$PROJECT_DIR/go.mod" ]; then
    FRAMEWORKS="${FRAMEWORKS}Go, "
fi
if [ -f "$PROJECT_DIR/requirements.txt" ] || [ -f "$PROJECT_DIR/pyproject.toml" ]; then
    FRAMEWORKS="${FRAMEWORKS}Python, "
fi
if [ -f "$PROJECT_DIR/Cargo.toml" ] && [ ! -d "$PROJECT_DIR/src-tauri" ]; then
    FRAMEWORKS="${FRAMEWORKS}Rust, "
fi
if [ -f "$PROJECT_DIR/Gemfile" ]; then
    FRAMEWORKS="${FRAMEWORKS}Ruby, "
fi
if [ -f "$PROJECT_DIR/composer.json" ]; then
    FRAMEWORKS="${FRAMEWORKS}PHP, "
fi
SHELL_FILE=$(find "$PROJECT_DIR" -maxdepth 3 -type f \( -name "*.sh" -o -name "*.bash" \) ! -path "$FLOW_DIR/*" 2>/dev/null | head -1 || true)
if [ -n "$SHELL_FILE" ]; then
    FRAMEWORKS="${FRAMEWORKS}Shell/Bash, "
fi
MARKDOWN_FILE=$(find "$PROJECT_DIR" -maxdepth 3 -type f \( -name "*.md" -o -name "*.markdown" \) ! -path "$FLOW_DIR/*" 2>/dev/null | head -1 || true)
if [ -n "$MARKDOWN_FILE" ]; then
    FRAMEWORKS="${FRAMEWORKS}Markdown, "
fi
if [ -n "$FRAMEWORKS" ] && echo "$FRAMEWORKS" | grep -q "Next.js\|React\|Vue\|Angular\|Electron\|TailwindCSS" && ! echo "$FRAMEWORKS" | grep -q "Java\|Go\|Python\|Ruby\|PHP"; then
    FRAMEWORKS="TypeScript/JavaScript, ${FRAMEWORKS}"
fi
if [ -z "$FRAMEWORKS" ] && [ -d "$PROJECT_DIR/.git" ]; then
    LANG_LIST=$(find "$PROJECT_DIR" -maxdepth 3 \( -name "*.java" -o -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.vue" \) 2>/dev/null | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -3)
    if [ -n "$LANG_LIST" ]; then
        FRAMEWORKS=$(echo "$LANG_LIST" | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')
    fi
fi
DETECT_STACK="${FRAMEWORKS%, }"
[ -z "$DETECT_STACK" ] && DETECT_STACK="未检测到明确技术栈"

# Initialize local rule.yaml from global default if missing
if [ ! -f "$FLOW_DIR/rule.yaml" ] && [ -f "$AI_FLOW_HOME/rule.yaml" ]; then
    echo ">>> Initializing project rule.yaml..."
    cp "$AI_FLOW_HOME/rule.yaml" "$FLOW_DIR/rule.yaml"
    
    # Refine content based on source code (no-dependency string replacement)
    python3 - "$FLOW_DIR/rule.yaml" "$DETECT_STACK" "$PROJECT_DIR" <<'PY'
import sys
from pathlib import Path

rule_path = Path(sys.argv[1])
detect_stack = sys.argv[2]
project_dir = Path(sys.argv[3])

if not rule_path.is_file():
    sys.exit(0)

text = rule_path.read_text(encoding='utf-8')

# 1. Update shared_context
stack_info = f"Project Stack: {detect_stack}"
if "shared_context: []" in text:
    text = text.replace("shared_context: []", f"shared_context:\n    - \"{stack_info}\"")

# 2. Update required_reads
candidates = ["README.md", "README_CN.md", "CLAUDE.md"]
found = [c for c in candidates if (project_dir / c).is_file()]
if found and "required_reads: []" in text:
    reads_str = "required_reads:\n" + "\n".join([f"    - \"{c}\"" for c in found])
    text = text.replace("required_reads: []", reads_str)

# 3. Update test_policy
has_tests = False
for d in ["tests", "test", "src/test"]:
    if (project_dir / d).is_dir():
        has_tests = True
        break
if has_tests:
    text = text.replace("require_tests_for_code_change: false", "require_tests_for_code_change: true")

rule_path.write_text(text, encoding='utf-8')
PY
    echo "    Optimized $FLOW_DIR/rule.yaml based on project status ($DETECT_STACK)"
fi

TEMPLATE_CONTENT=$(render_plan_template_content "$REQUIREMENT" "$REQUIREMENT")

if [ "$SLUG_EXPLICIT" = true ] && [ -f "$EXISTING_STATE_FILE" ]; then
    local_review_items=$(mktemp)
    printf '%s\n' "$(extract_plan_review_items "$PLAN_FILE")" > "$local_review_items"
    PLAN_CONTENT_FOR_PROMPT=$(cat "$PLAN_FILE")
    PLAN_REVIEW_ITEMS_FOR_PROMPT=$(cat "$local_review_items")
    echo ">>> 修订现有 draft plan: $SLUG [$PLAN_STATUS]"
    echo "    计划文件: $PLAN_FILE"
    if ! revise_plan_from_failed_review "1" "$local_review_items"; then
        if [ "$PLAN_ENGINE_NAME" = "Codex(unavailable)" ]; then
            if [ "$PLAN_ENGINE_MODE" = "claude" ]; then
                fail_protocol "PLAN_ENGINE_MODE=claude 模式下不应进入 codex 执行路径"
            fi
            rm -f "$local_review_items"
            PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$PLAN_FILE")"
            PROTOCOL_STATE="$PLAN_STATUS"
            PROTOCOL_SUMMARY="Codex 不可用，已降级到 ai-flow-claude-plan。"
            emit_current_protocol "degraded"
            exit 0
        fi
    fi
    rm -f "$local_review_items"
    echo "    状态保持 [$PLAN_STATUS]"
    PROTOCOL_STATE="$PLAN_STATUS"
    PROTOCOL_NEXT="ai-flow-plan-review"
    PROTOCOL_SUMMARY="draft plan 修订完成，状态保持 [$PLAN_STATUS]。"
else
    echo ">>> 生成 draft plan..."
    echo "    输出文件: $PLAN_FILE"
    echo "    检测到技术栈: $DETECT_STACK"
    AUTHORING_REASONING=$(plan_authoring_reasoning)
    echo "    推理强度: $AUTHORING_REASONING"
    echo ""
    PLAN_PROMPT=$(render_prompt_template "$PLAN_PROMPT_TEMPLATE")
    if ! run_plan_authoring_prompt "$PLAN_PROMPT" "$PLAN_FILE" "# 实施计划：" "$AUTHORING_REASONING"; then
        if [ "$PLAN_ENGINE_NAME" = "Codex(unavailable)" ]; then
            if [ "$PLAN_ENGINE_MODE" = "claude" ]; then
                fail_protocol "PLAN_ENGINE_MODE=claude 模式下不应进入 codex 执行路径"
            fi
            PROTOCOL_ARTIFACT="none"
            PROTOCOL_STATE="none"
            PROTOCOL_SUMMARY="Codex 不可用，已降级到 ai-flow-claude-plan。"
            emit_current_protocol "degraded"
            exit 0
        fi
    fi
    ensure_requirement_literal "$PLAN_FILE"
    echo ""
    echo ">>> 校验 draft plan 结构..."
    validate_plan_structure "$PLAN_FILE" "draft"
    echo "    结构校验通过"

    PLAN_TITLE=$(sed -n '1s/^# 实施计划：//p' "$PLAN_FILE")
    [ -z "$PLAN_TITLE" ] && PLAN_TITLE="$REQUIREMENT"

    REPO_SCOPE_JSON=$(build_repo_scope_json "$PLAN_FILE")
    rule_repo_args=()
    while IFS= read -r repo_arg; do
        [ -n "$repo_arg" ] && rule_repo_args+=("$repo_arg")
    done < <(collect_repo_args_from_scope_json "$REPO_SCOPE_JSON")
    load_rule_bundle_for_repos "plan_generation" "ai-flow-plan" "$AGENT_NAME" "${rule_repo_args[@]}"

    PLAN_CONTENT_FOR_PROMPT=$(cat "$PLAN_FILE")
    PLAN_REVIEW_ITEMS_FOR_PROMPT=""
    SECOND_STAGE_PROMPT=$(render_prompt_template "$PLAN_REVISION_PROMPT_TEMPLATE")
    second_stage_output=$(mktemp)
    echo ">>> 按参与仓库规则补强 draft plan..."
    if ! run_plan_authoring_prompt "$SECOND_STAGE_PROMPT" "$second_stage_output" "# 实施计划：" "$AUTHORING_REASONING"; then
        if [ "$PLAN_ENGINE_NAME" = "Codex(unavailable)" ]; then
            if [ "$PLAN_ENGINE_MODE" = "claude" ]; then
                fail_protocol "PLAN_ENGINE_MODE=claude 模式下不应进入 codex 执行路径"
            fi
            rm -f "$second_stage_output"
            PROTOCOL_ARTIFACT="none"
            PROTOCOL_STATE="none"
            PROTOCOL_SUMMARY="Codex 不可用，已降级到 ai-flow-claude-plan。"
            emit_current_protocol "degraded"
            exit 0
        fi
    fi
    mv "$second_stage_output" "$PLAN_FILE"
    ensure_requirement_literal "$PLAN_FILE"
    validate_plan_structure "$PLAN_FILE" "draft"

    echo ">>> 初始化状态文件..."
    AI_FLOW_ACTOR="$AGENT_NAME" "$FLOW_STATE_SH" create --slug "${DATE_PREFIX}-${SLUG}" --title "$PLAN_TITLE" --plan-file "$PLAN_FILE" --repo-scope-json "$REPO_SCOPE_JSON"
    PLAN_STATUS=$("$FLOW_STATE_SH" show "${DATE_PREFIX}-${SLUG}" --field current_status)
    echo "    状态已验证为 [$PLAN_STATUS]"
    PROTOCOL_STATE="$PLAN_STATUS"
    PROTOCOL_NEXT="ai-flow-plan-review"
    PROTOCOL_SUMMARY="draft plan 生成完成，状态进入 [$PLAN_STATUS]。"
fi

if [ "$PLAN_ENGINE_NAME" = "Codex(unavailable)" ] && [ "$PLAN_ENGINE_MODE" = "auto" ]; then
    PROTOCOL_SUMMARY="${PROTOCOL_SUMMARY%?} 已降级到 ai-flow-claude-plan。"
fi
emit_current_protocol
