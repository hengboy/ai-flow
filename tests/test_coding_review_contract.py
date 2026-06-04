#!/usr/bin/env python3
"""coding-review 协议回归测试。"""

import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent


class CodingReviewContractTest(unittest.TestCase):
    def test_standalone_review_pass_routes_to_git_commit(self):
        executor = (
            PROJECT_ROOT / "subagents/shared/coding-review/bin/coding-review-executor.sh"
        ).read_text(encoding="utf-8")

        passed_branch = re.search(
            r'if \[ "\$IS_STANDALONE" -eq 1 \]; then.*?case "\$RESULT" in.*?passed\)\s+'
            r'PROTOCOL_NEXT="([^"]+)".*?PROTOCOL_SUMMARY="standalone 审查通过，无状态绑定。"',
            executor,
            re.S,
        )
        self.assertIsNotNone(passed_branch, "未找到 standalone passed 分支")
        self.assertEqual(passed_branch.group(1), "ai-flow-git-commit")

        passed_with_notes_branch = re.search(
            r'passed_with_notes\)\s+PROTOCOL_NEXT="([^"]+)".*?'
            r'PROTOCOL_SUMMARY="standalone 审查通过（附 Minor 建议），无状态绑定。"',
            executor,
            re.S,
        )
        self.assertIsNotNone(
            passed_with_notes_branch, "未找到 standalone passed_with_notes 分支"
        )
        self.assertEqual(passed_with_notes_branch.group(1), "ai-flow-git-commit")

    def test_plan_coding_review_skill_mentions_git_commit_next_step(self):
        skill = (
            PROJECT_ROOT / "skills/ai-flow-plan-coding-review/SKILL.md"
        ).read_text(encoding="utf-8")

        self.assertIn("NEXT: ai-flow-git-commit", skill)
        self.assertIn("/ai-flow-git-commit", skill)

    def test_coding_review_agents_accept_explicit_git_commit_next(self):
        expected = (
            "NEXT: ai-flow-code-optimize|ai-flow-plan-coding|ai-flow-git-commit|none"
        )

        codex_agent = (
            PROJECT_ROOT / "subagents/ai-flow-codex-plan-coding-review/AGENT.md"
        ).read_text(encoding="utf-8")
        claude_agent = (
            PROJECT_ROOT / "subagents/ai-flow-claude-plan-coding-review/AGENT.md"
        ).read_text(encoding="utf-8")

        self.assertIn(expected, codex_agent)
        self.assertIn(expected, claude_agent)

    def test_review_prompt_uses_review_packet(self):
        """验证 review-generation.md 包含 __AI_FLOW_REVIEW_PACKET__ 变量引用。"""
        review_gen = (
            PROJECT_ROOT
            / "subagents/shared/coding-review/prompts/review-generation.md"
        ).read_text(encoding="utf-8")

        self.assertIn("__AI_FLOW_REVIEW_PACKET__", review_gen)
        # 确认不再是主上下文（__AI_FLOW_PLAN_CONTENT__ 不应作为主注入项出现）
        # 注意：__AI_FLOW_PLAN_CONTENT__ 仍保留在 render_prompt_template 中作为 fallback
        # 但在 review prompt 模板中不应作为主上下文出现
        self.assertNotIn("__AI_FLOW_PLAN_CONTENT__", review_gen)


if __name__ == "__main__":
    unittest.main()
