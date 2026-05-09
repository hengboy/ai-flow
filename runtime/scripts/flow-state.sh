#!/bin/bash
# flow-state.sh — AI Flow JSON 状态机唯一写入口

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/flow-common.sh"
ai_flow_setup_runtime_logging "${BASH_SOURCE[0]}" create

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


SCHEMA_VERSION = 2
STATUS_VALUES = {
    "AWAITING_PLAN_REVIEW",
    "PLAN_REVIEW_FAILED",
    "PLANNED",
    "IMPLEMENTING",
    "AWAITING_REVIEW",
    "REVIEW_FAILED",
    "FIXING_REVIEW",
    "DONE",
}
REVIEW_MODES = {"regular", "recheck"}
REVIEW_RESULTS = {"passed", "failed", "passed_with_notes"}
PLAN_REVIEW_RESULTS = {"passed", "failed", "passed_with_notes"}
ALLOWED_TRANSITIONS = {
    ("plan_created", None): "AWAITING_PLAN_REVIEW",
    ("plan_review_failed", "AWAITING_PLAN_REVIEW"): "PLAN_REVIEW_FAILED",
    ("plan_review_failed", "PLAN_REVIEW_FAILED"): "PLAN_REVIEW_FAILED",
    ("plan_review_passed", "AWAITING_PLAN_REVIEW"): "PLANNED",
    ("plan_review_passed", "PLAN_REVIEW_FAILED"): "PLANNED",
    ("execute_started", "PLANNED"): "IMPLEMENTING",
    ("implementation_completed", "IMPLEMENTING"): "AWAITING_REVIEW",
    ("review_passed", "AWAITING_REVIEW"): "DONE",
    ("review_failed", "AWAITING_REVIEW"): "REVIEW_FAILED",
    ("fix_started", "REVIEW_FAILED"): "FIXING_REVIEW",
    ("fix_completed", "FIXING_REVIEW"): "AWAITING_REVIEW",
    ("recheck_passed", "DONE"): "DONE",
    ("recheck_failed", "DONE"): "REVIEW_FAILED",
}
LEGACY_EVENT_ALIASES = {
    "coding_review_passed": "review_passed",
    "coding_review_failed": "review_failed",
    "coding_recheck_passed": "recheck_passed",
    "coding_recheck_failed": "recheck_failed",
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


def review_result_from_transition(item: dict) -> str:
    result = (item.get("artifacts") or {}).get("result")
    if result in REVIEW_RESULTS:
        return result
    return "passed" if item["event"].endswith("passed") else "failed"


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
            return {
                "mode": mode,
                "round": artifacts.get("round"),
                "result": review_result_from_transition(item),
                "report_file": artifacts.get("report_file"),
                "at": item["at"],
            }
    return None


def expected_active_fix_from_transitions(transitions: list, current_status: str, last_review):
    if current_status != "FIXING_REVIEW":
        return None

    latest_fix_started = None
    for item in reversed(transitions):
        if item["event"] == "fix_started":
            latest_fix_started = item
            break

    if latest_fix_started is None:
        raise FlowError("FIXING_REVIEW 状态必须存在 fix_started transition")
    if not last_review:
        raise FlowError("FIXING_REVIEW 状态必须能推导出 last_review")

    report_file = latest_fix_started["artifacts"].get("report_file") or last_review.get("report_file")
    if not report_file:
        raise FlowError("FIXING_REVIEW 状态无法推导 active_fix.report_file")

    return {
        "mode": last_review["mode"],
        "round": last_review["round"],
        "report_file": report_file,
        "at": latest_fix_started["at"],
    }


def synchronize_derived_fields(state: dict) -> dict:
    transitions = state.get("transitions")
    if not isinstance(transitions, list) or not transitions:
        raise FlowError("transitions 不能为空")

    first_transition = transitions[0]
    last_transition = transitions[-1]
    first_plan_file = (first_transition.get("artifacts") or {}).get("plan_file")
    if (not state.get("plan_file")) and first_plan_file:
        state["plan_file"] = first_plan_file

    state["created_at"] = first_transition["at"]
    state["updated_at"] = last_transition["at"]
    state["current_status"] = last_transition["to"]
    state["review_rounds"] = expected_rounds_from_transitions(transitions)
    state["latest_regular_review_file"] = expected_latest_from_transitions(transitions, "regular")
    state["latest_recheck_review_file"] = expected_latest_from_transitions(transitions, "recheck")
    state["last_review"] = expected_last_review_from_transitions(transitions)
    state["active_fix"] = expected_active_fix_from_transitions(
        transitions, state["current_status"], state["last_review"]
    )
    return state


def build_execution_scope(*, mode, workspace_file=None):
    """Build execution_scope from explicit parameters or auto-detect."""
    if mode == "workspace":
        if not workspace_file:
            raise FlowError("workspace 模式必须提供 workspace_file")
        ws_path = Path(workspace_file)
        if ws_path.is_absolute():
            abs_ws = ws_path.resolve()
        else:
            abs_ws = (PROJECT_DIR / ws_path).resolve()
        try:
            rel_ws = abs_ws.relative_to(PROJECT_DIR).as_posix()
        except ValueError:
            rel_ws = abs_ws.as_posix()

        # Load manifest to get repo list
        if not abs_ws.is_file():
            raise FlowError(f"workspace manifest 不存在: {abs_ws}")
        manifest = json.loads(abs_ws.read_text(encoding="utf-8"))
        repos = manifest.get("repos")
        if not isinstance(repos, list) or not repos:
            raise FlowError("workspace manifest repos 必须是非空数组")

        # Validate each repo is a valid git repo
        import subprocess
        validated_repos = []
        seen_ids: set[str] = set()
        for idx, repo in enumerate(repos):
            repo_id = repo.get("id")
            repo_path = repo.get("path")
            if not isinstance(repo_id, str) or not repo_id.strip():
                raise FlowError(f"manifest repos[{idx}].id 无效")
            if not isinstance(repo_path, str) or not repo_path.strip():
                raise FlowError(f"manifest repos[{idx}].path 无效")
            if repo_id in seen_ids:
                raise FlowError(f"manifest repos[{idx}].id 重复: {repo_id!r}")
            seen_ids.add(repo_id)

            abs_repo = (PROJECT_DIR / repo_path).resolve()
            try:
                result = subprocess.run(
                    ["git", "-C", str(abs_repo), "rev-parse", "--show-toplevel"],
                    capture_output=True, text=True, timeout=10,
                )
                if result.returncode != 0:
                    raise FlowError(f"manifest repos[{idx}].path={repo_path!r} 不是有效的 Git 仓库")
                git_root = result.stdout.strip()
            except FileNotFoundError:
                raise FlowError("git 命令不可用")

            try:
                rel_git_root = Path(git_root).relative_to(PROJECT_DIR).as_posix()
            except ValueError:
                rel_git_root = git_root

            validated_repos.append({
                "id": repo_id,
                "path": (abs_repo.relative_to(PROJECT_DIR)).as_posix(),
                "git_root": rel_git_root,
            })

        return {
            "mode": "workspace",
            "workspace_file": rel_ws,
            "repos": validated_repos,
        }

    # single_repo mode — derive from current repo root
    import subprocess
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
            cwd=str(PROJECT_DIR),
        )
        if result.returncode == 0:
            git_root = result.stdout.strip()
        else:
            git_root = PROJECT_DIR.as_posix()
    except FileNotFoundError:
        git_root = PROJECT_DIR.as_posix()

    try:
        rel_git_root = Path(git_root).relative_to(PROJECT_DIR).as_posix()
    except ValueError:
        rel_git_root = git_root

    return {
        "mode": "single_repo",
        "workspace_file": None,
        "repos": [{
            "id": "root",
            "path": ".",
            "git_root": rel_git_root,
        }],
    }


def normalize_execution_scope(state: dict) -> None:
    """Inject execution_scope into states that lack it (schema_version 1)."""
    if "execution_scope" in state:
        return

    import subprocess
    # Derive single_repo scope
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
            cwd=str(PROJECT_DIR),
        )
        if result.returncode == 0:
            git_root = result.stdout.strip()
        else:
            git_root = PROJECT_DIR.as_posix()
    except FileNotFoundError:
        git_root = PROJECT_DIR.as_posix()

    try:
        rel_git_root = Path(git_root).relative_to(PROJECT_DIR).as_posix()
    except ValueError:
        rel_git_root = git_root

    state["execution_scope"] = {
        "mode": "single_repo",
        "workspace_file": None,
        "repos": [{
            "id": "root",
            "path": ".",
            "git_root": rel_git_root,
        }],
    }


def normalize_legacy_state(state: dict) -> list[str]:
    transitions = state.get("transitions")
    if not isinstance(transitions, list) or not transitions:
        raise FlowError("transitions 不能为空，无法执行 normalize")

    changes = []

    # Bump schema_version to 2
    if state.get("schema_version", 1) < SCHEMA_VERSION:
        old_sv = state.get("schema_version", 1)
        state["schema_version"] = SCHEMA_VERSION
        changes.append(f"schema_version: {old_sv} -> {SCHEMA_VERSION}")

    # Inject execution_scope if missing
    if "execution_scope" not in state:
        normalize_execution_scope(state)
        changes.append("execution_scope: <missing> -> injected")

    review_events = {"review_passed", "review_failed", "recheck_passed", "recheck_failed"}
    for index, item in enumerate(transitions):
        if not isinstance(item, dict):
            raise FlowError(f"transitions[{index}] 必须是对象，无法执行 normalize")

        original_event = item.get("event")
        normalized_event = LEGACY_EVENT_ALIASES.get(original_event, original_event)
        if normalized_event != original_event:
            item["event"] = normalized_event
            changes.append(f"transitions[{index + 1}].event: {original_event} -> {normalized_event}")

        if item.get("event") in review_events:
            artifacts = item.setdefault("artifacts", {})
            expected_mode = "recheck" if item["event"].startswith("recheck_") else "regular"
            if artifacts.get("mode") != expected_mode:
                previous_mode = artifacts.get("mode")
                artifacts["mode"] = expected_mode
                if previous_mode is None:
                    changes.append(f"transitions[{index + 1}].artifacts.mode: <missing> -> {expected_mode}")
                else:
                    changes.append(
                        f"transitions[{index + 1}].artifacts.mode: {previous_mode} -> {expected_mode}"
                    )

            if item["event"].endswith("failed") and artifacts.get("result") != "failed":
                previous_result = artifacts.get("result")
                artifacts["result"] = "failed"
                if previous_result is None:
                    changes.append(f"transitions[{index + 1}].artifacts.result: <missing> -> failed")
                else:
                    changes.append(
                        f"transitions[{index + 1}].artifacts.result: {previous_result} -> failed"
                    )
            elif "result" not in artifacts:
                artifacts["result"] = "passed"
                changes.append(f"transitions[{index + 1}].artifacts.result: <missing> -> passed")

    synchronize_derived_fields(state)
    return changes


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
        if item["event"] != "plan_created" or item["from"] is not None or item["to"] != "AWAITING_PLAN_REVIEW":
            raise FlowError("第一条 transition 必须是 null -> AWAITING_PLAN_REVIEW 的 plan_created")
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
    if item["event"] in {"plan_review_passed", "plan_review_failed"}:
        required_artifacts = {"round", "result", "engine", "model"}
        missing = required_artifacts - set(item["artifacts"].keys())
        if missing:
            raise FlowError(
                f"transitions[{index}] 的计划审核 artifacts 缺少字段: {', '.join(sorted(missing))}"
            )
        if item["artifacts"]["result"] not in PLAN_REVIEW_RESULTS:
            raise FlowError(f"transitions[{index}] 的计划审核 result 非法")
        if not isinstance(item["artifacts"]["round"], int) or item["artifacts"]["round"] <= 0:
            raise FlowError(f"transitions[{index}] 的计划审核 round 必须是正整数")
        if not isinstance(item["artifacts"]["engine"], str) or not item["artifacts"]["engine"]:
            raise FlowError(f"transitions[{index}] 的计划审核 engine 不能为空")
        if not isinstance(item["artifacts"]["model"], str) or not item["artifacts"]["model"]:
            raise FlowError(f"transitions[{index}] 的计划审核 model 不能为空")
    if item["event"] in {"review_passed", "review_failed", "recheck_passed", "recheck_failed"}:
        if "engine" in item["artifacts"] and (not isinstance(item["artifacts"]["engine"], str) or not item["artifacts"]["engine"]):
            raise FlowError(f"transitions[{index}] 的审查 engine 不能为空")
        if "model" in item["artifacts"] and (not isinstance(item["artifacts"]["model"], str) or not item["artifacts"]["model"]):
            raise FlowError(f"transitions[{index}] 的审查 model 不能为空")


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
        "execution_scope",
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

    exec_scope = state.get("execution_scope")
    if not isinstance(exec_scope, dict):
        raise FlowError("execution_scope 必须是对象")
    for key in ("mode", "workspace_file", "repos"):
        if key not in exec_scope:
            raise FlowError(f"execution_scope 缺少字段: {key}")
    if exec_scope["mode"] not in {"single_repo", "workspace"}:
        raise FlowError(f"execution_scope.mode 必须是 single_repo 或 workspace，实际: {exec_scope['mode']!r}")
    if exec_scope["mode"] == "workspace" and not exec_scope["workspace_file"]:
        raise FlowError("workspace 模式必须存在 execution_scope.workspace_file")
    if not isinstance(exec_scope["repos"], list) or not exec_scope["repos"]:
        raise FlowError("execution_scope.repos 必须是非空数组")
    seen_repo_ids: set[str] = set()
    for r_idx, r_item in enumerate(exec_scope["repos"]):
        if not isinstance(r_item, dict):
            raise FlowError(f"execution_scope.repos[{r_idx}] 必须是对象")
        for r_key in ("id", "path", "git_root"):
            if r_key not in r_item:
                raise FlowError(f"execution_scope.repos[{r_idx}] 缺少字段: {r_key}")
        if r_item["id"] in seen_repo_ids:
            raise FlowError(f"execution_scope.repos[{r_idx}].id 重复: {r_item['id']!r}")
        seen_repo_ids.add(r_item["id"])

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
    expected_active_fix = expected_active_fix_from_transitions(
        transitions, state["current_status"], expected_last_review
    )
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
    if active_fix != expected_active_fix:
        raise FlowError("active_fix 必须等于 fix_started transition 与 last_review 的派生结果")


def with_lock(slug: str, mutator, *, validate_current: bool = True):
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
        if current_state is not None and validate_current:
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

    # Derive execution_scope
    scope_mode = getattr(args, "scope_mode", None) or "single_repo"
    workspace_file = getattr(args, "workspace_file", None)
    exec_scope = build_execution_scope(mode=scope_mode, workspace_file=workspace_file)

    def mutator(state):
        if state is not None:
            raise FlowError(f"状态文件已存在: {state_path_for_slug(args.slug)}")
        at = now_iso()
        artifacts: dict = {"plan_file": plan_file}
        engine = (getattr(args, "engine", None) or "").strip()
        model = (getattr(args, "model", None) or "").strip()
        if engine:
            artifacts["engine"] = engine
        if model:
            artifacts["model"] = model

        return {
            "schema_version": SCHEMA_VERSION,
            "slug": ensure_slug(args.slug),
            "title": title,
            "current_status": "AWAITING_PLAN_REVIEW",
            "created_at": at,
            "updated_at": at,
            "plan_file": plan_file,
            "review_rounds": {"regular": 0, "recheck": 0},
            "latest_regular_review_file": None,
            "latest_recheck_review_file": None,
            "last_review": None,
            "active_fix": None,
            "execution_scope": exec_scope,
            "transitions": [
                {
                    "seq": 1,
                    "at": at,
                    "event": "plan_created",
                    "from": None,
                    "to": "AWAITING_PLAN_REVIEW",
                    "actor": ACTOR,
                    "artifacts": artifacts,
                    "note": "",
                }
            ],
        }

    state = with_lock(args.slug, mutator)
    print(f"已创建状态: {state_path_for_slug(args.slug)} -> {state['current_status']}")


def cmd_record_plan_review(args):
    slug = resolve_record_plan_review_value(args.slug, args.legacy_slug, "slug")
    result = resolve_record_plan_review_value(args.result, args.legacy_result, "result")
    engine = resolve_record_plan_review_value(args.engine, args.legacy_engine, "engine").strip()
    model = resolve_record_plan_review_value(args.model, args.legacy_model, "model").strip()
    positional_note = " ".join(args.legacy_note).strip()
    note = resolve_record_plan_review_note(args.note, positional_note)
    ensure_slug(slug)
    if not engine:
        raise FlowError("engine 不能为空")
    if not model:
        raise FlowError("model 不能为空")

    def mutator(state):
        state = require_state(state, slug)
        current_status = state["current_status"]
        if current_status not in {"AWAITING_PLAN_REVIEW", "PLAN_REVIEW_FAILED"}:
            raise FlowError(
                f"计划审核只允许 AWAITING_PLAN_REVIEW 或 PLAN_REVIEW_FAILED，当前是 {current_status}"
            )

        round_number = 1
        for item in state["transitions"]:
            if item["event"] in {"plan_review_passed", "plan_review_failed"}:
                round_number += 1

        event = "plan_review_passed" if result in {"passed", "passed_with_notes"} else "plan_review_failed"
        to_status = ALLOWED_TRANSITIONS[(event, current_status)]
        append_transition(
            state,
            event=event,
            to_status=to_status,
            at=now_iso(),
            artifacts={
                "round": round_number,
                "result": result,
                "engine": engine,
                "model": model,
            },
            note=note,
        )
        return state

    state = with_lock(slug, mutator)
    print(f"{slug}: {state['current_status']}")


def resolve_record_plan_review_value(flag_value, positional_value, field_name: str) -> str:
    if flag_value is not None and positional_value is not None and flag_value != positional_value:
        raise FlowError(f"record-plan-review 的 {field_name} 同时通过命名参数和位置参数提供，且值不一致")
    value = flag_value if flag_value is not None else positional_value
    if value is None:
        raise FlowError(
            "record-plan-review 需要提供 slug、result、engine、model；"
            "推荐使用 --slug/--result/--engine/--model，"
            "也兼容旧的位置参数顺序 slug result engine model"
        )
    return value


def resolve_record_plan_review_note(flag_note, positional_note: str) -> str:
    flag_note = (flag_note or "").strip()
    if flag_note and positional_note and flag_note != positional_note:
        raise FlowError("record-plan-review 的 note 同时通过 --note 和位置参数提供，且值不一致")
    return flag_note or positional_note


def _add_engine_model(artifacts: dict, engine, model) -> None:
    e = (engine or "").strip()
    m = (model or "").strip()
    if e:
        artifacts["engine"] = e
    if m:
        artifacts["model"] = m


def require_state(state, slug: str) -> dict:
    if state is None:
        raise FlowError(f"状态文件不存在: {state_path_for_slug(slug)}")
    return state


def cmd_start_execute(args):
    def mutator(state):
        state = require_state(state, args.slug)
        if state["current_status"] != "PLANNED":
            raise FlowError(f"只有 PLANNED 可以 start-execute，当前是 {state['current_status']}")
        artifacts: dict = {"plan_file": state["plan_file"]}
        _add_engine_model(artifacts, getattr(args, "engine", None), getattr(args, "model", None))
        append_transition(
            state,
            event="execute_started",
            to_status="IMPLEMENTING",
            at=now_iso(),
            artifacts=artifacts,
        )
        return state

    state = with_lock(args.slug, mutator)
    print(f"{args.slug}: {state['current_status']}")


def cmd_finish_implementation(args):
    def mutator(state):
        state = require_state(state, args.slug)
        if state["current_status"] != "IMPLEMENTING":
            raise FlowError(f"只有 IMPLEMENTING 可以 finish-implementation，当前是 {state['current_status']}")
        artifacts: dict = {"plan_file": state["plan_file"]}
        _add_engine_model(artifacts, getattr(args, "engine", None), getattr(args, "model", None))
        append_transition(
            state,
            event="implementation_completed",
            to_status="AWAITING_REVIEW",
            at=now_iso(),
            artifacts=artifacts,
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
        artifacts: dict = {
            "mode": mode,
            "round": round_number,
            "result": result,
            "report_file": report_file,
        }
        _add_engine_model(artifacts, getattr(args, "engine", None), getattr(args, "model", None))
        append_transition(
            state,
            event=event,
            to_status=to_status,
            at=at,
            artifacts=artifacts,
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
        artifacts: dict = {"report_file": state["active_fix"]["report_file"]}
        _add_engine_model(artifacts, getattr(args, "engine", None), getattr(args, "model", None))
        append_transition(
            state,
            event="fix_started",
            to_status="FIXING_REVIEW",
            at=at,
            artifacts=artifacts,
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
        artifacts: dict = {"report_file": report_file}
        _add_engine_model(artifacts, getattr(args, "engine", None), getattr(args, "model", None))
        append_transition(
            state,
            event="fix_completed",
            to_status="AWAITING_REVIEW",
            at=now_iso(),
            artifacts=artifacts,
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


def cmd_normalize(args):
    def mutator(state):
        state = require_state(state, args.slug)
        before_status = state.get("current_status")
        changes = normalize_legacy_state(state)
        note_parts = []
        if changes:
            note_parts.append("normalize: " + "; ".join(changes))
        else:
            note_parts.append("normalize: no structural changes")
        if args.note:
            note_parts.append(args.note)
        append_transition(
            state,
            event="repair_metadata",
            to_status=state["current_status"],
            at=now_iso(),
            artifacts={"normalized_changes": changes},
            note=" | ".join(note_parts),
        )
        if before_status != state["current_status"]:
            state["transitions"][-1]["event"] = "repair"
        return state

    state = with_lock(args.slug, mutator, validate_current=False)
    print(f"{args.slug}: {state['current_status']}")


def build_parser():
    parser = argparse.ArgumentParser(prog="flow-state.sh")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--slug", required=True)
    create.add_argument("--title", required=True)
    create.add_argument("--plan-file", required=True)
    create.add_argument("--scope-mode", choices=["single_repo", "workspace"])
    create.add_argument("--workspace-file")
    create.add_argument("--engine")
    create.add_argument("--model")
    create.set_defaults(func=cmd_create)

    record_plan_review = subparsers.add_parser("record-plan-review")
    record_plan_review.add_argument("--slug")
    record_plan_review.add_argument("--result", choices=sorted(PLAN_REVIEW_RESULTS))
    record_plan_review.add_argument("--engine")
    record_plan_review.add_argument("--model")
    record_plan_review.add_argument("--note")
    record_plan_review.add_argument("legacy_slug", nargs="?")
    record_plan_review.add_argument("legacy_result", nargs="?", choices=sorted(PLAN_REVIEW_RESULTS))
    record_plan_review.add_argument("legacy_engine", nargs="?")
    record_plan_review.add_argument("legacy_model", nargs="?")
    record_plan_review.add_argument("legacy_note", nargs="*")
    record_plan_review.set_defaults(func=cmd_record_plan_review)

    start_execute = subparsers.add_parser("start-execute")
    start_execute.add_argument("slug")
    start_execute.add_argument("--engine")
    start_execute.add_argument("--model")
    start_execute.set_defaults(func=cmd_start_execute)

    finish_implementation = subparsers.add_parser("finish-implementation")
    finish_implementation.add_argument("slug")
    finish_implementation.add_argument("--engine")
    finish_implementation.add_argument("--model")
    finish_implementation.set_defaults(func=cmd_finish_implementation)

    record_review = subparsers.add_parser("record-review")
    record_review.add_argument("--slug", required=True)
    record_review.add_argument("--mode", required=True, choices=sorted(REVIEW_MODES))
    record_review.add_argument("--result", required=True, choices=sorted(REVIEW_RESULTS))
    record_review.add_argument("--report-file", required=True)
    record_review.add_argument("--engine")
    record_review.add_argument("--model")
    record_review.set_defaults(func=cmd_record_review)

    start_fix = subparsers.add_parser("start-fix")
    start_fix.add_argument("slug")
    start_fix.add_argument("--engine")
    start_fix.add_argument("--model")
    start_fix.set_defaults(func=cmd_start_fix)

    finish_fix = subparsers.add_parser("finish-fix")
    finish_fix.add_argument("slug")
    finish_fix.add_argument("--engine")
    finish_fix.add_argument("--model")
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

    normalize = subparsers.add_parser("normalize")
    normalize.add_argument("--slug", required=True)
    normalize.add_argument("--note")
    normalize.set_defaults(func=cmd_normalize)

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
