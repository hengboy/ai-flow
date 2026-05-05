#!/bin/bash
# flow-state.sh — AI Flow JSON 状态机唯一写入口

set -euo pipefail

python3 - "$@" <<'PY'
import argparse
import copy
import json
import os
import re
import sys
import tempfile
from datetime import datetime
from pathlib import Path


SCHEMA_VERSION = 1
STATUS_VALUES = {
    "PLANNED",
    "IMPLEMENTING",
    "AWAITING_REVIEW",
    "REVIEW_FAILED",
    "FIXING_REVIEW",
    "DONE",
}
REVIEW_MODES = {"regular", "recheck"}
REVIEW_RESULTS = {"passed", "failed", "passed_with_notes"}
ALLOWED_TRANSITIONS = {
    ("plan_created", None): "PLANNED",
    ("execute_started", "PLANNED"): "IMPLEMENTING",
    ("implementation_completed", "IMPLEMENTING"): "AWAITING_REVIEW",
    ("review_passed", "AWAITING_REVIEW"): "DONE",
    ("review_failed", "AWAITING_REVIEW"): "REVIEW_FAILED",
    ("fix_started", "REVIEW_FAILED"): "FIXING_REVIEW",
    ("fix_completed", "FIXING_REVIEW"): "AWAITING_REVIEW",
    ("recheck_passed", "DONE"): "DONE",
    ("recheck_failed", "DONE"): "REVIEW_FAILED",
}
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class FlowError(Exception):
    pass


PROJECT_DIR = Path.cwd().resolve()
FLOW_DIR = PROJECT_DIR / ".ai-flow"
STATE_DIR = FLOW_DIR / "state"
LOCKS_DIR = STATE_DIR / ".locks"
ACTOR = os.environ.get("AI_FLOW_ACTOR", "flow-state.sh")


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def parse_iso(value: str, field_name: str) -> datetime:
    if not isinstance(value, str):
        raise FlowError(f"{field_name} 必须是 ISO 时间字符串")
    try:
        return datetime.fromisoformat(value)
    except ValueError as exc:
        raise FlowError(f"{field_name} 不是合法的 ISO 时间: {value}") from exc


def ensure_slug(slug: str) -> str:
    if not slug or not SLUG_RE.match(slug):
        raise FlowError(f"非法 slug: {slug!r}；只允许小写字母、数字和连字符")
    return slug


def normalize_path(path_value: str) -> str:
    if not path_value:
        raise FlowError("路径参数不能为空")
    path = Path(path_value)
    if path.is_absolute():
        absolute = path.resolve()
    else:
        absolute = (PROJECT_DIR / path).resolve()

    try:
        return absolute.relative_to(PROJECT_DIR).as_posix()
    except ValueError:
        return absolute.as_posix()


def state_path_for_slug(slug: str) -> Path:
    return STATE_DIR / f"{ensure_slug(slug)}.json"


def load_state_by_slug(slug: str) -> dict:
    path = state_path_for_slug(slug)
    if not path.is_file():
        raise FlowError(f"状态文件不存在: {path}")
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        raise FlowError(f"状态文件 JSON 损坏: {path}") from exc


def write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = None
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


def append_transition(state: dict, *, event: str, to_status: str, at: str, artifacts=None, note: str = "") -> None:
    previous_status = state.get("current_status")
    transition = {
        "seq": len(state["transitions"]) + 1,
        "at": at,
        "event": event,
        "from": previous_status,
        "to": to_status,
        "actor": ACTOR,
        "artifacts": artifacts or {},
        "note": note,
    }
    state["current_status"] = to_status
    state["updated_at"] = at
    state["transitions"].append(transition)


def expected_latest_from_transitions(transitions: list, mode: str):
    events = {"regular": {"review_passed", "review_failed"}, "recheck": {"recheck_passed", "recheck_failed"}}[mode]
    for item in reversed(transitions):
        if item["event"] in events:
            return item["artifacts"].get("report_file")
    return None


def expected_rounds_from_transitions(transitions: list) -> dict:
    regular = 0
    recheck = 0
    for item in transitions:
        if item["event"] in {"review_passed", "review_failed"}:
            regular += 1
        elif item["event"] in {"recheck_passed", "recheck_failed"}:
            recheck += 1
    return {"regular": regular, "recheck": recheck}


def expected_last_review_from_transitions(transitions: list):
    for item in reversed(transitions):
        if item["event"] in {"review_passed", "review_failed", "recheck_passed", "recheck_failed"}:
            artifacts = item["artifacts"]
            mode = "recheck" if item["event"].startswith("recheck_") else "regular"
            # Use stored result to preserve passed_with_notes distinction
            result = artifacts.get("result", "passed" if item["event"].endswith("passed") else "failed")
            return {
                "mode": mode,
                "round": artifacts.get("round"),
                "result": result,
                "report_file": artifacts.get("report_file"),
                "at": item["at"],
            }
    return None


def get_nested(state: dict, field: str):
    value = state
    for part in field.split("."):
        if isinstance(value, dict) and part in value:
            value = value[part]
        else:
            raise FlowError(f"字段不存在: {field}")
    return value


def validate_transition_item(item: dict, previous_to, index: int) -> None:
    if not isinstance(item, dict):
        raise FlowError(f"transitions[{index}] 必须是对象")
    required = {"seq", "at", "event", "from", "to", "actor", "artifacts", "note"}
    missing = required - set(item.keys())
    if missing:
        raise FlowError(f"transitions[{index}] 缺少字段: {', '.join(sorted(missing))}")
    if item["seq"] != index + 1:
        raise FlowError(f"transitions[{index}] 的 seq 必须为 {index + 1}")
    parse_iso(item["at"], f"transitions[{index}].at")
    if item["to"] not in STATUS_VALUES:
        raise FlowError(f"transitions[{index}].to 不是合法状态: {item['to']}")
    if item["from"] is not None and item["from"] not in STATUS_VALUES:
        raise FlowError(f"transitions[{index}].from 不是合法状态: {item['from']}")
    if index == 0:
        if item["event"] != "plan_created" or item["from"] is not None or item["to"] != "PLANNED":
            raise FlowError("第一条 transition 必须是 null -> PLANNED 的 plan_created")
    else:
        if item["from"] != previous_to:
            raise FlowError(f"transitions[{index}] 的 from 必须等于上一条 to")
    if item["event"] not in {"repair", "repair_metadata"}:
        expected_to = ALLOWED_TRANSITIONS.get((item["event"], item["from"]))
        if expected_to is None or expected_to != item["to"]:
            raise FlowError(
                f"非法迁移: event={item['event']} from={item['from']} to={item['to']}"
            )
    if not isinstance(item["actor"], str) or not item["actor"]:
        raise FlowError(f"transitions[{index}].actor 不能为空")
    if not isinstance(item["artifacts"], dict):
        raise FlowError(f"transitions[{index}].artifacts 必须是对象")
    if not isinstance(item["note"], str):
        raise FlowError(f"transitions[{index}].note 必须是字符串")


def validate_state(state: dict, *, expected_slug: str = None) -> None:
    if not isinstance(state, dict):
        raise FlowError("状态文件根节点必须是 JSON 对象")

    required = {
        "schema_version",
        "slug",
        "title",
        "current_status",
        "created_at",
        "updated_at",
        "plan_file",
        "review_rounds",
        "latest_regular_review_file",
        "latest_recheck_review_file",
        "last_review",
        "active_fix",
        "transitions",
    }
    missing = required - set(state.keys())
    if missing:
        raise FlowError(f"状态文件缺少字段: {', '.join(sorted(missing))}")

    if state["schema_version"] != SCHEMA_VERSION:
        raise FlowError(f"schema_version 必须是 {SCHEMA_VERSION}")
    ensure_slug(state["slug"])
    if expected_slug and state["slug"] != expected_slug:
        raise FlowError(f"状态文件 slug 与文件名不一致: {state['slug']} != {expected_slug}")
    if not isinstance(state["title"], str) or not state["title"].strip():
        raise FlowError("title 不能为空")
    if state["current_status"] not in STATUS_VALUES:
        raise FlowError(f"current_status 不是合法状态: {state['current_status']}")

    created_at = parse_iso(state["created_at"], "created_at")
    updated_at = parse_iso(state["updated_at"], "updated_at")
    if updated_at < created_at:
        raise FlowError("updated_at 不能早于 created_at")

    if not isinstance(state["plan_file"], str) or not state["plan_file"]:
        raise FlowError("plan_file 不能为空")

    rounds = state["review_rounds"]
    if not isinstance(rounds, dict) or set(rounds.keys()) != {"regular", "recheck"}:
        raise FlowError("review_rounds 必须包含 regular 和 recheck")
    for key, value in rounds.items():
        if not isinstance(value, int) or value < 0:
            raise FlowError(f"review_rounds.{key} 必须是非负整数")

    transitions = state["transitions"]
    if not isinstance(transitions, list) or not transitions:
        raise FlowError("transitions 不能为空")
    previous_to = None
    for index, item in enumerate(transitions):
        validate_transition_item(item, previous_to, index)
        previous_to = item["to"]

    last_transition = transitions[-1]
    if state["updated_at"] != last_transition["at"]:
        raise FlowError("updated_at 必须等于最后一条 transition.at")
    if state["current_status"] != last_transition["to"]:
        raise FlowError("current_status 必须等于最后一条 transition.to")

    if state["created_at"] != transitions[0]["at"]:
        raise FlowError("created_at 必须等于第一条 transition.at")

    expected_rounds = expected_rounds_from_transitions(transitions)
    if rounds != expected_rounds:
        raise FlowError(
            f"review_rounds 与 transition 统计不一致: 期望 {expected_rounds}，实际 {rounds}"
        )

    expected_last_review = expected_last_review_from_transitions(transitions)
    if state["last_review"] != expected_last_review:
        raise FlowError("last_review 必须等于最近一次审查 transition 的派生结果")

    expected_latest_regular = expected_latest_from_transitions(transitions, "regular")
    expected_latest_recheck = expected_latest_from_transitions(transitions, "recheck")
    if state["latest_regular_review_file"] != expected_latest_regular:
        raise FlowError("latest_regular_review_file 与 transition 不一致")
    if state["latest_recheck_review_file"] != expected_latest_recheck:
        raise FlowError("latest_recheck_review_file 与 transition 不一致")

    active_fix = state["active_fix"]
    if state["current_status"] == "FIXING_REVIEW":
        if not isinstance(active_fix, dict):
            raise FlowError("FIXING_REVIEW 状态下 active_fix 不能为空")
        for key in ("mode", "round", "report_file", "at"):
            if key not in active_fix:
                raise FlowError(f"active_fix 缺少字段: {key}")
        if active_fix["mode"] not in REVIEW_MODES:
            raise FlowError("active_fix.mode 非法")
        if not isinstance(active_fix["round"], int) or active_fix["round"] <= 0:
            raise FlowError("active_fix.round 必须是正整数")
        if not isinstance(active_fix["report_file"], str) or not active_fix["report_file"]:
            raise FlowError("active_fix.report_file 不能为空")
        parse_iso(active_fix["at"], "active_fix.at")
    else:
        if active_fix is not None:
            raise FlowError("只有 FIXING_REVIEW 状态允许 active_fix 非空")


def with_lock(slug: str, mutator):
    slug = ensure_slug(slug)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOCKS_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = LOCKS_DIR / f"{slug}.lock"

    try:
        os.mkdir(lock_path)
    except FileExistsError as exc:
        raise FlowError(f"状态锁已存在，稍后重试: {lock_path}") from exc

    try:
        current_state = load_state_by_slug(slug) if state_path_for_slug(slug).exists() else None
        if current_state is not None:
            validate_state(current_state, expected_slug=slug)
        next_state = mutator(copy.deepcopy(current_state))
        validate_state(next_state, expected_slug=slug)
        write_json_atomic(state_path_for_slug(slug), next_state)
        reloaded = load_state_by_slug(slug)
        validate_state(reloaded, expected_slug=slug)
        return reloaded
    finally:
        try:
            os.rmdir(lock_path)
        except FileNotFoundError:
            pass


def cmd_create(args):
    plan_file = normalize_path(args.plan_file)
    title = args.title.strip()
    if not title:
        raise FlowError("title 不能为空")

    def mutator(state):
        if state is not None:
            raise FlowError(f"状态文件已存在: {state_path_for_slug(args.slug)}")
        at = now_iso()
        return {
            "schema_version": SCHEMA_VERSION,
            "slug": ensure_slug(args.slug),
            "title": title,
            "current_status": "PLANNED",
            "created_at": at,
            "updated_at": at,
            "plan_file": plan_file,
            "review_rounds": {"regular": 0, "recheck": 0},
            "latest_regular_review_file": None,
            "latest_recheck_review_file": None,
            "last_review": None,
            "active_fix": None,
            "transitions": [
                {
                    "seq": 1,
                    "at": at,
                    "event": "plan_created",
                    "from": None,
                    "to": "PLANNED",
                    "actor": ACTOR,
                    "artifacts": {"plan_file": plan_file},
                    "note": "",
                }
            ],
        }

    state = with_lock(args.slug, mutator)
    print(f"已创建状态: {state_path_for_slug(args.slug)} -> {state['current_status']}")


def require_state(state, slug: str) -> dict:
    if state is None:
        raise FlowError(f"状态文件不存在: {state_path_for_slug(slug)}")
    return state


def cmd_start_execute(args):
    def mutator(state):
        state = require_state(state, args.slug)
        if state["current_status"] != "PLANNED":
            raise FlowError(f"只有 PLANNED 可以 start-execute，当前是 {state['current_status']}")
        append_transition(
            state,
            event="execute_started",
            to_status="IMPLEMENTING",
            at=now_iso(),
            artifacts={"plan_file": state["plan_file"]},
        )
        return state

    state = with_lock(args.slug, mutator)
    print(f"{args.slug}: {state['current_status']}")


def cmd_finish_implementation(args):
    def mutator(state):
        state = require_state(state, args.slug)
        if state["current_status"] != "IMPLEMENTING":
            raise FlowError(f"只有 IMPLEMENTING 可以 finish-implementation，当前是 {state['current_status']}")
        append_transition(
            state,
            event="implementation_completed",
            to_status="AWAITING_REVIEW",
            at=now_iso(),
            artifacts={"plan_file": state["plan_file"]},
        )
        return state

    state = with_lock(args.slug, mutator)
    print(f"{args.slug}: {state['current_status']}")


def cmd_record_review(args):
    report_file = normalize_path(args.report_file)
    mode = args.mode
    result = args.result

    def mutator(state):
        state = require_state(state, args.slug)
        current_status = state["current_status"]
        if mode == "regular" and current_status != "AWAITING_REVIEW":
            raise FlowError(f"常规审查只允许 AWAITING_REVIEW，当前是 {current_status}")
        if mode == "recheck" and current_status != "DONE":
            raise FlowError(f"再审查只允许 DONE，当前是 {current_status}")

        round_number = state["review_rounds"][mode] + 1
        at = now_iso()
        if mode == "regular":
            event_base = "review"
        else:
            event_base = "recheck"
        # passed_with_notes maps to the same DONE state as passed
        result_suffix = "passed" if result in ("passed", "passed_with_notes") else "failed"
        event = f"{event_base}_{result_suffix}"
        to_status = ALLOWED_TRANSITIONS[(event, current_status)]

        state["review_rounds"][mode] = round_number
        if mode == "regular":
            state["latest_regular_review_file"] = report_file
        else:
            state["latest_recheck_review_file"] = report_file
        state["last_review"] = {
            "mode": mode,
            "round": round_number,
            "result": result,
            "report_file": report_file,
            "at": at,
        }
        state["active_fix"] = None
        append_transition(
            state,
            event=event,
            to_status=to_status,
            at=at,
            artifacts={
                "mode": mode,
                "round": round_number,
                "result": result,
                "report_file": report_file,
            },
        )
        return state

    state = with_lock(args.slug, mutator)
    print(f"{args.slug}: {state['current_status']}")


def cmd_start_fix(args):
    def mutator(state):
        state = require_state(state, args.slug)
        if state["current_status"] != "REVIEW_FAILED":
            raise FlowError(f"只有 REVIEW_FAILED 可以 start-fix，当前是 {state['current_status']}")
        if not state["last_review"] or state["last_review"]["result"] != "failed":
            raise FlowError("REVIEW_FAILED 状态必须存在失败的 last_review")
        at = now_iso()
        state["active_fix"] = {
            "mode": state["last_review"]["mode"],
            "round": state["last_review"]["round"],
            "report_file": state["last_review"]["report_file"],
            "at": at,
        }
        append_transition(
            state,
            event="fix_started",
            to_status="FIXING_REVIEW",
            at=at,
            artifacts={"report_file": state["active_fix"]["report_file"]},
        )
        return state

    state = with_lock(args.slug, mutator)
    print(f"{args.slug}: {state['current_status']}")


def cmd_finish_fix(args):
    def mutator(state):
        state = require_state(state, args.slug)
        if state["current_status"] != "FIXING_REVIEW":
            raise FlowError(f"只有 FIXING_REVIEW 可以 finish-fix，当前是 {state['current_status']}")
        report_file = state["active_fix"]["report_file"]
        state["active_fix"] = None
        append_transition(
            state,
            event="fix_completed",
            to_status="AWAITING_REVIEW",
            at=now_iso(),
            artifacts={"report_file": report_file},
        )
        return state

    state = with_lock(args.slug, mutator)
    print(f"{args.slug}: {state['current_status']}")


def cmd_show(args):
    if args.slug:
        state = load_state_by_slug(args.slug)
        validate_state(state, expected_slug=args.slug)
        payload = get_nested(state, args.field) if args.field else state
    else:
        states = []
        if STATE_DIR.exists():
            for path in sorted(STATE_DIR.glob("*.json")):
                state = load_state_by_slug(path.stem)
                validate_state(state, expected_slug=path.stem)
                states.append(state)
        payload = states

    if isinstance(payload, (dict, list)):
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    elif payload is None:
        sys.stdout.write("null\n")
    else:
        sys.stdout.write(f"{payload}\n")


def cmd_validate(args):
    if args.all:
        files = sorted(STATE_DIR.glob("*.json")) if STATE_DIR.exists() else []
        if not files:
            print("没有状态文件")
            return
        for path in files:
            state = load_state_by_slug(path.stem)
            validate_state(state, expected_slug=path.stem)
            print(f"OK {path}")
        return

    if not args.slug:
        raise FlowError("validate 需要提供 slug 或 --all")
    state = load_state_by_slug(args.slug)
    validate_state(state, expected_slug=args.slug)
    print(f"OK {state_path_for_slug(args.slug)}")


def cmd_repair(args):
    def mutator(state):
        state = require_state(state, args.slug)
        before_status = state["current_status"]
        after_status = args.status or before_status
        if after_status not in STATUS_VALUES:
            raise FlowError(f"repair 指定了非法状态: {after_status}")
        if args.title is not None:
            if not args.title.strip():
                raise FlowError("repair title 不能为空")
            state["title"] = args.title.strip()
        if args.plan_file is not None:
            state["plan_file"] = normalize_path(args.plan_file)
        if args.clear_active_fix:
            state["active_fix"] = None
        elif args.active_fix_report_file is not None:
            if args.active_fix_mode not in REVIEW_MODES:
                raise FlowError("repair active_fix_mode 必须是 regular 或 recheck")
            if args.active_fix_round is None or args.active_fix_round <= 0:
                raise FlowError("repair active_fix_round 必须是正整数")
            state["active_fix"] = {
                "mode": args.active_fix_mode,
                "round": args.active_fix_round,
                "report_file": normalize_path(args.active_fix_report_file),
                "at": args.active_fix_at or now_iso(),
            }

        append_transition(
            state,
            event="repair" if after_status != before_status else "repair_metadata",
            to_status=after_status,
            at=now_iso(),
            artifacts={},
            note=args.note or "",
        )
        return state

    state = with_lock(args.slug, mutator)
    print(f"{args.slug}: {state['current_status']}")


def build_parser():
    parser = argparse.ArgumentParser(prog="flow-state.sh")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--slug", required=True)
    create.add_argument("--title", required=True)
    create.add_argument("--plan-file", required=True)
    create.set_defaults(func=cmd_create)

    start_execute = subparsers.add_parser("start-execute")
    start_execute.add_argument("slug")
    start_execute.set_defaults(func=cmd_start_execute)

    finish_implementation = subparsers.add_parser("finish-implementation")
    finish_implementation.add_argument("slug")
    finish_implementation.set_defaults(func=cmd_finish_implementation)

    record_review = subparsers.add_parser("record-review")
    record_review.add_argument("--slug", required=True)
    record_review.add_argument("--mode", required=True, choices=sorted(REVIEW_MODES))
    record_review.add_argument("--result", required=True, choices=sorted(REVIEW_RESULTS))
    record_review.add_argument("--report-file", required=True)
    record_review.set_defaults(func=cmd_record_review)

    start_fix = subparsers.add_parser("start-fix")
    start_fix.add_argument("slug")
    start_fix.set_defaults(func=cmd_start_fix)

    finish_fix = subparsers.add_parser("finish-fix")
    finish_fix.add_argument("slug")
    finish_fix.set_defaults(func=cmd_finish_fix)

    show = subparsers.add_parser("show")
    show.add_argument("slug", nargs="?")
    show.add_argument("--field")
    show.set_defaults(func=cmd_show)

    validate = subparsers.add_parser("validate")
    validate.add_argument("slug", nargs="?")
    validate.add_argument("--all", action="store_true")
    validate.set_defaults(func=cmd_validate)

    repair = subparsers.add_parser("repair")
    repair.add_argument("--slug", required=True)
    repair.add_argument("--status")
    repair.add_argument("--title")
    repair.add_argument("--plan-file")
    repair.add_argument("--active-fix-mode")
    repair.add_argument("--active-fix-round", type=int)
    repair.add_argument("--active-fix-report-file")
    repair.add_argument("--active-fix-at")
    repair.add_argument("--clear-active-fix", action="store_true")
    repair.add_argument("--note")
    repair.set_defaults(func=cmd_repair)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    ensure_slug(getattr(args, "slug", "noop")) if hasattr(args, "slug") and args.slug else None
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except FlowError as exc:
        print(f"错误: {exc}", file=sys.stderr)
        sys.exit(1)
PY
