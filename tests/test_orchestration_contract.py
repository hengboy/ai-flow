#!/usr/bin/env python3
"""Contract tests for multi-plan orchestration docs."""

import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent


class OrchestrationContractTest(unittest.TestCase):
    def test_git_commit_has_noninteractive_orchestration_rule(self) -> None:
        content = (PROJECT_ROOT / "skills" / "ai-flow-git-commit" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("编排非交互模式", content)
        self.assertIn("pull conflict", content)
        self.assertIn("额外改动不明", content)
        self.assertIn("必须失败返回", content)
        self.assertIn("不得进入交互式取舍", content)

    def test_auto_run_still_does_not_commit(self) -> None:
        content = (PROJECT_ROOT / "skills" / "ai-flow-auto-run" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("不覆盖 plan 生成、plan review 和 git commit", content)
        self.assertIn("ai-flow-git-commit", content)
        self.assertIn("不自动提交代码", content)

    def test_orchestrate_skill_declares_queue_contract(self) -> None:
        content = (PROJECT_ROOT / "skills" / "ai-flow-plan-orchestrate" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("/ai-flow-plan-orchestrate --queue", content)
        self.assertIn(".ai-flow/orchestrations/state/{queue_slug}.json", content)
        self.assertIn("ai-flow-auto-run", content)
        self.assertIn("ai-flow-git-commit <active_slug>", content)
        self.assertIn("flow-plan-orchestrate-launch.sh", content)


if __name__ == "__main__":
    unittest.main()
