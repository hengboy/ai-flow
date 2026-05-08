#!/bin/bash

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_FLOW_STATE_SCRIPT="$TEST_ROOT/runtime/scripts/flow-state.sh"
SOURCE_FLOW_STATUS_SCRIPT="$TEST_ROOT/runtime/scripts/flow-status.sh"
SOURCE_FLOW_CHANGE_SCRIPT="$TEST_ROOT/runtime/scripts/flow-change.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -q -- "$pattern" "$file" || fail "Expected '$file' to contain '$pattern'"
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    if grep -q -- "$pattern" "$file"; then
        fail "Expected '$file' not to contain '$pattern'"
    fi
}

assert_file_exists() {
    [ -f "$1" ] || fail "Expected file to exist: $1"
}

assert_file_not_exists() {
    [ ! -e "$1" ] || fail "Expected file not to exist: $1"
}

assert_dir_exists() {
    [ -d "$1" ] || fail "Expected directory to exist: $1"
}

assert_equals() {
    [ "$1" = "$2" ] || fail "Expected '$1', got '$2'"
}

assert_protocol_field() {
    local file="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual=$(protocol_field "$file" "$key")
    assert_equals "$expected" "$actual"
}

protocol_field() {
    local file="$1"
    local key="$2"
    sed -n "s/^${key}: //p" "$file" | tail -1
}

make_temp_root() {
    mktemp -d
}

installed_runtime_script() {
    local temp_root="$1"
    local script="$2"
    printf '%s/home/.config/ai-flow/scripts/%s' "$temp_root" "$script"
}

installed_subagent_executor() {
    local temp_root="$1"
    local agent="$2"
    local script="$3"
    printf '%s/home/.claude/agents/%s/bin/%s' "$temp_root" "$agent" "$script"
}

installed_subagent_asset() {
    local temp_root="$1"
    local agent="$2"
    local relative_path="$3"
    printf '%s/home/.claude/agents/%s/%s' "$temp_root" "$agent" "$relative_path"
}

install_ai_flow() {
    local temp_root="$1"
    mkdir -p "$temp_root/home"
    HOME="$temp_root/home" \
        CLAUDE_AGENTS_DIR="$temp_root/home/.claude/agents" \
        OPENCODE_AGENTS_DIR="$temp_root/home/.config/opencode/agents" \
        ONSPACE_SKILLS_DIR="$temp_root/home/.config/onespace/skills/local_state/models/claude" \
        ONSPACE_SUBAGENTS_CLAUDE_DIR="$temp_root/home/.config/onespace/subagents/local_state/models/claude" \
        ONSPACE_SUBAGENTS_OPENCODE_DIR="$temp_root/home/.config/onespace/subagents/local_state/models/opencode" \
        AI_FLOW_HOME="$temp_root/home/.config/ai-flow" \
        bash "$TEST_ROOT/install.sh" >"$temp_root/install.out"
}

setup_project_root() {
    local project_dir="$1"
    mkdir -p "$project_dir/src"
    printf '{ "name": "fixture" }\n' > "$project_dir/package.json"
}

setup_project_dirs() {
    local project_dir="$1"
    local date_dir="${2:-20260503}"
    setup_project_root "$project_dir"
    mkdir -p \
        "$project_dir/.ai-flow/plans/$date_dir" \
        "$project_dir/.ai-flow/reports/$date_dir" \
        "$project_dir/.ai-flow/state/.locks"
}

setup_git_repo_clean() {
    local project_dir="$1"
    (
        cd "$project_dir" || exit 1
        git init -q
        git config user.email test@example.com
        git config user.name Test
        git add .
        git commit -q -m init
    )
}

setup_git_repo_with_change() {
    local project_dir="$1"
    setup_git_repo_clean "$project_dir"
    printf 'changed\n' > "$project_dir/src/review-target.txt"
}

state_field() {
    local project_dir="$1"
    local slug="$2"
    local field="$3"
    python3 - "$project_dir/.ai-flow/state/$slug.json" "$field" <<'PY'
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
    elif isinstance(value, list) and part.isdigit():
        index = int(part)
        value = value[index] if 0 <= index < len(value) else None
    else:
        value = None
        break
if value is None:
    sys.exit(1)
print(value)
PY
}

create_plan_file() {
    local project_dir="$1"
    local slug="$2"
    local date_dir="${3:-20260503}"
    local title="${4:-$slug}"
    local requirement="${5:-测试计划。}"
    local plan_file="$project_dir/.ai-flow/plans/$date_dir/$slug.md"
    cat > "$plan_file" <<PLAN
# 实施计划：$title

> 创建日期：2026-05-03
> 需求简称：$slug
> 需求来源：测试
> 状态文件：\`.ai-flow/state/$slug.json\`
> 文档角色：本文件仅记录实施证据与执行步骤；流程状态以 JSON 状态文件为准。
> 执行约定：使用 \`/ai-flow-plan-coding\` 按 Step 顺序执行；每个 Step 内的动作使用 \`- [ ]\` 复选框追踪进度。

## 1. 需求概述

**目标**：生成测试计划。

**背景**：用于测试 AI Flow 状态机与 review 工作流。

**原始需求（原文）**：
$requirement

**非目标**：无。

## 2. 技术分析

### 2.1 涉及模块

| 模块 | 职责 | 变更类型 |
|------|------|----------|
| \`src/review-target.txt\` | 提供 review 目标文件 | 修改 |

### 2.2 数据模型变更

无。

### 2.3 API 变更

无。

### 2.4 依赖影响

无。

### 2.5 文件边界总览

| 文件 | 操作 | 职责 | 对应步骤 |
|------|------|------|----------|
| \`src/review-target.txt\` | Modify | 提供最小变更面 | Step 1 |

### 2.6 高风险路径与缺陷族

| 高风险能力/路径 | 影响面 | 典型失效模式 | 对应缺陷族 | 必须覆盖的验证方式 |
|----------------|--------|--------------|------------|--------------------|
| review 目标文件写入链路 | review 工作流与报告校验 | 变更未被审查、验证证据缺失 | 测试/证据 | \`bash tests/run.sh\` |

## 3. 实施步骤

### Step 1: 示例

**目标**：生成最小测试上下文

**文件边界**：
- Modify: \`src/review-target.txt\` — 测试输入

**本轮 review 预期关注面**：
- 测试/证据 缺陷族，以及 review-target 变更是否被定向验证覆盖

**执行动作**：
- [ ] **1.1 运行通过验证**
  - 命令：\`bash tests/run.sh\`
  - 预期：PASS

**本步关闭条件**：
- \`bash tests/run.sh\` 通过，且 review 报告能记录定向验证执行证据

## 4. 测试计划

### 4.1 单元测试

- [ ] review 工作流测试夹具生成

### 4.2 集成测试

- [ ] \`bash tests/test_subagent_coding_review.sh\`

### 4.3 回归验证

- [ ] \`bash tests/run.sh\`

### 4.4 定向验证矩阵

| 缺陷族 | 目标风险路径 | 定向验证命令 | 验证类型 | 通过标准 |
|--------|--------------|--------------|----------|----------|
| 测试/证据 | review 工作流验证证据收集 | \`bash tests/test_subagent_coding_review.sh\` | 集成 | 报告包含 1.2 定向验证执行证据 |

## 5. 风险与注意事项

- 无

## 6. 验收标准

- [ ] 通过

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|
| 2026-05-03 00:00 | 无 | 测试夹具 |

## 8. 计划审核记录

### 8.1 当前审核结论

- 审核状态：待审核
- 与原始需求一致性：待审核
- 是否允许进入 \`/ai-flow-plan-coding\`：否
- 当前审核轮次：0
- 审核引擎/模型：待审核

### 8.2 偏差与建议

- 待审核

### 8.3 审核历史

- 第 0 轮：初始化 draft，待审核。
PLAN
}

write_review_report_fixture() {
    local file="$1"
    local slug="$2"
    local plan_file="$3"
    local mode="$4"
    local round="$5"
    local result="$6"
    local title="${7:-$slug}"
    local overall="总体通过"
    local conclusion_pass="- [x] **通过** — 所有步骤已实现，无严重缺陷"
    local conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
    local conclusion_fix="- [ ] **需要修复** — 存在以下问题需要处理"
    local severe_rows=""
    local suggest_rows=""
    local tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |'

    if [ "$result" = "failed" ]; then
        overall="需要修复"
        conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
        conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
        conclusion_fix="- [x] **需要修复** — 存在以下问题需要处理"
        severe_rows='| DEF-1 | Important | src/review-target.txt | problem | impact | fix | [待修复] |'
        tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [待修复] | | |'
    elif [ "$result" = "passed_with_notes" ]; then
        overall="总体通过（附建议）"
        conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
        conclusion_notes="- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
        suggest_rows='| SUG-1 | Minor | src/review-target.txt | suggestion | refine | [可选] |'
        tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| SUG-1 | v1 | [可选] | deferred | noted |'
    fi

    cat > "$file" <<REPORT
# 审查报告：$title

> 审查日期：2026-05-03
> 需求简称：$slug
> 审查模式：$mode
> 审查轮次：$round
> 审查结果：$result
> 对比计划：\`$plan_file\`
> 审查工具：Codex (test xhigh)
> 规则标识：\`review\`、\`fix-review\`、\`verify-before-done\`

## 1. 总体评价

$overall

### 1.1 审查上下文

| 项目 | 内容 |
|------|------|
| Plan 文件 | \`$plan_file\` |
| 变更范围 | staged / unstaged / untracked |
| 上一轮报告 | 无 |
| 验证证据 | 测试夹具 |

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`git diff -- src/review-target.txt\` | PASS | 测试夹具提供的定向验证证据 |

## 2. 计划覆盖度检查

| 实施步骤 | 状态 | 备注 |
|----------|------|------|
| Step 1: 示例 | 已实现 | ok |

**覆盖率**：100%

## 2.1 计划外变更识别

| 变更文件/模块 | 变更内容摘要 | 判定 | 备注 |
|----------|----------|------|------|
| 无 | 无 | 接受 | 无 |

## 3. 代码质量审查

### 3.1 架构与设计

- 合理

### 3.2 规范性

- 合理

### 3.3 安全性

- 无明显问题

### 3.4 性能

- 无明显问题

### 3.5 逻辑正确性

| 检查项 | 审查结果 | 问题描述 |
|--------|----------|----------|
| 边界条件 | 通过 | 已检查 |
| 空值处理 | 通过 | 已检查 |
| 异常路径 | 通过 | 已检查 |
| 数据一致性 | 通过 | 已检查 |
| 类型转换 | 通过 | 已检查 |
| 权限校验 | 通过 | 已检查 |
| 输入校验 | 通过 | 已检查 |
| 副作用 | 通过 | 已检查 |

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | 已检查 report 证据链 |

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|
$severe_rows

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|
$suggest_rows

## 5. 审查结论

$conclusion_pass
$conclusion_notes
$conclusion_fix

## 6. 缺陷修复追踪

$tracking
REPORT
}

create_state_with_status() {
    local flow_state_script="$1"
    local project_dir="$2"
    local slug="$3"
    local target_status="$4"
    local date_dir="${5:-20260503}"
    local title="${6:-$slug}"
    local plan_file=".ai-flow/plans/$date_dir/$slug.md"
    create_plan_file "$project_dir" "$slug" "$date_dir" "$title"
    (
        cd "$project_dir" || exit 1
        bash "$flow_state_script" create --slug "$slug" --title "$title" --plan-file "$plan_file" >/dev/null
        case "$target_status" in
            AWAITING_PLAN_REVIEW)
                ;;
            PLAN_REVIEW_FAILED)
                bash "$flow_state_script" record-plan-review --slug "$slug" --result failed --engine Fixture --model fixture-model >/dev/null
                ;;
            PLANNED)
                bash "$flow_state_script" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                ;;
            IMPLEMENTING)
                bash "$flow_state_script" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$flow_state_script" start-execute "$slug" >/dev/null
                ;;
            AWAITING_REVIEW)
                bash "$flow_state_script" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$flow_state_script" start-execute "$slug" >/dev/null
                bash "$flow_state_script" finish-implementation "$slug" >/dev/null
                ;;
            REVIEW_FAILED)
                bash "$flow_state_script" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$flow_state_script" start-execute "$slug" >/dev/null
                bash "$flow_state_script" finish-implementation "$slug" >/dev/null
                write_review_report_fixture ".ai-flow/reports/$date_dir/${slug}-review.md" "$slug" "$plan_file" "regular" "1" "failed" "$title"
                bash "$flow_state_script" record-review --slug "$slug" --mode regular --result failed --report-file ".ai-flow/reports/$date_dir/${slug}-review.md" >/dev/null
                ;;
            FIXING_REVIEW)
                create_state_with_status "$flow_state_script" "$project_dir" "$slug" "REVIEW_FAILED" "$date_dir" "$title"
                bash "$flow_state_script" start-fix "$slug" >/dev/null
                ;;
            DONE)
                bash "$flow_state_script" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$flow_state_script" start-execute "$slug" >/dev/null
                bash "$flow_state_script" finish-implementation "$slug" >/dev/null
                write_review_report_fixture ".ai-flow/reports/$date_dir/${slug}-review.md" "$slug" "$plan_file" "regular" "1" "passed" "$title"
                bash "$flow_state_script" record-review --slug "$slug" --mode regular --result passed --report-file ".ai-flow/reports/$date_dir/${slug}-review.md" >/dev/null
                ;;
            *)
                fail "Unknown target status: $target_status"
                ;;
        esac
    )
}

write_fake_plan_agents() {
    local temp_root="$1"
    mkdir -p "$temp_root/bin"
    cat > "$temp_root/bin/codex" <<'FAKE_CODEX'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
    cat <<'HELP'
Usage: codex exec [OPTIONS]
      --skip-git-repo-check
HELP
    exit 0
fi
temp_root="${FAKE_PLAN_TEMP_ROOT:?}"
printf 'call\n' >> "$temp_root/codex.plan.calls"
printf '%s\n' "$*" >> "$temp_root/codex.plan.argv"
if [ "${FAKE_PLAN_CODEX_MODE:-success}" = "unavailable" ]; then
    echo "codex unavailable during plan execution" >&2
    exit 127
fi
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    fi
    shift || true
done
prompt_file="$temp_root/codex-plan-prompt-$(date +%s%N).txt"
cat > "$prompt_file"
slug=$(sed -n 's/^> 需求简称：//p' "$prompt_file" | head -1)
[ -n "$slug" ] || slug=demo
extract_requirement() {
    local file="$1"
    local result
    result=$(awk '/^需求描述：/{flag=1;next}/^要求：/{flag=0}flag{print}' "$file")
    if [ -z "$result" ]; then
        result=$(awk '/^原始需求：/{flag=1;next}/^当前 plan：/{flag=0}flag{print}' "$file")
    fi
    printf '%s' "${result:-测试需求}"
}
requirement="$(extract_requirement "$prompt_file")"
guard_note=""
if [ "${FAKE_PLAN_INCLUDE_NEGATIVE_TBD:-0}" = "1" ]; then
    guard_note=$'> 校验说明：计划文件不得包含 `TBD`、`TODO`。\n'
fi
build_plan() {
    cat > "$out" <<PLAN
# 实施计划：$slug

> 创建日期：2026-05-03
> 需求简称：$slug
> 需求来源：测试
> 状态文件：\`.ai-flow/state/$slug.json\`
> 文档角色：本文件仅记录实施证据与执行步骤；流程状态以 JSON 状态文件为准。
$guard_note

## 1. 需求概述

**目标**：实现测试计划。

**背景**：fake codex plan output

**原始需求（原文）**：
$requirement

**非目标**：无。

## 2. 技术分析

### 2.1 涉及模块

| 模块 | 职责 | 变更类型 |
|------|------|----------|
| \`src/review-target.txt\` | fixture | 修改 |

### 2.2 数据模型变更

无。

### 2.3 API 变更

无。

### 2.4 依赖影响

无。

### 2.5 文件边界总览

| 文件 | 操作 | 职责 | 对应步骤 |
|------|------|------|----------|
| \`src/review-target.txt\` | Modify | fixture | Step 1 |

### 2.6 高风险路径与缺陷族

| 高风险能力/路径 | 影响面 | 典型失效模式 | 对应缺陷族 | 必须覆盖的验证方式 |
|----------------|--------|--------------|------------|--------------------|
| fake plan path | plan 状态机 | 结构缺失 | 状态机/流程 | \`bash tests/run.sh\` |

## 3. 实施步骤

### Step 1: fake

**目标**：生成可执行草案

**文件边界**：
- Modify: \`src/review-target.txt\` — fixture

**本轮 review 预期关注面**：
- 状态机/流程

**执行动作**：
- [ ] **1.1 运行通过验证**
  - 命令：\`bash tests/run.sh\`
  - 预期：PASS

**本步关闭条件**：
- \`bash tests/run.sh\` 通过

## 4. 测试计划

### 4.1 单元测试

- [ ] \`bash tests/run.sh\`

### 4.2 集成测试

- [ ] \`bash tests/run.sh\`

### 4.3 回归验证

- [ ] \`bash tests/run.sh\`

### 4.4 定向验证矩阵

| 缺陷族 | 目标风险路径 | 定向验证命令 | 验证类型 | 通过标准 |
|--------|--------------|--------------|----------|----------|
| 状态机/流程 | plan fixture | \`bash tests/run.sh\` | 集成 | 草案生成成功 |

## 5. 风险与注意事项

- 无

## 6. 验收标准

- [ ] 通过

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|
| 2026-05-03 00:00 | 无 | fake codex |

## 8. 计划审核记录

### 8.1 当前审核结论

- 审核状态：待审核
- 与原始需求一致性：待审核
- 是否允许进入 \`/ai-flow-plan-coding\`：否
- 当前审核轮次：0
- 审核引擎/模型：待审核

### 8.2 偏差与建议

- 待审核

### 8.3 审核历史

- 第 0 轮：初始化 draft，待审核。
PLAN
}
build_plan_review() {
    case "${FAKE_PLAN_REVIEW_RESULT:-passed}" in
        passed)
            cat > "$out" <<'REVIEW'
RESULT: passed
ALIGNMENT: 与原始需求一致
EXECUTE_READY: yes
SUMMARY: 审核通过
ITEMS:
- 无
REVIEW
            ;;
        passed_with_notes)
            cat > "$out" <<'REVIEW'
RESULT: passed_with_notes
ALIGNMENT: 基本一致但有可选建议
EXECUTE_READY: yes
SUMMARY: 审核通过但建议补充说明
ITEMS:
- [可选][Minor] 建议补充一条背景说明
REVIEW
            ;;
        failed)
            cat > "$out" <<'REVIEW'
RESULT: failed
ALIGNMENT: 存在阻断偏差
EXECUTE_READY: no
SUMMARY: 缺少必要验证闭环
ITEMS:
- [待修订][Important] 缺少必要验证闭环
REVIEW
            ;;
    esac
}
if grep -q '只允许输出以下固定格式' "$prompt_file"; then
    build_plan_review
else
    build_plan
fi
FAKE_CODEX
    chmod +x "$temp_root/bin/codex"

    cat > "$temp_root/bin/opencode" <<'FAKE_OPENCODE'
#!/bin/bash
set -euo pipefail
temp_root="${FAKE_PLAN_TEMP_ROOT:?}"
printf 'call\n' >> "$temp_root/opencode.plan.calls"
printf '%s\n' "$*" >> "$temp_root/opencode.plan.argv"
prompt="${*: -1}"
prompt_file="$temp_root/opencode-plan-prompt-$(date +%s%N).txt"
printf '%s' "$prompt" > "$prompt_file"
slug=$(sed -n 's/^> 需求简称：//p' "$prompt_file" | head -1)
[ -n "$slug" ] || slug=demo
extract_requirement() {
    local file="$1"
    local result
    result=$(awk '/^需求描述：/{flag=1;next}/^要求：/{flag=0}flag{print}' "$file")
    if [ -z "$result" ]; then
        result=$(awk '/^原始需求：/{flag=1;next}/^当前 plan：/{flag=0}flag{print}' "$file")
    fi
    printf '%s' "${result:-测试需求}"
}
requirement="$(extract_requirement "$prompt_file")"
if grep -q '只允许输出以下固定格式' "$prompt_file"; then
    case "${FAKE_PLAN_REVIEW_RESULT:-passed}" in
        passed)
            cat <<'REVIEW'
RESULT: passed
ALIGNMENT: 与原始需求一致
EXECUTE_READY: yes
SUMMARY: 审核通过
ITEMS:
- 无
REVIEW
            ;;
        passed_with_notes)
            cat <<'REVIEW'
RESULT: passed_with_notes
ALIGNMENT: 基本一致但有可选建议
EXECUTE_READY: yes
SUMMARY: 审核通过但建议补充说明
ITEMS:
- [可选][Minor] 建议补充一条背景说明
REVIEW
            ;;
        failed)
            cat <<'REVIEW'
RESULT: failed
ALIGNMENT: 存在阻断偏差
EXECUTE_READY: no
SUMMARY: 缺少必要验证闭环
ITEMS:
- [待修订][Important] 缺少必要验证闭环
REVIEW
            ;;
    esac
else
    cat <<PLAN
# 实施计划：$slug

> 创建日期：2026-05-03
> 需求简称：$slug
> 需求来源：测试
> 状态文件：\`.ai-flow/state/$slug.json\`
> 文档角色：本文件仅记录实施证据与执行步骤；流程状态以 JSON 状态文件为准。

## 1. 需求概述

**目标**：实现测试计划。

**背景**：fake opencode plan output

**原始需求（原文）**：
$requirement

**非目标**：无。

## 2. 技术分析

### 2.1 涉及模块

| 模块 | 职责 | 变更类型 |
|------|------|----------|
| \`src/review-target.txt\` | fixture | 修改 |

### 2.2 数据模型变更

无。

### 2.3 API 变更

无。

### 2.4 依赖影响

无。

### 2.5 文件边界总览

| 文件 | 操作 | 职责 | 对应步骤 |
|------|------|------|----------|
| \`src/review-target.txt\` | Modify | fixture | Step 1 |

### 2.6 高风险路径与缺陷族

| 高风险能力/路径 | 影响面 | 典型失效模式 | 对应缺陷族 | 必须覆盖的验证方式 |
|----------------|--------|--------------|------------|--------------------|
| fake plan path | plan 状态机 | 结构缺失 | 状态机/流程 | \`bash tests/run.sh\` |

## 3. 实施步骤

### Step 1: fake

**目标**：生成可执行草案

**文件边界**：
- Modify: \`src/review-target.txt\` — fixture

**本轮 review 预期关注面**：
- 状态机/流程

**执行动作**：
- [ ] **1.1 运行通过验证**
  - 命令：\`bash tests/run.sh\`
  - 预期：PASS

**本步关闭条件**：
- \`bash tests/run.sh\` 通过

## 4. 测试计划

### 4.1 单元测试

- [ ] \`bash tests/run.sh\`

### 4.2 集成测试

- [ ] \`bash tests/run.sh\`

### 4.3 回归验证

- [ ] \`bash tests/run.sh\`

### 4.4 定向验证矩阵

| 缺陷族 | 目标风险路径 | 定向验证命令 | 验证类型 | 通过标准 |
|--------|--------------|--------------|----------|----------|
| 状态机/流程 | plan fixture | \`bash tests/run.sh\` | 集成 | 草案生成成功 |

## 5. 风险与注意事项

- 无

## 6. 验收标准

- [ ] 通过

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|
| 2026-05-03 00:00 | 无 | fake opencode |

## 8. 计划审核记录

### 8.1 当前审核结论

- 审核状态：待审核
- 与原始需求一致性：待审核
- 是否允许进入 \`/ai-flow-plan-coding\`：否
- 当前审核轮次：0
- 审核引擎/模型：待审核

### 8.2 偏差与建议

- 待审核

### 8.3 审核历史

- 第 0 轮：初始化 draft，待审核。
PLAN
fi
FAKE_OPENCODE
    chmod +x "$temp_root/bin/opencode"
}

run_with_fake_plan_agents() {
    local temp_root="$1"
    shift
    PATH="$temp_root/bin:$PATH" \
        HOME="$temp_root/home" \
        AI_FLOW_HOME="${AI_FLOW_HOME:-$temp_root/home/.config/ai-flow}" \
        FAKE_PLAN_TEMP_ROOT="$temp_root" \
        "$@"
}

write_fake_coding_review_agents() {
    local temp_root="$1"
    mkdir -p "$temp_root/bin"
    cat > "$temp_root/bin/codex" <<'FAKE_CODEX'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
    cat <<'HELP'
Usage: codex exec [OPTIONS]
      --skip-git-repo-check
HELP
    exit 0
fi
temp_root="${FAKE_REVIEW_TEMP_ROOT:?}"
printf 'call\n' >> "$temp_root/codex.review.calls"
printf '%s\n' "$*" >> "$temp_root/codex.review.argv"
if [ "${FAKE_REVIEW_CODEX_MODE:-success}" = "unavailable" ]; then
    echo "codex unavailable during review" >&2
    exit 127
fi
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    fi
    shift || true
done
prompt_file="$temp_root/codex-review-prompt-$(date +%s%N).txt"
cat > "$prompt_file"
title=$(sed -n 's/^# 审查报告：//p' "$prompt_file" | tail -1)
[ -n "$title" ] || title=demo
slug=$(sed -n 's/^> 需求简称：//p' "$prompt_file" | tail -1)
[ -n "$slug" ] || slug=demo
mode=$(sed -n 's/^> 审查模式：//p' "$prompt_file" | tail -1)
[ -n "$mode" ] || mode=regular
round=$(sed -n 's/^> 审查轮次：//p' "$prompt_file" | tail -1)
[ -n "$round" ] || round=1
plan_file=$(sed -n 's/^> 对比计划：`//p' "$prompt_file" | tail -1 | sed 's/`$//')
[ -n "$plan_file" ] || plan_file=.ai-flow/plans/20260503/demo.md
result="${FAKE_CODE_REVIEW_RESULT:-passed}"
overall="总体通过"
conclusion_pass="- [x] **通过** — 所有步骤已实现，无严重缺陷"
conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
conclusion_fix="- [ ] **需要修复** — 存在以下问题需要处理"
severe_rows=""
suggest_rows=""
tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |'
tracking_note=""
if [ "${FAKE_REVIEW_INCLUDE_STATUS_NOTE:-0}" = "1" ]; then
    tracking_note=$'> 每轮修复后，在此更新对应缺陷的状态。阻塞缺陷未修复时标记为 `[待修复]`，Minor 未处理时标记为 `[可选]`，已修复项标记为 `[已修复]`。\n'
fi
if [ "$result" = "failed" ]; then
    overall="需要修复"
    conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
    conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
    conclusion_fix="- [x] **需要修复** — 存在以下问题需要处理"
    severe_rows='| DEF-1 | Important | src/review-target.txt | problem | impact | fix | [待修复] |'
    tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [待修复] | | |'
elif [ "$result" = "passed_with_notes" ]; then
    overall="总体通过（附建议）"
    conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
    conclusion_notes="- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
    suggest_rows='| SUG-1 | Minor | src/review-target.txt | suggestion | refine | [可选] |'
    tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| SUG-1 | v1 | [可选] | deferred | noted |'
fi
cat > "$out" <<REPORT
# 审查报告：$title

> 审查日期：2026-05-03
> 需求简称：$slug
> 审查模式：$mode
> 审查轮次：$round
> 审查结果：$result
> 对比计划：\`$plan_file\`
> 审查工具：Codex (test xhigh)
> 规则标识：\`review\`、\`fix-review\`、\`verify-before-done\`

## 1. 总体评价

$overall

### 1.1 审查上下文

| 项目 | 内容 |
|------|------|
| Plan 文件 | \`$plan_file\` |
| 变更范围 | staged / unstaged / untracked |
| 上一轮报告 | 无 |
| 验证证据 | fake review fixture |

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`git diff -- src/review-target.txt\` | PASS | fake review fixture |

## 2. 计划覆盖度检查

| 实施步骤 | 状态 | 备注 |
|----------|------|------|
| Step 1: 示例 | 已实现 | ok |

**覆盖率**：100%

## 2.1 计划外变更识别

| 变更文件/模块 | 变更内容摘要 | 判定 | 备注 |
|----------|----------|------|------|
| 无 | 无 | 接受 | 无 |

## 3. 代码质量审查

### 3.1 架构与设计

- 合理

### 3.2 规范性

- 合理

### 3.3 安全性

- 无明显问题

### 3.4 性能

- 无明显问题

### 3.5 逻辑正确性

| 检查项 | 审查结果 | 问题描述 |
|--------|----------|----------|
| 边界条件 | 通过 | 已检查 |
| 空值处理 | 通过 | 已检查 |
| 异常路径 | 通过 | 已检查 |
| 数据一致性 | 通过 | 已检查 |
| 类型转换 | 通过 | 已检查 |
| 权限校验 | 通过 | 已检查 |
| 输入校验 | 通过 | 已检查 |
| 副作用 | 通过 | 已检查 |

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | fake review fixture |

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|
$severe_rows

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|
$suggest_rows

## 5. 审查结论

$conclusion_pass
$conclusion_notes
$conclusion_fix

## 6. 缺陷修复追踪

$tracking_note
$tracking
REPORT
FAKE_CODEX
    chmod +x "$temp_root/bin/codex"

    cat > "$temp_root/bin/opencode" <<'FAKE_OPENCODE'
#!/bin/bash
set -euo pipefail
temp_root="${FAKE_REVIEW_TEMP_ROOT:?}"
printf 'call\n' >> "$temp_root/opencode.review.calls"
printf '%s\n' "$*" >> "$temp_root/opencode.review.argv"
prompt="${*: -1}"
prompt_file="$temp_root/opencode-review-prompt-$(date +%s%N).txt"
printf '%s' "$prompt" > "$prompt_file"
title=$(sed -n 's/^# 审查报告：//p' "$prompt_file" | tail -1)
[ -n "$title" ] || title=demo
slug=$(sed -n 's/^> 需求简称：//p' "$prompt_file" | tail -1)
[ -n "$slug" ] || slug=demo
mode=$(sed -n 's/^> 审查模式：//p' "$prompt_file" | tail -1)
[ -n "$mode" ] || mode=regular
round=$(sed -n 's/^> 审查轮次：//p' "$prompt_file" | tail -1)
[ -n "$round" ] || round=1
plan_file=$(sed -n 's/^> 对比计划：`//p' "$prompt_file" | tail -1 | sed 's/`$//')
[ -n "$plan_file" ] || plan_file=.ai-flow/plans/20260503/demo.md
result="${FAKE_CODE_REVIEW_RESULT:-passed}"
overall="总体通过"
conclusion_pass="- [x] **通过** — 所有步骤已实现，无严重缺陷"
conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
conclusion_fix="- [ ] **需要修复** — 存在以下问题需要处理"
severe_rows=""
suggest_rows=""
tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |'
tracking_note=""
if [ "${FAKE_REVIEW_INCLUDE_STATUS_NOTE:-0}" = "1" ]; then
    tracking_note=$'> 每轮修复后，在此更新对应缺陷的状态。阻塞缺陷未修复时标记为 `[待修复]`，Minor 未处理时标记为 `[可选]`，已修复项标记为 `[已修复]`。\n'
fi
if [ "$result" = "failed" ]; then
    overall="需要修复"
    conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
    conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
    conclusion_fix="- [x] **需要修复** — 存在以下问题需要处理"
    severe_rows='| DEF-1 | Important | src/review-target.txt | problem | impact | fix | [待修复] |'
    tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [待修复] | | |'
elif [ "$result" = "passed_with_notes" ]; then
    overall="总体通过（附建议）"
    conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
    conclusion_notes="- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
    suggest_rows='| SUG-1 | Minor | src/review-target.txt | suggestion | refine | [可选] |'
    tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| SUG-1 | v1 | [可选] | deferred | noted |'
fi
cat <<REPORT
# 审查报告：$title

> 审查日期：2026-05-03
> 需求简称：$slug
> 审查模式：$mode
> 审查轮次：$round
> 审查结果：$result
> 对比计划：\`$plan_file\`
> 审查工具：OpenCode (zhipuai-coding-plan/glm-5.1 max)
> 规则标识：\`review\`、\`fix-review\`、\`verify-before-done\`

## 1. 总体评价

$overall

### 1.1 审查上下文

| 项目 | 内容 |
|------|------|
| Plan 文件 | \`$plan_file\` |
| 变更范围 | staged / unstaged / untracked |
| 上一轮报告 | 无 |
| 验证证据 | fake review fixture |

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`git diff -- src/review-target.txt\` | PASS | fake review fixture |

## 2. 计划覆盖度检查

| 实施步骤 | 状态 | 备注 |
|----------|------|------|
| Step 1: 示例 | 已实现 | ok |

**覆盖率**：100%

## 2.1 计划外变更识别

| 变更文件/模块 | 变更内容摘要 | 判定 | 备注 |
|----------|----------|------|------|
| 无 | 无 | 接受 | 无 |

## 3. 代码质量审查

### 3.1 架构与设计

- 合理

### 3.2 规范性

- 合理

### 3.3 安全性

- 无明显问题

### 3.4 性能

- 无明显问题

### 3.5 逻辑正确性

| 检查项 | 审查结果 | 问题描述 |
|--------|----------|----------|
| 边界条件 | 通过 | 已检查 |
| 空值处理 | 通过 | 已检查 |
| 异常路径 | 通过 | 已检查 |
| 数据一致性 | 通过 | 已检查 |
| 类型转换 | 通过 | 已检查 |
| 权限校验 | 通过 | 已检查 |
| 输入校验 | 通过 | 已检查 |
| 副作用 | 通过 | 已检查 |

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | fake review fixture |

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|
$severe_rows

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|
$suggest_rows

## 5. 审查结论

$conclusion_pass
$conclusion_notes
$conclusion_fix

## 6. 缺陷修复追踪

$tracking_note
$tracking
REPORT
FAKE_OPENCODE
    chmod +x "$temp_root/bin/opencode"
}

run_with_fake_coding_review_agents() {
    local temp_root="$1"
    shift
    PATH="$temp_root/bin:$PATH" \
        HOME="$temp_root/home" \
        AI_FLOW_HOME="${AI_FLOW_HOME:-$temp_root/home/.config/ai-flow}" \
        FAKE_REVIEW_TEMP_ROOT="$temp_root" \
        "$@"
}

# ─── Workspace fixture helpers ───

setup_workspace_root() {
    local workspace_root="$1"
    local workspace_name="${2:-workspace-test}"
    local date_dir="${3:-20260503}"
    mkdir -p "$workspace_root/.ai-flow/state/.locks" \
             "$workspace_root/.ai-flow/plans/$date_dir" \
             "$workspace_root/.ai-flow/reports/$date_dir"

    cat > "$workspace_root/.ai-flow/workspace.json" <<WS
{
  "schema_version": 1,
  "name": "$workspace_name",
  "repos": [
    { "id": "repo-alpha", "path": "repo-alpha" },
    { "id": "repo-beta", "path": "repo-beta" }
  ]
}
WS
}

setup_workspace_git_repos() {
    local workspace_root="$1"
    local repo
    for repo in repo-alpha repo-beta; do
        mkdir -p "$workspace_root/$repo/src"
        printf '{ "name": "%s" }\n' "$repo" > "$workspace_root/$repo/package.json"
        (
            cd "$workspace_root/$repo" || exit 1
            git init -q
            git config user.email test@example.com
            git config user.name Test
            git add .
            git commit -q -m "init $repo"
        )
    done
}

setup_workspace_repo_change() {
    local workspace_root="$1"
    local repo="${2:-repo-alpha}"
    local change_file="${3:-src/workspace-changed.txt}"
    printf 'changed in workspace\n' > "$workspace_root/$repo/$change_file"
}

create_workspace_state_fixture() {
    local flow_state_script="$1"
    local workspace_root="$2"
    local slug="$3"
    local target_status="$4"
    local date_dir="${5:-20260503}"
    local title="${6:-$slug}"
    local plan_file=".ai-flow/plans/$date_dir/$slug.md"
    create_plan_file "$workspace_root" "$slug" "$date_dir" "$title"

    (
        cd "$workspace_root" || exit 1
        bash "$flow_state_script" create --slug "$slug" --title "$title" --plan-file "$plan_file" \
            --scope-mode workspace --workspace-file .ai-flow/workspace.json >/dev/null
        case "$target_status" in
            AWAITING_PLAN_REVIEW) ;;
            PLANNED)
                bash "$flow_state_script" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                ;;
            AWAITING_REVIEW)
                bash "$flow_state_script" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$flow_state_script" start-execute "$slug" >/dev/null
                bash "$flow_state_script" finish-implementation "$slug" >/dev/null
                ;;
            DONE)
                bash "$flow_state_script" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$flow_state_script" start-execute "$slug" >/dev/null
                bash "$flow_state_script" finish-implementation "$slug" >/dev/null
                write_review_report_fixture ".ai-flow/reports/$date_dir/${slug}-review.md" "$slug" "$plan_file" "regular" "1" "passed" "$title"
                bash "$flow_state_script" record-review --slug "$slug" --mode regular --result passed --report-file ".ai-flow/reports/$date_dir/${slug}-review.md" >/dev/null
                ;;
            *)
                fail "Unknown target status for workspace fixture: $target_status"
                ;;
        esac
    )
}
