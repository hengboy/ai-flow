#!/usr/bin/env python3
"""AI Flow ordinary-plan queue orchestration state machine."""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
QUEUE_STATUS_VALUES = {"READY", "RUNNING", "FAILED", "DONE"}
ITEM_STATUS_VALUES = {"PENDING", "RUNNING", "DONE_REVIEWED", "COMMITTED", "FAILED"}
PLAN_ALLOWED_STATUSES = {
    "PLANNED",
    "IMPLEMENTING",
    "AWAITING_REVIEW",
    "REVIEW_FAILED",
    "FIXING_REVIEW",
    "DONE",
}
PLAN_REJECTED_STATUSES = {"AWAITING_PLAN_REVIEW", "PLAN_REVIEW_FAILED"}
QUEUE_SLUG_RE = re.compile(r"^[a-z0-9一-鿿][a-z0-9一-鿿-]*$")
DATED_PLAN_SLUG_RE = re.compile(r"^\d{8}-[a-z0-9一-鿿][a-z0-9一-鿿-]*$")


class FlowError(Exception):
    pass


def resolve_project_dir() -> Path:
    cwd = Path.cwd().resolve()
    candidate = cwd
    while True:
        if (candidate / ".ai-flow" / "state").is_dir():
            return candidate
        if ".ai-flow-tests" in candidate.parts:
            break
        parent = candidate.parent
        if parent == candidate:
            break
        candidate = parent
    try:
        import subprocess

        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=10,
            cwd=str(cwd),
        )
        if result.returncode == 0 and result.stdout.strip():
            return Path(result.stdout.strip()).resolve()
    except FileNotFoundError:
        pass
    return cwd


PROJECT_DIR = resolve_project_dir()
FLOW_DIR = PROJECT_DIR / ".ai-flow"
PLAN_STATE_DIR = FLOW_DIR / "state"
GROUP_STATE_DIR = FLOW_DIR / "plan-groups" / "state"
ORCH_DIR = FLOW_DIR / "orchestrations"
STATE_DIR = ORCH_DIR / "state"
LOCKS_DIR = STATE_DIR / ".locks"
SCRIPT_DIR = Path(__file__).resolve().parent

try:
    from flow_state_cli import validate_state as validate_plan_state_schema
except ImportError:  # pragma: no cover - direct runtime layout always has this.
    validate_plan_state_schema = None


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def parse_iso(value: str, field_name: str) -> datetime:
    if not isinstance(value, str):
        raise FlowError(f"{field_name} 必须是 ISO 时间字符串")
    try:
        return datetime.fromisoformat(value)
    except ValueError as exc:
        raise FlowError(f"{field_name} 不是合法的 ISO 时间: {value}") from exc


def ensure_queue_slug(slug: str) -> str:
    cleaned = slug.strip()
    if QUEUE_SLUG_RE.fullmatch(cleaned):
        return cleaned
    raise FlowError(f"queue_slug 格式非法: {slug!r}")


def ensure_plan_slug(slug: str) -> str:
    cleaned = slug.strip()
    if DATED_PLAN_SLUG_RE.fullmatch(cleaned):
        return cleaned
    raise FlowError(f"plan slug 必须是完整 dated slug: {slug!r}")


def state_path_for_queue(queue_slug: str) -> Path:
    return STATE_DIR / f"{ensure_queue_slug(queue_slug)}.json"


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise FlowError(f"状态文件不存在: {path}") from exc
    except json.JSONDecodeError as exc:
        raise FlowError(f"状态文件 JSON 损坏: {path}") from exc


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f"{path.stem}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temp_path = Path(handle.name)
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
    finally:
        if temp_path and temp_path.exists():
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass


def get_nested(value: Any, field: str) -> Any:
    current = value
    for part in field.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif isinstance(current, list) and part.isdigit():
            index = int(part)
            if 0 <= index < len(current):
                current = current[index]
            else:
                raise FlowError(f"数组索引越界: {part}")
        else:
            raise FlowError(f"字段不存在: {field}")
    return current


def validate_plan_slug(slug: str, *, enforce_done_needs_work: bool = True) -> dict[str, Any]:
    slug = ensure_plan_slug(slug)
    if (GROUP_STATE_DIR / f"{slug}.json").exists():
        raise FlowError(f"拒绝计划组 slug: {slug}")
    path = PLAN_STATE_DIR / f"{slug}.json"
    state = read_json(path)
    if validate_plan_state_schema is None:
        raise FlowError("缺少普通 plan state 校验器")
    try:
        validate_plan_state_schema(state, expected_slug=slug)
    except Exception as exc:
        raise FlowError(f"plan {slug} 状态文件无效: {exc}") from exc
    if state.get("slug") != slug:
        raise FlowError(f"plan 状态 slug 与文件名不一致: {slug}")
    status = state.get("current_status")
    if status in PLAN_REJECTED_STATUSES:
        raise FlowError(f"plan {slug} 状态 {status} 不允许入队")
    if status not in PLAN_ALLOWED_STATUSES:
        raise FlowError(f"plan {slug} 状态非法或不允许入队: {status}")
    if enforce_done_needs_work and status == "DONE" and not done_plan_needs_commit_or_recheck(slug):
        raise FlowError(f"plan {slug} 状态 DONE 但当前无需提交/复审，不允许入队")
    return state


def done_plan_needs_commit_or_recheck(slug: str) -> bool:
    helper = Path(os.environ.get("AI_FLOW_AUTO_RUN_SH", SCRIPT_DIR / "flow-auto-run.sh"))
    if not helper.is_file():
        raise FlowError(f"缺少 dirty 检查 helper: {helper}")
    result = subprocess.run(
        ["bash", str(helper), "dirty", slug],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise FlowError(f"plan {slug} DONE dirty 检查失败: {detail}")
    first_line = result.stdout.splitlines()[0].strip() if result.stdout.splitlines() else ""
    return first_line == "dirty"


def build_create_payload(queue_slug: str, plan_slugs: list[str], at: str) -> dict[str, Any]:
    if not plan_slugs:
        raise FlowError("队列至少需要一个 plan slug")
    seen: set[str] = set()
    items: list[dict[str, Any]] = []
    for index, raw_slug in enumerate(plan_slugs):
        slug = ensure_plan_slug(raw_slug)
        if slug in seen:
            raise FlowError(f"重复 plan slug: {slug}")
        seen.add(slug)
        plan_state = validate_plan_slug(slug)
        items.append(
            {
                "index": index,
                "slug": slug,
                "status": "PENDING",
                "plan_status_at_enqueue": plan_state["current_status"],
                "started_at": None,
                "done_reviewed_at": None,
                "committed_at": None,
                "head_before_commit": [],
                "commits": [],
                "error": None,
            }
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "queue_slug": queue_slug,
        "current_status": "READY",
        "active_index": 0,
        "items": items,
        "created_at": at,
        "updated_at": at,
        "transitions": [
            {
                "seq": 1,
                "at": at,
                "event": "queue_created",
                "from": None,
                "to": "READY",
                "actor": os.environ.get("AI_FLOW_ACTOR", "flow-plan-orchestrate.sh"),
                "payload": {"plan_slugs": plan_slugs},
                "note": "",
            }
        ],
    }


def validate_item(item: Any, index: int) -> None:
    if not isinstance(item, dict):
        raise FlowError(f"items[{index}] 必须是对象")
    required = {
        "index",
        "slug",
        "status",
        "plan_status_at_enqueue",
        "started_at",
        "done_reviewed_at",
        "committed_at",
        "head_before_commit",
        "commits",
        "error",
    }
    missing = required - set(item)
    if missing:
        raise FlowError(f"items[{index}] 缺少字段: {', '.join(sorted(missing))}")
    extras = set(item) - required
    if extras:
        raise FlowError(f"items[{index}] 存在未知字段: {', '.join(sorted(extras))}")
    if item["index"] != index:
        raise FlowError(f"items[{index}].index 必须等于数组位置")
    ensure_plan_slug(item["slug"])
    if item["status"] not in ITEM_STATUS_VALUES:
        raise FlowError(f"items[{index}].status 非法: {item['status']}")
    if item["plan_status_at_enqueue"] not in PLAN_ALLOWED_STATUSES:
        raise FlowError(f"items[{index}].plan_status_at_enqueue 非法: {item['plan_status_at_enqueue']}")
    for field_name in ("started_at", "done_reviewed_at", "committed_at"):
        if item[field_name] is not None:
            parse_iso(item[field_name], f"items[{index}].{field_name}")
    if not isinstance(item["head_before_commit"], list):
        raise FlowError(f"items[{index}].head_before_commit 必须是数组")
    if not isinstance(item["commits"], list):
        raise FlowError(f"items[{index}].commits 必须是数组")
    if item["error"] is not None and not isinstance(item["error"], str):
        raise FlowError(f"items[{index}].error 必须是字符串或 null")


def validate_queue_state(state: dict[str, Any], *, expected_slug: str | None = None) -> None:
    if not isinstance(state, dict):
        raise FlowError("状态文件根节点必须是对象")
    required = {
        "schema_version",
        "queue_slug",
        "current_status",
        "active_index",
        "items",
        "created_at",
        "updated_at",
        "transitions",
    }
    missing = required - set(state)
    if missing:
        raise FlowError(f"状态文件缺少字段: {', '.join(sorted(missing))}")
    extras = set(state) - required
    if extras:
        raise FlowError(f"状态文件存在未知字段: {', '.join(sorted(extras))}")
    if state["schema_version"] != SCHEMA_VERSION:
        raise FlowError(f"schema_version 非法: {state['schema_version']}")
    queue_slug = ensure_queue_slug(state["queue_slug"])
    if expected_slug and queue_slug != expected_slug:
        raise FlowError(f"queue_slug 不一致: {queue_slug} != {expected_slug}")
    if state["current_status"] not in QUEUE_STATUS_VALUES:
        raise FlowError(f"current_status 非法: {state['current_status']}")
    items = state["items"]
    if not isinstance(items, list) or not items:
        raise FlowError("items 必须是非空数组")
    slugs: set[str] = set()
    for index, item in enumerate(items):
        validate_item(item, index)
        if item["slug"] in slugs:
            raise FlowError(f"items[{index}].slug 重复: {item['slug']}")
        slugs.add(item["slug"])
    if not isinstance(state["active_index"], int):
        raise FlowError("active_index 必须是整数")
    if not 0 <= state["active_index"] <= len(items):
        raise FlowError("active_index 越界")
    created_at = parse_iso(state["created_at"], "created_at")
    updated_at = parse_iso(state["updated_at"], "updated_at")
    if updated_at < created_at:
        raise FlowError("updated_at 不能早于 created_at")
    transitions = state["transitions"]
    if not isinstance(transitions, list) or not transitions:
        raise FlowError("transitions 不能为空")
    for index, item in enumerate(transitions):
        if not isinstance(item, dict):
            raise FlowError(f"transitions[{index}] 必须是对象")
        required_transition = {"seq", "at", "event", "from", "to", "actor", "payload", "note"}
        missing_transition = required_transition - set(item)
        if missing_transition:
            raise FlowError(f"transitions[{index}] 缺少字段: {', '.join(sorted(missing_transition))}")
        if item["seq"] != index + 1:
            raise FlowError(f"transitions[{index}].seq 必须为 {index + 1}")
        parse_iso(item["at"], f"transitions[{index}].at")
        if item["to"] not in QUEUE_STATUS_VALUES:
            raise FlowError(f"transitions[{index}].to 非法: {item['to']}")
        if item["from"] is not None and item["from"] not in QUEUE_STATUS_VALUES:
            raise FlowError(f"transitions[{index}].from 非法: {item['from']}")
        if not isinstance(item["actor"], str) or not item["actor"].strip():
            raise FlowError(f"transitions[{index}].actor 不能为空")
        if not isinstance(item["payload"], dict):
            raise FlowError(f"transitions[{index}].payload 必须是对象")
        if not isinstance(item["note"], str):
            raise FlowError(f"transitions[{index}].note 必须是字符串")
    if state["created_at"] != transitions[0]["at"]:
        raise FlowError("created_at 必须等于第一条 transition.at")
    if state["updated_at"] != transitions[-1]["at"]:
        raise FlowError("updated_at 必须等于最后一条 transition.at")
    if state["current_status"] != transitions[-1]["to"]:
        raise FlowError("current_status 必须等于最后一条 transition.to")
    if state["current_status"] == "DONE" and state["active_index"] != len(items):
        raise FlowError("DONE 队列 active_index 必须等于 items 长度")
    if state["current_status"] == "FAILED":
        if not any(item["status"] == "FAILED" for item in items):
            raise FlowError("FAILED 队列必须包含 FAILED item")


def current_item(state: dict[str, Any]) -> dict[str, Any]:
    if state["active_index"] >= len(state["items"]):
        raise FlowError("队列已无 active item")
    return state["items"][state["active_index"]]


def append_transition(
    state: dict[str, Any],
    *,
    event: str,
    from_status: str,
    to_status: str,
    at: str,
    payload: dict[str, Any],
    note: str = "",
) -> None:
    state["transitions"].append(
        {
            "seq": len(state["transitions"]) + 1,
            "at": at,
            "event": event,
            "from": from_status,
            "to": to_status,
            "actor": os.environ.get("AI_FLOW_ACTOR", "flow-plan-orchestrate.sh"),
            "payload": payload,
            "note": note,
        }
    )
    state["current_status"] = to_status
    state["updated_at"] = at


def with_lock(queue_slug: str, mutator) -> dict[str, Any]:
    queue_slug = ensure_queue_slug(queue_slug)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOCKS_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = LOCKS_DIR / f"{queue_slug}.lock"
    try:
        os.mkdir(lock_path)
    except FileExistsError as exc:
        raise FlowError(f"状态锁已存在: {lock_path}") from exc
    try:
        path = state_path_for_queue(queue_slug)
        current = None
        if path.exists():
            current = read_json(path)
            validate_queue_state(current, expected_slug=queue_slug)
        next_state = mutator(copy.deepcopy(current))
        validate_queue_state(next_state, expected_slug=queue_slug)
        write_json_atomic(path, next_state)
        reloaded = read_json(path)
        validate_queue_state(reloaded, expected_slug=queue_slug)
        return reloaded
    finally:
        try:
            os.rmdir(lock_path)
        except FileNotFoundError:
            pass


def cmd_create(args: argparse.Namespace) -> int:
    queue_slug = ensure_queue_slug(args.queue_slug)
    at = args.at.strip() if args.at else now_iso()
    parse_iso(at, "at")

    def mutator(current: dict[str, Any] | None) -> dict[str, Any]:
        if current is not None:
            raise FlowError(f"队列状态文件已存在: {state_path_for_queue(queue_slug)}")
        return build_create_payload(queue_slug, args.plan_slugs, at)

    state = with_lock(queue_slug, mutator)
    sys.stdout.write(f"{queue_slug}: {state['current_status']} items={len(state['items'])}\n")
    return 0


def cmd_start_current(args: argparse.Namespace) -> int:
    queue_slug = ensure_queue_slug(args.queue_slug)
    at = args.at.strip() if args.at else now_iso()
    parse_iso(at, "at")

    def mutator(state: dict[str, Any] | None) -> dict[str, Any]:
        if state is None:
            raise FlowError(f"队列状态文件不存在: {state_path_for_queue(queue_slug)}")
        if state["current_status"] not in {"READY", "RUNNING"}:
            raise FlowError(f"队列状态 {state['current_status']} 不允许启动当前 item")
        item = current_item(state)
        if item["status"] == "RUNNING":
            return state
        if item["status"] != "PENDING":
            raise FlowError(f"当前 item 状态 {item['status']} 不允许启动")
        from_status = state["current_status"]
        item["status"] = "RUNNING"
        item["started_at"] = at
        append_transition(
            state,
            event="item_started",
            from_status=from_status,
            to_status="RUNNING",
            at=at,
            payload={"index": item["index"], "slug": item["slug"]},
        )
        return state

    state = with_lock(queue_slug, mutator)
    item = current_item(state)
    sys.stdout.write(f"{queue_slug}: RUNNING {item['slug']}\n")
    return 0


def cmd_mark_reviewed(args: argparse.Namespace) -> int:
    queue_slug = ensure_queue_slug(args.queue_slug)
    at = args.at.strip() if args.at else now_iso()
    parse_iso(at, "at")

    def mutator(state: dict[str, Any] | None) -> dict[str, Any]:
        if state is None:
            raise FlowError(f"队列状态文件不存在: {state_path_for_queue(queue_slug)}")
        if state["current_status"] != "RUNNING":
            raise FlowError(f"队列状态 {state['current_status']} 不允许标记 reviewed")
        item = current_item(state)
        if item["status"] != "RUNNING":
            raise FlowError(f"当前 item 状态 {item['status']} 不允许标记 reviewed")
        plan_state = validate_plan_slug(item["slug"], enforce_done_needs_work=False)
        if plan_state.get("current_status") != "DONE":
            raise FlowError(f"当前 item plan 状态不是 DONE: {plan_state.get('current_status')}")
        item["status"] = "DONE_REVIEWED"
        item["done_reviewed_at"] = at
        append_transition(
            state,
            event="item_done_reviewed",
            from_status="RUNNING",
            to_status="RUNNING",
            at=at,
            payload={"index": item["index"], "slug": item["slug"]},
        )
        return state

    state = with_lock(queue_slug, mutator)
    item = current_item(state)
    sys.stdout.write(f"{queue_slug}: DONE_REVIEWED {item['slug']}\n")
    return 0


def parse_json_arg(value: str | None, name: str) -> Any:
    if value is None or value == "":
        return []
    try:
        return json.loads(value)
    except json.JSONDecodeError as exc:
        raise FlowError(f"--{name} 不是合法 JSON") from exc


def cmd_record_heads(args: argparse.Namespace) -> int:
    queue_slug = ensure_queue_slug(args.queue_slug)
    heads = parse_json_arg(args.heads_json, "heads-json")
    if not isinstance(heads, list):
        raise FlowError("--heads-json 必须是数组")
    at = args.at.strip() if args.at else now_iso()
    parse_iso(at, "at")

    def mutator(state: dict[str, Any] | None) -> dict[str, Any]:
        if state is None:
            raise FlowError(f"队列状态文件不存在: {state_path_for_queue(queue_slug)}")
        if state["current_status"] != "RUNNING":
            raise FlowError(f"队列状态 {state['current_status']} 不允许记录 HEAD")
        item = current_item(state)
        if item["status"] != "DONE_REVIEWED":
            raise FlowError(f"当前 item 状态 {item['status']} 不允许记录 HEAD")
        item["head_before_commit"] = heads
        append_transition(
            state,
            event="heads_recorded",
            from_status="RUNNING",
            to_status="RUNNING",
            at=at,
            payload={"index": item["index"], "slug": item["slug"], "head_count": len(heads)},
        )
        return state

    state = with_lock(queue_slug, mutator)
    item = current_item(state)
    sys.stdout.write(f"{queue_slug}: HEADS_RECORDED {item['slug']}\n")
    return 0


def cmd_mark_committed(args: argparse.Namespace) -> int:
    queue_slug = ensure_queue_slug(args.queue_slug)
    commits = parse_json_arg(args.commits_json, "commits-json")
    if not isinstance(commits, list):
        raise FlowError("--commits-json 必须是数组")
    at = args.at.strip() if args.at else now_iso()
    parse_iso(at, "at")

    def mutator(state: dict[str, Any] | None) -> dict[str, Any]:
        if state is None:
            raise FlowError(f"队列状态文件不存在: {state_path_for_queue(queue_slug)}")
        if state["current_status"] != "RUNNING":
            raise FlowError(f"队列状态 {state['current_status']} 不允许标记 committed")
        item = current_item(state)
        if item["status"] != "DONE_REVIEWED":
            raise FlowError(f"当前 item 状态 {item['status']} 不允许标记 committed")
        if not item["head_before_commit"]:
            raise FlowError("标记 committed 前必须先记录 head_before_commit")
        item["status"] = "COMMITTED"
        item["committed_at"] = at
        item["commits"] = commits
        from_status = state["current_status"]
        state["active_index"] += 1
        next_status = "DONE" if state["active_index"] >= len(state["items"]) else "RUNNING"
        append_transition(
            state,
            event="item_committed",
            from_status=from_status,
            to_status=next_status,
            at=at,
            payload={
                "index": item["index"],
                "slug": item["slug"],
                "commit_count": len(commits),
            },
        )
        return state

    state = with_lock(queue_slug, mutator)
    sys.stdout.write(f"{queue_slug}: {state['current_status']} active_index={state['active_index']}\n")
    return 0


def cmd_fail(args: argparse.Namespace) -> int:
    queue_slug = ensure_queue_slug(args.queue_slug)
    reason = args.reason.strip() if args.reason else "orchestration failed"
    at = args.at.strip() if args.at else now_iso()
    parse_iso(at, "at")

    def mutator(state: dict[str, Any] | None) -> dict[str, Any]:
        if state is None:
            raise FlowError(f"队列状态文件不存在: {state_path_for_queue(queue_slug)}")
        if state["current_status"] in {"DONE", "FAILED"}:
            raise FlowError(f"队列状态 {state['current_status']} 不允许再次失败")
        item = current_item(state)
        item["status"] = "FAILED"
        item["error"] = reason
        append_transition(
            state,
            event="item_failed",
            from_status=state["current_status"],
            to_status="FAILED",
            at=at,
            payload={"index": item["index"], "slug": item["slug"], "reason": reason},
            note=reason,
        )
        return state

    state = with_lock(queue_slug, mutator)
    item = state["items"][state["active_index"]]
    sys.stdout.write(f"{queue_slug}: FAILED {item['slug']}: {reason}\n")
    return 0


def cmd_reopen_current(args: argparse.Namespace) -> int:
    queue_slug = ensure_queue_slug(args.queue_slug)
    reason = args.reason.strip() if args.reason else "manual recovery"
    at = args.at.strip() if args.at else now_iso()
    parse_iso(at, "at")

    def mutator(state: dict[str, Any] | None) -> dict[str, Any]:
        if state is None:
            raise FlowError(f"队列状态文件不存在: {state_path_for_queue(queue_slug)}")
        if state["current_status"] != "FAILED":
            raise FlowError(f"队列状态 {state['current_status']} 不允许 reopen-current")
        item = current_item(state)
        if item["status"] != "FAILED":
            raise FlowError(f"当前 item 状态 {item['status']} 不允许 reopen-current")
        validate_plan_slug(item["slug"], enforce_done_needs_work=False)
        item["status"] = "RUNNING"
        item["error"] = None
        if item["started_at"] is None:
            item["started_at"] = at
        append_transition(
            state,
            event="item_reopened",
            from_status="FAILED",
            to_status="RUNNING",
            at=at,
            payload={"index": item["index"], "slug": item["slug"], "reason": reason},
            note=reason,
        )
        return state

    state = with_lock(queue_slug, mutator)
    item = current_item(state)
    sys.stdout.write(f"{queue_slug}: RUNNING {item['slug']}\n")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    if args.queue_slug and args.all:
        raise FlowError("show 不能同时使用 --queue-slug 与 --all")
    if not args.queue_slug and not args.all:
        raise FlowError("show 需要提供 --queue-slug 或 --all")

    def render_one(queue_slug: str) -> Any:
        state = read_json(state_path_for_queue(queue_slug))
        validate_queue_state(state, expected_slug=queue_slug)
        payload: Any = state
        if args.field:
            payload = get_nested(payload, args.field)
        return payload

    if args.all:
        payload = [render_one(path.stem) for path in sorted(STATE_DIR.glob("*.json"))] if STATE_DIR.exists() else []
    else:
        payload = render_one(ensure_queue_slug(args.queue_slug))

    if isinstance(payload, (dict, list)):
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    elif payload is None:
        sys.stdout.write("null\n")
    else:
        sys.stdout.write(f"{payload}\n")
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    if args.queue_slug and args.all:
        raise FlowError("validate 不能同时使用 --queue-slug 与 --all")
    if not args.queue_slug and not args.all:
        raise FlowError("validate 需要提供 --queue-slug 或 --all")
    if args.all:
        invalid = False
        files = sorted(STATE_DIR.glob("*.json")) if STATE_DIR.exists() else []
        for path in files:
            try:
                state = read_json(path)
                validate_queue_state(state, expected_slug=path.stem)
                sys.stdout.write(f"OK {path.stem}\n")
            except FlowError as exc:
                invalid = True
                sys.stderr.write(f"INVALID {path.stem}: {exc}\n")
        if invalid:
            raise FlowError("存在无效队列状态文件")
        sys.stdout.write(f"validated {len(files)} orchestration state file(s)\n")
        return 0
    queue_slug = ensure_queue_slug(args.queue_slug)
    validate_queue_state(read_json(state_path_for_queue(queue_slug)), expected_slug=queue_slug)
    sys.stdout.write(f"OK {queue_slug}\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="flow-plan-orchestrate-state.sh",
        description="AI Flow 多普通 plan 队列状态机。",
    )
    subparsers = parser.add_subparsers(dest="command")

    create = subparsers.add_parser("create")
    create.add_argument("--queue-slug", required=True)
    create.add_argument("--at")
    create.add_argument("plan_slugs", nargs="+")
    create.set_defaults(func=cmd_create)

    start = subparsers.add_parser("start-current")
    start.add_argument("--queue-slug", required=True)
    start.add_argument("--at")
    start.set_defaults(func=cmd_start_current)

    reviewed = subparsers.add_parser("mark-reviewed")
    reviewed.add_argument("--queue-slug", required=True)
    reviewed.add_argument("--at")
    reviewed.set_defaults(func=cmd_mark_reviewed)

    heads = subparsers.add_parser("record-heads")
    heads.add_argument("--queue-slug", required=True)
    heads.add_argument("--heads-json")
    heads.add_argument("--at")
    heads.set_defaults(func=cmd_record_heads)

    committed = subparsers.add_parser("mark-committed")
    committed.add_argument("--queue-slug", required=True)
    committed.add_argument("--commits-json")
    committed.add_argument("--at")
    committed.set_defaults(func=cmd_mark_committed)

    fail = subparsers.add_parser("fail")
    fail.add_argument("--queue-slug", required=True)
    fail.add_argument("--reason")
    fail.add_argument("--at")
    fail.set_defaults(func=cmd_fail)

    reopen = subparsers.add_parser("reopen-current")
    reopen.add_argument("--queue-slug", required=True)
    reopen.add_argument("--reason")
    reopen.add_argument("--at")
    reopen.set_defaults(func=cmd_reopen_current)

    show = subparsers.add_parser("show")
    show.add_argument("--queue-slug")
    show.add_argument("--all", action="store_true")
    show.add_argument("--field")
    show.set_defaults(func=cmd_show)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--queue-slug")
    validate.add_argument("--all", action="store_true")
    validate.set_defaults(func=cmd_validate)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv[1:])
    if not hasattr(args, "func"):
        parser.print_help(sys.stderr)
        return 1
    return args.func(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except FlowError as exc:
        sys.stderr.write(f"{exc}\n")
        raise SystemExit(1)
