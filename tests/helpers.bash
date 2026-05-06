#!/bin/bash

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AI_FLOW_PLAN_SCRIPT="$TEST_ROOT/skills/ai-flow-plan/scripts/codex-plan.sh"
AI_FLOW_REVIEW_SCRIPT="$TEST_ROOT/skills/ai-flow-review/scripts/codex-review.sh"
AI_FLOW_OPENCODE_REVIEW_SCRIPT="$TEST_ROOT/skills/ai-flow-review/scripts/opencode-review.sh"
AI_FLOW_CHANGE_SCRIPT="$TEST_ROOT/runtime/scripts/flow-change.sh"
AI_FLOW_STATUS_SCRIPT="$TEST_ROOT/runtime/scripts/flow-status.sh"
AI_FLOW_STATE_SCRIPT="$TEST_ROOT/runtime/scripts/flow-state.sh"

installed_skill_script() {
    local temp_root="$1"
    local skill="$2"
    local script="$3"
    printf '%s/home/.claude/skills/%s/scripts/%s' "$temp_root" "$skill" "$script"
}

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
    mkdir -p "$temp_root/home"
    HOME="$temp_root/home" "$TEST_ROOT/install.sh" >/dev/null
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

setup_minimal_project_root() {
    local project_dir="$1"
    mkdir -p "$project_dir/src"
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

**目标**：生成测试计划。

**背景**：用于测试 AI Flow 状态机与 review 工作流。

**原始需求（原文）**：
测试计划。

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

## 8. 计划审核记录

### 8.1 当前审核结论

- 审核状态：passed
- 与原始需求一致性：与原始需求一致
- 是否允许进入 \`/ai-flow-execute\`：是
- 当前审核轮次：1
- 审核引擎/模型：Fixture / fixture-model
- 结论摘要：测试夹具默认视为已通过计划审核。

### 8.2 偏差与建议

- 无

### 8.3 审核历史

#### 第 1 轮
- 结果：passed
- 与原始需求一致性：与原始需求一致
- 是否允许进入 \`/ai-flow-execute\`：是
- 审核引擎/模型：Fixture / fixture-model
- 结论摘要：测试夹具默认视为已通过计划审核。
- 条目：
  - 无
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
    local conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
    local conclusion_fail="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
    local conclusion_fix="- [ ] **需要修复** — 存在以下问题需要处理"
    local defects="无"
    local tracking="无"

    if [ "$result" = "failed" ]; then
        overall="需要修复"
        conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
        conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
        conclusion_fix="- [x] **需要修复** — 存在以下问题需要处理"
        defects='| DEF-1 | Critical | src/review-target.txt | problem | impact | fix | [待修复] |'
        tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [待修复] | | |'
    elif [ "$result" = "passed_with_notes" ]; then
        overall="总体通过（附建议）"
        conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
        conclusion_notes="- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
        defects='| SUG-1 | Minor | src/review-target.txt | suggestion | refine | [可选] |'
        tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| SUG-1 | v1 | [可选] | deferred | noted |'
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
| bash tests/test_review_workflow.sh | PASS | 测试夹具提供的定向验证证据 |

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
$conclusion_notes
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
        bash "$AI_FLOW_STATE_SCRIPT" create --slug "$slug" --title "$title" --plan-file "$plan_file" >/dev/null
        case "$target_status" in
            AWAITING_PLAN_REVIEW)
                ;;
            PLANNED)
                bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                ;;
            IMPLEMENTING)
                bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" start-execute "$slug" >/dev/null
                ;;
            PLAN_REVIEW_FAILED)
                bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug "$slug" --result failed --engine Fixture --model fixture-model >/dev/null
                ;;
            AWAITING_REVIEW)
                bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" start-execute "$slug" >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" finish-implementation "$slug" >/dev/null
                ;;
            REVIEW_FAILED)
                bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" start-execute "$slug" >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" finish-implementation "$slug" >/dev/null
                write_review_report_fixture ".ai-flow/reports/$date_dir/${slug}-review.md" "$slug" "$plan_file" "regular" "1" "failed" "$title"
                bash "$AI_FLOW_STATE_SCRIPT" record-review --slug "$slug" --mode regular --result failed --report-file ".ai-flow/reports/$date_dir/${slug}-review.md" >/dev/null
                ;;
            FIXING_REVIEW)
                bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" start-execute "$slug" >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" finish-implementation "$slug" >/dev/null
                write_review_report_fixture ".ai-flow/reports/$date_dir/${slug}-review.md" "$slug" "$plan_file" "regular" "1" "failed" "$title"
                bash "$AI_FLOW_STATE_SCRIPT" record-review --slug "$slug" --mode regular --result failed --report-file ".ai-flow/reports/$date_dir/${slug}-review.md" >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" start-fix "$slug" >/dev/null
                ;;
            DONE)
                bash "$AI_FLOW_STATE_SCRIPT" record-plan-review --slug "$slug" --result passed --engine Fixture --model fixture-model >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" start-execute "$slug" >/dev/null
                bash "$AI_FLOW_STATE_SCRIPT" finish-implementation "$slug" >/dev/null
                write_review_report_fixture ".ai-flow/reports/$date_dir/${slug}-review.md" "$slug" "$plan_file" "regular" "1" "passed" "$title"
                bash "$AI_FLOW_STATE_SCRIPT" record-review --slug "$slug" --mode regular --result passed --report-file ".ai-flow/reports/$date_dir/${slug}-review.md" >/dev/null
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
if [ "\$1" = "exec" ] && [ "\$2" = "--help" ]; then
    cat <<'HELP'
Usage: codex exec [OPTIONS]
      --skip-git-repo-check
HELP
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
| skills/ai-flow-plan/scripts/codex-plan.sh | 校验 plan | 修改 |

## 3. 实施步骤

### Step 1: fake

**目标**：验证 plan 校验。

**文件边界**：
- Modify: \`skills/ai-flow-plan/scripts/codex-plan.sh\` — 补充校验

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
- Modify: \`skills/ai-flow-plan/scripts/codex-plan.sh\` — 补充校验

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
  - 文件：skills/ai-flow-plan/scripts/codex-plan.sh
  - 改动：补充验证
  - 约束：保持 Bash 兼容

- [ ] **1.4 运行通过验证**
  - 命令：bash tests/run.sh
  - 预期：PASS

- [ ] **1.5 本步自检**
  - 命令：git diff -- skills/ai-flow-plan/scripts/codex-plan.sh tests
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
    cat <<'HELP'
Usage: codex exec [OPTIONS]
      --skip-git-repo-check
HELP
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
> 对比计划：\$plan_file
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
| bash tests/test_review_workflow.sh | PASS | 已执行定向验证 |

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
- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
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
| bash tests/test_review_workflow.sh | PASS | 已执行定向验证 |

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
| SUG-1 | Minor | src/a | problem | fix | [可选] |

## 5. 审查结论
- [x] **通过** — 所有步骤已实现，无严重缺陷
- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| SUG-1 | v1 | [可选] | | |
REPORT
        ;;
    passed_with_notes_valid)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：passed_with_notes
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
总体通过（附建议）

### 1.1 审查上下文
ok

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| bash tests/test_review_workflow.sh | PASS | 已执行定向验证 |

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

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|
| SUG-1 | Minor | src/a | problem | fix | [可选] |

## 5. 审查结论
- [ ] **通过** — 所有步骤已实现，无严重缺陷
- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| SUG-1 | v1 | [可选] | deferred | noted |
REPORT
        ;;
    passed_with_notes_pending)
        cat > "\$out" <<REPORT
# 审查报告：\$title

> 审查日期：2026-05-03
> 需求简称：\$slug
> 审查模式：\$mode
> 审查轮次：\$round
> 审查结果：passed_with_notes
> 对比计划：\$plan_file
> 审查工具：Codex (test high)

## 1. 总体评价
总体通过（附建议）

### 1.1 审查上下文
ok

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| bash tests/test_review_workflow.sh | PASS | 已执行定向验证 |

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

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|
| SUG-1 | Minor | src/a | problem | fix | [待修复] |

## 5. 审查结论
- [ ] **通过** — 所有步骤已实现，无严重缺陷
- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| SUG-1 | v1 | [待修复] | | |
REPORT
        ;;
    optional_on_defect)
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
| bash tests/test_review_workflow.sh | FAIL | 已执行定向验证 |

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

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|
| DEF-1 | Critical | src/a | problem | impact | fix | [可选] |

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|

## 5. 审查结论
- [ ] **通过** — 所有步骤已实现，无严重缺陷
- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
- [x] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [可选] | | |
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
| bash tests/test_review_workflow.sh | PASS | 已执行定向验证 |

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
- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
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
| bash tests/test_review_workflow.sh | FAIL | 仅用于构造失败夹具 |

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
- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
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
| bash tests/test_review_workflow.sh | FAIL | 仅用于构造失败夹具 |

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
| bash tests/test_review_workflow.sh | PASS | 已执行定向验证 |

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
\$( if [ "$result" = "passed" ]; then echo "总体通过"; elif [ "$result" = "passed_with_notes" ]; then echo "总体通过（附建议）"; else echo "需要修复"; fi )

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
| bash tests/test_review_workflow.sh | \$( [ "$result" = "passed" ] && echo "PASS" || echo "FAIL" ) | 测试夹具生成的定向验证证据 |

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
| 测试/证据 | \$( [ "$result" = "failed" ] && echo "未覆盖" || echo "已覆盖" ) | \$( [ "$result" = "failed" ] && echo "仍存在待修复项" || echo "定向验证通过" ) |

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|
\$( if [ "$result" = "failed" ]; then echo "| DEF-1 | Critical | src/review-target.txt | problem | impact | fix | [待修复] |"; fi )

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|
\$( if [ "$result" = "passed_with_notes" ]; then echo "| SUG-1 | Minor | src/review-target.txt | suggestion | refine | [可选] |"; fi )

## 5. 审查结论

\$( if [ "$result" = "passed" ]; then echo "- [x] **通过** — 所有步骤已实现，无严重缺陷"; else echo "- [ ] **通过** — 所有步骤已实现，无严重缺陷"; fi )
\$( if [ "$result" = "passed_with_notes" ]; then echo "- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"; else echo "- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"; fi )
\$( if [ "$result" = "failed" ]; then echo "- [x] **需要修复** — 存在以下问题需要处理"; else echo "- [ ] **需要修复** — 存在以下问题需要处理"; fi )

## 6. 缺陷修复追踪

\$( if [ "$result" = "passed" ]; then cat <<'EOF'
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |
EOF
elif [ "$result" = "passed_with_notes" ]; then cat <<'EOF'
| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| SUG-1 | v1 | [可选] | deferred | noted |
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

write_fake_review_engines() {
    local temp_root="$1"
    local scenario="$2"
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
scenario="${FAKE_REVIEW_SCENARIO:?}"
printf '%s\n' "$*" > "$temp_root/codex.args"

case "$scenario" in
    fallback_passed)
        echo "codex unavailable during review" >&2
        exit 127
        ;;
    *)
        echo "unexpected fake codex review scenario: $scenario" >&2
        exit 1
        ;;
esac
FAKE_CODEX
    chmod +x "$temp_root/bin/codex"

    cat > "$temp_root/bin/opencode" <<'FAKE_OPENCODE'
#!/bin/bash
set -euo pipefail
temp_root="${FAKE_REVIEW_TEMP_ROOT:?}"
scenario="${FAKE_REVIEW_SCENARIO:?}"
printf '%s\n' "$*" > "$temp_root/opencode.args"
prompt_file="$temp_root/captured-review-opencode-prompt.txt"
printf '%s' "${*: -1}" > "$prompt_file"

title=$(sed -n 's/^# 审查报告：//p' "$prompt_file" | tail -1)
[ -z "$title" ] && title=demo
slug=$(sed -n 's/^> 需求简称：//p' "$prompt_file" | tail -1)
[ -z "$slug" ] && slug=demo
mode=$(sed -n 's/^> 审查模式：//p' "$prompt_file" | tail -1)
[ -z "$mode" ] && mode=regular
round=$(sed -n 's/^> 审查轮次：//p' "$prompt_file" | tail -1)
[ -z "$round" ] && round=1
plan_file=$(sed -n 's/^> 对比计划：`//p' "$prompt_file" | tail -1 | sed 's/`$//')
[ -z "$plan_file" ] && plan_file=.ai-flow/plans/20260503/demo.md

case "$scenario" in
    fallback_passed)
        cat <<REPORT
# 审查报告：$title

> 审查日期：2026-05-03
> 需求简称：$slug
> 审查模式：$mode
> 审查轮次：$round
> 审查结果：passed
> 对比计划：\`$plan_file\`
> 审查工具：OpenCode (zhipuai-coding-plan/glm-5.1 max)
> 规则标识：\`review\`、\`fix-review\`、\`verify-before-done\`

## 1. 总体评价

总体通过

### 1.1 审查上下文

| 项目 | 内容 |
|------|------|
| Plan 文件 | \`$plan_file\` |
| 变更范围 | staged / unstaged / untracked |
| 上一轮报告 | 无 |
| 验证证据 | OpenCode fallback fixture |

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| \`git diff -- src/review-target.txt\` | PASS | fallback 夹具已校验变更范围 |

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
| 测试/证据 | 已覆盖 | fallback 审查已覆盖关键路径 |

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复状态 |
|---|----------|------|------|------|----------|

## 5. 审查结论

- [x] **通过** — 所有步骤已实现，无严重缺陷
- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理
- [ ] **需要修复** — 存在以下问题需要处理

## 6. 缺陷修复追踪

| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |
REPORT
        ;;
    *)
        echo "unexpected fake opencode review scenario: $scenario" >&2
        exit 1
        ;;
esac
FAKE_OPENCODE
    chmod +x "$temp_root/bin/opencode"
}

run_with_fake_review_engines() {
    local temp_root="$1"
    local scenario="$2"
    shift 2
    PATH="$temp_root/bin:$PATH" \
    HOME="$temp_root/home" \
    FAKE_REVIEW_TEMP_ROOT="$temp_root" \
    FAKE_REVIEW_SCENARIO="$scenario" \
    "$@"
}

write_fake_plan_workflow_engines() {
    local temp_root="$1"
    local scenario="$2"
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
scenario="${FAKE_PLAN_SCENARIO:?}"
call_file="$temp_root/fake-plan-codex-call-count"
count=0
[ -f "$call_file" ] && count=$(cat "$call_file")
count=$((count + 1))
printf '%s' "$count" > "$call_file"
printf '%s\n' "$*" > "$temp_root/codex.args.$count"

out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    fi
    shift || true
done

prompt_file="$temp_root/captured-plan-call-$count.txt"
cat > "$prompt_file"
if [ "$count" -eq 1 ]; then
    cp "$prompt_file" "$temp_root/captured-plan-prompt.txt"
fi

slug=$(basename "$out" .md)

write_plan() {
    local review_state="$1"
    local review_items="$2"
    cat > "$out" <<PLAN
# 实施计划：fake

> 创建日期：2026-05-03
> 需求简称：$slug
> 需求来源：测试
> 状态文件：\`.ai-flow/state/$slug.json\`
> 文档角色：本文件仅记录实施证据与执行步骤；流程状态以 JSON 状态文件为准。

## 1. 需求概述

**目标**：生成可执行计划。

**背景**：用于测试 plan 生成与审核串联。

**原始需求（原文）**：
placeholder

**非目标**：无。

## 2. 技术分析

### 2.1 涉及模块

| 模块 | 职责 | 变更类型 |
|------|------|----------|
| \`skills/ai-flow-plan/scripts/codex-plan.sh\` | 串联 draft 生成、审核与修订 | 修改 |

### 2.2 数据模型变更

无。

### 2.3 API 变更

| 接口 | 方法 | 路径 | 说明 |
|------|------|------|------|
| 无 | 无 | 无 | 无 |

### 2.4 依赖影响

无。

### 2.5 文件边界总览

| 文件 | 操作 | 职责 | 对应步骤 |
|------|------|------|----------|
| \`skills/ai-flow-plan/scripts/codex-plan.sh\` | Modify | 串联 plan 审核流程 | Step 1 |
| \`tests/test_plan_workflow.sh\` | Test | 覆盖计划审核回归 | Step 1 |

### 2.6 高风险路径与缺陷族

| 高风险能力/路径 | 影响面 | 典型失效模式 | 对应缺陷族 | 必须覆盖的验证方式 |
|----------------|--------|--------------|------------|--------------------|
| plan 审核门禁 | plan 与 execute 之间的状态衔接 | draft 未经审核直接放行 | 状态机/流程 | \`bash tests/test_plan_workflow.sh\` |
| 计划修订闭环 | 审核失败后的重写与复审 | 阻断项未消除仍误判通过 | 测试/证据 | \`bash tests/test_plan_workflow.sh\` |

## 3. 实施步骤

### Step 1: 建立计划审核闭环

**目标**：让 draft plan 必须先审核通过再允许执行。

**文件边界**：
- Modify: \`skills/ai-flow-plan/scripts/codex-plan.sh\` — 串联 draft 生成、审核、修订和复审
- Test: \`tests/test_plan_workflow.sh\` — 覆盖通过、失败、复审和降级路径

**本轮 review 预期关注面**：
- 状态机/流程缺陷族，以及计划审核记录回写是否与最终门禁状态一致

**执行动作**：
- [ ] **1.1 写失败用例**
  - 文件：\`tests/test_plan_workflow.sh\`
  - 场景：draft plan 未经审核不能进入 execute
  - 预期：当前实现下失败，失败原因是状态仍被错误放行为 \`PLANNED\`

- [ ] **1.2 运行失败验证**
  - 命令：\`bash tests/test_plan_workflow.sh\`
  - 预期：FAIL，错误信息包含 \`PLANNED\`

- [ ] **1.3 实现最小改动**
  - 文件：\`skills/ai-flow-plan/scripts/codex-plan.sh\`
  - 改动：补齐审核 prompt、失败修订和状态推进
  - 约束：保持单入口，不新增独立 plan-review skill

- [ ] **1.4 运行通过验证**
  - 命令：\`bash tests/test_plan_workflow.sh\`
  - 预期：PASS

- [ ] **1.5 本步自检**
  - 命令：\`git diff -- skills/ai-flow-plan tests\`
  - 确认：无计划外文件、无占位符、无临时日志、无未说明行为变化

**本步验收**：
- [ ] draft plan 审核通过后才进入 \`PLANNED\`
- [ ] 审核失败时保留在 plan 文件内形成完整历史

**本步关闭条件**：
- \`bash tests/test_plan_workflow.sh\` 通过，且计划审核记录中的 execute 门禁与状态一致

**阻塞条件**：
- 如果计划审核输出无法解析，停止执行并向用户确认，不猜测实现。

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
| 状态机/流程 | draft plan 到 execute 的门禁 | \`bash tests/test_plan_workflow.sh\` | 集成 | 未经审核的 draft 不得进入 execute |
| 测试/证据 | 计划审核记录回写与复审历史 | \`bash tests/test_plan_workflow.sh\` | 集成 | 第 8 章完整记录当前结论和历史轮次 |

## 5. 风险与注意事项

- 审核通过与否必须由固定规则推导，不依赖模型自由发挥。

## 6. 验收标准

- [ ] \`bash tests/test_plan_workflow.sh\` 通过
- [ ] 计划审核通过前不得提示进入 \`/ai-flow-execute\`

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|
| 2026-05-03 00:00 | 无 | 测试夹具 |

## 8. 计划审核记录

### 8.1 当前审核结论

- 审核状态：$review_state
- 与原始需求一致性：待审核
- 是否允许进入 \`/ai-flow-execute\`：否
- 当前审核轮次：0
- 审核引擎/模型：待审核
- 结论摘要：等待计划审核。

### 8.2 偏差与建议

$review_items

### 8.3 审核历史

- 第 0 轮：初始化 draft，待审核。
PLAN
}

case "$scenario:$count" in
    review_passed:1|review_notes:1|review_failed:1|review_fail_then_pass:1|review_fallback_pass:1)
        write_plan "待审核" "- 待审核"
        ;;
    review_passed:2)
        cat > "$out" <<'REVIEW'
RESULT: passed
ALIGNMENT: 与原始需求一致
EXECUTE_READY: yes
SUMMARY: 计划覆盖了需求和门禁要求，可以进入 execute。
ITEMS:
- 无
REVIEW
        ;;
    review_notes:2)
        cat > "$out" <<'REVIEW'
RESULT: passed_with_notes
ALIGNMENT: 基本一致但有可选建议
EXECUTE_READY: yes
SUMMARY: 计划可以执行，但有一条非阻断建议。
ITEMS:
- [可选][Minor] 可以补充一条更明确的人工验证说明
REVIEW
        ;;
    review_failed:2)
        cat > "$out" <<'REVIEW'
RESULT: failed
ALIGNMENT: 存在阻断偏差
EXECUTE_READY: no
SUMMARY: 计划遗漏了审核失败后的修订闭环。
ITEMS:
- [待修订][Important] 缺少审核失败后的修订与复审步骤
REVIEW
        ;;
    review_fail_then_pass:2)
        cat > "$out" <<'REVIEW'
RESULT: failed
ALIGNMENT: 存在阻断偏差
EXECUTE_READY: no
SUMMARY: 初稿没有写清失败后如何修订并复审。
ITEMS:
- [待修订][Important] 需要补齐失败后修订 plan 并复审的闭环
REVIEW
        ;;
    review_fail_then_pass:3)
        write_plan "failed" "- [待修订][Important] 需要补齐失败后修订 plan 并复审的闭环"
        ;;
    review_fail_then_pass:4)
        cat > "$out" <<'REVIEW'
RESULT: passed
ALIGNMENT: 与原始需求一致
EXECUTE_READY: yes
SUMMARY: 修订后计划已补齐复审闭环，可以执行。
ITEMS:
- 无
REVIEW
        ;;
    review_fallback_pass:2)
        echo "codex unavailable during review" >&2
        exit 127
        ;;
    *)
        echo "unexpected fake codex scenario: $scenario call $count" >&2
        exit 1
        ;;
esac
FAKE_CODEX
    chmod +x "$temp_root/bin/codex"

    cat > "$temp_root/bin/opencode" <<'FAKE_OPENCODE'
#!/bin/bash
set -euo pipefail
temp_root="${FAKE_PLAN_TEMP_ROOT:?}"
scenario="${FAKE_PLAN_SCENARIO:?}"
call_file="$temp_root/fake-plan-opencode-call-count"
count=0
[ -f "$call_file" ] && count=$(cat "$call_file")
count=$((count + 1))
printf '%s' "$count" > "$call_file"
prompt_file="$temp_root/captured-plan-opencode-call-$count.txt"
printf '%s\n' "$*" > "$temp_root/opencode.args"
printf '%s' "${*: -1}" > "$prompt_file"

case "$scenario:$count" in
    review_fallback_pass:1)
        cat <<'REVIEW'
RESULT: passed
ALIGNMENT: 与原始需求一致
EXECUTE_READY: yes
SUMMARY: OpenCode 审核确认计划可执行。
ITEMS:
- 无
REVIEW
        ;;
    *)
        echo "unexpected fake opencode scenario: $scenario call $count" >&2
        exit 1
        ;;
esac
FAKE_OPENCODE
    chmod +x "$temp_root/bin/opencode"
}

run_with_fake_plan_engines() {
    local temp_root="$1"
    local scenario="$2"
    shift 2
    PATH="$temp_root/bin:$PATH" \
        HOME="$temp_root/home" \
        FAKE_PLAN_TEMP_ROOT="$temp_root" \
        FAKE_PLAN_SCENARIO="$scenario" \
        "$@"
}
