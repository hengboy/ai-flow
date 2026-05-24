#!/usr/bin/env python3
"""AI Flow plan group state machine v1."""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
GROUP_STATUS_VALUES = {
    "AWAITING_GROUP_REVIEW",
    "GROUP_REVIEW_FAILED",
    "GROUP_PLANNED",
    "RUNNING_CHILD",
    "AWAITING_GROUP_FINAL_REVIEW",
    "GROUP_FINAL_REVIEW_FAILED",
    "GROUP_DONE",
}
GROUP_EVENT_TRANSITIONS = {
    ("group_created", None): "AWAITING_GROUP_REVIEW",
    ("group_review_passed", "AWAITING_GROUP_REVIEW"): "GROUP_PLANNED",
    ("group_review_failed", "AWAITING_GROUP_REVIEW"): "GROUP_REVIEW_FAILED",
    ("group_reopened", "GROUP_REVIEW_FAILED"): "AWAITING_GROUP_REVIEW",
    ("child_bound", "GROUP_PLANNED"): "RUNNING_CHILD",
    ("child_bound", "GROUP_REVIEW_FAILED"): "RUNNING_CHILD",
    ("child_completed", "RUNNING_CHILD"): "RUNNING_CHILD",
    ("child_completed", "RUNNING_CHILD", "all_done"): "AWAITING_GROUP_FINAL_REVIEW",
    ("final_review_passed", "AWAITING_GROUP_FINAL_REVIEW"): "GROUP_DONE",
    ("final_review_failed", "AWAITING_GROUP_FINAL_REVIEW"): "GROUP_FINAL_REVIEW_FAILED",
    ("final_review_reopened", "GROUP_FINAL_REVIEW_FAILED"): "AWAITING_GROUP_FINAL_REVIEW",
    ("implementation_reopened", "GROUP_PLANNED"): "RUNNING_CHILD",
    ("implementation_reopened", "GROUP_DONE"): "RUNNING_CHILD",
    ("implementation_reopened", "RUNNING_CHILD"): "RUNNING_CHILD",
    ("child_added", "GROUP_REVIEW_FAILED"): "GROUP_PLANNED",
}
GROUP_TRANSITION_EVENTS = {
    "group_created",
    "group_review_passed",
    "group_review_failed",
    "group_reopened",
    "child_bound",
    "child_completed",
    "final_review_passed",
    "final_review_failed",
    "final_review_reopened",
    "implementation_reopened",
    "child_added",
}

GROUP_SLUG_RE = re.compile(r"^(\d{8}-)?[a-z0-9一-鿿][a-z0-9一-鿿-]*$")
CHILD_ID_RE = re.compile(r"^child-[a-z0-9一-鿿][a-z0-9一-鿿-]*$")

CHILD_SCHEMA_KEYS = {
    "child_id", "title", "depends_on", "scope_summary",
    "primary_risk", "planned_semantic_slug",
    "created_slug", "plan_file", "state_file",
}
GROUP_ROOT_KEYS = {
    "schema_version", "group_slug", "title", "group_file",
    "current_status", "children", "current_child_id",
    "created_at", "updated_at", "transitions",
}
FORBIDDEN_CHILD_EXEC_FIELDS = {
    "current_status", "last_status", "transitions", "review", "derived",
}


class FlowError(Exception):
    pass


def resolve_project_dir() -> Path:
    cwd = Path.cwd().resolve()
    candidate = cwd
    while True:
        if (candidate / ".ai-flow" / "plan-groups" / "state").is_dir():
            return candidate
        parent = candidate.parent
        if parent == candidate:
            break
        candidate = parent
    try:
        import subprocess
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10, cwd=str(cwd),
        )
        if result.returncode == 0 and result.stdout.strip():
            return Path(result.stdout.strip()).resolve()
    except FileNotFoundError:
        pass
    return cwd


PROJECT_DIR = resolve_project_dir()
GROUPS_DIR = PROJECT_DIR / ".ai-flow" / "plan-groups"
STATE_DIR = GROUPS_DIR / "state"
REPORTS_DIR = GROUPS_DIR / "reports"
LOCKS_DIR = STATE_DIR / ".locks"


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def parse_iso(value: str, field_name: str) -> datetime:
    if not isinstance(value, str):
        raise FlowError(f"{field_name} 必须是 ISO 时间字符串")
    try:
        return datetime.fromisoformat(value)
    except ValueError as exc:
        raise FlowError(f"{field_name} 不是合法的 ISO 时间: {value}") from exc


def ensure_group_slug(slug: str) -> str:
    cleaned = slug.strip()
    if GROUP_SLUG_RE.fullmatch(cleaned):
        return cleaned
    raise FlowError(f"group_slug 格式非法: {slug!r}")


def state_path_for_slug(slug: str) -> Path:
    return STATE_DIR / f"{ensure_group_slug(slug)}.json"


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
            "w", encoding="utf-8", dir=path.parent,
            prefix=f"{path.stem}.", suffix=".tmp", delete=False,
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


def load_group_state(slug: str) -> dict[str, Any]:
    return read_json(state_path_for_slug(slug))


def default_next_events(status: str) -> list[str]:
    mapping = {
        "AWAITING_GROUP_REVIEW": ["group_review_passed", "group_review_failed"],
        "GROUP_REVIEW_FAILED": ["group_reopened", "child_added"],
        "GROUP_PLANNED": ["child_bound"],
        "RUNNING_CHILD": ["child_completed", "implementation_reopened"],
        "AWAITING_GROUP_FINAL_REVIEW": ["final_review_passed", "final_review_failed"],
        "GROUP_FINAL_REVIEW_FAILED": ["final_review_reopened"],
        "GROUP_DONE": ["implementation_reopened"],
    }
    return mapping[status]


def validate_children(children: Any) -> None:
    if not isinstance(children, list):
        raise FlowError("children 必须是数组")
    seen_ids: set[str] = set()
    for idx, child in enumerate(children):
        if not isinstance(child, dict):
            raise FlowError(f"children[{idx}] 必须是对象")
        child_keys = set(child.keys())
        unknown = child_keys - CHILD_SCHEMA_KEYS
        if unknown:
            raise FlowError(f"children[{idx}] 存在未知字段: {', '.join(sorted(unknown))}")
        for key in ("child_id", "title"):
            if key not in child:
                raise FlowError(f"children[{idx}] 缺少字段: {key}")
        child_id = child["child_id"]
        if not isinstance(child_id, str) or not CHILD_ID_RE.fullmatch(child_id):
            raise FlowError(f"children[{idx}].child_id 格式非法: {child_id!r}")
        if child_id in seen_ids:
            raise FlowError(f"children[{idx}].child_id 重复: {child_id}")
        seen_ids.add(child_id)

        if not isinstance(child.get("depends_on"), list):
            raise FlowError(f"children[{idx}].depends_on 必须是数组")
        for dep_idx, dep in enumerate(child["depends_on"]):
            if not isinstance(dep, str) or not CHILD_ID_RE.fullmatch(dep):
                raise FlowError(f"children[{idx}].depends_on[{dep_idx}] 格式非法: {dep!r}")

        for key in ("scope_summary", "primary_risk", "planned_semantic_slug"):
            if key not in child:
                raise FlowError(f"children[{idx}] 缺少字段: {key}")

        for exec_field in FORBIDDEN_CHILD_EXEC_FIELDS:
            if exec_field in child:
                raise FlowError(f"children[{idx}] 不允许包含执行状态字段: {exec_field}")


def validate_group_state(state: dict[str, Any], *, expected_slug: str | None = None) -> None:
    if not isinstance(state, dict):
        raise FlowError("状态文件根节点必须是对象")
    missing = GROUP_ROOT_KEYS - set(state)
    if missing:
        raise FlowError(f"状态文件缺少字段: {', '.join(sorted(missing))}")
    extras = set(state) - GROUP_ROOT_KEYS
    if extras:
        raise FlowError(f"状态文件存在未知字段: {', '.join(sorted(extras))}")
    if state["schema_version"] != SCHEMA_VERSION:
        raise FlowError(f"schema_version 非法: {state['schema_version']}（请删除后重建）")
    slug = ensure_group_slug(state["group_slug"])
    if expected_slug and slug != expected_slug:
        raise FlowError(f"group_slug 不一致: {slug} != {expected_slug}")
    if not isinstance(state["title"], str) or not state["title"].strip():
        raise FlowError("title 不能为空")
    if not isinstance(state["group_file"], str) or not state["group_file"]:
        raise FlowError("group_file 不能为空")
    if state["current_status"] not in GROUP_STATUS_VALUES:
        raise FlowError(f"current_status 非法: {state['current_status']}")
    validate_children(state["children"])
    cid = state.get("current_child_id")
    if cid is not None and (not isinstance(cid, str) or not CHILD_ID_RE.fullmatch(cid)):
        raise FlowError(f"current_child_id 格式非法: {cid!r}")
    created_at = parse_iso(state["created_at"], "created_at")
    updated_at = parse_iso(state["updated_at"], "updated_at")
    if updated_at < created_at:
        raise FlowError("updated_at 不能早于 created_at")
    transitions = state["transitions"]
    if not isinstance(transitions, list) or not transitions:
        raise FlowError("transitions 不能为空")
    previous_to = None
    for idx, item in enumerate(transitions):
        if not isinstance(item, dict):
            raise FlowError(f"transitions[{idx}] 必须是对象")
        item_required = {"seq", "at", "event", "from", "to", "actor", "payload", "note"}
        item_keys = set(item)
        item_missing = item_required - item_keys
        if item_missing:
            raise FlowError(f"transitions[{idx}] 缺少字段: {', '.join(sorted(item_missing))}")
        item_extras = item_keys - item_required
        if item_extras:
            raise FlowError(f"transitions[{idx}] 存在未知字段: {', '.join(sorted(item_extras))}")
        if item["seq"] != idx + 1:
            raise FlowError(f"transitions[{idx}].seq 必须为 {idx + 1}")
        parse_iso(item["at"], f"transitions[{idx}].at")
        event = item["event"]
        if event not in GROUP_TRANSITION_EVENTS:
            raise FlowError(f"transitions[{idx}].event 非法: {event}")
        if item["from"] is not None and item["from"] not in GROUP_STATUS_VALUES:
            raise FlowError(f"transitions[{idx}].from 非法: {item['from']}")
        if item["to"] not in GROUP_STATUS_VALUES:
            raise FlowError(f"transitions[{idx}].to 非法: {item['to']}")
        if idx == 0:
            if event != "group_created" or item["from"] is not None or item["to"] != "AWAITING_GROUP_REVIEW":
                raise FlowError("第一条 transition 必须是 group_created: null -> AWAITING_GROUP_REVIEW")
        elif item["from"] != previous_to:
            raise FlowError(f"transitions[{idx}].from 必须等于上一条 to")
        expected_to = GROUP_EVENT_TRANSITIONS.get((event, item["from"]))
        # 兼容 3-tuple 键（如 child_completed + all_done）
        if expected_to is None or expected_to != item["to"]:
            for key, val in GROUP_EVENT_TRANSITIONS.items():
                if len(key) == 3 and key[0] == event and key[1] == item["from"] and val == item["to"]:
                    expected_to = val
                    break
        if expected_to is None:
            raise FlowError(f"非法迁移: event={event} from={item['from']}")
        if expected_to != item["to"]:
            raise FlowError(f"非法迁移: event={event} from={item['from']} to={item['to']} (预期 {expected_to})")
        if not isinstance(item["actor"], str) or not item["actor"].strip():
            raise FlowError(f"transitions[{idx}].actor 不能为空")
        if not isinstance(item["note"], str):
            raise FlowError(f"transitions[{idx}].note 必须是字符串")
        if not isinstance(item["payload"], dict):
            raise FlowError(f"transitions[{idx}].payload 必须是对象")
        previous_to = item["to"]
    if state["created_at"] != transitions[0]["at"]:
        raise FlowError("created_at 必须等于第一条 transition.at")
    if state["updated_at"] != transitions[-1]["at"]:
        raise FlowError("updated_at 必须等于最后一条 transition.at")
    if state["current_status"] != transitions[-1]["to"]:
        raise FlowError("current_status 必须等于最后一条 transition.to")
    created_payload = transitions[0]["payload"]
    if state["title"] != created_payload.get("title"):
        raise FlowError("title 不得在 group_created 后修改")
    if state["group_file"] != created_payload.get("group_file"):
        raise FlowError("group_file 不得在 group_created 后修改")


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


def require_arg(value: str | None, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise FlowError(f"{name} 不能为空")
    return value.strip()


def disallow_args(event: str, args: argparse.Namespace, field_names: list[str]) -> None:
    for field_name in field_names:
        value = getattr(args, field_name)
        if value is None or (isinstance(value, str) and value == ""):
            continue
        raise FlowError(f"{event} 不接受参数 --{field_name.replace('_', '-')}")


def build_transition_payload(event: str, state: dict[str, Any] | None, args: argparse.Namespace) -> dict[str, Any]:
    if event == "group_created":
        if state is not None:
            raise FlowError(f"状态文件已存在: {state_path_for_slug(args.group_slug)}")
        disallow_args(event, args, ["result", "report_file", "engine", "model"])
        payload = {
            "title": require_arg(args.title, "title"),
            "group_file": require_arg(args.group_file, "group_file"),
            "children": [],
        }
        children_json = getattr(args, "children_json", None)
        if children_json is not None:
            try:
                parsed = json.loads(require_arg(children_json, "children_json"))
                if not isinstance(parsed, list):
                    raise FlowError("children_json 必须是数组")
                payload["children"] = parsed
            except json.JSONDecodeError as exc:
                raise FlowError("children_json 不是合法 JSON") from exc
        return payload
    if state is None:
        raise FlowError(f"状态文件不存在: {state_path_for_slug(args.group_slug)}")
    disallow_args(event, args, ["title", "group_file", "children_json"])
    return {}


def resolve_transition_target(event: str, state: dict[str, Any], payload: dict[str, Any]) -> str | None:
    if event == "child_completed":
        all_done = True
        for child in state.get("children", []):
            if child.get("created_slug") is None:
                continue
            child_state_path = STATE_DIR.parent.parent / "state" / f"{child['created_slug']}.json"
            if not child_state_path.exists():
                all_done = False
                break
            child_state = read_json(child_state_path)
            if child_state.get("current_status") != "DONE":
                all_done = False
                break
        return "all_done" if all_done else None
    return None


def cmd_transition(args: argparse.Namespace) -> int:
    slug = ensure_group_slug(args.group_slug)
    event = args.event
    at = args.at.strip() if isinstance(args.at, str) and args.at.strip() else now_iso()
    parse_iso(at, "at")
    note = (args.note or "").strip()
    actor = os.environ.get("AI_FLOW_ACTOR", "flow-plan-group-state.sh")

    def mutator(current_state: dict[str, Any] | None) -> dict[str, Any]:
        payload = build_transition_payload(event, current_state, args)
        if event == "group_created":
            state_file_path = state_path_for_slug(slug)
            if state_file_path.exists():
                raise FlowError(f"状态文件已存在: {state_file_path}")
            return {
                "schema_version": SCHEMA_VERSION,
                "group_slug": slug,
                "title": payload["title"],
                "group_file": payload["group_file"],
                "current_status": "AWAITING_GROUP_REVIEW",
                "children": payload["children"],
                "current_child_id": None,
                "created_at": at,
                "updated_at": at,
                "transitions": [
                    {
                        "seq": 1,
                        "at": at,
                        "event": "group_created",
                        "from": None,
                        "to": "AWAITING_GROUP_REVIEW",
                        "actor": actor,
                        "payload": payload,
                        "note": note,
                    }
                ],
            }
        assert current_state is not None
        current_status = current_state["current_status"]
        target_hint = resolve_transition_target(event, current_state, payload)
        key = (event, current_status) if target_hint is None else (event, current_status, target_hint)
        next_status = GROUP_EVENT_TRANSITIONS.get(key)
        if next_status is None:
            raise FlowError(f"非法迁移: event={event} from={current_status}")
        current_state["transitions"].append(
            {
                "seq": len(current_state["transitions"]) + 1,
                "at": at,
                "event": event,
                "from": current_status,
                "to": next_status,
                "actor": actor,
                "payload": payload,
                "note": note,
            }
        )
        current_state["current_status"] = next_status
        current_state["updated_at"] = at
        return current_state

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOCKS_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = LOCKS_DIR / f"{slug}.lock"
    try:
        os.mkdir(lock_path)
    except FileExistsError as exc:
        raise FlowError(f"状态锁已存在: {lock_path}") from exc
    try:
        path = state_path_for_slug(slug)
        current = None
        if path.exists():
            current = read_json(path)
            validate_group_state(current, expected_slug=slug)
        next_state = mutator(copy.deepcopy(current))
        validate_group_state(next_state, expected_slug=slug)
        write_json_atomic(path, next_state)
        reloaded = read_json(path)
        validate_group_state(reloaded, expected_slug=slug)
    finally:
        try:
            os.rmdir(lock_path)
        except FileNotFoundError:
            pass

    sys.stdout.write(f"{slug}: {next_state['current_status']}\n")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    if args.group_slug and args.all:
        raise FlowError("show 不能同时使用 --group-slug 与 --all")
    if not args.group_slug and not args.all:
        raise FlowError("show 需要提供 --group-slug 或 --all")

    def render_one(slug: str) -> Any:
        state = load_group_state(slug)
        validate_group_state(state, expected_slug=slug)
        payload: Any = state if args.raw else state
        if args.field:
            payload = get_nested(payload, args.field)
        return payload

    if args.all:
        files = sorted(STATE_DIR.glob("*.json")) if STATE_DIR.exists() else []
        payload = [render_one(path.stem) for path in files]
    else:
        payload = render_one(ensure_group_slug(args.group_slug))

    if isinstance(payload, (dict, list)):
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    elif payload is None:
        sys.stdout.write("null\n")
    else:
        sys.stdout.write(f"{payload}\n")
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    if args.group_slug and args.all:
        raise FlowError("validate 不能同时使用 --group-slug 与 --all")
    if not args.group_slug and not args.all:
        raise FlowError("validate 需要提供 --group-slug 或 --all")
    if args.all:
        files = sorted(STATE_DIR.glob("*.json")) if STATE_DIR.exists() else []
        invalid = False
        for path in files:
            try:
                state = read_json(path)
                validate_group_state(state, expected_slug=path.stem)
                sys.stdout.write(f"OK {path.stem}\n")
            except FlowError as exc:
                invalid = True
                sys.stderr.write(f"INVALID {path.stem}: {exc}\n")
        if invalid:
            raise FlowError("存在无效状态文件")
        sys.stdout.write(f"validated {len(files)} group state file(s)\n")
        return 0
    slug = ensure_group_slug(args.group_slug)
    validate_group_state(load_group_state(slug), expected_slug=slug)
    sys.stdout.write(f"OK {slug}\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="flow-plan-group-state.sh",
        description="AI Flow 计划组状态机 v1。唯一写入口是 transition。",
    )
    subparsers = parser.add_subparsers(dest="command")

    transition = subparsers.add_parser("transition", description="统一状态写入口")
    transition.add_argument("--group-slug", required=True)
    transition.add_argument("--event", required=True, choices=sorted(GROUP_TRANSITION_EVENTS))
    transition.add_argument("--note", default="")
    transition.add_argument("--at")
    transition.add_argument("--title")
    transition.add_argument("--group-file")
    transition.add_argument("--children-json")
    transition.add_argument("--result")
    transition.add_argument("--report-file")
    transition.add_argument("--engine")
    transition.add_argument("--model")
    transition.set_defaults(func=cmd_transition)

    show = subparsers.add_parser("show", description="查看状态文件")
    show.add_argument("--group-slug")
    show.add_argument("--all", action="store_true")
    show.add_argument("--field")
    show.add_argument("--raw", action="store_true")
    show.set_defaults(func=cmd_show)

    validate = subparsers.add_parser("validate", description="校验状态文件")
    validate.add_argument("--group-slug")
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
