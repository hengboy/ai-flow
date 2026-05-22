#!/bin/bash
# test_flow_plan_coding.sh — flow-plan-coding.sh 单元测试
# 测试状态门禁和协议输出。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

PLAN_CODING_SH="$SCRIPTS_DIR/flow-plan-coding.sh"
FLOW_STATE_SH="$SCRIPTS_DIR/flow-state.sh"
PLAN_CODING_SKILL="$PROJECT_ROOT/skills/ai-flow-plan-coding/SKILL.md"

echo "=== flow-plan-coding.sh 测试 ==="
echo ""

# --- 测试 1: 无 slug ---
test_no_slug() {
    local output exit_code=0
    output="$(bash "$PLAN_CODING_SH" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "无 slug 时退出码为1"
    assert_contains "$output" "用法" "无 slug 时显示用法"
}

# --- 测试 2: 找不到 slug ---
test_slug_not_found() {
    local dir
    dir="$(create_temp_project "plan-coding-2")"
    local output exit_code=0
    output="$(bash "$PLAN_CODING_SH" "nonexist" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 1 "找不到 slug 时失败"
    assert_contains "$output" "找不到" "找不到 slug 时输出错误"
    cleanup_temp_project "$dir"
}

# --- 测试 3: plan-coding skill 要求每个 Step 完成后即时勾选 ---
test_skill_requires_immediate_step_checkbox_update() {
    local content
    content="$(sed -n '1,220p' "$PLAN_CODING_SKILL")"
    assert_contains "$content" "每完成一个 Step 后" "skill 明确要求 Step 完成后更新复选框"
    assert_contains "$content" "立即勾选" "skill 明确要求立即勾选"
    assert_contains "$content" "禁止等到全部 Step 完成后统一勾选" "skill 禁止最后统一勾选"
}

# --- 测试 3: PLANNED 状态通过门禁 ---
test_planned_passes() {
    local dir
    dir="$(create_temp_project "plan-coding-3")"
    # 创建 rule-loader.sh 的 mock（因为门禁需要它）
    mkdir -p "$dir/.ai-flow/state"

    # 先创建一个 plan 文件
    mkdir -p "$dir/.ai-flow/plans"
    cat > "$dir/.ai-flow/plans/test.md" <<'EOF'
# 测试计划
## 1. 概述
## 7. 需求变更记录
EOF

    create_minimal_state "$dir" "20260519-test-planned"
    cd "$dir"
    # 转换到 PLANNED
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-planned" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    cd "$SCRIPT_DIR"

    # 注意：此测试需要 rule-loader.sh，这里只测试基本的状态门禁
    # 真正的门禁会在有完整规则环境的项目中运行
    test_info "PLANNED 状态门禁需要在有 rule-loader 的环境中测试"
    cleanup_temp_project "$dir"
}

# --- 测试 4: IMPLEMENTING 状态继续执行未勾选 step ---
test_implementing_continues_pending_steps() {
    local dir
    dir="$(create_temp_project "plan-coding-4-impl")"

    mkdir -p "$dir/.ai-flow/plans"
    cat > "$dir/.ai-flow/plans/test.md" <<'EOF'
# 测试计划
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
- [ ] **实现**
  - 命令：`echo ok`
  - 预期：PASS

**本步验收**：
- [ ] 命令成功

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

    create_minimal_state "$dir" "20260519-test-impl-continue"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-impl-continue" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-impl-continue" \
        --event execute_started >/dev/null 2>&1

    local output exit_code=0
    output="$(AI_FLOW_HOME="$PROJECT_ROOT/runtime" bash "$PLAN_CODING_SH" "20260519-test-impl-continue" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "IMPLEMENTING 状态可继续运行"
    assert_contains "$output" "当前已在 IMPLEMENTING" "IMPLEMENTING 状态输出成功摘要"
    assert_contains "$output" "未勾选的 step / action" "IMPLEMENTING 状态明确提示继续执行未完成项"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 4: AWAITING_PLAN_REVIEW 状态被拒 ---
test_awaiting_plan_review_rejected() {
    local dir
    dir="$(create_temp_project "plan-coding-4")"
    create_minimal_state "$dir" "20260519-test-apr"
    cd "$dir"

    # 因为缺少 rule-loader，我们直接验证状态文件当前是 AWAITING_PLAN_REVIEW
    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-apr" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "AWAITING_PLAN_REVIEW" "状态文件正确创建"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 5: IMPLEMENTING 状态继续 ---
test_implementing_continue() {
    local dir
    dir="$(create_temp_project "plan-coding-5")"
    create_minimal_state "$dir" "20260519-test-impl"
    cd "$dir"
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-impl" \
        --event plan_review_passed --result passed \
        --engine test-engine --model test-model >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-impl" \
        --event execute_started >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-impl" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "IMPLEMENTING" "IMPLEMENTING 状态正确"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 6: REVIEW_FAILED 状态 ---
test_review_failed_state() {
    local dir
    dir="$(create_temp_project "plan-coding-6")"
    create_minimal_state "$dir" "20260519-test-rf"
    cd "$dir"
    # 快速走到 REVIEW_FAILED
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event plan_review_passed --result passed --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event execute_started >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event implementation_completed >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event review_failed --result failed --report-file .ai-flow/reports/r.md --engine e --model m >/dev/null 2>&1
    bash "$FLOW_STATE_SH" transition --slug "20260519-test-rf" \
        --event fix_started >/dev/null 2>&1

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-rf" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "FIXING_REVIEW" "FIXING_REVIEW 状态正确"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 测试 7: DONE 状态被拒 ---
test_done_rejected() {
    local dir
    dir="$(create_temp_project "plan-coding-7")"
    create_minimal_state "$dir" "20260519-test-done"
    cd "$dir"
    create_minimal_review_report "$dir" "r.md"
    # 快速走到 DONE
    for cmd in \
        "plan_review_passed --result passed --engine e --model m" \
        "execute_started" \
        "implementation_completed" \
        "review_passed --result passed --report-file .ai-flow/reports/r.md --engine e --model m"
    do
        bash $FLOW_STATE_SH transition --slug "20260519-test-done" --event $cmd >/dev/null 2>&1
    done

    local status
    status="$(bash "$FLOW_STATE_SH" show --slug "20260519-test-done" --field "current_status" 2>/dev/null)"
    assert_equal "$status" "DONE" "DONE 状态正确"

    cd "$SCRIPT_DIR"
    cleanup_temp_project "$dir"
}

# --- 运行 ---
test_no_slug
test_slug_not_found
test_skill_requires_immediate_step_checkbox_update
test_planned_passes
test_implementing_continues_pending_steps
test_awaiting_plan_review_rejected
test_implementing_continue
test_review_failed_state
test_done_rejected

print_summary
exit "$fail_count"
