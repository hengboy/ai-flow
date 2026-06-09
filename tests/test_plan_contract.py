#!/usr/bin/env python3
"""plan generation/revision contract regression tests."""

import unittest
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11 fallback
    tomllib = None


PROJECT_ROOT = Path(__file__).resolve().parent.parent


def load_toml_contract(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if tomllib is not None:
        return tomllib.loads(text)

    data = {}
    for key in ("name", "description"):
        prefix = f'{key} = "'
        for line in text.splitlines():
            if line.startswith(prefix):
                data[key] = line[len(prefix):-1]
                break
    marker = 'developer_instructions = """'
    start = text.index(marker) + len(marker)
    end = text.rindex('"""')
    data["developer_instructions"] = text[start:end]
    return data


class PlanContractTest(unittest.TestCase):
    def test_executor_requires_reopened_state_after_failed_review_revision(self):
        executor = (
            PROJECT_ROOT / "subagents/shared/plan/bin/plan-executor.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("require_plan_status()", executor)
        self.assertIn(
            'PLAN_STATUS=$(require_plan_status "$EXISTING_DATED_SLUG" "AWAITING_PLAN_REVIEW")',
            executor,
        )

    def test_claude_plan_agent_reopens_failed_review_revision(self):
        agent = (
            PROJECT_ROOT / "subagents/ai-flow-claude-plan/AGENT.md"
        ).read_text(encoding="utf-8")

        self.assertIn("PLAN_REVIEW_FAILED", agent)
        self.assertIn("--event plan_reopened", agent)
        self.assertIn("show --field current_status", agent)
        self.assertIn("AWAITING_PLAN_REVIEW", agent)
        self.assertIn("禁止宣称修订成功", agent)

    def test_plan_bak_files_are_temporary_only(self):
        plan_skill = (
            PROJECT_ROOT / "skills/ai-flow-plan/SKILL.md"
        ).read_text(encoding="utf-8")
        coding_skill = (
            PROJECT_ROOT / "skills/ai-flow-plan-coding/SKILL.md"
        ).read_text(encoding="utf-8")
        claude_agent = (
            PROJECT_ROOT / "subagents/ai-flow-claude-plan/AGENT.md"
        ).read_text(encoding="utf-8")
        executor = (
            PROJECT_ROOT / "subagents/shared/plan/bin/plan-executor.sh"
        ).read_text(encoding="utf-8")

        for content in (plan_skill, coding_skill, claude_agent):
            self.assertIn(".bak", content)
            self.assertIn("临时存在", content)
            self.assertIn("必须删除", content)

        self.assertIn(".ai-flow/plans/history/<slug>/vN.md", plan_skill)
        self.assertNotIn(".md.bak", executor)

    def test_codex_native_agents_are_valid_toml_and_do_not_call_model_clis(self):
        agents_dir = PROJECT_ROOT / "codex/agents"
        expected = {
            "ai-flow-codex-plan.toml": "ai-flow-codex-plan",
            "ai-flow-codex-plan-review.toml": "ai-flow-codex-plan-review",
            "ai-flow-codex-plan-coding-review.toml": "ai-flow-codex-plan-coding-review",
        }

        for filename, name in expected.items():
            data = load_toml_contract(agents_dir / filename)
            self.assertEqual(data["name"], name)
            self.assertTrue(data["description"])
            instructions = data["developer_instructions"]
            self.assertTrue(instructions)
            self.assertIn("原生执行", instructions)
            self.assertIn("禁止调用任何外部模型 CLI", instructions)
            self.assertIn("codex exec", instructions)
            self.assertIn("Claude CLI", instructions)
            self.assertIn("opencode", instructions)
            self.assertNotIn("codex exec --", instructions)

    def test_thin_skills_include_claude_and_codex_host_routing(self):
        skill_files = [
            PROJECT_ROOT / "skills/ai-flow-plan/SKILL.md",
            PROJECT_ROOT / "skills/ai-flow-plan-review/SKILL.md",
            PROJECT_ROOT / "skills/ai-flow-plan-coding-review/SKILL.md",
        ]

        for skill_file in skill_files:
            content = skill_file.read_text(encoding="utf-8")
            self.assertIn("宿主分流", content)
            self.assertIn("Claude Code 宿主", content)
            self.assertIn("Codex 宿主", content)
            self.assertIn("native subagent", content)
            self.assertIn("engine_mode=claude 不可用", content)
            self.assertIn("重启 Codex", content)
            self.assertIn("禁止回退到 `codex exec`", content)


if __name__ == "__main__":
    unittest.main()
