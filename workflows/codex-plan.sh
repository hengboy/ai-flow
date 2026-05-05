#!/bin/bash
# codex-plan.sh — 调用 Codex 分析需求并生成实施计划
# 用法: codex-plan.sh "需求描述" [英文简称] [模型名]

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "用法: codex-plan.sh \"需求描述\" [英文简称] [模型名]"
    echo "示例: codex-plan.sh \"新增用户权限管理模块\" user-permission"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_STATE_SH="$SCRIPT_DIR/flow-state.sh"

REQUIREMENT="$1"
SLUG="${2:-}"
MODEL="${3:-gpt-5.4}"
PROJECT_DIR="$(pwd)"
FLOW_DIR="$PROJECT_DIR/.ai-flow"
STATE_DIR="$FLOW_DIR/state"
DATE_DIR="$(date +%Y%m%d)"
PLANS_DIR="$FLOW_DIR/plans/$DATE_DIR"
TEMPLATE="$HOME/.claude/templates/plan-template.md"

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&/\]/\\&/g'
}

slug_exists() {
    local candidate="$1"
    if [ -f "$STATE_DIR/${candidate}.json" ]; then
        return 0
    fi
    find "$FLOW_DIR/plans" -name "${candidate}.md" -type f 2>/dev/null | grep -q .
}

SLUG_AUTO=false
if [ -z "$SLUG" ]; then
    SLUG_AUTO=true
    ENG_WORDS=$(echo "$REQUIREMENT" | grep -oE '[A-Za-z]+' | head -3 | tr '\n' '-' | sed 's/-$//' || true)
    if [ -n "$ENG_WORDS" ]; then
        SLUG=$(echo "$ENG_WORDS" | tr '[:upper:]' '[:lower:]')
    else
        SLUG="plan-$DATE_DIR"
    fi
fi

if ! echo "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
    echo "错误: 英文简称 '$SLUG' 包含非法字符，只允许小写字母、数字和连字符（-）"
    exit 1
fi

if slug_exists "$SLUG" && [ "$SLUG_AUTO" = true ]; then
    BASE_SLUG="$SLUG"
    SUFFIX=2
    while slug_exists "$SLUG"; do
        SLUG="${BASE_SLUG}-${SUFFIX}"
        SUFFIX=$((SUFFIX + 1))
    done
fi

if slug_exists "$SLUG"; then
    echo "⚠ 警告: 同名计划或状态已存在: $SLUG"
    echo "    如需重新生成，请先清理对应的 .ai-flow/state/${SLUG}.json 和计划文件，或更换简称"
    exit 1
fi

PLAN_FILE="$PLANS_DIR/$SLUG.md"

mkdir -p "$PLANS_DIR" "$FLOW_DIR/reports/$DATE_DIR" "$STATE_DIR"

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
    "$TEMPLATE")
TEMPLATE_CONTENT=${TEMPLATE_CONTENT//\`/\\\`}

echo ">>> 将需求描述发送给 Codex (模型: $MODEL)..."
echo "    输出文件: $PLAN_FILE"
echo "    检测到技术栈: $DETECT_STACK"
echo ""

PLAN_PROMPT=$(cat <<PROMPT_END
你是高级软件架构师。请分析以下需求，生成详细的分步骤实施计划。

模板结构（请按照此结构填充具体内容）：
$TEMPLATE_CONTENT

项目技术栈：
$DETECT_STACK

需求描述：
$REQUIREMENT

要求：
1. 先做轻量需求澄清（intake）：确认目标、非目标、约束、成功标准；如果需求包含多个独立子系统，在 plan 中先拆解边界和推荐顺序
2. 填充模板中的所有占位符，删除大括号标记
3. 实施步骤要拆得足够细，每个 Step 先写目标和文件边界（file-boundary），文件路径必须精确，并补齐“本轮 review 预期关注面”“本步关闭条件”
4. 代码必须严格匹配上述检测到的技术栈，不要引入项目不使用的语言或框架
5. 直接输出完整的计划 Markdown 内容，不要包含其他解释文字
6. 本计划是证据文档，不承担流程状态语义；流程状态只写入 .ai-flow/state/${SLUG}.json
   - 不得为 .ai-flow/state/${SLUG}.json 设计任何 JSON 结构、字段列表、样例内容或手工维护步骤
   - 该状态文件只能由 flow-state.sh 维护，固定字段只有：schema_version、slug、title、current_status、created_at、updated_at、plan_file、review_rounds、latest_regular_review_file、latest_recheck_review_file、last_review、active_fix、transitions
   - 如果需要记录步骤进度、验证结果、变更登记，写在计划文档自身（Step 复选框、测试计划、需求变更记录），不要写进 state JSON 设计
7. 所有规则、算法、接口结构必须自包含，不能引用 plan 外的代码或文档
8. "**前置阅读**"字段是可选的，仅在需要参考现有代码范式（如新增文件要遵循已有模式、修改接口需了解调用方）时填写，说明为什么要读和了解什么
9. 每个 Step 的"执行动作"必须使用 "- [ ]" 复选框，动作粒度控制在 2-5 分钟（step-run）
10. 涉及代码修改的动作必须说明具体函数、类型、配置、分支逻辑、错误处理和边界条件
11. 技术分析必须包含“2.6 高风险路径与缺陷族”：每个高风险能力至少写清影响面、典型失效模式、对应缺陷族、必须覆盖的验证方式
12. 测试计划必须包含“4.4 定向验证矩阵”：每个缺陷族至少绑定一个定向验证命令；SQL-heavy / mapper-heavy / workflow-heavy 需求至少覆盖 test-compile、目标单测、目标 Mapper/集成验证中的两类
13. 缺陷族至少要能追踪到数据/SQL/映射、权限/范围、状态机/流程、输入/边界、测试/证据这些常见风险中的相关项；如果某类不适用，要明确写“不适用”原因
14. 验证动作必须给出确切命令和预期结果；测试优先（test-first）按"写失败用例 -> 验证失败 -> 最小实现 -> 验证通过"组织
15. 每个 Step 必须包含"本步自检"，至少检查 git diff 范围、计划外文件、占位符和临时日志
16. 禁止输出 TBD、TODO、后续补充、类似上一步、适当处理异常、根据情况处理等不可执行描述
17. 如果某类内容不适用，删除对应模板行或写"无"，不要保留占位符
18. 输出前自检：需求覆盖完整、无占位符、函数/类型/路径命名一致、2.6 和 4.4 已填充、每个 Step 都有验证命令和预期结果
PROMPT_END
)

printf '%s\n' "$PLAN_PROMPT" | codex exec \
    -m "$MODEL" \
    --sandbox workspace-write \
    -o "$PLAN_FILE"

echo ""
echo ">>> 校验计划结构..."
ERRORS=""
if [ ! -s "$PLAN_FILE" ]; then
    ERRORS="${ERRORS}计划文件为空或未生成\n"
else
    FIRST_LINE=$(head -1 "$PLAN_FILE")
    if ! echo "$FIRST_LINE" | grep -qE '^# 实施计划：'; then
        ERRORS="${ERRORS}首行必须是 '# 实施计划：...'\n"
    fi
    for section in "## 1. 需求概述" "## 2. 技术分析" "## 3. 实施步骤" "## 4. 测试计划" "## 5. 风险与注意事项" "## 6. 验收标准"; do
        if ! grep -Fq "$section" "$PLAN_FILE"; then
            ERRORS="${ERRORS}缺少章节: $section\n"
        fi
    done
    for section in "### 2.6 高风险路径与缺陷族" "### 4.4 定向验证矩阵"; do
        if ! grep -Fq "$section" "$PLAN_FILE"; then
            ERRORS="${ERRORS}缺少强制小节: $section\n"
        fi
    done
    if ! grep -q '^### Step ' "$PLAN_FILE"; then
        ERRORS="${ERRORS}缺少可执行 Step\n"
    fi
    if ! grep -q '^- \[ \]' "$PLAN_FILE"; then
        ERRORS="${ERRORS}缺少待执行复选框动作\n"
    fi
    if ! grep -q '命令：' "$PLAN_FILE"; then
        ERRORS="${ERRORS}缺少验证命令\n"
    fi
    if ! grep -q '预期：' "$PLAN_FILE"; then
        ERRORS="${ERRORS}缺少验证预期\n"
    fi
    if ! grep -q '\*\*本轮 review 预期关注面\*\*' "$PLAN_FILE"; then
        ERRORS="${ERRORS}缺少 Step 级别的本轮 review 预期关注面\n"
    fi
    if ! grep -q '\*\*本步关闭条件\*\*' "$PLAN_FILE"; then
        ERRORS="${ERRORS}缺少 Step 级别的本步关闭条件\n"
    fi
    if ! awk '
        /^### 2\.6 高风险路径与缺陷族/ {in_section=1; next}
        /^## / && in_section {exit}
        in_section && /^\| .* \|/ {count++}
        END {exit(count >= 2 ? 0 : 1)}
    ' "$PLAN_FILE"; then
        ERRORS="${ERRORS}2.6 高风险路径与缺陷族缺少有效表格内容\n"
    fi
    if ! awk '
        /^### 4\.4 定向验证矩阵/ {in_section=1; next}
        /^## / && in_section {exit}
        in_section && /^\| .* \|/ {count++}
        END {exit(count >= 2 ? 0 : 1)}
    ' "$PLAN_FILE"; then
        ERRORS="${ERRORS}4.4 定向验证矩阵缺少有效表格内容\n"
    fi
    if ! awk '
        /^### 4\.4 定向验证矩阵/ {in_section=1; next}
        /^## / && in_section {exit}
        in_section && /`[^`]+`/ {found=1}
        END {exit(found ? 0 : 1)}
    ' "$PLAN_FILE"; then
        ERRORS="${ERRORS}4.4 定向验证矩阵缺少确切命令\n"
    fi
    if grep -qE '^\# \[[^]]+\]' "$PLAN_FILE"; then
        ERRORS="${ERRORS}plan 首行不允许再携带状态码\n"
    fi

    PLAN_PLACEHOLDERS=(
        "{需求名称}"
        "{需求简称}"
        "{YYYY-MM-DD}"
        "{需求文档/口头描述/Jira 等}"
        "{一句话说明要交付什么能力}"
        "{简要描述业务背景、目标用户、预期效果}"
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
    DISALLOWED_STATE_SCHEMA_FIELDS=(
        '`requirement_key`:'
        '`status`:'
        '`steps`:'
        '`verification_results`:'
        '`change_register`:'
    )
    for placeholder in "${PLAN_PLACEHOLDERS[@]}"; do
        if grep -Fq "$placeholder" "$PLAN_FILE"; then
            ERRORS="${ERRORS}未替换的模板占位符: $placeholder\n"
        fi
    done
    for field_marker in "${DISALLOWED_STATE_SCHEMA_FIELDS[@]}"; do
        if grep -Fq "$field_marker" "$PLAN_FILE"; then
            ERRORS="${ERRORS}计划中不得为状态文件设计自定义 schema 字段: $field_marker\n"
        fi
    done
    if grep -qE 'TBD|TODO|后续补充|类似上一步|适当处理异常|根据情况处理' "$PLAN_FILE"; then
        ERRORS="${ERRORS}包含不可执行描述或临时标记\n"
    fi
fi

if [ -n "$ERRORS" ]; then
    echo "⚠ 计划结构校验失败："
    echo -e "$ERRORS"
    echo "    计划文件已保留但标记为无效: $PLAN_FILE"
    exit 1
fi
echo "    结构校验通过"

PLAN_TITLE=$(sed -n '1s/^# 实施计划：//p' "$PLAN_FILE")
[ -z "$PLAN_TITLE" ] && PLAN_TITLE="$REQUIREMENT"

echo ">>> 初始化状态文件..."
"$FLOW_STATE_SH" create --slug "$SLUG" --title "$PLAN_TITLE" --plan-file "$PLAN_FILE"

echo ""
echo ">>> 计划已生成: $PLAN_FILE"
