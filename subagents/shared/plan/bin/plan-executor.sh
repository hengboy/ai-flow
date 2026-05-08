#!/bin/bash
# plan-executor.sh — 生成或修订 draft plan；内部也承载 plan review 实现

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$AGENT_DIR/lib/agent-common.sh"
exec 3>&1 1>&2

AI_FLOW_HOME="${AI_FLOW_HOME:-$HOME/.config/ai-flow}"
FLOW_STATE_SH="$AI_FLOW_HOME/scripts/flow-state.sh"
PROJECT_DIR="$(pwd)"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
STATE_DIR="$FLOW_DIR/state"
DATE_DIR="$(date +%Y%m%d)"
PLANS_DIR="$FLOW_DIR/plans/$DATE_DIR"
TEMPLATE="$AGENT_DIR/templates/plan-template.md"
PLAN_PROMPT_TEMPLATE="$AGENT_DIR/prompts/plan-generation.md"
PLAN_REVIEW_PROMPT_TEMPLATE="${AI_FLOW_PLAN_REVIEW_PROMPT_TEMPLATE:-$AGENT_DIR/prompts/plan-review.md}"
PLAN_REVISION_PROMPT_TEMPLATE="$AGENT_DIR/prompts/plan-revision.md"
PLAN_OPENCODE_MODEL="${AI_FLOW_PLAN_OPENCODE_MODEL:-zhipuai-coding-plan/glm-5.1}"
PLAN_REASONING="${AI_FLOW_PLAN_REASONING:-xhigh}"
PLAN_REVIEW_REASONING="${AI_FLOW_PLAN_REVIEW_REASONING:-xhigh}"
PLAN_ENGINE_FALLBACK_ACTIVE=false
PLAN_ENGINE_NAME=""
PLAN_ENGINE_MODEL=""
INTERNAL_PLAN_REVIEW=0
REQUIREMENT=""
SLUG=""
MODEL="$(default_model_for_engine "$AGENT_ENGINE")"
MATCH_KEYWORD=""
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
if [ "${1:-}" = "--internal-plan-review" ]; then
    INTERNAL_PLAN_REVIEW=1
    MATCH_KEYWORD="${2:-}"
    MODEL="$(default_model_for_engine "$AGENT_ENGINE")"
    if [ -z "$MATCH_KEYWORD" ]; then
        fail_protocol "用法: plan-review-executor.sh {slug或唯一关键词}" "failed"
    fi
else
    if [ -z "${1:-}" ]; then
        fail_protocol "用法: plan-executor.sh \"需求描述\" [英文简称]" ""
    fi
    REQUIREMENT="$1"
    SLUG="${2:-}"
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

ensure_project_root_context() {
    local candidate
    local -a candidates=()

    if has_project_root_marker "$PROJECT_DIR"; then
        return 0
    fi

    while IFS= read -r candidate; do
        [ -n "$candidate" ] && candidates+=("$candidate")
    done < <(discover_project_root_candidates "$PROJECT_DIR")

    local message
    message="当前目录不是可识别的项目根目录: $PROJECT_DIR"
    if [ "${#candidates[@]}" -eq 1 ]; then
        message="$message；检测到候选项目根目录: $PROJECT_DIR/${candidates[0]}"
    elif [ "${#candidates[@]}" -gt 1 ]; then
        message="$message；检测到多个候选项目根目录，请进入目标模块根目录后重新运行 /ai-flow-plan"
    else
        message="$message；请在包含 .git、pom.xml、package.json、go.mod、src 等根标记的目录中运行"
    fi
    fail_protocol "$message" "${PROTOCOL_REVIEW_RESULT:-}"
}

validate_installed_resources

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\/&]/\\&/g'
}

render_prompt_template() {
    local prompt_template="$1"
    AI_FLOW_TEMPLATE_CONTENT="${TEMPLATE_CONTENT:-}" \
    AI_FLOW_DETECT_STACK="${DETECT_STACK:-}" \
    AI_FLOW_REQUIREMENT="$REQUIREMENT" \
    AI_FLOW_SLUG="$SLUG" \
    AI_FLOW_PLAN_CONTENT="${PLAN_CONTENT_FOR_PROMPT:-}" \
    AI_FLOW_REVIEW_ITEMS="${PLAN_REVIEW_ITEMS_FOR_PROMPT:-}" \
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
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
sys.stdout.write(text)
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
    find "$FLOW_DIR/plans" -name "${candidate}.md" -type f 2>/dev/null | grep -q .
}

map_reasoning_to_opencode_variant() {
    case "$1" in
        xhigh) echo "max" ;;
        high) echo "high" ;;
        *) echo "minimal" ;;
    esac
}

trim_generated_file_to_marker() {
    local file="$1"
    local marker="$2"
    python3 - "$file" "$marker" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text(encoding="utf-8")
lines = text.splitlines()
for index, line in enumerate(lines):
    if line.startswith(marker):
        trimmed = "\n".join(lines[index:])
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
            "### 2.6 高风险路径与缺陷族" \
            "### 4.4 定向验证矩阵" \
            "### 8.1 当前审核结论" \
            "### 8.2 偏差与建议" \
            "### 8.3 审核历史"; do
            if ! grep -Fq "$section" "$plan_file"; then
                errors="${errors}缺少强制小节: $section\n"
            fi
        done
        if ! grep -Fq '**原始需求（原文）**' "$plan_file"; then
            errors="${errors}缺少原始需求（原文）字段\n"
        fi
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

run_opencode_prompt() {
    local prompt="$1"
    local output_file="$2"
    local variant="$3"
    opencode run \
        -m "$PLAN_OPENCODE_MODEL" \
        --variant "$variant" \
        --dangerously-skip-permissions \
        --format default \
        --dir "$PROJECT_DIR" \
        "$prompt" > "$output_file"
}

is_codex_unavailable_error() {
    local rc="$1"
    local stderr_file="$2"
    if [ "$rc" -eq 127 ]; then
        return 0
    fi
    grep -qiE 'command not found|codex unavailable|codex 未安装|not installed|No such file|unavailable' "$stderr_file"
}

run_review_phase_prompt() {
    local prompt="$1"
    local output_file="$2"
    local marker="$3"
    local variant
    variant=$(map_reasoning_to_opencode_variant "$PLAN_REVIEW_REASONING")

    if [ "${AI_FLOW_PLAN_REVIEW_FORCE_OPENCODE:-0}" = "1" ]; then
        PLAN_ENGINE_FALLBACK_ACTIVE=true
    fi

    if [ "$PLAN_ENGINE_FALLBACK_ACTIVE" = false ]; then
        if ! command -v codex >/dev/null 2>&1; then
            PLAN_ENGINE_FALLBACK_ACTIVE=true
        else
            local stderr_file rc
            stderr_file=$(mktemp)
            set +e
            run_codex_prompt "$prompt" "$output_file" "$PLAN_REVIEW_REASONING" 2>"$stderr_file"
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then
                PLAN_ENGINE_NAME="Codex"
                PLAN_ENGINE_MODEL="$MODEL"
                trim_generated_file_to_marker "$output_file" "$marker"
                rm -f "$stderr_file"
                return 0
            fi
            if is_codex_unavailable_error "$rc" "$stderr_file"; then
                echo ">>> 计划审核阶段 Codex 不可用，降级到 OpenCode ($PLAN_OPENCODE_MODEL)"
                PLAN_ENGINE_FALLBACK_ACTIVE=true
            else
                cat "$stderr_file" >&2
                rm -f "$stderr_file"
                echo "错误: Codex 执行计划审核阶段失败，且不属于可降级的不可用场景"
                fail_protocol "Codex 执行计划审核阶段失败，且不属于可降级的不可用场景" "failed"
            fi
            rm -f "$stderr_file"
        fi
    fi

    if ! command -v opencode >/dev/null 2>&1; then
        fail_protocol "计划审核阶段需要降级到 OpenCode，但 opencode 不可用" "failed"
    fi
    run_opencode_prompt "$prompt" "$output_file" "$variant"
    trim_generated_file_to_marker "$output_file" "$marker"
    PLAN_ENGINE_NAME="OpenCode"
    PLAN_ENGINE_MODEL="$PLAN_OPENCODE_MODEL"
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
    run_plan_authoring_prompt "$revision_prompt" "$revision_output" "# 实施计划："
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
    local variant
    variant=$(map_reasoning_to_opencode_variant "$PLAN_REASONING")

    if [ "${AI_FLOW_PLAN_FORCE_OPENCODE:-0}" = "1" ]; then
        PLAN_ENGINE_FALLBACK_ACTIVE=true
    fi

    if [ "$PLAN_ENGINE_FALLBACK_ACTIVE" = false ]; then
        if ! command -v codex >/dev/null 2>&1; then
            PLAN_ENGINE_FALLBACK_ACTIVE=true
        else
            local stderr_file rc
            stderr_file=$(mktemp)
            set +e
            run_codex_prompt "$prompt" "$output_file" "$PLAN_REASONING" 2>"$stderr_file"
            rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then
                PLAN_ENGINE_NAME="Codex"
                PLAN_ENGINE_MODEL="$MODEL"
                trim_generated_file_to_marker "$output_file" "$marker"
                rm -f "$stderr_file"
                return 0
            fi
            if is_codex_unavailable_error "$rc" "$stderr_file"; then
                echo ">>> Plan 阶段 Codex 不可用，降级到 OpenCode ($PLAN_OPENCODE_MODEL)"
                PLAN_ENGINE_FALLBACK_ACTIVE=true
            else
                cat "$stderr_file" >&2
                rm -f "$stderr_file"
                echo "错误: Codex 执行 plan 生成/修订失败，且不属于可降级的不可用场景"
                fail_protocol "Codex 执行 plan 生成/修订失败，且不属于可降级的不可用场景"
            fi
            rm -f "$stderr_file"
        fi
    fi

    if ! command -v opencode >/dev/null 2>&1; then
        fail_protocol "Plan 阶段需要降级到 OpenCode，但 opencode 不可用"
    fi
    run_opencode_prompt "$prompt" "$output_file" "$variant"
    trim_generated_file_to_marker "$output_file" "$marker"
    PLAN_ENGINE_NAME="OpenCode"
    PLAN_ENGINE_MODEL="$PLAN_OPENCODE_MODEL"
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
mkdir -p "$PLANS_DIR" "$FLOW_DIR/reports/$DATE_DIR" "$STATE_DIR"

if [ "$INTERNAL_PLAN_REVIEW" -eq 1 ]; then
    STATE_FILE=$(find_state_file_by_keyword "$MATCH_KEYWORD")
    SLUG=$(basename "$STATE_FILE" .json)
    PLAN_STATUS=$(state_json_value "$STATE_FILE" "current_status")
    PLAN_FILE=$(state_json_value "$STATE_FILE" "plan_file")
    PLAN_TITLE=$(state_json_value "$STATE_FILE" "title")

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
    REQUIREMENT=$(extract_requirement_from_plan "$PLAN_FILE")
    TEMPLATE_CONTENT=$(sed \
        -e "s/{需求名称}/$(escape_sed_replacement "$PLAN_TITLE")/g" \
        -e "s/{需求简称}/$(escape_sed_replacement "$SLUG")/g" \
        -e "s/{YYYY-MM-DD}/$(date +%Y-%m-%d)/g" \
        -e "s#{需求文档/口头描述/Jira 等}#需求描述#g" \
        -e "s/{原始需求原文}/$(escape_sed_replacement "$REQUIREMENT")/g" \
        "$TEMPLATE")
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
    echo ">>> 执行第 ${REVIEW_ROUND} 轮计划审核..."
    echo "    目标需求: $SLUG [$PLAN_STATUS]"
    run_review_phase_prompt "$REVIEW_PROMPT" "$local_review_output" "RESULT:"

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
    if [ "$PLAN_ENGINE_NAME" = "OpenCode" ] && [ "$AGENT_ENGINE" = "codex" ]; then
        PROTOCOL_SUMMARY="${PROTOCOL_SUMMARY%?} 已降级到 OpenCode。"
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
        SLUG="plan-$DATE_DIR"
    fi
fi

if ! echo "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
    fail_protocol "英文简称 '$SLUG' 包含非法字符，只允许小写字母、数字和连字符（-）"
fi

EXISTING_STATE_FILE="$STATE_DIR/$SLUG.json"
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
    PLAN_FILE="$PLANS_DIR/$SLUG.md"
fi
PROTOCOL_ARTIFACT="$(display_path "$PROJECT_DIR" "$PLAN_FILE")"

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

TEMPLATE_CONTENT=$(sed \
    -e "s/{需求名称}/$(escape_sed_replacement "$REQUIREMENT")/g" \
    -e "s/{需求简称}/$(escape_sed_replacement "$SLUG")/g" \
    -e "s/{YYYY-MM-DD}/$(date +%Y-%m-%d)/g" \
    -e "s#{需求文档/口头描述/Jira 等}#需求描述#g" \
    -e "s/{原始需求原文}/$(escape_sed_replacement "$REQUIREMENT")/g" \
    "$TEMPLATE")

if [ "$SLUG_EXPLICIT" = true ] && [ -f "$EXISTING_STATE_FILE" ]; then
    local_review_items=$(mktemp)
    printf '%s\n' "$(extract_plan_review_items "$PLAN_FILE")" > "$local_review_items"
    PLAN_CONTENT_FOR_PROMPT=$(cat "$PLAN_FILE")
    PLAN_REVIEW_ITEMS_FOR_PROMPT=$(cat "$local_review_items")
    echo ">>> 修订现有 draft plan: $SLUG [$PLAN_STATUS]"
    echo "    计划文件: $PLAN_FILE"
    revise_plan_from_failed_review "1" "$local_review_items"
    rm -f "$local_review_items"
    echo "    状态保持 [$PLAN_STATUS]"
    PROTOCOL_STATE="$PLAN_STATUS"
    PROTOCOL_NEXT="ai-flow-plan-review"
    PROTOCOL_SUMMARY="draft plan 修订完成，状态保持 [$PLAN_STATUS]。"
else
    echo ">>> 生成 draft plan..."
    echo "    输出文件: $PLAN_FILE"
    echo "    检测到技术栈: $DETECT_STACK"
    echo ""
    PLAN_PROMPT=$(render_prompt_template "$PLAN_PROMPT_TEMPLATE")
    run_plan_authoring_prompt "$PLAN_PROMPT" "$PLAN_FILE" "# 实施计划："
    ensure_requirement_literal "$PLAN_FILE"
    echo ""
    echo ">>> 校验 draft plan 结构..."
    validate_plan_structure "$PLAN_FILE" "draft"
    echo "    结构校验通过"

    PLAN_TITLE=$(sed -n '1s/^# 实施计划：//p' "$PLAN_FILE")
    [ -z "$PLAN_TITLE" ] && PLAN_TITLE="$REQUIREMENT"

    echo ">>> 初始化状态文件..."
    AI_FLOW_ACTOR="$AGENT_NAME" "$FLOW_STATE_SH" create --slug "$SLUG" --title "$PLAN_TITLE" --plan-file "$PLAN_FILE"
    PLAN_STATUS=$("$FLOW_STATE_SH" show "$SLUG" --field current_status)
    echo "    状态已验证为 [$PLAN_STATUS]"
    PROTOCOL_STATE="$PLAN_STATUS"
    PROTOCOL_NEXT="ai-flow-plan-review"
    PROTOCOL_SUMMARY="draft plan 生成完成，状态进入 [$PLAN_STATUS]。"
fi

if [ "$PLAN_ENGINE_NAME" = "OpenCode" ] && [ "$AGENT_ENGINE" = "codex" ]; then
    PROTOCOL_SUMMARY="${PROTOCOL_SUMMARY%?} 已降级到 OpenCode。"
fi
emit_current_protocol
