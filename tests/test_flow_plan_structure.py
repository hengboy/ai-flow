#!/usr/bin/env python3
"""plan 结构与完成度校验测试。"""

import tempfile
import unittest
from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "subagents" / "shared" / "lib"))

from flow_utils import FlowUtils  # noqa: E402


def build_plan(action_mark: str = "x", acceptance_mark: str = "x") -> str:
    return f"""# 实施计划：测试功能

> 创建日期：2026-05-19
> 创建时间：10:00:00
> 需求简称：测试功能
> 需求来源：单元测试
> 执行范围：owner
> Plan 参与仓库：owner
> 状态文件：.ai-flow/state/test.json
> 文档角色：实施计划
> 状态文件约束：仅 flow-state.sh transition 可修改
> 执行约定：按 Step 顺序执行
> 验证约定：运行计划中的验证命令
> 规则标识：test

## 1. 需求概述

**目标**：验证结构

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

**目标**：完成测试步骤

**文件边界**：
- Modify: `a.txt` — test
- Test: `tests/a_test.py` — test

**本轮 review 预期关注面**：test-family

**执行动作**：
- [{action_mark}] **实现**
  - 命令：`echo ok`
  - 预期：PASS

**本步验收**：
- [{acceptance_mark}] 命令成功

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
"""


def build_report(*, rows: list[str], mode: str = "regular", section_title: str = "## 2. 计划覆盖度检查") -> str:
    coverage_rows = "\n".join(rows)
    return f"""# 审查报告：测试功能

> 审查日期：2026-05-19
> 审查时间：10:10:00
> 需求简称：test
> 审查模式：{mode}
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

{section_title}

| 实施步骤 | 状态 | 备注 |
|----------|------|------|
{coverage_rows}

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

- [x] **通过** — 所有步骤已实现，无严重缺陷

## 6. 缺陷修复追踪

无
"""


class TestFlowPlanStructure(unittest.TestCase):
    def _write_temp_plan(self, content: str) -> str:
        tmpdir = tempfile.mkdtemp()
        path = Path(tmpdir) / "plan.md"
        path.write_text(content, encoding="utf-8")
        return str(path)

    def _write_temp_report(self, content: str) -> str:
        tmpdir = tempfile.mkdtemp()
        path = Path(tmpdir) / "report.md"
        path.write_text(content, encoding="utf-8")
        return str(path)

    def test_validate_plan_structure_passes_for_standard_plan(self):
        path = self._write_temp_plan(build_plan())
        self.assertEqual(FlowUtils.validate_plan_structure(path), [])

    def test_validate_plan_structure_fails_for_legacy_numbered_step_without_fields(self):
        path = self._write_temp_plan("# 错误计划\n\n## 3. 实施步骤\n\n### 2.1 删除旧测试\n")
        errors = FlowUtils.validate_plan_structure(path)
        self.assertTrue(errors)
        self.assertIn("plan 实施步骤结构不符合标准模板", errors[0])

    def test_validate_plan_completion_fails_when_actions_pending(self):
        path = self._write_temp_plan(build_plan(action_mark=" ", acceptance_mark="x"))
        errors = FlowUtils.validate_plan_completion(path)
        self.assertTrue(errors)
        self.assertIn("仍有未完成执行动作", errors[0])

    def test_validate_plan_completion_fails_when_acceptance_pending(self):
        path = self._write_temp_plan(build_plan(action_mark="x", acceptance_mark=" "))
        errors = FlowUtils.validate_plan_completion(path)
        self.assertTrue(errors)
        self.assertIn("仍有未完成验收项", errors[0])

    def test_validate_plan_coverage_passes_for_matching_report(self):
        plan = self._write_temp_plan(build_plan())
        report = self._write_temp_report(
            build_report(rows=["| `step-one`（第一步） | 已实现 | 已覆盖 |"])
        )
        self.assertEqual(FlowUtils.validate_plan_coverage(plan, report), [])

    def test_validate_plan_coverage_fails_when_step_missing(self):
        plan = self._write_temp_plan(
            build_plan().replace(
                "| `a.txt` | owner | Modify | test | `step-one` |",
                "| `a.txt` | owner | Modify | test | `step-one` |\n| `b.txt` | owner | Modify | test | `step-two` |",
            ).replace(
                "## 4. 测试计划",
                """
### 第二步

**Step ID**：`step-two`

**目标**：第二步

**文件边界**：
- Modify: `b.txt` — test
- Test: `tests/b_test.py` — test

**本轮 review 预期关注面**：test-family

**执行动作**：
- [x] **实现**
  - 命令：`echo ok`
  - 预期：PASS

**本步验收**：
- [x] 命令成功

**本步关闭条件**：命令通过

**阻塞条件**：- 无

## 4. 测试计划""",
            )
        )
        report = self._write_temp_report(
            build_report(rows=["| `step-one`（第一步） | 已实现 | 已覆盖 |"])
        )
        errors = FlowUtils.validate_plan_coverage(plan, report)
        self.assertTrue(errors)
        self.assertIn("缺少以下 plan 步骤: step-two", errors[0])

    def test_validate_plan_coverage_accepts_legacy_full_section_title(self):
        plan = self._write_temp_plan(build_plan())
        report = self._write_temp_report(
            build_report(
                rows=["| `step-one`（第一步） | **已实现** | 已覆盖 |"],
                section_title="## 2. 计划覆盖度检查（全量）",
            )
        )
        self.assertEqual(FlowUtils.validate_plan_coverage(plan, report), [])


if __name__ == "__main__":
    unittest.main()
