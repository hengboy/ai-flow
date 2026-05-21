#!/bin/bash
# testkit.bash — AI Flow 测试通用工具函数。
# 在测试脚本开头 source 即可使用。

set -uo pipefail

TESTKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$TESTKIT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

SCRIPTS_DIR="$PROJECT_ROOT/runtime/scripts"
SHARED_LIB="$PROJECT_ROOT/subagents/shared/lib"
RUNTIME_LIB="$PROJECT_ROOT/runtime/lib"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass_count=0
fail_count=0

test_pass() {
    echo -e "  ${GREEN}PASS${NC} $1"
    ((pass_count++))
}

test_fail() {
    echo -e "  ${RED}FAIL${NC} $1"
    if [[ -n "${2:-}" ]]; then
        echo "    详情: $2"
    fi
    ((fail_count++))
}

test_info() {
    echo -e "  ${YELLOW}INFO${NC} $1"
}

# assert_equal <actual> <expected> <label>
assert_equal() {
    if [[ "$1" == "$2" ]]; then
        test_pass "$3"
    else
        test_fail "$3" "期望='$2' 实际='$1'"
    fi
}

# assert_contains <haystack> <needle> <label>
assert_contains() {
    if [[ "$1" == *"$2"* ]]; then
        test_pass "$3"
    else
        test_fail "$3" "期望包含 '$2' 但实际='$1'"
    fi
}

# assert_not_contains <haystack> <needle> <label>
assert_not_contains() {
    if [[ "$1" != *"$2"* ]]; then
        test_pass "$3"
    else
        test_fail "$3" "不应包含 '$2'"
    fi
}

# assert_exit_code <actual_code> <expected_code> <label>
assert_exit_code() {
    if [[ "$1" -eq "$2" ]]; then
        test_pass "$3"
    else
        test_fail "$3" "期望退出码=$2 实际=$1"
    fi
}

# create_temp_project [name]
# 创建临时项目目录（位于 .ai-flow-tests 下），返回路径。
create_temp_project() {
    local name="${1:-test-$$}"
    local test_root="$PROJECT_ROOT/.ai-flow-tests"
    mkdir -p "$test_root"
    local dir
    dir="$(mktemp -d "${test_root}/${name}.XXXXXX")"
    mkdir -p "$dir/.ai-flow/state"
    printf '%s' "$dir"
}

# cleanup_temp_project <dir>
cleanup_temp_project() {
    rm -rf "$1"
}

# create_minimal_state <project_dir> <slug>
# 创建一个最小合法的状态文件。
create_minimal_state() {
    local project_dir="$1"
    local slug="$2"
    local state_dir="$project_dir/.ai-flow/state"
    mkdir -p "$state_dir"
    mkdir -p "$project_dir/.ai-flow/plans"
    if [[ ! -f "$project_dir/.ai-flow/plans/test.md" ]]; then
        cat > "$project_dir/.ai-flow/plans/test.md" <<'EOF'
# 实施计划：测试功能

> 创建日期：2026-05-19
> 创建时间：10:00:00
> 需求简称：测试功能
> 需求来源：测试
> 执行范围：owner
> Plan 参与仓库：owner
> 状态文件：.ai-flow/state/test.json
> 文档角色：实施计划
> 状态文件约束：仅 flow-state.sh transition 可修改
> 执行约定：按 Step 顺序执行
> 验证约定：运行计划中的验证命令
> 规则标识：test

## 1. 需求概述

**目标**：测试

**背景**：测试

**原始需求（原文）**：
测试

**非目标**：无

## 2. 技术分析

### 2.1 涉及模块

| 模块 | 仓库 | 职责 | 变更类型 |
|------|------|------|----------|
| test | owner | test | 修改 |

### 2.2 数据模型变更

不涉及数据库变更

### 2.3 API 变更

| 接口 | 方法 | 路径 | 说明 |
|------|------|------|------|
| 无新增/修改接口 | - | - | - |

### 2.4 依赖影响

无

### 2.5 文件边界总览

| 文件 | 仓库 | 操作 | 职责 | 对应 Step ID |
|------|------|------|------|----------|
| `a.txt` | owner | Modify | test | `step-one` |

### 2.6 高风险路径与缺陷族

| 高风险能力/路径 | 影响面 | 典型失效模式 | 对应缺陷族 | 必须覆盖的验证方式 |
|----------------|--------|--------------|------------|--------------------|
| test | test | test | test-family | 单测 |

## 3. 实施步骤

### 第一步

**Step ID**：`step-one`

**目标**：测试

**文件边界**：
- Modify: `a.txt` — test
- Test: `tests/a_test.py` — test

**本轮 review 预期关注面**：test-family

**执行动作**：
- [x] **实现**
  - 命令：`echo ok`
  - 预期：PASS

**本步验收**：
- [x] 命令成功

**本步关闭条件**：命令通过

**阻塞条件**：- 无

## 4. 测试计划

### 4.1 单元测试

- [ ] test

### 4.2 集成测试

- [ ] 无

### 4.3 回归验证

- [ ] `echo ok`

### 4.4 定向验证矩阵

| 缺陷族 | 目标风险路径 | 定向验证命令 | 验证类型 | 通过标准 |
|--------|--------------|--------------|----------|----------|
| test-family | test | `echo ok` | 单测 | 输出 ok |

## 5. 风险与注意事项

- 无

## 6. 验收标准

- [ ] test

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|

## 8. 计划审核记录

### 8.1 当前审核结论

- 待审核

### 8.2 偏差与建议

- 无

### 8.3 审核历史

- 无
EOF
    fi

    python3 - "$state_dir" "$slug" "$project_dir" <<'PY'
import json
import sys
from pathlib import Path

state_dir = Path(sys.argv[1])
slug = sys.argv[2]
project_dir = sys.argv[3]

state = {
    "schema_version": 4,
    "slug": slug,
    "title": "测试功能",
    "plan_file": ".ai-flow/plans/test.md",
    "execution_scope": {
        "mode": "plan_repos",
        "repos": [{
            "id": "owner",
            "path": ".",
            "git_root": project_dir,
            "role": "owner"
        }]
    },
    "current_status": "AWAITING_PLAN_REVIEW",
    "created_at": "2026-05-19T10:00:00+08:00",
    "updated_at": "2026-05-19T10:00:00+08:00",
    "transitions": [{
        "seq": 1,
        "at": "2026-05-19T10:00:00+08:00",
        "event": "plan_created",
        "from": None,
        "to": "AWAITING_PLAN_REVIEW",
        "actor": "test-runner",
        "payload": {
            "title": "测试功能",
            "plan_file": ".ai-flow/plans/test.md",
            "execution_scope": {
                "mode": "plan_repos",
                "repos": [{
                    "id": "owner",
                    "path": ".",
                    "git_root": project_dir,
                    "role": "owner"
                }]
            }
        },
        "note": "创建计划"
    }]
}

(state_dir / f"{slug}.json").write_text(
    json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8"
)
PY
}

# create_minimal_review_report <project_dir> [name]
# 创建一个满足当前 review_passed 门禁的最小合法审查报告。
create_minimal_review_report() {
    local project_dir="$1"
    local name="${2:-r1.md}"
    local report_dir="$project_dir/.ai-flow/reports"
    mkdir -p "$report_dir"
    cat > "$report_dir/$name" <<'EOF'
# 审查报告：测试功能

> 审查日期：2026-05-19
> 审查时间：10:10:00
> 需求简称：测试功能
> 审查模式：regular
> 审查轮次：1
> 审查结果：passed
> 对比计划：`.ai-flow/plans/test.md`
> 审查工具：test
> 规则标识：`review`

## 1. 总体评价

总体通过

### 1.1 审查上下文

| 项目 | 内容 |
|------|------|
| Plan 文件 | `.ai-flow/plans/test.md` |
| 变更范围 | test |
| 上一轮报告 | 无 |
| 验证证据 | test |

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
| `echo ok` | PASS | test |

## 2. 计划覆盖度检查

| 实施步骤 | 状态 | 备注 |
|----------|------|------|
| `step-one`（第一步） | 已实现 | 已覆盖 |

**覆盖率**：100%

### 2.1 计划外变更识别

| 变更文件/模块 | 变更内容摘要 | 判定 | 备注 |
|----------|----------|------|------|
| `a.txt` | test | 接受 | test |

## 3. 代码质量审查

### 3.1 架构与设计

- 无

### 3.2 规范性

- 无

### 3.3 安全性

- 无

### 3.4 性能

- 无

### 3.5 逻辑正确性

| 检查项 | 审查结果 | 问题描述 |
|--------|----------|----------|
| 边界条件 | 通过 | test |

### 3.6 缺陷族覆盖度

| 缺陷族 | 覆盖状态 | 依据 |
|--------|----------|------|
| test-family | 已覆盖 | test |

## 4. 缺陷清单

### 4.1 严重缺陷

无

### 4.2 建议改进

无

## 5. 审查结论

- [x] **通过** - 所有步骤已实现，无严重缺陷

## 6. 缺陷修复追踪

无
EOF
}

setup_minimal_change_runtime() {
    local project_dir="$1"
    mkdir -p "$project_dir/.ai-flow/plans"
    mkdir -p "$project_dir/.ai-flow"
    if ! grep -q '^## 7\. 需求变更记录' "$project_dir/.ai-flow/plans/test.md" 2>/dev/null; then
        cat >> "$project_dir/.ai-flow/plans/test.md" <<'EOF'

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|
| {YYYY-MM-DD HH:MM} | {执行过程中新增或调整的需求；无则保留空表} | {用户确认/文档同步/其他} |
EOF
    fi
    cat > "$project_dir/.ai-flow/rule.yaml" <<'EOF'
version: 1
prompt:
  shared_context: []
  skill_overrides: []
  subagent_overrides: []
constraints:
  required_reads: []
  protected_paths: []
  forbidden_changes: []
  test_policy:
    require_tests_for_code_change: false
    allow_testless_paths: []
review:
  required_checks: []
  required_evidence: []
  severity_rules: {}
  fail_conditions: []
EOF
}

# write_user_setting <home_dir> <json_content>
# 在指定 home 目录写入用户级 setting.json
write_user_setting() {
    local home_dir="$1"
    local json_content="$2"
    mkdir -p "$home_dir"
    printf '%s' "$json_content" > "$home_dir/setting.json"
}

# write_project_setting <project_dir> <json_content>
# 在 <project_dir>/.ai-flow/setting.json 写入项目级配置
write_project_setting() {
    local project_dir="$1"
    local json_content="$2"
    mkdir -p "$project_dir/.ai-flow"
    printf '%s' "$json_content" > "$project_dir/.ai-flow/setting.json"
}

# write_partial_project_setting <project_dir> <json_content>
# 同 write_project_setting，用于部分覆盖场景
write_partial_project_setting() {
    write_project_setting "$@"
}

print_summary() {
    echo ""
    echo "==============================="
    echo -e "  测试完成: ${GREEN}$pass_count PASS${NC}, ${RED}$fail_count FAIL${NC}"
    echo "==============================="
}
