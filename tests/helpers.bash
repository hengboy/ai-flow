#!/bin/bash

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    local file="$1"
    [ -f "$file" ] || fail "Expected file to exist: $file"
}

assert_file_not_exists() {
    local file="$1"
    [ ! -e "$file" ] || fail "Expected file not to exist: $file"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    [ "$expected" = "$actual" ] || fail "Expected '$expected', got '$actual'"
}

make_temp_root() {
    mktemp -d
}

setup_home_with_templates() {
    local temp_root="$1"
    mkdir -p "$temp_root/home/.claude/templates"
    cp "$TEST_ROOT/templates/review-template.md" "$temp_root/home/.claude/templates/review-template.md"
    cp "$TEST_ROOT/templates/plan-template.md" "$temp_root/home/.claude/templates/plan-template.md"
}

setup_project_dirs() {
    local project_dir="$1"
    local date_dir="${2:-20260503}"
    mkdir -p \
        "$project_dir/.ai-flow/plans/$date_dir" \
        "$project_dir/.ai-flow/reports/$date_dir" \
        "$project_dir/.ai-flow/state/.locks" \
        "$project_dir/src"
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
    mkdir -p "$project_dir/src"
    printf 'changed\n' > "$project_dir/src/review-target.txt"
}

create_plan_file() {
    local project_dir="$1"
    local slug="$2"
    local date_dir="${3:-20260503}"
    local title="${4:-$slug}"
    local plan_file="$project_dir/.ai-flow/plans/$date_dir/$slug.md"
    cat > "$plan_file" <<PLAN
# 实施计划：$title

> 创建日期：2026-05-03
> 需求简称：$slug
> 需求来源：测试
> 状态文件：\`.ai-flow/state/$slug.json\`
> 文档角色：本文件仅记录实施证据与执行步骤；流程状态以 JSON 状态文件为准。

## 1. 需求概述

测试计划。

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
| review 目标文件写入链路 | review 工作流与报告校验 | 变更未被审查、验证证据缺失 | 测试/证据 | \`bash tests/run.sh\`、人工核对报告 |

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

- [ ] \`bash tests/test_review_workflow.sh\`

### 4.3 回归验证

- [ ] \`bash tests/run.sh\`

### 4.4 定向验证矩阵

| 缺陷族 | 目标风险路径 | 定向验证命令 | 验证类型 | 通过标准 |
|--------|--------------|--------------|----------|----------|
| 测试/证据 | review 工作流验证证据收集 | \`bash tests/test_review_workflow.sh\` | 集成 | 报告包含 1.2 定向验证执行证据 |

## 5. 风险与注意事项

- 无

## 6. 验收标准

- [ ] 通过

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|
| {YYYY-MM-DD HH:MM} | {执行过程中新增或调整的需求；无则保留空表} | {用户确认/文档同步/其他} |
PLAN
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
    else:
        value = None
        break
if value is None:
    sys.exit(1)
print(value)
PY
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
    local conclusion_fail="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
    local conclusion_fix="- [ ] **需要修复** — 存在以下问题需要处理"
    local defects="无"
    local tracking="无"

    if [ "$result" = "failed" ]; then
        overall="需要修复"
        conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
        conclusion_fix="- [x] **需要修复** — 存在以下问题需要处理"
        defects='| DEF-1 | Critical | src/review-target.txt | problem | impact | fix | [待修复] |'
        tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [待修复] | | |'
    else
        tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |'
    fi

    cat > "$file" <<REPORT
# 审查报告：$title

> 审查日期：2026-05-03
> 需求简称：$slug
> 审查模式：$mode
> 审查轮次：$round
> 审查结果：$result
> 对比计划：\$plan_file
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
| \`bash tests/test_review_workflow.sh\` | PASS | 测试夹具提供的定向验证证据 |

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
$defects

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|

## 5. 审查结论

$conclusion_pass
$conclusion_fix

## 6. 缺陷修复追踪

$tracking
REPORT
}

create_state() {
    local project_dir="$1"
    local slug="$2"
    local target_status="$3"
    local date_dir="${4:-20260503}"
    local title="${5:-$slug}"
    local plan_file=".ai-flow/plans/$date_dir/$slug.md"
    create_plan_file "$project_dir" "$slug" "$date_dir" "$title"
    (
        cd "$project_dir" || exit 1
        bash "$TEST_ROOT/workflows/flow-state.sh" create --slug "$slug" --title "$title" --plan-file "$plan_file" >/dev/null
        case "$target_status" in
            PLANNED)
                ;;
            IMPLEMENTING)
                bash "$TEST_ROOT/workflows/flow-state.sh" start-execute "$slug" >/dev/null
                ;;
            AWAITING_REVIEW)
                bash "$TEST_ROOT/workflows/flow-state.sh" start-execute "$slug" >/dev/null
                bash "$TEST_ROOT/workflows/flow-state.sh" finish-implementation "$slug" >/dev/null
                ;;
            REVIEW_FAILED)
                bash "$TEST_ROOT/workflows/flow-state.sh" start-execute "$slug" >/dev/null
                bash "$TEST_ROOT/workflows/flow-state.sh" finish-implementation "$slug" >/dev/null
                write_review_report_fixture ".ai-flow/reports/$date_dir/${slug}-review.md" "$slug" "$plan_file" "regular" "1" "failed" "$title"
                bash "$TEST_ROOT/workflows/flow-state.sh" record-review --slug "$slug" --mode regular --result failed --report-file ".ai-flow/reports/$date_dir/${slug}-review.md" >/dev/null
                ;;
            FIXING_REVIEW)
                bash "$TEST_ROOT/workflows/flow-state.sh" start-execute "$slug" >/dev/null
                bash "$TEST_ROOT/workflows/flow-state.sh" finish-implementation "$slug" >/dev/null
                write_review_report_fixture ".ai-flow/reports/$date_dir/${slug}-review.md" "$slug" "$plan_file" "regular" "1" "failed" "$title"
                bash "$TEST_ROOT/workflows/flow-state.sh" record-review --slug "$slug" --mode regular --result failed --report-file ".ai-flow/reports/$date_dir/${slug}-review.md" >/dev/null
                bash "$TEST_ROOT/workflows/flow-state.sh" start-fix "$slug" >/dev/null
                ;;
            DONE)
                bash "$TEST_ROOT/workflows/flow-state.sh" start-execute "$slug" >/dev/null
                bash "$TEST_ROOT/workflows/flow-state.sh" finish-implementation "$slug" >/dev/null
                write_review_report_fixture ".ai-flow/reports/$date_dir/${slug}-review.md" "$slug" "$plan_file" "regular" "1" "passed" "$title"
                bash "$TEST_ROOT/workflows/flow-state.sh" record-review --slug "$slug" --mode regular --result passed --report-file ".ai-flow/reports/$date_dir/${slug}-review.md" >/dev/null
                ;;
            *)
                echo "Unknown target status: $target_status" >&2
                exit 1
                ;;
        esac
    )
}

write_fake_codex_plan() {
    local temp_root="$1"
    local body_mode="${2:-valid}"
    mkdir -p "$temp_root/bin"
    cat > "$temp_root/bin/codex" <<FAKE_CODEX
#!/bin/bash
out=""
printf "%s\n" "\$*" > "$temp_root/codex.args"
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "-o" ]; then
        shift
        out="\$1"
    fi
    shift || true
done
cat > "$temp_root/captured-plan-prompt.txt"
case "$body_mode" in
    missing_risk_families)
        cat > "\$out" <<'PLAN'
# 实施计划：fake

> 创建日期：2026-05-03
> 需求简称：fake
> 需求来源：测试
> 状态文件：\`.ai-flow/state/fake.json\`
> 文档角色：本文件仅记录实施证据与执行步骤；流程状态以 JSON 状态文件为准。

## 1. 需求概述

**目标**：验证缺陷族章节校验。

## 2. 技术分析

### 2.1 涉及模块

| 模块 | 职责 | 变更类型 |
|------|------|----------|
| workflows/codex-plan.sh | 校验 plan | 修改 |

## 3. 实施步骤

### Step 1: fake

**目标**：验证 plan 校验。

**文件边界**：
- Modify: \`workflows/codex-plan.sh\` — 补充校验

**本轮 review 预期关注面**：
- 测试/证据

**执行动作**：
- [ ] **1.1 验证**
  - 命令：bash tests/run.sh
  - 预期：PASS

**本步关闭条件**：
- \`bash tests/run.sh\` 通过

## 4. 测试计划

### 4.4 定向验证矩阵

| 缺陷族 | 目标风险路径 | 定向验证命令 | 验证类型 | 通过标准 |
|--------|--------------|--------------|----------|----------|
| 测试/证据 | plan 校验 | \`bash tests/run.sh\` | 集成 | 通过 |

## 5. 风险与注意事项

无

## 6. 验收标准

- [ ] 通过
PLAN
        ;;
    missing_validation_matrix)
        cat > "\$out" <<'PLAN'
# 实施计划：fake

> 创建日期：2026-05-03
> 需求简称：fake
> 需求来源：测试
> 状态文件：\`.ai-flow/state/fake.json\`
> 文档角色：本文件仅记录实施证据与执行步骤；流程状态以 JSON 状态文件为准。

## 1. 需求概述

**目标**：验证定向验证矩阵校验。

## 2. 技术分析

### 2.6 高风险路径与缺陷族

| 高风险能力/路径 | 影响面 | 典型失效模式 | 对应缺陷族 | 必须覆盖的验证方式 |
|----------------|--------|--------------|------------|--------------------|
| plan 校验链路 | plan 生成 | 章节遗漏 | 测试/证据 | \`bash tests/run.sh\` |

## 3. 实施步骤

### Step 1: fake

**目标**：验证 plan 校验。

**文件边界**：
- Modify: \`workflows/codex-plan.sh\` — 补充校验

**本轮 review 预期关注面**：
- 测试/证据

**执行动作**：
- [ ] **1.1 验证**
  - 命令：bash tests/run.sh
  - 预期：PASS

**本步关闭条件**：
- \`bash tests/run.sh\` 通过

## 4. 测试计划

### 4.1 单元测试

- [ ] bash tests/run.sh

## 5. 风险与注意事项

无

## 6. 验收标准

- [ ] 通过
PLAN
        ;;
    placeholder)
        cat > "\$out" <<'PLAN'
# 实施计划：fake

## 1. 需求概述

**目标**：{一句话说明要交付什么能力}

## 2. 技术分析

无

## 3. 实施步骤

### Step 1: fake

**执行动作**：
- [ ] **1.1 验证**
  - 命令：bash tests/run.sh
  - 预期：PASS

## 4. 测试计划

- [ ] bash tests/run.sh

## 5. 风险与注意事项

无

## 6. 验收标准

- [ ] 通过
PLAN
        ;;
    custom_state_schema)
        cat > "\$out" <<'PLAN'
# 实施计划：fake

> 创建日期：2026-05-03
> 需求简称：fake
> 需求来源：测试
> 状态文件：\`.ai-flow/state/fake.json\`
> 文档角色：本文件仅记录实施证据与执行步骤；流程状态以 JSON 状态文件为准。

## 1. 需求概述

**目标**：生成错误状态 schema 示例。

## 2. 技术分析

无。

## 3. 实施步骤

### Step 1: 错误示例

**执行动作**：
- [ ] **1.1 写入状态文件结构**
  - 文件：\`.ai-flow/state/fake.json\`
  - 内容结构：
    - \`requirement_key\`: \`fake\`
    - \`status\`: \`in_progress\`
    - \`steps\`: 记录步骤状态
    - \`verification_results\`: 记录验证结果
    - \`change_register\`: 记录变更登记

- [ ] **1.2 运行通过验证**
  - 命令：bash tests/run.sh
  - 预期：PASS

## 4. 测试计划

- [ ] bash tests/run.sh

## 5. 风险与注意事项

- 无

## 6. 验收标准

- [ ] 通过
PLAN
        ;;
    missing_steps)
        cat > "\$out" <<'PLAN'
# 实施计划：fake

## 1. 需求概述

ok

## 2. 技术分析

ok

## 4. 测试计划

ok

## 5. 风险与注意事项

ok

## 6. 验收标准

ok
PLAN
        ;;
    *)
        cat > "\$out" <<'PLAN'
# 实施计划：fake

> 创建日期：2026-05-03
> 需求简称：fake
> 需求来源：测试
> 状态文件：\`.ai-flow/state/fake.json\`
> 文档角色：本文件仅记录实施证据与执行步骤；流程状态以 JSON 状态文件为准。

## 1. 需求概述

**目标**：生成可执行计划。

## 2. 技术分析

无数据模型和 API 变更。

### 2.6 高风险路径与缺陷族

| 高风险能力/路径 | 影响面 | 典型失效模式 | 对应缺陷族 | 必须覆盖的验证方式 |
|----------------|--------|--------------|------------|--------------------|
| plan 校验链路 | 计划生成与后续执行 | 缺少章节、验证缺口、状态设计越界 | 测试/证据 | \`bash tests/run.sh\`、\`bash tests/test_plan_workflow.sh\` |

## 3. 实施步骤

### Step 1: 建立验证

**目标**：验证计划结构。

**文件边界**：
- Test: tests/run.sh - 回归验证

**本轮 review 预期关注面**：
- 测试/证据缺陷族，以及 plan 结构校验是否覆盖 2.6 / 4.4 / Step 关闭条件

**执行动作**：
- [ ] **1.1 写失败用例**
  - 文件：tests/run.sh
  - 场景：运行测试
  - 预期：当前实现下失败，失败原因是 missing behavior

- [ ] **1.2 运行失败验证**
  - 命令：bash tests/run.sh
  - 预期：FAIL，错误信息包含 missing behavior

- [ ] **1.3 实现最小改动**
  - 文件：workflows/codex-plan.sh
  - 改动：补充验证
  - 约束：保持 Bash 兼容

- [ ] **1.4 运行通过验证**
  - 命令：bash tests/run.sh
  - 预期：PASS

- [ ] **1.5 本步自检**
  - 命令：git diff -- workflows/codex-plan.sh tests
  - 确认：无计划外文件

**本步验收**：
- [ ] 计划结构有效

**本步关闭条件**：
- \`bash tests/run.sh\` 通过，且 4.4 定向验证矩阵中的命令都可追踪到具体验证目的

**阻塞条件**：
- 如果测试脚本不可运行，停止执行并确认。

## 4. 测试计划

### 4.1 单元测试

- [ ] \`bash tests/test_plan_workflow.sh\`

### 4.2 集成测试

- [ ] \`bash tests/run.sh\`

### 4.3 回归验证

- [ ] \`bash tests/run.sh\`

### 4.4 定向验证矩阵

| 缺陷族 | 目标风险路径 | 定向验证命令 | 验证类型 | 通过标准 |
|--------|--------------|--------------|----------|----------|
| 测试/证据 | plan 结构校验 | \`bash tests/test_plan_workflow.sh\` | 集成 | 缺少 2.6 / 4.4 / Step 关闭条件时失败 |
| 测试/证据 | 总体回归 | \`bash tests/run.sh\` | 回归 | 全部工作流测试通过 |

## 5. 风险与注意事项

- 保持脚本兼容 macOS Bash。

## 6. 验收标准

- [ ] bash tests/run.sh 通过

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|
PLAN
        ;;
esac
FAKE_CODEX
    chmod +x "$temp_root/bin/codex"
}

write_fake_codex_review() {
    local temp_root="$1"
    local result="${2:-passed}"
    local body_mode="${3:-valid}"
    mkdir -p "$temp_root/bin"
    cat > "$temp_root/bin/codex" <<FAKE_CODEX
#!/bin/bash
if [ "\$1" = "exec" ] && [ "\$2" = "--help" ]; then
    echo "Usage: codex exec [OPTIONS]"
    exit 0
fi
out=""
printf "%s\n" "\$*" > "$temp_root/codex.args"
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "-o" ]; then
        shift
        out="\$1"
    fi
    shift || true
done
cat > "$temp_root/captured-prompt.txt"
title=\$(sed -n 's/^# 审查报告：//p' "$temp_root/captured-prompt.txt" | tail -1)
[ -z "\$title" ] && title=test
slug=\$(sed -n 's/^> 需求简称：//p' "$temp_root/captured-prompt.txt" | tail -1)
[ -z "\$slug" ] && slug=demo
mode=\$(sed -n 's/^> 审查模式：//p' "$temp_root/captured-prompt.txt" | tail -1)
[ -z "\$mode" ] && mode=regular
round=\$(sed -n 's/^> 审查轮次：//p' "$temp_root/captured-prompt.txt" | tail -1)
[ -z "\$round" ] && round=1
plan_file=\$(sed -n 's/^> 对比计划：\`//p' "$temp_root/captured-prompt.txt" | tail -1 | sed 's/\`$//')
[ -z "\$plan_file" ] && plan_file=.ai-flow/plans/20260503/demo.md
case "$body_mode" in
    placeholder)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：{审查结果}
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
{总体通过 / 需要修复 / 存在风险}

## 2. 计划覆盖度检查
ok

## 2.1 计划外变更识别
none

## 3. 代码质量审查
ok

## 4. 缺陷清单
none

## 5. 审查结论
passed

## 6. 缺陷修复追踪
none
REPORT
        ;;
    missing_validation_evidence)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：passed
> 对比计划：\`\$plan_file\`
> 审查工具：Codex (test high)

## 1. 总体评价
总体通过

### 1.1 审查上下文
ok

## 2. 计划覆盖度检查
ok

## 2.1 计划外变更识别
none

## 3. 代码质量审查
### 3.5 逻辑正确性
ok

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | 已复查 |

## 4. 缺陷清单
none

## 5. 审查结论
- [x] **通过** — 所有步骤已实现，无严重缺陷
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |
REPORT
        ;;
    missing_previous_family_coverage)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：passed
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
总体通过

### 1.1 审查上下文
ok

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`bash tests/test_review_workflow.sh\` | PASS | 已执行定向验证 |

## 2. 计划覆盖度检查
ok

## 2.1 计划外变更识别
none

## 3. 代码质量审查
### 3.5 逻辑正确性
ok

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | 已复查 |

## 4. 缺陷清单
none

## 5. 审查结论
- [x] **通过** — 所有步骤已实现，无严重缺陷
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-9 | v1 | [已修复] | fixed | verified |
REPORT
        ;;
    passed_with_pending)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：passed
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
总体通过

### 1.1 审查上下文
ok

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`bash tests/test_review_workflow.sh\` | PASS | 已执行定向验证 |

## 2. 计划覆盖度检查
ok

## 2.1 计划外变更识别
none

## 3. 代码质量审查
### 3.5 逻辑正确性
ok

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | 已复查 |

## 4. 缺陷清单
| DEF-1 | src/a | problem | fix | [待修复] |

## 5. 审查结论
- [x] **通过** — 所有步骤已实现，无严重缺陷
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| DEF-1 | v1 | [待修复] | | |
REPORT
        ;;
    passed_with_needs_fix_conclusion)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：passed
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
总体通过

### 1.1 审查上下文
ok

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`bash tests/test_review_workflow.sh\` | PASS | 已执行定向验证 |

## 2. 计划覆盖度检查
ok

## 2.1 计划外变更识别
none

## 3. 代码质量审查
### 3.5 逻辑正确性
ok

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | 已复查 |

## 4. 缺陷清单
none

## 5. 审查结论
- [ ] **通过** — 所有步骤已实现，无严重缺陷
- [x] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |
REPORT
        ;;
    failed_without_defect)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：failed
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
需要修复

### 1.1 审查上下文
ok

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`bash tests/test_review_workflow.sh\` | FAIL | 仅用于构造失败夹具 |

## 2. 计划覆盖度检查
ok

## 2.1 计划外变更识别
none

## 3. 代码质量审查
### 3.5 逻辑正确性
ok

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 未覆盖 | 未执行补充修复 |

## 4. 缺陷清单
none

## 5. 审查结论
- [ ] **通过** — 所有步骤已实现，无严重缺陷
- [x] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
none
REPORT
        ;;
    failed_valid)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：failed
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
需要修复

### 1.1 审查上下文
ok

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`bash tests/test_review_workflow.sh\` | FAIL | 仅用于构造失败夹具 |

## 2. 计划覆盖度检查
ok

## 2.1 计划外变更识别
none

## 3. 代码质量审查
### 3.5 逻辑正确性
ok

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 未覆盖 | 仍存在待修复项 |

## 4. 缺陷清单
| DEF-1 | src/a | problem | fix | [待修复] |

## 5. 审查结论
- [ ] **通过** — 所有步骤已实现，无严重缺陷
- [x] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| DEF-1 | v1 | [待修复] | | |
REPORT
        ;;
    json_braces)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：passed
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
总体通过，示例 JSON 为 {"ok":true}。

### 1.1 审查上下文
ok

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`bash tests/test_review_workflow.sh\` | PASS | 已执行定向验证 |

## 2. 计划覆盖度检查
ok

## 2.1 计划外变更识别
none

## 3. 代码质量审查
### 3.5 逻辑正确性
ok

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| 测试/证据 | 已覆盖 | 已复查 |

## 4. 缺陷清单
none

## 5. 审查结论
- [x] **通过** — 所有步骤已实现，无严重缺陷
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |
REPORT
        ;;
    *)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：$result
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
\$( [ "$result" = "passed" ] && echo "总体通过" || echo "需要修复" )

### 1.1 审查上下文

| 项目 | 内容 |
|------|------|
| Plan 文件 | \$plan_file |
| 变更范围 | staged / unstaged / untracked |
| 上一轮报告 | 无 |
| 验证证据 | 测试夹具 |

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`bash tests/test_review_workflow.sh\` | \$( [ "$result" = "passed" ] && echo "PASS" || echo "FAIL" ) | 测试夹具生成的定向验证证据 |

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
| 测试/证据 | \$( [ "$result" = "passed" ] && echo "已覆盖" || echo "未覆盖" ) | \$( [ "$result" = "passed" ] && echo "定向验证通过" || echo "仍存在待修复项" ) |

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|
\$( if [ "$result" = "failed" ]; then echo "| DEF-1 | Critical | src/review-target.txt | problem | impact | fix | [待修复] |"; fi )

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|

## 5. 审查结论

\$( if [ "$result" = "passed" ]; then echo "- [x] **通过** — 所有步骤已实现，无严重缺陷"; else echo "- [ ] **通过** — 所有步骤已实现，无严重缺陷"; fi )
\$( if [ "$result" = "passed" ]; then echo "- [ ] **需要修复** — 存在以下问题需要处理"; else echo "- [x] **需要修复** — 存在以下问题需要处理"; fi )

## 6. 缺陷修复追踪

\$( if [ "$result" = "passed" ]; then cat <<'EOF'
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |
EOF
else
cat <<'EOF'
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [待修复] | | |
EOF
fi )
REPORT
        ;;
esac
FAKE_CODEX
    chmod +x "$temp_root/bin/codex"
}

run_with_fake_codex() {
    local temp_root="$1"
    shift
    PATH="$temp_root/bin:$PATH" HOME="$temp_root/home" "$@"
}
