#!/usr/bin/env python3
"""flow_plan_orchestration_state_cli.py queue state tests."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = PROJECT_ROOT / "runtime" / "scripts" / "flow_plan_orchestration_state_cli.py"


def write_plan_state(root: Path, slug: str, status: str) -> None:
    state_dir = root / ".ai-flow" / "state"
    plan_dir = root / ".ai-flow" / "plans"
    state_dir.mkdir(parents=True, exist_ok=True)
    plan_dir.mkdir(parents=True, exist_ok=True)
    (plan_dir / f"{slug}.md").write_text("# test\n", encoding="utf-8")
    execution_scope = {
        "mode": "plan_repos",
        "repos": [
            {
                "id": "owner",
                "path": ".",
                "git_root": str(root),
                "role": "owner",
            }
        ],
    }

    def transition(seq: int, event: str, from_status: str | None, to_status: str, payload: dict) -> dict:
        minute = seq - 1
        at = f"2026-06-09T10:{minute:02d}:00+08:00"
        return {
            "seq": seq,
            "at": at,
            "event": event,
            "from": from_status,
            "to": to_status,
            "actor": "test-runner",
            "payload": payload,
            "note": "",
        }

    transitions = [
        transition(
            1,
            "plan_created",
            None,
            "AWAITING_PLAN_REVIEW",
            {"title": slug, "plan_file": f".ai-flow/plans/{slug}.md", "execution_scope": execution_scope},
        )
    ]
    current = "AWAITING_PLAN_REVIEW"
    if status in {"PLANNED", "IMPLEMENTING", "AWAITING_REVIEW", "REVIEW_FAILED", "FIXING_REVIEW", "DONE"}:
        transitions.append(
            transition(
                len(transitions) + 1,
                "plan_review_passed",
                current,
                "PLANNED",
                {"result": "passed", "round": 1, "engine": "test-engine", "model": "test-model"},
            )
        )
        current = "PLANNED"
    if status in {"IMPLEMENTING", "AWAITING_REVIEW", "REVIEW_FAILED", "FIXING_REVIEW", "DONE"}:
        transitions.append(transition(len(transitions) + 1, "execute_started", current, "IMPLEMENTING", {}))
        current = "IMPLEMENTING"
    if status in {"AWAITING_REVIEW", "REVIEW_FAILED", "FIXING_REVIEW", "DONE"}:
        transitions.append(transition(len(transitions) + 1, "implementation_completed", current, "AWAITING_REVIEW", {}))
        current = "AWAITING_REVIEW"
    if status in {"REVIEW_FAILED", "FIXING_REVIEW"}:
        transitions.append(
            transition(
                len(transitions) + 1,
                "review_failed",
                current,
                "REVIEW_FAILED",
                {
                    "result": "failed",
                    "round": 1,
                    "report_file": ".ai-flow/reports/test.md",
                    "engine": "test-engine",
                    "model": "test-model",
                },
            )
        )
        current = "REVIEW_FAILED"
    if status == "FIXING_REVIEW":
        transitions.append(transition(len(transitions) + 1, "fix_started", current, "FIXING_REVIEW", {}))
        current = "FIXING_REVIEW"
    if status == "DONE":
        transitions.append(
            transition(
                len(transitions) + 1,
                "review_passed",
                current,
                "DONE",
                {
                    "result": "passed",
                    "round": 1,
                    "report_file": ".ai-flow/reports/test.md",
                    "engine": "test-engine",
                    "model": "test-model",
                },
            )
        )
        current = "DONE"
    if current != status:
        raise AssertionError(f"unsupported test status: {status}")

    payload = {
        "schema_version": 4,
        "slug": slug,
        "title": slug,
        "plan_file": f".ai-flow/plans/{slug}.md",
        "execution_scope": execution_scope,
        "current_status": status,
        "created_at": transitions[0]["at"],
        "updated_at": transitions[-1]["at"],
        "transitions": transitions,
    }
    (state_dir / f"{slug}.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


class OrchestrationStateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(dir=PROJECT_ROOT / ".ai-flow-tests")
        self.root = Path(self.tempdir.name)
        (self.root / ".ai-flow" / "state").mkdir(parents=True, exist_ok=True)
        self.env = None

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=30,
            env=self.env,
        )

    def read_queue(self, queue_slug: str) -> dict:
        return json.loads(
            (self.root / ".ai-flow" / "orchestrations" / "state" / f"{queue_slug}.json").read_text(
                encoding="utf-8"
            )
        )

    def install_dirty_stub(self, text: str = "dirty\n") -> None:
        stub = self.root / "runtime" / "scripts" / "flow-auto-run.sh"
        stub.parent.mkdir(parents=True, exist_ok=True)
        stub.write_text(f"#!/bin/sh\nprintf '%b' {text!r}\n", encoding="utf-8")
        stub.chmod(0o755)
        import os

        self.env = dict(os.environ)
        self.env["AI_FLOW_AUTO_RUN_SH"] = str(stub)

    def test_create_queue_preserves_order(self) -> None:
        write_plan_state(self.root, "20260609-first", "PLANNED")
        write_plan_state(self.root, "20260609-second", "AWAITING_REVIEW")

        result = self.run_cli("create", "--queue-slug", "queue-a", "20260609-first", "20260609-second")

        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_queue("queue-a")
        self.assertEqual([item["slug"] for item in state["items"]], ["20260609-first", "20260609-second"])
        self.assertEqual(state["current_status"], "READY")

    def test_rejects_duplicate_slug(self) -> None:
        write_plan_state(self.root, "20260609-dup", "PLANNED")

        result = self.run_cli("create", "--queue-slug", "queue-dup", "20260609-dup", "20260609-dup")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("重复 plan slug", result.stderr)

    def test_rejects_plan_group_slug(self) -> None:
        slug = "20260609-group"
        write_plan_state(self.root, slug, "PLANNED")
        group_dir = self.root / ".ai-flow" / "plan-groups" / "state"
        group_dir.mkdir(parents=True, exist_ok=True)
        (group_dir / f"{slug}.json").write_text("{}", encoding="utf-8")

        result = self.run_cli("create", "--queue-slug", "queue-group", slug)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("拒绝计划组 slug", result.stderr)

    def test_rejects_invalid_plan_status(self) -> None:
        write_plan_state(self.root, "20260609-reviewing-plan", "AWAITING_PLAN_REVIEW")

        result = self.run_cli("create", "--queue-slug", "queue-invalid", "20260609-reviewing-plan")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("不允许入队", result.stderr)

    def test_rejects_invalid_plan_state_schema(self) -> None:
        state_dir = self.root / ".ai-flow" / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "20260609-broken.json").write_text(
            json.dumps({"slug": "20260609-broken", "current_status": "PLANNED"}),
            encoding="utf-8",
        )

        result = self.run_cli("create", "--queue-slug", "queue-broken", "20260609-broken")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("状态文件无效", result.stderr)

    def test_rejects_done_clean_plan(self) -> None:
        write_plan_state(self.root, "20260609-done-clean", "DONE")
        self.install_dirty_stub("clean\n")

        result = self.run_cli("create", "--queue-slug", "queue-clean", "20260609-done-clean")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("无需提交/复审", result.stderr)

    def test_allows_done_dirty_plan(self) -> None:
        write_plan_state(self.root, "20260609-done-dirty", "DONE")
        self.install_dirty_stub("dirty\n")

        result = self.run_cli("create", "--queue-slug", "queue-dirty", "20260609-done-dirty")

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_item_lifecycle_advances_active_index_and_done(self) -> None:
        write_plan_state(self.root, "20260609-one", "PLANNED")
        write_plan_state(self.root, "20260609-two", "PLANNED")
        self.assertEqual(
            self.run_cli("create", "--queue-slug", "queue-life", "20260609-one", "20260609-two").returncode,
            0,
        )

        self.assertEqual(self.run_cli("start-current", "--queue-slug", "queue-life").returncode, 0)
        write_plan_state(self.root, "20260609-one", "DONE")
        self.assertEqual(self.run_cli("mark-reviewed", "--queue-slug", "queue-life").returncode, 0)
        self.assertEqual(
            self.run_cli(
                "record-heads",
                "--queue-slug",
                "queue-life",
                "--heads-json",
                json.dumps([{"repo_id": "owner", "git_root": str(self.root), "head": "h1"}]),
            ).returncode,
            0,
        )
        self.assertEqual(
            self.run_cli("mark-committed", "--queue-slug", "queue-life", "--commits-json", "[]").returncode,
            0,
        )
        state = self.read_queue("queue-life")
        self.assertEqual(state["active_index"], 1)
        self.assertEqual(state["current_status"], "RUNNING")
        self.assertEqual(state["items"][0]["status"], "COMMITTED")

        self.assertEqual(self.run_cli("start-current", "--queue-slug", "queue-life").returncode, 0)
        write_plan_state(self.root, "20260609-two", "DONE")
        self.assertEqual(self.run_cli("mark-reviewed", "--queue-slug", "queue-life").returncode, 0)
        self.assertEqual(
            self.run_cli(
                "record-heads",
                "--queue-slug",
                "queue-life",
                "--heads-json",
                json.dumps([{"repo_id": "owner", "git_root": str(self.root), "head": "h2"}]),
            ).returncode,
            0,
        )
        self.assertEqual(
            self.run_cli("mark-committed", "--queue-slug", "queue-life", "--commits-json", "[]").returncode,
            0,
        )
        state = self.read_queue("queue-life")
        self.assertEqual(state["active_index"], 2)
        self.assertEqual(state["current_status"], "DONE")
        self.assertTrue(all(item["status"] == "COMMITTED" for item in state["items"]))

    def test_mark_reviewed_requires_plan_done(self) -> None:
        write_plan_state(self.root, "20260609-not-done", "PLANNED")
        self.assertEqual(self.run_cli("create", "--queue-slug", "queue-review-gate", "20260609-not-done").returncode, 0)
        self.assertEqual(self.run_cli("start-current", "--queue-slug", "queue-review-gate").returncode, 0)

        result = self.run_cli("mark-reviewed", "--queue-slug", "queue-review-gate")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("plan 状态不是 DONE", result.stderr)

    def test_mark_committed_requires_recorded_heads(self) -> None:
        write_plan_state(self.root, "20260609-no-head", "PLANNED")
        self.assertEqual(self.run_cli("create", "--queue-slug", "queue-head-gate", "20260609-no-head").returncode, 0)
        self.assertEqual(self.run_cli("start-current", "--queue-slug", "queue-head-gate").returncode, 0)
        write_plan_state(self.root, "20260609-no-head", "DONE")
        self.assertEqual(self.run_cli("mark-reviewed", "--queue-slug", "queue-head-gate").returncode, 0)

        result = self.run_cli("mark-committed", "--queue-slug", "queue-head-gate", "--commits-json", "[]")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("head_before_commit", result.stderr)

    def test_failed_queue_can_reopen_current(self) -> None:
        write_plan_state(self.root, "20260609-reopen", "PLANNED")
        self.assertEqual(self.run_cli("create", "--queue-slug", "queue-reopen", "20260609-reopen").returncode, 0)
        self.assertEqual(self.run_cli("start-current", "--queue-slug", "queue-reopen").returncode, 0)
        self.assertEqual(
            self.run_cli("fail", "--queue-slug", "queue-reopen", "--reason", "blocked").returncode,
            0,
        )

        result = self.run_cli("reopen-current", "--queue-slug", "queue-reopen", "--reason", "fixed")

        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_queue("queue-reopen")
        self.assertEqual(state["current_status"], "RUNNING")
        self.assertEqual(state["items"][0]["status"], "RUNNING")
        self.assertIsNone(state["items"][0]["error"])


if __name__ == "__main__":
    unittest.main()
