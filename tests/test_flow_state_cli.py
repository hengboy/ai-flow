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

    def test_full_lifecycle_to_done(self):
        """完整流程: 创建 -> 审核通过 -> 执行 -> 完成 -> 审查通过。"""
        self.proj.create_state(self.slug)
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
