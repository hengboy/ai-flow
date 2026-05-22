#!/usr/bin/env python3
"""Tests for flow_plan_group_state_cli.py — full lifecycle and schema validation."""

import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).parent / "flow_plan_group_state_cli.py"
PROJECT_ROOT = Path(__file__).parent.parent.parent  # runtime/scripts -> runtime -> project root


def test_create_group():
    """create 命令应成功创建 group。"""
    SLUG = "test-create-group"
    state_dir = PROJECT_ROOT / ".ai-flow" / "plan-groups" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / f"{SLUG}.json"
    state_file.unlink(missing_ok=True)

    result = subprocess.run(
        [sys.executable, str(SCRIPT), "transition",
         "--group-slug", SLUG,
         "--event", "group_created",
         "--title", "Test Group",
         "--group-file", ".ai-flow/plan-groups/test-group.md"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, f"创建失败: {result.stderr}"
    assert SLUG in result.stdout
    created = list(state_dir.glob(f"{SLUG}.json"))
    if created:
        created[0].unlink()


def test_transition_group_created():
    """transition group_created 应成功创建状态文件。"""
    SLUG = "test-transition-create"
    state_dir = PROJECT_ROOT / ".ai-flow" / "plan-groups" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / f"{SLUG}.json"
    state_file.unlink(missing_ok=True)

    result = subprocess.run(
        [sys.executable, str(SCRIPT), "transition",
         "--group-slug", SLUG,
         "--event", "group_created",
         "--title", "Test Group",
         "--group-file", ".ai-flow/plan-groups/test.md"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, f"transition 失败: {result.stderr}"
    # 使用 glob 查找（resolve_project_dir 可能找到不同的根目录）
    created = list(state_dir.glob(f"{SLUG}.json"))
    assert len(created) == 1, f"状态文件应被创建在 {state_dir}"
    created[0].unlink()


def test_validate_rejects_invalid_schema():
    """validate 应拒绝缺少必填字段的状态文件。"""
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "validate",
         "--group-slug", "nonexistent"],
        capture_output=True, text=True,
    )
    assert result.returncode != 0, "预期失败（状态文件不存在或 schema 非法）"


def test_children_cannot_contain_execution_status():
    """children[] 不允许包含执行状态字段。"""
    import json
    import tempfile

    # 先创建一个合法的 group state 文件
    state = {
        "schema_version": 1,
        "group_slug": "test-exec-fields",
        "title": "Test Group",
        "group_file": ".ai-flow/plan-groups/test.md",
        "current_status": "AWAITING_GROUP_REVIEW",
        "children": [
            {
                "child_id": "child-test",
                "title": "Test Child",
                "depends_on": [],
                "scope_summary": "test",
                "primary_risk": "low",
                "planned_semantic_slug": "test-child",
                "created_slug": None,
                "plan_file": "test.md",
                "state_file": "test.json",
            }
        ],
        "current_child_id": None,
        "created_at": "2026-05-22T12:00:00+08:00",
        "updated_at": "2026-05-22T12:00:00+08:00",
        "transitions": [
            {
                "seq": 1,
                "at": "2026-05-22T12:00:00+08:00",
                "event": "group_created",
                "from": None,
                "to": "AWAITING_GROUP_REVIEW",
                "actor": "test",
                "payload": {
                    "title": "Test Group",
                    "group_file": ".ai-flow/plan-groups/test.md",
                    "children": [
                        {
                            "child_id": "child-test",
                            "title": "Test Child",
                            "depends_on": [],
                            "scope_summary": "test",
                            "primary_risk": "low",
                            "planned_semantic_slug": "test-child",
                            "created_slug": None,
                            "plan_file": "test.md",
                            "state_file": "test.json",
                        }
                    ],
                },
                "note": "",
            }
        ],
    }

    state_dir = PROJECT_ROOT / ".ai-flow" / "plan-groups" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / "test-exec-fields.json"
    state_file.write_text(json.dumps(state))

    # 验证合法状态文件通过校验
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "validate", "--group-slug", "test-exec-fields"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, f"合法状态文件应通过校验: {result.stderr}"

    # 在 children 中注入执行状态字段
    state["children"][0]["current_status"] = "DONE"
    state_file.write_text(json.dumps(state))

    # 校验应失败
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "validate", "--group-slug", "test-exec-fields"],
        capture_output=True, text=True,
    )
    assert result.returncode != 0, "children 包含执行状态字段时应拒绝"
    assert "不允许包含执行状态字段" in result.stderr or "current_status" in result.stderr

    # 清理
    state_file.unlink()


def test_full_lifecycle():
    """正向端到端测试：group_created -> group_review_passed -> child_bound -> child_completed (all_done) -> final_review_passed -> GROUP_DONE。"""
    SLUG = "test-lifecycle-e2e"
    state_dir = PROJECT_ROOT / ".ai-flow" / "plan-groups" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / f"{SLUG}.json"

    def run(*extra_args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "transition", "--group-slug", SLUG, *extra_args],
            capture_output=True, text=True,
        )

    # 1. group_created
    result = run("--event", "group_created",
                 "--title", "Lifecycle Test",
                 "--group-file", ".ai-flow/plan-groups/lifecycle-test.md",
                 "--children-json", json.dumps([
                     {"child_id": "child-a", "title": "Child A", "depends_on": [],
                      "scope_summary": "test", "primary_risk": "low",
                      "planned_semantic_slug": "lifecycle-child-a",
                      "created_slug": None, "plan_file": "a.md", "state_file": "a.json"}
                 ]))
    assert result.returncode == 0, f"group_created 失败: {result.stderr}"

    # 2. group_review_passed
    result = run("--event", "group_review_passed")
    assert result.returncode == 0, f"group_review_passed 失败: {result.stderr}"

    # 3. child_bound
    result = run("--event", "child_bound")
    assert result.returncode == 0, f"child_bound 失败: {result.stderr}"

    # 4. child_completed — 需要一个实际的 child state 文件来模拟完成
    child_state_dir = PROJECT_ROOT / ".ai-flow" / "state"
    child_state_dir.mkdir(parents=True, exist_ok=True)
    child_file = child_state_dir / "lifecycle-child-a.json"
    child_state = {
        "schema_version": 4, "slug": "lifecycle-child-a", "title": "Child A",
        "plan_file": "a.md", "current_status": "DONE", "created_at": "2026-05-22T12:00:00+08:00",
        "updated_at": "2026-05-22T12:00:00+08:00", "transitions": [],
    }
    child_file.write_text(json.dumps(child_state))

    result = run("--event", "child_completed")
    assert result.returncode == 0, f"child_completed 失败: {result.stderr}"
    # 验证进入了 AWAITING_GROUP_FINAL_REVIEW
    show = subprocess.run(
        [sys.executable, str(SCRIPT), "show", "--group-slug", SLUG, "--field", "current_status"],
        capture_output=True, text=True,
    )
    assert "AWAITING_GROUP_FINAL_REVIEW" in show.stdout, f"应进入 AWAITING_GROUP_FINAL_REVIEW，实际: {show.stdout}"

    # 5. final_review_passed
    result = run("--event", "final_review_passed")
    assert result.returncode == 0, f"final_review_passed 失败: {result.stderr}"

    # 6. 验证最终状态为 GROUP_DONE
    show = subprocess.run(
        [sys.executable, str(SCRIPT), "show", "--group-slug", SLUG, "--field", "current_status"],
        capture_output=True, text=True,
    )
    assert "GROUP_DONE" in show.stdout, f"应进入 GROUP_DONE，实际: {show.stdout}"

    # 清理
    state_file.unlink(missing_ok=True)
    child_file.unlink(missing_ok=True)


if __name__ == "__main__":
    test_create_group()
    print("PASS: test_create_group")

    test_transition_group_created()
    print("PASS: test_transition_group_created")

    test_validate_rejects_invalid_schema()
    print("PASS: test_validate_rejects_invalid_schema")

    test_children_cannot_contain_execution_status()
    print("PASS: test_children_cannot_contain_execution_status")

    test_full_lifecycle()
    print("PASS: test_full_lifecycle")

    print("\n所有测试通过")
