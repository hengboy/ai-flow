#!/usr/bin/env python3
"""flow_state_cli.py 核心状态机单元测试。"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent.parent / "runtime" / "scripts"
FLOW_STATE_SH = SCRIPT_DIR / "flow-state.sh"
TESTS_LIB = Path(__file__).resolve().parent / "lib"
sys.path.insert(0, str(TESTS_LIB))
from fixtures import TempProject  # noqa: E402


WORKTREE_SNAPSHOT = json.dumps(
    {
        "repos": [
            {
                "repo_id": "owner",
                "entries": [
                    {"path": "runtime/scripts/flow-auto-run.sh", "tokens": ["M"]},
                    {"path": "tests/test_flow_auto_run.sh", "tokens": ["??"]},
                ],
            }
        ]
    },
    ensure_ascii=False,
)


class TestSlugValidation(unittest.TestCase):
    """slug 格式校验测试。"""

    def _run(self, *args, cwd=None):
        result = subprocess.run(
            ["bash", str(FLOW_STATE_SH), *args],
            capture_output=True, text=True, timeout=30,
            cwd=cwd,
        )
        return result

    def test_valid_dated_slug(self):
        r = self._run("show", "--slug", "20260519-test-slug")
        self.assertIn("状态文件不存在", r.stderr)

    def test_valid_semantic_slug_auto_date(self):
        r = self._run("show", "--slug", "user-auth")
        self.assertNotIn("slug 格式非法", r.stderr)

    def test_invalid_slug_with_spaces(self):
        r = self._run("show", "--slug", "has space")
        self.assertIn("slug 格式非法", r.stderr)

    def test_invalid_slug_special_chars(self):
        r = self._run("show", "--slug", "@#!invalid")
        self.assertIn("slug 格式非法", r.stderr)


class TestStateTransition(unittest.TestCase):
    """状态转换全流程测试。"""

    def setUp(self):
        self.proj = TempProject()
        self.slug = "20260519-test-transition"

    def tearDown(self):
        self.proj.cleanup()

    def _run(self, *args):
        return subprocess.run(
            ["bash", str(FLOW_STATE_SH), *args],
            capture_output=True, text=True, timeout=30,
            cwd=self.proj.root, env=self.proj.env,
        )

    def _write_plan(self, content: str):
        plan_dir = self.proj.root / ".ai-flow" / "plans"
        plan_dir.mkdir(parents=True, exist_ok=True)
        (plan_dir / "test.md").write_text(content, encoding="utf-8")

    def _write_report(self, content: str, name: str = "r.md"):
        report_dir = self.proj.root / ".ai-flow" / "reports"
        report_dir.mkdir(parents=True, exist_ok=True)
        (report_dir / name).write_text(content, encoding="utf-8")

    def _review_report(self, *, mode: str = "regular", covered_steps: Optional[List[Tuple[str, str]]] = None) -> str:
        rows = covered_steps or [("step-one", "第一步")]
        coverage_lines = "\n".join(
            f"| `{step_id}`（{title}） | 已实现 | 已覆盖 |"
            for step_id, title in rows
        )
        return f"""# 审查报告：测试功能

> 审查日期：2026-05-19
> 审查时间：10:10:00
> 需求简称：{self.slug}
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

## 2. 计划覆盖度检查

| 实施步骤 | 状态 | 备注 |
|----------|------|------|
{coverage_lines}

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

    def _standard_plan(self, *, all_done: bool = True, step_count: int = 1) -> str:
        action_mark = "x" if all_done else " "
        step_two = f"""

### 第二步

**Step ID**：`step-two`

**目标**：完成第二步

**文件边界**：
- Modify: `b.txt` — test
- Test: `tests/b_test.py` — test

**本轮 review 预期关注面**：test-family

**执行动作**：
- [{action_mark}] **实现**
  - 命令：`echo ok`
  - 预期：PASS

**本步验收**：
- [{action_mark}] 命令成功

**本步关闭条件**：命令通过

**阻塞条件**：- 无
""" if step_count > 1 else ""
        file_boundary_rows = """| `a.txt` | owner | Modify | test | `step-one` |
| `b.txt` | owner | Modify | test | `step-two` |""" if step_count > 1 else "| `a.txt` | owner | Modify | test | `step-one` |"
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

**目标**：验证状态门禁

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
{file_boundary_rows}

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
- [{action_mark}] 命令成功

**本步关闭条件**：命令通过

**阻塞条件**：- 无
{step_two}

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

    def test_plan_review_passed(self):
        self.proj.create_state(self.slug)
        r = self._run("transition", "--slug", self.slug,
                       "--event", "plan_review_passed",
                       "--result", "passed", "--engine", "test-engine", "--model", "test-model")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("PLANNED", r.stdout)

    def test_plan_review_failed(self):
        self.proj.create_state(self.slug)
        r = self._run("transition", "--slug", self.slug,
                       "--event", "plan_review_failed",
                       "--result", "failed", "--engine", "test-engine", "--model", "test-model")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("PLAN_REVIEW_FAILED", r.stdout)

    def test_plan_review_passed_rejects_nonstandard_plan(self):
        self.proj.create_state(self.slug)
        self._write_plan("# 错误计划\n\n## 3. 实施步骤\n\n### 2.1 错误步骤\n")
        r = self._run(
            "transition", "--slug", self.slug, "--event", "plan_review_passed",
            "--result", "passed", "--engine", "e", "--model", "m",
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("plan 结构校验失败", r.stderr)

    def test_full_lifecycle_to_done(self):
        """完整流程: 创建 -> 审核通过 -> 执行 -> 完成 -> 审查通过。"""
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=True))
        self._write_report(self._review_report())
        steps = [
            ("plan_review_passed", ["--result", "passed", "--engine", "e", "--model", "m"]),
            ("execute_started", []),
            ("implementation_completed", []),
            ("review_passed", ["--result", "passed", "--report-file", ".ai-flow/reports/r.md", "--engine", "e", "--model", "m"]),
        ]
        for event, extra in steps:
            r = self._run("transition", "--slug", self.slug, "--event", event, *extra)
            self.assertEqual(r.returncode, 0, f"事件 {event} 失败: {r.stderr}")
        state_file = self.proj.state_dir / f"{self.slug}.json"
        state = json.loads(state_file.read_text(encoding="utf-8"))
        self.assertEqual(state["current_status"], "DONE")

    def test_review_passed_rejects_report_missing_plan_step(self):
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=True, step_count=2))
        self._write_report(self._review_report(covered_steps=[("step-one", "第一步")]))
        steps = [
            ("plan_review_passed", ["--result", "passed", "--engine", "e", "--model", "m"]),
            ("execute_started", []),
            ("implementation_completed", []),
        ]
        for event, extra in steps:
            r = self._run("transition", "--slug", self.slug, "--event", event, *extra)
            self.assertEqual(r.returncode, 0, f"事件 {event} 失败: {r.stderr}")

        r = self._run(
            "transition", "--slug", self.slug, "--event", "review_passed",
            "--result", "passed", "--report-file", ".ai-flow/reports/r.md",
            "--engine", "e", "--model", "m",
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("报告覆盖度校验失败", r.stderr)
        self.assertIn("缺少以下 plan 步骤: step-two", r.stderr)

    def test_implementation_completed_rejects_nonstandard_plan(self):
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=True))
        self._run("transition", "--slug", self.slug, "--event", "plan_review_passed",
                  "--result", "passed", "--engine", "e", "--model", "m")
        self._run("transition", "--slug", self.slug, "--event", "execute_started")
        self._write_plan("# 错误计划\n\n## 3. 实施步骤\n\n### 2.1 错误步骤\n")
        r = self._run("transition", "--slug", self.slug, "--event", "implementation_completed")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("plan 结构校验失败", r.stderr)

    def test_implementation_completed_rejects_incomplete_plan(self):
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=False))
        self._run("transition", "--slug", self.slug, "--event", "plan_review_passed",
                  "--result", "passed", "--engine", "e", "--model", "m")
        self._run("transition", "--slug", self.slug, "--event", "execute_started")
        r = self._run("transition", "--slug", self.slug, "--event", "implementation_completed")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("plan 完成度校验失败", r.stderr)

    def test_transition_count_seq(self):
        """验证 transition 的 seq 自动递增。"""
        self.proj.create_state(self.slug)
        self._run("transition", "--slug", self.slug, "--event", "plan_review_passed",
                   "--result", "passed", "--engine", "e", "--model", "m")
        self._run("transition", "--slug", self.slug, "--event", "execute_started")
        state_file = self.proj.state_dir / f"{self.slug}.json"
        state = json.loads(state_file.read_text(encoding="utf-8"))
        seqs = [t["seq"] for t in state["transitions"]]
        self.assertEqual(seqs, [1, 2, 3])

    def test_invalid_transition_from_wrong_state(self):
        self.proj.create_state(self.slug)
        r = self._run("transition", "--slug", self.slug, "--event", "execute_started")
        self.assertNotEqual(r.returncode, 0)

    def test_fix_started_requires_failed_review(self):
        """fix_started 之前必须有失败的审查。"""
        self.proj.create_state(self.slug)
        r = self._run("transition", "--slug", self.slug, "--event", "fix_started")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("非法迁移", r.stderr)

    def test_plan_reopened_from_planned(self):
        self.proj.create_state(self.slug)
        self._run("transition", "--slug", self.slug, "--event", "plan_review_passed",
                   "--result", "passed", "--engine", "e", "--model", "m")
        r = self._run("transition", "--slug", self.slug, "--event", "plan_reopened",
                       "--note", "需求变更")
        self.assertEqual(r.returncode, 0)
        self.assertIn("AWAITING_PLAN_REVIEW", r.stdout)

    def test_recheck_from_done(self):
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=True))
        self._write_report(self._review_report())
        steps = [
            ("plan_review_passed", ["--result", "passed", "--engine", "e", "--model", "m"]),
            ("execute_started", []),
            ("implementation_completed", []),
            ("review_passed", ["--result", "passed", "--report-file", ".ai-flow/reports/r.md", "--engine", "e", "--model", "m"]),
        ]
        for event, extra in steps:
            self._run("transition", "--slug", self.slug, "--event", event, *extra)
        r = self._run("transition", "--slug", self.slug, "--event", "recheck_failed",
                       "--result", "failed", "--report-file", ".ai-flow/reports/r2.md", "--engine", "e", "--model", "m")
        self.assertEqual(r.returncode, 0)
        self.assertIn("REVIEW_FAILED", r.stdout)

    def test_review_passed_accepts_worktree_snapshot(self):
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=True))
        self._write_report(self._review_report())
        steps = [
            ("plan_review_passed", ["--result", "passed", "--engine", "e", "--model", "m"]),
            ("execute_started", []),
            ("implementation_completed", []),
        ]
        for event, extra in steps:
            r = self._run("transition", "--slug", self.slug, "--event", event, *extra)
            self.assertEqual(r.returncode, 0, f"事件 {event} 失败: {r.stderr}")

        r = self._run(
            "transition", "--slug", self.slug, "--event", "review_passed",
            "--result", "passed", "--report-file", ".ai-flow/reports/r.md",
            "--engine", "e", "--model", "m",
            "--worktree-snapshot-json", WORKTREE_SNAPSHOT,
        )
        self.assertEqual(r.returncode, 0, r.stderr)

        state_file = self.proj.state_dir / f"{self.slug}.json"
        state = json.loads(state_file.read_text(encoding="utf-8"))
        payload = state["transitions"][-1]["payload"]
        self.assertIn("worktree_snapshot", payload)
        self.assertEqual(payload["worktree_snapshot"]["repos"][0]["repo_id"], "owner")

    def test_review_failed_rejects_worktree_snapshot(self):
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=True))
        steps = [
            ("plan_review_passed", ["--result", "passed", "--engine", "e", "--model", "m"]),
            ("execute_started", []),
            ("implementation_completed", []),
        ]
        for event, extra in steps:
            r = self._run("transition", "--slug", self.slug, "--event", event, *extra)
            self.assertEqual(r.returncode, 0, f"事件 {event} 失败: {r.stderr}")

        r = self._run(
            "transition", "--slug", self.slug, "--event", "review_failed",
            "--result", "failed", "--report-file", ".ai-flow/reports/r.md",
            "--engine", "e", "--model", "m",
            "--worktree-snapshot-json", WORKTREE_SNAPSHOT,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("失败事件不接受参数 --worktree-snapshot-json", r.stderr)

    def test_review_passed_rejects_invalid_worktree_snapshot(self):
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=True))
        self._write_report(self._review_report())
        steps = [
            ("plan_review_passed", ["--result", "passed", "--engine", "e", "--model", "m"]),
            ("execute_started", []),
            ("implementation_completed", []),
        ]
        for event, extra in steps:
            r = self._run("transition", "--slug", self.slug, "--event", event, *extra)
            self.assertEqual(r.returncode, 0, f"事件 {event} 失败: {r.stderr}")

        bad_snapshot = json.dumps({"repos": [{"repo_id": "owner", "entries": [{"path": "", "tokens": ["M"]}]}]})
        r = self._run(
            "transition", "--slug", self.slug, "--event", "review_passed",
            "--result", "passed", "--report-file", ".ai-flow/reports/r.md",
            "--engine", "e", "--model", "m",
            "--worktree-snapshot-json", bad_snapshot,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("path 不能为空", r.stderr)

    def test_review_passed_accepts_real_git_status_tokens(self):
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=True))
        self._write_report(self._review_report())
        steps = [
            ("plan_review_passed", ["--result", "passed", "--engine", "e", "--model", "m"]),
            ("execute_started", []),
            ("implementation_completed", []),
        ]
        for event, extra in steps:
            r = self._run("transition", "--slug", self.slug, "--event", event, *extra)
            self.assertEqual(r.returncode, 0, f"事件 {event} 失败: {r.stderr}")

        snapshot = json.dumps({
            "repos": [
                {
                    "repo_id": "owner",
                    "entries": [
                        {"path": "README.md", "tokens": ["??"]},
                        {"path": "src/app.js", "tokens": ["MM"]},
                    ],
                }
            ]
        }, ensure_ascii=False)
        r = self._run(
            "transition", "--slug", self.slug, "--event", "review_passed",
            "--result", "passed", "--report-file", ".ai-flow/reports/r.md",
            "--engine", "e", "--model", "m",
            "--worktree-snapshot-json", snapshot,
        )
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_review_passed_rejects_snapshot_repo_mismatch(self):
        self.proj.create_state(self.slug)
        self._write_plan(self._standard_plan(all_done=True))
        self._write_report(self._review_report())
        steps = [
            ("plan_review_passed", ["--result", "passed", "--engine", "e", "--model", "m"]),
            ("execute_started", []),
            ("implementation_completed", []),
        ]
        for event, extra in steps:
            r = self._run("transition", "--slug", self.slug, "--event", event, *extra)
            self.assertEqual(r.returncode, 0, f"事件 {event} 失败: {r.stderr}")

        mismatch_snapshot = json.dumps({
            "repos": [
                {
                    "repo_id": "other-repo",
                    "entries": [{"path": "README.md", "tokens": ["M"]}],
                }
            ]
        }, ensure_ascii=False)
        r = self._run(
            "transition", "--slug", self.slug, "--event", "review_passed",
            "--result", "passed", "--report-file", ".ai-flow/reports/r.md",
            "--engine", "e", "--model", "m",
            "--worktree-snapshot-json", mismatch_snapshot,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("必须与 execution_scope.repos 完全一致", r.stderr)


class TestShowCommand(unittest.TestCase):
    """show 子命令测试。"""

    def setUp(self):
        self.proj = TempProject()
        self.slug = "20260519-test-show"

    def tearDown(self):
        self.proj.cleanup()

    def _run(self, *args):
        return subprocess.run(
            ["bash", str(FLOW_STATE_SH), *args],
            capture_output=True, text=True, timeout=30,
            cwd=self.proj.root, env=self.proj.env,
        )

    def test_show_full_state(self):
        self.proj.create_state(self.slug)
        r = self._run("show", "--slug", self.slug)
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        self.assertEqual(data["slug"], self.slug)
        self.assertIn("derived", data)

    def test_show_field(self):
        self.proj.create_state(self.slug)
        r = self._run("show", "--slug", self.slug, "--field", "current_status")
        self.assertEqual(r.stdout.strip(), "AWAITING_PLAN_REVIEW")

    def test_show_field_nested(self):
        self.proj.create_state(self.slug)
        r = self._run("show", "--slug", self.slug, "--field", "execution_scope.mode")
        self.assertEqual(r.stdout.strip(), "plan_repos")

    def test_show_raw(self):
        self.proj.create_state(self.slug)
        r = self._run("show", "--slug", self.slug, "--raw")
        data = json.loads(r.stdout)
        self.assertNotIn("derived", data)

    def test_show_all(self):
        self.proj.create_state("20260519-test-a")
        self.proj.create_state("20260519-test-b")
        r = self._run("show", "--all")
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        self.assertEqual(len(data), 2)


class TestValidateCommand(unittest.TestCase):
    """validate 子命令测试。"""

    def setUp(self):
        self.proj = TempProject()
        self.slug = "20260519-test-validate"

    def tearDown(self):
        self.proj.cleanup()

    def _run(self, *args):
        return subprocess.run(
            ["bash", str(FLOW_STATE_SH), *args],
            capture_output=True, text=True, timeout=30,
            cwd=self.proj.root, env=self.proj.env,
        )

    def test_validate_missing_fields(self):
        state = {"schema_version": 4, "slug": self.slug}
        (self.proj.state_dir / f"{self.slug}.json").write_text(json.dumps(state), encoding="utf-8")
        r = self._run("validate", "--slug", self.slug)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("缺少字段", r.stderr)

    def test_validate_invalid_status_value(self):
        self.proj.create_state(self.slug, current_status="INVALID_STATUS")
        r = self._run("validate", "--slug", self.slug)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("非法", r.stderr)

    def test_validate_valid_state(self):
        self.proj.create_state(self.slug)
        r = self._run("validate", "--slug", self.slug)
        self.assertEqual(r.returncode, 0)
        self.assertIn("OK", r.stdout)

    def test_validate_bad_json(self):
        (self.proj.state_dir / f"{self.slug}.json").write_text("{bad json}", encoding="utf-8")
        r = self._run("validate", "--slug", self.slug)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("损坏", r.stderr)

    def test_validate_all(self):
        self.proj.create_state("20260519-val-a")
        self.proj.create_state("20260519-val-b")
        r = self._run("validate", "--all")
        self.assertEqual(r.returncode, 0)
        self.assertIn("OK", r.stdout)


class TestDerivedState(unittest.TestCase):
    """derived 字段推导测试。"""

    def setUp(self):
        self.proj = TempProject()
        self.slug = "20260519-test-derived"

    def tearDown(self):
        self.proj.cleanup()

    def _run(self, *args):
        return subprocess.run(
            ["bash", str(FLOW_STATE_SH), *args],
            capture_output=True, text=True, timeout=30,
            cwd=self.proj.root, env=self.proj.env,
        )

    def _create_with_review(self):
        self.proj.create_state(self.slug)
        plan_dir = self.proj.root / ".ai-flow" / "plans"
        plan_dir.mkdir(parents=True, exist_ok=True)
        (plan_dir / "test.md").write_text(
            TestStateTransition._standard_plan(self, all_done=True),
            encoding="utf-8",
        )
        report_dir = self.proj.root / ".ai-flow" / "reports"
        report_dir.mkdir(parents=True, exist_ok=True)
        (report_dir / "r1.md").write_text(
            TestStateTransition._review_report(self),
            encoding="utf-8",
        )
        steps = [
            ("plan_review_passed", ["--result", "passed", "--engine", "e", "--model", "m"]),
            ("execute_started", []),
            ("implementation_completed", []),
            ("review_passed", ["--result", "passed", "--report-file", ".ai-flow/reports/r1.md", "--engine", "e", "--model", "m"]),
        ]
        for event, extra in steps:
            r = self._run("transition", "--slug", self.slug, "--event", event, *extra)
            self.assertEqual(r.returncode, 0, f"事件 {event} 失败: {r.stderr}")

    def _create_with_recheck(self):
        self._create_with_review()
        r = self._run("transition", "--slug", self.slug, "--event", "recheck_failed",
                       "--result", "failed", "--report-file", ".ai-flow/reports/r2.md",
                       "--engine", "e", "--model", "m")
        self.assertEqual(r.returncode, 0)

    def test_derived_review_rounds(self):
        self._create_with_review()
        r = self._run("show", "--slug", self.slug, "--field", "derived.review_rounds")
        data = json.loads(r.stdout)
        self.assertEqual(data["regular"], 1)
        self.assertEqual(data["recheck"], 0)

    def test_derived_next_events(self):
        self._create_with_review()
        r = self._run("show", "--slug", self.slug, "--field", "derived.next_events")
        data = json.loads(r.stdout)
        self.assertIn("recheck_passed", data)
        self.assertIn("recheck_failed", data)
        self.assertIn("implementation_reopened", data)

    def test_derived_last_review(self):
        self._create_with_review()
        r = self._run("show", "--slug", self.slug, "--field", "derived.last_review")
        data = json.loads(r.stdout)
        self.assertEqual(data["mode"], "regular")
        self.assertEqual(data["result"], "passed")
        self.assertEqual(data["report_file"], ".ai-flow/reports/r1.md")

    def test_derived_active_fix(self):
        """FIXING_REVIEW 下 active_fix 应有值。"""
        self._create_with_review()
        self._run("transition", "--slug", self.slug, "--event", "recheck_failed",
                   "--result", "failed", "--report-file", ".ai-flow/reports/r2.md",
                   "--engine", "e", "--model", "m")
        self._run("transition", "--slug", self.slug, "--event", "fix_started")
        r = self._run("show", "--slug", self.slug, "--field", "derived.active_fix")
        data = json.loads(r.stdout)
        self.assertIsNotNone(data)
        self.assertIn("report_file", data)


class TestActorConfig(unittest.TestCase):
    """actor 字段通过用户级 setting.json 配置加载的测试。
    注：项目级 setting.json 支持待后续实现。
    """

    def setUp(self):
        self.proj = TempProject()
        self.slug = "20260519-test-actor"
        self.home_dir = tempfile.mkdtemp()
        self.test_env = dict(self.proj.env)
        self.test_env["AI_FLOW_HOME"] = self.home_dir

    def tearDown(self):
        self.proj.cleanup()
        shutil.rmtree(self.home_dir)

    def _run(self, *args):
        return subprocess.run(
            ["bash", str(FLOW_STATE_SH), *args],
            capture_output=True, text=True, timeout=30,
            cwd=self.proj.root, env=self.test_env,
        )

    def test_default_actor(self):
        """无 setting.json 时使用默认 actor。"""
        self.proj.create_state(self.slug)
        self._run("transition", "--slug", self.slug, "--event", "plan_review_passed",
                   "--result", "passed", "--engine", "test-engine", "--model", "test-model")
        state_file = self.proj.state_dir / f"{self.slug}.json"
        state = json.loads(state_file.read_text(encoding="utf-8"))
        actor = state["transitions"][-1]["actor"]
        self.assertNotEqual(actor, "")

    def test_user_level_actor(self):
        """用户级 setting.json 的 state.actor 生效。"""
        self.proj.create_user_setting(self.home_dir, state={"actor": "user-actor"})
        self.proj.create_state(self.slug)
        self._run("transition", "--slug", self.slug, "--event", "plan_review_passed",
                   "--result", "passed", "--engine", "test-engine", "--model", "test-model")
        state_file = self.proj.state_dir / f"{self.slug}.json"
        state = json.loads(state_file.read_text(encoding="utf-8"))
        actor = state["transitions"][-1]["actor"]
        self.assertEqual(actor, "user-actor")

    def test_project_actor_override(self):
        """项目级 setting.json 的 state.actor 覆盖用户级。"""
        self.proj.create_user_setting(self.home_dir, state={"actor": "user-actor"})
        self.proj.create_project_setting(state={"actor": "project-actor"})
        self.proj.create_state(self.slug)
        self._run("transition", "--slug", self.slug, "--event", "plan_review_passed",
                   "--result", "passed", "--engine", "test-engine", "--model", "test-model")
        state_file = self.proj.state_dir / f"{self.slug}.json"
        state = json.loads(state_file.read_text(encoding="utf-8"))
        actor = state["transitions"][-1]["actor"]
        self.assertEqual(actor, "project-actor")


if __name__ == "__main__":
    unittest.main()
