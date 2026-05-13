#!/bin/bash

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_FLOW_STATE_SCRIPT="$TEST_ROOT/runtime/scripts/flow-state.sh"
SOURCE_FLOW_STATUS_SCRIPT="$TEST_ROOT/runtime/scripts/flow-status.sh"
SOURCE_FLOW_CHANGE_SCRIPT="$TEST_ROOT/runtime/scripts/flow-change.sh"
SOURCE_FLOW_COMMIT_SCRIPT="$TEST_ROOT/runtime/scripts/flow-commit.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -Fq -- "$pattern" "$file" || fail "Expected '$file' to contain '$pattern'"
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    if grep -Fq -- "$pattern" "$file"; then
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

git_head_subject() {
    local git_root="$1"
    git -C "$git_root" log -1 --pretty=%s
}

git_commit_count() {
    local git_root="$1"
    git -C "$git_root" rev-list --count HEAD
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
        ONSPACE_SKILLS_DIR="$temp_root/home/.config/onespace/skills/local_state/models/claude" \
        ONSPACE_SUBAGENTS_CLAUDE_DIR="$temp_root/home/.config/onespace/subagents/local_state/models/claude" \
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
        git commit -q --allow-empty -m init
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

repo_scope_json() {
    local owner_root="$1"
    shift || true
    python3 - "$owner_root" "$@" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

owner = Path(sys.argv[1]).resolve()
items = sys.argv[2:] or ["owner::."]
repos = []
for item in items:
    repo_id, repo_path = item.split("::", 1)
    abs_path = (owner / repo_path).resolve()
    result = subprocess.run(
        ["git", "-C", str(abs_path), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        raise SystemExit(result.stderr)
    repos.append({
        "id": repo_id,
        "path": repo_path,
        "git_root": str(Path(result.stdout.strip()).resolve()),
        "role": "owner" if repo_id == "owner" else "participant",
    })
print(json.dumps({"mode": "plan_repos", "repos": repos}, ensure_ascii=False))
PY
}

create_plan_file() {
    local project_dir="$1"
    local slug="$2"
    local date_dir="${3:-20260503}"
    local title="${4:-$slug}"
    local requirement="${5:-测试计划。}"
    local plan_file="$project_dir/.ai-flow/plans/${date_dir}-${slug}.md"
    cat > "$plan_file" <<PLAN
# 实施计划：$title

> 创建日期：2026-05-03
> 需求简称：$slug
> 需求来源：测试
> 执行范围：plan_repos
> Plan 参与仓库：owner (path: ., role: owner)
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

| 模块 | 仓库 | 职责 | 变更类型 |
|------|------|------|----------|
| \`src/review-target.txt\` | owner | 提供 review 目标文件 | 修改 |

### 2.2 数据模型变更

无。

### 2.3 API 变更

无。

### 2.4 依赖影响

无。

### 2.5 文件边界总览

| 文件 | 仓库 | 操作 | 职责 | 对应步骤 |
|------|------|------|------|----------|
| \`src/review-target.txt\` | owner | Modify | 提供最小变更面 | Step 1 |

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

**本步验收**：
- \`bash tests/run.sh\` 通过，且步骤产物满足计划结构要求

**本步关闭条件**：
- \`bash tests/run.sh\` 通过，且 review 报告能记录定向验证执行证据

**阻塞条件**：
- 无

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
        severe_rows='| DEF-1 | Important | src/review-target.txt | problem | impact | fix | ai-flow-plan-coding | [待修复] |'
        tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [待修复] | | |'
    elif [ "$result" = "passed_with_notes" ]; then
        overall="总体通过（附建议）"
        conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
        conclusion_notes="- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
        suggest_rows='| SUG-1 | Minor | src/review-target.txt | suggestion | refine | ai-flow-code-optimize | [可选] |'
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

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复流向 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|----------|
$severe_rows

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复流向 | 修复状态 |
|---|----------|------|------|------|----------|----------|
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
    local plan_file=".ai-flow/plans/${date_dir}-${slug}.md"
    create_plan_file "$project_dir" "$slug" "$date_dir" "$title"
    (
        cd "$project_dir" || exit 1
        if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            git init -q
            git config user.email test@example.com
            git config user.name Test
            git add .
            git commit -q -m init
        fi
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
workdir="$(pwd)"
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    elif [ "$1" = "-C" ]; then
        shift
        workdir="$1"
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
    result=$(awk '/^需求描述：/{getline; print; exit}' "$file")
    if [ -z "$result" ]; then
        result=$(awk '/^原始需求：/{getline; print; exit}' "$file")
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

| 模块 | 仓库 | 职责 | 变更类型 |
|------|------|------|----------|
| \`src/review-target.txt\` | owner | fixture | 修改 |

### 2.2 数据模型变更

无。

### 2.3 API 变更

无。

### 2.4 依赖影响

无。

### 2.5 文件边界总览

| 文件 | 仓库 | 操作 | 职责 | 对应步骤 |
|------|------|------|------|----------|
| \`src/review-target.txt\` | owner | Modify | fixture | Step 1 |

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

**本步验收**：
- \`bash tests/run.sh\` 成功，且草案结构满足模板要求

**本步关闭条件**：
- \`bash tests/run.sh\` 通过

**阻塞条件**：
- 无

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
workdir="$(pwd)"
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        out="$1"
    elif [ "$1" = "-C" ]; then
        shift
        workdir="$1"
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
failed_route_mode="${FAKE_CODE_REVIEW_FAILED_ROUTE_MODE:-coding}"
overall="总体通过"
conclusion_pass="- [x] **通过** — 所有步骤已实现，无严重缺陷"
conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
conclusion_fix="- [ ] **需要修复** — 存在以下问题需要处理"
severe_rows=""
suggest_rows=""
context_body='| 项目 | 内容 |
|------|------|
| Plan 文件 | `'"$plan_file"'` |
| 变更范围 | staged / unstaged / untracked |
| 上一轮报告 | 无 |
| 验证证据 | fake review fixture |'
verification_rows='| `git diff -- src/review-target.txt` | PASS | fake review fixture |'
family_rows='| 测试/证据 | 已覆盖 | fake review fixture |'
issue_location='src/review-target.txt'
tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [已修复] | fixed | verified |'
tracking_note=""
if [ "${FAKE_REVIEW_INCLUDE_STATUS_NOTE:-0}" = "1" ]; then
    tracking_note=$'> 每轮修复后，在此更新对应缺陷的状态。阻塞缺陷未修复时标记为 `[待修复]`，Minor 未处理时标记为 `[可选]`，已修复项标记为 `[已修复]`。\n'
fi
if grep -q 'plan_repos 模式' "$prompt_file"; then
    omitted_repo="${FAKE_WORKSPACE_REPORT_OMIT_REPO:-}"
    context_body='| 项目 | 内容 |
|------|------|
| Plan 文件 | `'"$plan_file"'` |'
    verification_rows=""
    family_rows='| 测试/证据 | 已覆盖 | fake plan_repos review fixture |'
    issue_location=""
    while IFS=$'\t' read -r repo_id repo_path git_root; do
        [ -n "$repo_id" ] || continue
        repo_changes="$(git -C "$git_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
        repo_reviewable_paths="$(printf '%s\n' "$repo_changes" | awk -v prefix="${repo_id}/" '
            {
                path = substr($0, 4)
                if (path ~ /^\.ai-flow\//) {
                    next
                }
                print prefix path
            }
        ')"
        repo_first_path="$(printf '%s\n' "$repo_reviewable_paths" | sed -n '1p')"
        [ -n "$repo_first_path" ] || continue
        if [ -n "$omitted_repo" ] && [ "$repo_id" = "$omitted_repo" ]; then
            continue
        fi
        if [ -z "$issue_location" ]; then
            issue_location="$repo_first_path"
        fi
        context_body="${context_body}
| Dirty Repo | \`${repo_id}\` (\`${repo_path}\`) |"
        verification_target="${repo_first_path#${repo_id}/}"
        verification_rows="${verification_rows}
| \`git -C ${git_root} diff -- ${verification_target}\` | PASS | ${repo_id} 定向验证证据 |"
        family_rows="${family_rows}
| ${repo_id}/测试/证据 | 已覆盖 | 已检查 \`${repo_first_path}\` |"
    done < <(grep -E 'repo=`[^`]+` path=`[^`]+` git_root=`[^`]+`' "$prompt_file" | sed -E 's/.*repo=`([^`]+)` path=`([^`]+)` git_root=`([^`]+)`.*/\1\t\2\t\3/')
    context_body="${context_body}
| 上一轮报告 | 无 |
| 验证证据 | fake plan_repos review fixture |"
    if [ -z "$verification_rows" ]; then
        verification_rows='| `git status --porcelain` | PASS | fake plan_repos review fixture |'
    fi
    if [ -z "$issue_location" ]; then
        issue_location='repo-alpha/src/review-target.txt'
    fi
fi
if [ "$result" = "failed" ]; then
    overall="需要修复"
    conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
    conclusion_notes="- [ ] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
    conclusion_fix="- [x] **需要修复** — 存在以下问题需要处理"
    case "$failed_route_mode" in
        optimize)
            severe_rows="| DEF-1 | Important | ${issue_location} | problem | impact | fix | ai-flow-code-optimize | [待修复] |"
            ;;
        mixed)
            severe_rows="| DEF-1 | Important | ${issue_location} | problem | impact | fix | ai-flow-code-optimize | [待修复] |
| DEF-2 | Important | ${issue_location} | another problem | impact | fix | ai-flow-plan-coding | [待修复] |"
            ;;
        coding|*)
            severe_rows="| DEF-1 | Important | ${issue_location} | problem | impact | fix | ai-flow-plan-coding | [待修复] |"
            ;;
    esac
    tracking='| 缺陷编号 | 首次发现轮次 | 当前状态 | 修复说明 | 验证结果 |
|----------|------------|----------|----------|----------|
| DEF-1 | v1 | [待修复] | | |'
elif [ "$result" = "passed_with_notes" ]; then
    overall="总体通过（附建议）"
    conclusion_pass="- [ ] **通过** — 所有步骤已实现，无严重缺陷"
    conclusion_notes="- [x] **通过（附建议）** — 所有阻塞缺陷已关闭，仍有 Minor 建议可选处理"
    suggest_rows="| SUG-1 | Minor | ${issue_location} | suggestion | refine | ai-flow-code-optimize | [可选] |"
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

$context_body

### 1.2 定向验证执行证据

| 命令 | 结果 | 结论 |
|------|------|------|
$verification_rows

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
$family_rows

## 4. 缺陷清单

### 4.1 严重缺陷

| # | 严重级别 | 位置 | 描述 | 证据/影响 | 修复建议 | 修复流向 | 修复状态 |
|---|----------|------|------|-----------|----------|----------|----------|
$severe_rows

### 4.2 建议改进

| # | 严重级别 | 位置 | 描述 | 建议 | 修复流向 | 修复状态 |
|---|----------|------|------|------|----------|----------|
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

# ─── Plan-scoped multi-repo fixture helpers ───

setup_workspace_root() {
    local workspace_root="$1"
    local workspace_name="${2:-workspace-test}"
    local date_dir="${3:-20260503}"
    mkdir -p "$workspace_root/.ai-flow/state/.locks" \
             "$workspace_root/.ai-flow/plans/$date_dir" \
             "$workspace_root/.ai-flow/reports/$date_dir"
}

setup_workspace_git_repos() {
    local workspace_root="$1"
    local repo
    if ! git -C "$workspace_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        (
            cd "$workspace_root" || exit 1
            git init -q
            git config user.email test@example.com
            git config user.name Test
            git add .ai-flow
            git commit -q --allow-empty -m "init owner"
        )
    fi
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

setup_workspace_root_with_repos() {
    local workspace_root="$1"
    local workspace_name="${2:-workspace-test}"
    local date_dir="${3:-20260503}"
    local repo_ids=() repo_paths=()
    shift 3 || return 1
    while [ $# -gt 0 ]; do
        repo_ids+=("${1%%::*}")
        repo_paths+=("${1#*::}")
        shift
    done
    if [ ${#repo_ids[@]} -eq 0 ]; then
        repo_ids=("repo-alpha" "repo-beta")
        repo_paths=("repo-alpha" "repo-beta")
    fi

    mkdir -p "$workspace_root/.ai-flow/state/.locks" \
             "$workspace_root/.ai-flow/plans/$date_dir" \
             "$workspace_root/.ai-flow/reports/$date_dir"
    if ! git -C "$workspace_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        (
            cd "$workspace_root" || exit 1
            git init -q
            git config user.email test@example.com
            git config user.name Test
            git add .ai-flow
            git commit -q --allow-empty -m "init owner"
        )
    fi
}

setup_workspace_single_git_repo() {
    local workspace_root="$1"
    local repo_name="$2"
    mkdir -p "$workspace_root/$repo_name/src"
    printf '{ "name": "%s" }\n' "$repo_name" > "$workspace_root/$repo_name/package.json"
    (
        cd "$workspace_root/$repo_name" || exit 1
        git init -q
        git config user.email test@example.com
        git config user.name Test
        git add .
        git commit -q -m "init $repo_name"
    )
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
    local plan_file=".ai-flow/plans/${date_dir}-${slug}.md"
    local repo_scope
    create_plan_file "$workspace_root" "$slug" "$date_dir" "$title"
    repo_scope="$(repo_scope_json "$workspace_root" "owner::." "repo-alpha::repo-alpha" "repo-beta::repo-beta")"

    (
        cd "$workspace_root" || exit 1
        bash "$flow_state_script" create --slug "$slug" --title "$title" --plan-file "$plan_file" \
            --repo-scope-json "$repo_scope" >/dev/null
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

write_simple_test_runner() {
    local repo_root="$1"
    mkdir -p "$repo_root/tests"
cat > "$repo_root/tests/run.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
if find src tests -type f ! -path "tests/run.sh" 2>/dev/null | xargs grep -l "<<<<<<< " >/dev/null 2>&1; then
    echo "merge conflict markers found" >&2
    exit 1
fi
echo "ok"
EOF
    chmod +x "$repo_root/tests/run.sh"
}

setup_git_remote_pair() {
    local base_dir="$1"
    local name="$2"
    local remote_dir="$base_dir/${name}-remote.git"
    local seed_dir="$base_dir/${name}-seed"
    local work_dir="$base_dir/${name}-work"

    git init -q --bare "$remote_dir"
    mkdir -p "$seed_dir"
    printf '{ "name": "%s" }\n' "$name" > "$seed_dir/package.json"
    mkdir -p "$seed_dir/src"
    printf 'base\n' > "$seed_dir/src/app.txt"
    (
        cd "$seed_dir" || exit 1
        git init -q
        git config user.email test@example.com
        git config user.name Test
        git add .
        git commit -q -m "init $name"
        git branch -M main
        git remote add origin "$remote_dir"
        git push -q -u origin main
    )
    git --git-dir="$remote_dir" symbolic-ref HEAD refs/heads/main
    git clone -q "$remote_dir" "$work_dir"
    (
        cd "$work_dir" || exit 1
        git config user.email test@example.com
        git config user.name Test
    )
    write_simple_test_runner "$work_dir"
    printf '%s\n' "$work_dir"
}

make_remote_change() {
    local remote_dir="$1"
    local target_file="$2"
    local content="$3"
    local temp_clone
    temp_clone="$(mktemp -d)"
    git clone -q "$remote_dir" "$temp_clone"
    (
        cd "$temp_clone" || exit 1
        git config user.email test@example.com
        git config user.name Test
        mkdir -p "$(dirname "$target_file")"
        printf '%s\n' "$content" > "$target_file"
        git add "$target_file"
        git commit -q -m "remote update"
        git push -q
    )
    rm -rf "$temp_clone"
}

write_plan_repos_commit_plan() {
    local workspace_root="$1"
    local slug="$2"
    local date_dir="${3:-20260503}"
    local include_dependency_table="${4:-1}"
    cat > "$workspace_root/.ai-flow/plans/${date_dir}-${slug}.md" <<PLAN
# 实施计划：$slug

> 创建日期：2026-05-03
> 需求简称：$slug
> 需求来源：测试
> 执行范围：plan_repos
> Plan 参与仓库：owner (path: ., role: owner), repo-alpha (path: repo-alpha, role: participant), repo-beta (path: repo-beta, role: participant)
> 状态文件：\`.ai-flow/state/$slug.json\`

## 1. 需求概述

**目标**：测试提交流程。

**背景**：用于验证 ai-flow-git-commit。

**原始需求（原文）**：
测试。

**非目标**：无。

## 2. 技术分析

### 2.1 涉及模块

| 模块 | 仓库 | 职责 | 变更类型 |
|------|------|------|----------|
| \`src/alpha.txt\` | repo-alpha | alpha 业务 | 修改 |
| \`src/beta.txt\` | repo-beta | beta 业务 | 修改 |

### 2.2 数据模型变更

无。

### 2.3 API 变更

无。

### 2.4 依赖影响

无。

### 2.5 文件边界总览

| 文件 | 仓库 | 操作 | 职责 | 对应步骤 |
|------|------|------|------|----------|
| \`src/alpha.txt\` | repo-alpha | Modify | alpha 业务 | Step 1 |
| \`tests/run.sh\` | repo-alpha | Test | alpha 验证 | Step 1 |
| \`src/beta.txt\` | repo-beta | Modify | beta 业务 | Step 2 |
| \`tests/run.sh\` | repo-beta | Test | beta 验证 | Step 2 |
PLAN
    if [ "$include_dependency_table" = "1" ]; then
        cat >> "$workspace_root/.ai-flow/plans/${date_dir}-${slug}.md" <<'PLAN'

### 2.5 跨仓依赖表

| 先提交仓库 | 后提交仓库 | 原因 |
|------------|------------|------|
| repo-beta | repo-alpha | 上游接口先落库 |
PLAN
    fi
    cat >> "$workspace_root/.ai-flow/plans/${date_dir}-${slug}.md" <<'PLAN'

### 2.6 高风险路径与缺陷族

| 高风险能力/路径 | 影响面 | 典型失效模式 | 对应缺陷族 | 必须覆盖的验证方式 |
|----------------|--------|--------------|------------|--------------------|
| 提交流程 | 提交链路 | 误提交流水 | 测试/证据 | `bash tests/run.sh` |

## 3. 实施步骤

### Step 1: 提交 alpha 业务

**目标**：提交 repo-alpha 变更

**文件边界**：
- Modify: `src/alpha.txt` — alpha 业务代码
- Test: `tests/run.sh` — alpha 最小验证

**本轮 review 预期关注面**：
- alpha 业务完整性

**执行动作**：
- [ ] **1.1 运行通过验证**
  - 命令：`bash tests/run.sh`
  - 预期：PASS

**本步关闭条件**：
- `bash tests/run.sh` 通过

**阻塞条件**：
- 无

### Step 2: 提交 beta 业务

**目标**：提交 repo-beta 变更

**文件边界**：
- Modify: `src/beta.txt` — beta 业务代码
- Test: `tests/run.sh` — beta 最小验证

**本轮 review 预期关注面**：
- beta 业务完整性

**执行动作**：
- [ ] **2.1 运行通过验证**
  - 命令：`bash tests/run.sh`
  - 预期：PASS

**本步关闭条件**：
- `bash tests/run.sh` 通过

**阻塞条件**：
- 无

## 4. 测试计划

### 4.1 单元测试

- [ ] `bash tests/run.sh`

### 4.2 集成测试

- [ ] `bash tests/run.sh`

### 4.3 回归验证

- [ ] `bash tests/run.sh`

### 4.4 定向验证矩阵

| 缺陷族 | 目标风险路径 | 定向验证命令 | 验证类型 | 通过标准 |
|--------|--------------|--------------|----------|----------|
| 测试/证据 | 提交流程 | `bash tests/run.sh` | 集成 | 提交前验证通过 |

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
- 是否允许进入 `/ai-flow-plan-coding`：否
- 当前审核轮次：0
- 审核引擎/模型：待审核

### 8.2 偏差与建议

- 待审核

### 8.3 审核历史

- 第 0 轮：初始化 draft，待审核。
PLAN
}
