#!/usr/bin/env python3
"""AI Flow state machine v4."""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 4
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
EVENT_TRANSITIONS = {
    ("plan_created", None): "AWAITING_PLAN_REVIEW",
    ("plan_review_passed", "AWAITING_PLAN_REVIEW"): "PLANNED",
    ("plan_review_failed", "AWAITING_PLAN_REVIEW"): "PLAN_REVIEW_FAILED",
    ("plan_reopened", "PLAN_REVIEW_FAILED"): "AWAITING_PLAN_REVIEW",
    ("execute_started", "PLANNED"): "IMPLEMENTING",
    ("implementation_completed", "IMPLEMENTING"): "AWAITING_REVIEW",
    ("review_passed", "AWAITING_REVIEW"): "DONE",
    ("review_failed", "AWAITING_REVIEW"): "REVIEW_FAILED",
    ("recheck_passed", "DONE"): "DONE",
    ("recheck_failed", "DONE"): "REVIEW_FAILED",
    ("fix_started", "REVIEW_FAILED"): "FIXING_REVIEW",
    ("fix_completed", "FIXING_REVIEW"): "AWAITING_REVIEW",
    ("plan_reopened", "PLANNED"): "AWAITING_PLAN_REVIEW",
    ("plan_reopened", "IMPLEMENTING"): "AWAITING_PLAN_REVIEW",
    ("implementation_reopened", "AWAITING_REVIEW"): "IMPLEMENTING",
    ("implementation_reopened", "DONE"): "IMPLEMENTING",
    ("implementation_reopened", "REVIEW_FAILED"): "IMPLEMENTING",
    ("implementation_reopened", "FIXING_REVIEW"): "IMPLEMENTING",
}
TRANSITION_EVENTS = {
    "plan_created",
    "plan_review_passed",
    "plan_review_failed",
    "execute_started",
    "implementation_completed",
    "review_passed",
    "review_failed",
    "recheck_passed",
    "recheck_failed",
    "fix_started",
    "fix_completed",
    "plan_reopened",
    "implementation_reopened",
}
PLAN_REVIEW_PASS_RESULTS = {"passed", "passed_with_notes"}
REVIEW_PASS_RESULTS = {"passed", "passed_with_notes"}
SLUG_RE = re.compile(r"^\d{8}-[a-z0-9一-鿿][a-z0-9一-鿿-]*$")
SEMANTIC_SLUG_RE = re.compile(r"^[a-z0-9一-鿿][a-z0-9一-鿿-]*$")
REPO_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class FlowError(Exception):
    pass


@dataclass(frozen=True)
class DerivedReview:
    mode: str
    round: int
    result: str
    report_file: str
    at: str
    engine: str
    model: str
    worktree_snapshot: dict[str, Any] | None = None

    def as_dict(self) -> dict[str, Any]:
        payload = {
            "mode": self.mode,
            "round": self.round,
            "result": self.result,
            "report_file": self.report_file,
            "at": self.at,
            "engine": self.engine,
            "model": self.model,
        }
        if self.worktree_snapshot is not None:
            payload["worktree_snapshot"] = self.worktree_snapshot
        return payload


def resolve_project_dir() -> Path:
    """Resolve flow root by searching upward for .ai-flow/state directory.
    Falls back to git toplevel, then cwd.
    Stops if entering a .ai-flow-tests directory (test isolation).
    """
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
    # Fallback: try git toplevel
    try:
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


# 注入 runtime/lib 路径以导入 flow_config
_lib_dir = Path(__file__).resolve().parent.parent / "lib"
if str(_lib_dir) not in sys.path:
    sys.path.insert(0, str(_lib_dir))

_shared_lib_dir = Path(__file__).resolve().parent.parent.parent / "subagents" / "shared" / "lib"
if str(_shared_lib_dir) not in sys.path:
    sys.path.insert(0, str(_shared_lib_dir))

try:
    from flow_config import get_config_value as _get_config_value
except ImportError:
    _get_config_value = None

try:
    from flow_utils import FlowUtils as _FlowUtils
except ImportError:
    _FlowUtils = None

PROJECT_DIR = resolve_project_dir()
FLOW_DIR = PROJECT_DIR / ".ai-flow"
STATE_DIR = FLOW_DIR / "state"
LOCKS_DIR = STATE_DIR / ".locks"

if _get_config_value is not None:
    ACTOR = os.environ.get("AI_FLOW_ACTOR", _get_config_value("state.actor", "flow-state.sh"))
else:
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


def normalize_semantic_slug(semantic_slug: str) -> str:
    date_prefix = datetime.now().strftime("%Y%m%d")
    return f"{date_prefix}-{semantic_slug}"


def ensure_slug(slug: str) -> str:
    cleaned = slug.strip()
    if SLUG_RE.fullmatch(cleaned):
        return cleaned
    if SEMANTIC_SLUG_RE.fullmatch(cleaned):
        return normalize_semantic_slug(cleaned)
    raise FlowError(f"slug 格式非法: {slug!r}")


def normalize_path(path_value: str) -> str:
    if not isinstance(path_value, str) or not path_value.strip():
        raise FlowError("路径参数不能为空")
    path = Path(path_value.strip())
    absolute = path.resolve() if path.is_absolute() else (PROJECT_DIR / path).resolve()
    try:
        return absolute.relative_to(PROJECT_DIR).as_posix()
    except ValueError:
        return absolute.as_posix()


def state_path_for_slug(slug: str) -> Path:
    return STATE_DIR / f"{ensure_slug(slug)}.json"


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise FlowError(f"状态文件不存在: {path}") from exc
    except json.JSONDecodeError as exc:
        raise FlowError(f"状态文件 JSON 损坏，请删除后重建: {path}") from exc


def load_state_by_slug(slug: str) -> dict[str, Any]:
    return read_json(state_path_for_slug(slug))


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


def default_next_events(status: str) -> list[str]:
    mapping = {
        "AWAITING_PLAN_REVIEW": ["plan_review_passed", "plan_review_failed"],
        "PLAN_REVIEW_FAILED": ["plan_reopened"],
        "PLANNED": ["execute_started", "plan_reopened"],
        "IMPLEMENTING": ["implementation_completed", "plan_reopened"],
        "AWAITING_REVIEW": ["review_passed", "review_failed", "implementation_reopened"],
        "REVIEW_FAILED": ["fix_started", "implementation_reopened"],
        "FIXING_REVIEW": ["fix_completed", "implementation_reopened"],
        "DONE": ["recheck_passed", "recheck_failed", "implementation_reopened"],
    }
    return mapping[status]


def validate_execution_scope(exec_scope: Any) -> None:
    if not isinstance(exec_scope, dict):
        raise FlowError("execution_scope 必须是对象")
    if exec_scope.get("mode") != "plan_repos":
        raise FlowError("execution_scope.mode 必须是 plan_repos")
    repos = exec_scope.get("repos")
    if not isinstance(repos, list) or not repos:
        raise FlowError("execution_scope.repos 必须是非空数组")
    seen_repo_ids: set[str] = set()
    owner_count = 0
    for index, repo in enumerate(repos):
        if not isinstance(repo, dict):
            raise FlowError(f"execution_scope.repos[{index}] 必须是对象")
        for key in ("id", "path", "git_root", "role"):
            if key not in repo:
                raise FlowError(f"execution_scope.repos[{index}] 缺少字段: {key}")
        repo_id = repo["id"]
        repo_path = repo["path"]
        git_root = repo["git_root"]
        role = repo["role"]
        if not isinstance(repo_id, str) or not REPO_ID_RE.fullmatch(repo_id):
            raise FlowError(f"execution_scope.repos[{index}].id 无效: {repo_id!r}")
        if repo_id in seen_repo_ids:
            raise FlowError(f"execution_scope.repos[{index}].id 重复: {repo_id!r}")
        seen_repo_ids.add(repo_id)
        if not isinstance(repo_path, str) or not repo_path.strip() or Path(repo_path).is_absolute():
            raise FlowError(f"execution_scope.repos[{index}].path 必须是相对路径")
        if not isinstance(git_root, str) or not Path(git_root).is_absolute():
            raise FlowError(f"execution_scope.repos[{index}].git_root 必须是绝对路径")
        if role not in {"owner", "participant"}:
            raise FlowError(f"execution_scope.repos[{index}].role 必须是 owner 或 participant")
        if role == "owner":
            owner_count += 1
        abs_repo = (PROJECT_DIR / repo_path).resolve()
        if not abs_repo.exists():
            raise FlowError(f"execution_scope.repos[{index}].path 不存在: {repo_path}")
        if role == "owner":
            resolved_owner = abs_repo.resolve()
            if resolved_owner != Path(git_root).resolve():
                raise FlowError(
                    f"execution_scope.repos[{index}].git_root 与 path 解析结果不一致: {git_root} != {resolved_owner}"
                )
            continue
        try:
            result = subprocess.run(
                ["git", "-C", str(abs_repo), "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except FileNotFoundError as exc:
            raise FlowError("git 命令不可用") from exc
        if result.returncode != 0 or not result.stdout.strip():
            raise FlowError(f"execution_scope.repos[{index}].path 不是有效 Git 仓库: {repo_path}")
        resolved_git_root = Path(result.stdout.strip()).resolve()
        if resolved_git_root != Path(git_root).resolve():
            raise FlowError(
                f"execution_scope.repos[{index}].git_root 与 path 解析结果不一致: {git_root} != {resolved_git_root}"
            )
    if owner_count != 1:
        raise FlowError("execution_scope.repos 必须且只能包含一个 role=owner 仓库")


def validate_worktree_snapshot(
    snapshot: Any,
    *,
    field_prefix: str = "worktree_snapshot",
    state: dict[str, Any] | None = None,
) -> None:
    if not isinstance(snapshot, dict):
        raise FlowError(f"{field_prefix} 必须是对象")
    repos = snapshot.get("repos")
    if not isinstance(repos, list):
        raise FlowError(f"{field_prefix}.repos 必须是数组")

    seen_repo_ids: set[str] = set()
    for repo_index, repo in enumerate(repos):
        if not isinstance(repo, dict):
            raise FlowError(f"{field_prefix}.repos[{repo_index}] 必须是对象")
        repo_id = repo.get("repo_id")
        if not isinstance(repo_id, str) or not REPO_ID_RE.fullmatch(repo_id):
            raise FlowError(f"{field_prefix}.repos[{repo_index}].repo_id 非法: {repo_id!r}")
        if repo_id in seen_repo_ids:
            raise FlowError(f"{field_prefix}.repos[{repo_index}].repo_id 重复: {repo_id}")
        seen_repo_ids.add(repo_id)

        entries = repo.get("entries")
        if not isinstance(entries, list):
            raise FlowError(f"{field_prefix}.repos[{repo_index}].entries 必须是数组")

        seen_paths: set[str] = set()
        for entry_index, entry in enumerate(entries):
            if not isinstance(entry, dict):
                raise FlowError(f"{field_prefix}.repos[{repo_index}].entries[{entry_index}] 必须是对象")
            path = entry.get("path")
            if not isinstance(path, str) or not path.strip():
                raise FlowError(f"{field_prefix}.repos[{repo_index}].entries[{entry_index}].path 不能为空")
            normalized_path = path.strip()
            if normalized_path in seen_paths:
                raise FlowError(
                    f"{field_prefix}.repos[{repo_index}].entries[{entry_index}].path 重复: {normalized_path}"
                )
            seen_paths.add(normalized_path)

            tokens = entry.get("tokens")
            if not isinstance(tokens, list) or not tokens:
                raise FlowError(f"{field_prefix}.repos[{repo_index}].entries[{entry_index}].tokens 必须是非空数组")
            normalized_tokens: list[str] = []
            for token_index, token in enumerate(tokens):
                if not isinstance(token, str) or not token.strip():
                    raise FlowError(
                        f"{field_prefix}.repos[{repo_index}].entries[{entry_index}].tokens[{token_index}] 不能为空"
                    )
                normalized_tokens.append(token.strip())
            if len(set(normalized_tokens)) != len(normalized_tokens):
                raise FlowError(
                    f"{field_prefix}.repos[{repo_index}].entries[{entry_index}].tokens 不允许重复"
                )

    if state is not None:
        exec_scope = state.get("execution_scope") or {}
        scope_repos = exec_scope.get("repos") or []
        expected_repo_ids = {
            str(repo.get("id"))
            for repo in scope_repos
            if isinstance(repo, dict) and repo.get("id")
        }
        actual_repo_ids = seen_repo_ids
        if actual_repo_ids != expected_repo_ids:
            raise FlowError(
                f"{field_prefix}.repos 必须与 execution_scope.repos 完全一致: "
                f"expected={sorted(expected_repo_ids)!r} actual={sorted(actual_repo_ids)!r}"
            )


def validate_plan_structure_for_state(state: dict[str, Any], event: str) -> None:
    if _FlowUtils is None:
        return
    plan_file = state.get("plan_file")
    if not isinstance(plan_file, str) or not plan_file.strip():
        raise FlowError("plan_file 不能为空")
    plan_path = Path(plan_file)
    if not plan_path.is_absolute():
        plan_path = PROJECT_DIR / plan_path
    errors = _FlowUtils.validate_plan_structure(str(plan_path))
    if errors:
        raise FlowError(
            f"{event} 前 plan 结构校验失败: " + " | ".join(errors)
        )
    if event in {"implementation_completed", "fix_completed"}:
        completion_errors = _FlowUtils.validate_plan_completion(str(plan_path))
        if completion_errors:
            raise FlowError(
                f"{event} 前 plan 完成度校验失败: " + " | ".join(completion_errors)
            )


def validate_review_report_coverage_for_state(
    state: dict[str, Any],
    event: str,
    payload: dict[str, Any],
) -> None:
    if _FlowUtils is None:
        return
    if event not in {"review_passed", "recheck_passed"}:
        return

    plan_file = state.get("plan_file")
    if not isinstance(plan_file, str) or not plan_file.strip():
        raise FlowError("plan_file 不能为空")
    report_file = payload.get("report_file")
    if not isinstance(report_file, str) or not report_file.strip():
        raise FlowError(f"{event}.report_file 不能为空")

    plan_path = Path(plan_file)
    if not plan_path.is_absolute():
        plan_path = PROJECT_DIR / plan_path
    report_path = Path(report_file)
    if not report_path.is_absolute():
        report_path = PROJECT_DIR / report_path

    coverage_errors = _FlowUtils.validate_plan_coverage(
        str(plan_path),
        str(report_path),
    )
    if coverage_errors:
        raise FlowError(
            f"{event} 前报告覆盖度校验失败: " + " | ".join(coverage_errors)
        )


def validate_payload(
    event: str,
    payload: Any,
    *,
    state: dict[str, Any] | None = None,
    prior_transitions: list[dict[str, Any]] | None = None,
) -> None:
    if not isinstance(payload, dict):
        raise FlowError("transition payload 必须是对象")
    if event == "plan_created":
        required = {"title", "plan_file", "execution_scope"}
        missing = required - set(payload)
        if missing:
            raise FlowError(f"plan_created payload 缺少字段: {', '.join(sorted(missing))}")
        if not isinstance(payload["title"], str) or not payload["title"].strip():
            raise FlowError("plan_created.title 不能为空")
        if not isinstance(payload["plan_file"], str) or not payload["plan_file"]:
            raise FlowError("plan_created.plan_file 不能为空")
        validate_execution_scope(payload["execution_scope"])
        return

    def validate_concrete_model_name(model: Any, engine: Any, *, field_prefix: str) -> None:
        if not isinstance(model, str) or not model.strip():
            raise FlowError(f"{field_prefix}.model 不能为空")
        normalized_model = model.strip()
        if normalized_model.lower() in {"claude", "codex", "auto"}:
            raise FlowError(f"{field_prefix}.model 必须是具体模型名，不能是引擎别名: {normalized_model}")
        if isinstance(engine, str) and engine.strip() and normalized_model == engine.strip():
            raise FlowError(f"{field_prefix}.model 必须是具体模型名，不能与 {field_prefix}.engine 相同: {normalized_model}")

    if event in {"plan_review_passed", "plan_review_failed"}:
        required = {"result", "round", "engine", "model"}
        missing = required - set(payload)
        if missing:
            raise FlowError(f"{event} payload 缺少字段: {', '.join(sorted(missing))}")
        if not isinstance(payload["round"], int) or payload["round"] <= 0:
            raise FlowError(f"{event}.round 必须是正整数")
        if not isinstance(payload["engine"], str) or not payload["engine"].strip():
            raise FlowError(f"{event}.engine 不能为空")
        validate_concrete_model_name(payload["model"], payload["engine"], field_prefix=event)
        result = payload["result"]
        if event == "plan_review_passed" and result not in PLAN_REVIEW_PASS_RESULTS:
            raise FlowError("plan_review_passed 只允许 result=passed 或 passed_with_notes")
        if event == "plan_review_failed" and result != "failed":
            raise FlowError("plan_review_failed 只允许 result=failed")
        return
    if event in {"review_passed", "review_failed", "recheck_passed", "recheck_failed"}:
        required = {"result", "round", "report_file", "engine", "model"}
        missing = required - set(payload)
        if missing:
            raise FlowError(f"{event} payload 缺少字段: {', '.join(sorted(missing))}")
        if not isinstance(payload["round"], int) or payload["round"] <= 0:
            raise FlowError(f"{event}.round 必须是正整数")
        if not isinstance(payload["report_file"], str) or not payload["report_file"]:
            raise FlowError(f"{event}.report_file 不能为空")
        if not isinstance(payload["engine"], str) or not payload["engine"].strip():
            raise FlowError(f"{event}.engine 不能为空")
        validate_concrete_model_name(payload["model"], payload["engine"], field_prefix=event)
        result = payload["result"]
        if event.endswith("_passed") and result not in REVIEW_PASS_RESULTS:
            raise FlowError(f"{event} 只允许 result=passed 或 passed_with_notes")
        if event.endswith("_failed") and result != "failed":
            raise FlowError(f"{event} 只允许 result=failed")
        if "worktree_snapshot" in payload:
            if event.endswith("_failed"):
                raise FlowError(f"{event} 不允许携带 worktree_snapshot")
            validate_worktree_snapshot(
                payload["worktree_snapshot"],
                field_prefix=f"{event}.worktree_snapshot",
                state=state,
            )
        return
    if event == "fix_started":
        if prior_transitions is not None:
            if not prior_transitions:
                raise FlowError("fix_started 之前必须存在失败的最近一次审查")
            probe_state = {
                "schema_version": SCHEMA_VERSION,
                "slug": "probe",
                "title": "probe",
                "plan_file": "probe",
                "execution_scope": {"mode": "plan_repos", "repos": [{"id": "owner", "path": ".", "git_root": str(PROJECT_DIR), "role": "owner"}]},
                "current_status": prior_transitions[-1]["to"],
                "created_at": prior_transitions[0]["at"],
                "updated_at": prior_transitions[-1]["at"],
                "transitions": prior_transitions,
            }
            derived = derive_state(probe_state)
        elif state is not None:
            derived = derive_state(state)
        else:
            raise FlowError("fix_started 校验缺少状态上下文")
        last_review = derived["last_review"]
        if not last_review or last_review["result"] != "failed":
            raise FlowError("fix_started 之前必须存在失败的最近一次审查")
        return
    if event in {"execute_started", "implementation_completed", "fix_completed", "plan_reopened", "implementation_reopened"}:
        if payload:
            raise FlowError(f"{event} 不接受额外 payload")
        return
    raise FlowError(f"未知事件: {event}")


def validate_transition_item(item: Any, previous_to: str | None, index: int, *, state: dict[str, Any]) -> None:
    if not isinstance(item, dict):
        raise FlowError(f"transitions[{index}] 必须是对象")
    required = {"seq", "at", "event", "from", "to", "actor", "payload", "note"}
    keys = set(item)
    missing = required - keys
    if missing:
        raise FlowError(f"transitions[{index}] 缺少字段: {', '.join(sorted(missing))}")
    extras = keys - required
    if extras:
        raise FlowError(f"transitions[{index}] 存在未知字段: {', '.join(sorted(extras))}")
    if item["seq"] != index + 1:
        raise FlowError(f"transitions[{index}] 的 seq 必须为 {index + 1}")
    parse_iso(item["at"], f"transitions[{index}].at")
    event = item["event"]
    if event not in TRANSITION_EVENTS:
        raise FlowError(f"transitions[{index}].event 非法: {event}")
    if item["from"] is not None and item["from"] not in STATUS_VALUES:
        raise FlowError(f"transitions[{index}].from 非法: {item['from']}")
    if item["to"] not in STATUS_VALUES:
        raise FlowError(f"transitions[{index}].to 非法: {item['to']}")
    if index == 0:
        if event != "plan_created" or item["from"] is not None or item["to"] != "AWAITING_PLAN_REVIEW":
            raise FlowError("第一条 transition 必须是 plan_created: null -> AWAITING_PLAN_REVIEW")
    elif item["from"] != previous_to:
        raise FlowError(f"transitions[{index}].from 必须等于上一条 to")
    expected_to = EVENT_TRANSITIONS.get((event, item["from"]))
    if expected_to != item["to"]:
        raise FlowError(f"非法迁移: event={event} from={item['from']} to={item['to']}")
    if not isinstance(item["actor"], str) or not item["actor"].strip():
        raise FlowError(f"transitions[{index}].actor 不能为空")
    if not isinstance(item["note"], str):
        raise FlowError(f"transitions[{index}].note 必须是字符串")
    validate_payload(event, item["payload"], state=state, prior_transitions=state["transitions"][:index])


def derive_state(state: dict[str, Any]) -> dict[str, Any]:
    transitions = state.get("transitions")
    if not isinstance(transitions, list) or not transitions:
        raise FlowError("transitions 不能为空")
    regular_count = 0
    recheck_count = 0
    latest_regular_review_file = None
    latest_recheck_review_file = None
    last_review: dict[str, Any] | None = None
    current_last_review: DerivedReview | None = None
    current_active_fix: dict[str, Any] | None = None
    for item in transitions:
        event = item["event"]
        payload = item["payload"]
        if event in {"review_passed", "review_failed"}:
            regular_count += 1
            current_last_review = DerivedReview(
                mode="regular",
                round=regular_count,
                result=str(payload["result"]),
                report_file=str(payload["report_file"]),
                at=str(item["at"]),
                engine=str(payload["engine"]),
                model=str(payload["model"]),
                worktree_snapshot=payload.get("worktree_snapshot"),
            )
            last_review = current_last_review.as_dict()
            latest_regular_review_file = current_last_review.report_file
            current_active_fix = None
        elif event in {"recheck_passed", "recheck_failed"}:
            recheck_count += 1
            current_last_review = DerivedReview(
                mode="recheck",
                round=recheck_count,
                result=str(payload["result"]),
                report_file=str(payload["report_file"]),
                at=str(item["at"]),
                engine=str(payload["engine"]),
                model=str(payload["model"]),
                worktree_snapshot=payload.get("worktree_snapshot"),
            )
            last_review = current_last_review.as_dict()
            latest_recheck_review_file = current_last_review.report_file
            current_active_fix = None
        elif event == "fix_started":
            if current_last_review is None or current_last_review.result != "failed":
                raise FlowError("fix_started 前必须先有失败审查")
            current_active_fix = {
                "mode": current_last_review.mode,
                "round": current_last_review.round,
                "report_file": current_last_review.report_file,
                "at": item["at"],
            }
        elif event in {"fix_completed", "plan_reopened", "implementation_reopened"}:
            current_active_fix = None
    current_status = transitions[-1]["to"]
    if current_status == "FIXING_REVIEW" and current_active_fix is None:
        raise FlowError("FIXING_REVIEW 状态必须能推导 active_fix")
    return {
        "review_rounds": {"regular": regular_count, "recheck": recheck_count},
        "latest_regular_review_file": latest_regular_review_file,
        "latest_recheck_review_file": latest_recheck_review_file,
        "last_review": last_review,
        "active_fix": current_active_fix if current_status == "FIXING_REVIEW" else None,
        "next_events": default_next_events(current_status),
    }


def materialize_view(state: dict[str, Any]) -> dict[str, Any]:
    view = copy.deepcopy(state)
    view["derived"] = derive_state(state)
    return view


def validate_state(state: dict[str, Any], *, expected_slug: str | None = None) -> None:
    if not isinstance(state, dict):
        raise FlowError("状态文件根节点必须是对象")
    required = {
        "schema_version",
        "slug",
        "title",
        "plan_file",
        "execution_scope",
        "current_status",
        "created_at",
        "updated_at",
        "transitions",
    }
    keys = set(state)
    missing = required - keys
    if missing:
        raise FlowError(f"状态文件缺少字段: {', '.join(sorted(missing))}")
    extras = keys - required
    if extras:
        raise FlowError(f"状态文件存在未知字段，请删除后重建: {', '.join(sorted(extras))}")
    if state["schema_version"] != SCHEMA_VERSION:
        raise FlowError(f"状态文件 schema_version 非法: {state['schema_version']}（请删除后重建）")
    slug = ensure_slug(state["slug"])
    if expected_slug and slug != expected_slug:
        raise FlowError(f"状态文件 slug 与文件名不一致: {slug} != {expected_slug}")
    if not isinstance(state["title"], str) or not state["title"].strip():
        raise FlowError("title 不能为空")
    if not isinstance(state["plan_file"], str) or not state["plan_file"]:
        raise FlowError("plan_file 不能为空")
    validate_execution_scope(state["execution_scope"])
    if state["current_status"] not in STATUS_VALUES:
        raise FlowError(f"current_status 非法: {state['current_status']}")
    created_at = parse_iso(state["created_at"], "created_at")
    updated_at = parse_iso(state["updated_at"], "updated_at")
    if updated_at < created_at:
        raise FlowError("updated_at 不能早于 created_at")
    transitions = state["transitions"]
    if not isinstance(transitions, list) or not transitions:
        raise FlowError("transitions 不能为空")
    previous_to = None
    for index, item in enumerate(transitions):
        validate_transition_item(item, previous_to, index, state=state)
        previous_to = item["to"]
    if state["created_at"] != transitions[0]["at"]:
        raise FlowError("created_at 必须等于第一条 transition.at")
    if state["updated_at"] != transitions[-1]["at"]:
        raise FlowError("updated_at 必须等于最后一条 transition.at")
    if state["current_status"] != transitions[-1]["to"]:
        raise FlowError("current_status 必须等于最后一条 transition.to")
    created_payload = transitions[0]["payload"]
    if state["title"] != created_payload["title"]:
        raise FlowError("title 不得在 plan_created 后修改")
    if state["plan_file"] != created_payload["plan_file"]:
        raise FlowError("plan_file 不得在 plan_created 后修改")
    if state["execution_scope"] != created_payload["execution_scope"]:
        raise FlowError("execution_scope 不得在 plan_created 后修改")
    derive_state(state)


def require_valid_v4_state(slug: str) -> dict[str, Any]:
    state = load_state_by_slug(slug)
    validate_state(state, expected_slug=slug)
    return state


def with_lock(slug: str, mutator) -> dict[str, Any]:
    slug = ensure_slug(slug)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOCKS_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = LOCKS_DIR / f"{slug}.lock"
    try:
        os.mkdir(lock_path)
    except FileExistsError as exc:
        raise FlowError(f"状态锁已存在，稍后重试: {lock_path}") from exc
    try:
        path = state_path_for_slug(slug)
        current_state = None
        if path.exists():
            current_state = read_json(path)
            validate_state(current_state, expected_slug=slug)
        next_state = mutator(copy.deepcopy(current_state))
        validate_state(next_state, expected_slug=slug)
        write_json_atomic(path, next_state)
        reloaded = read_json(path)
        validate_state(reloaded, expected_slug=slug)
        return reloaded
    finally:
        try:
            os.rmdir(lock_path)
        except FileNotFoundError:
            pass


def append_transition(
    state: dict[str, Any],
    *,
    event: str,
    at: str,
    payload: dict[str, Any],
    note: str,
) -> None:
    current_status = state.get("current_status")
    next_status = EVENT_TRANSITIONS.get((event, current_status))
    if next_status is None:
        raise FlowError(f"非法迁移: event={event} from={current_status}")
    if event in {"plan_review_passed", "implementation_completed", "fix_completed", "review_passed", "recheck_passed"}:
        validate_plan_structure_for_state(state, event)
    validate_payload(event, payload, state=state)
    validate_review_report_coverage_for_state(state, event, payload)
    state["transitions"].append(
        {
            "seq": len(state["transitions"]) + 1,
            "at": at,
            "event": event,
            "from": current_status,
            "to": next_status,
            "actor": ACTOR,
            "payload": payload,
            "note": note,
        }
    )
    state["current_status"] = next_status
    state["updated_at"] = at


def require_arg(value: str | None, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise FlowError(f"{name} 不能为空")
    return value.strip()


def disallow_args(event: str, args: argparse.Namespace, field_names: list[str]) -> None:
    for field_name in field_names:
        value = getattr(args, field_name)
        if value is None:
            continue
        if isinstance(value, str) and value == "":
            continue
        raise FlowError(f"{event} 不接受参数 --{field_name.replace('_', '-')}")


def build_plan_review_payload(state: dict[str, Any], args: argparse.Namespace, *, failed_only: bool) -> dict[str, Any]:
    result = require_arg(args.result, "result")
    if failed_only:
        if result != "failed":
            raise FlowError("失败事件只允许 --result failed")
        event_key = "plan_review_failed"
    else:
        if result not in PLAN_REVIEW_PASS_RESULTS:
            raise FlowError("通过事件只允许 --result passed 或 passed_with_notes")
        event_key = "plan_review_passed"
    round_number = 1 + sum(1 for item in state["transitions"] if item["event"] in {"plan_review_passed", "plan_review_failed"})
    disallow_args(event_key, args, ["title", "plan_file", "repo_scope_json", "report_file"])
    return {
        "result": result,
        "round": round_number,
        "engine": require_arg(args.engine, "engine"),
        "model": require_arg(args.model, "model"),
    }


def build_review_payload(state: dict[str, Any], args: argparse.Namespace, *, mode: str, failed_only: bool) -> dict[str, Any]:
    result = require_arg(args.result, "result")
    if failed_only:
        if result != "failed":
            raise FlowError("失败事件只允许 --result failed")
        if args.worktree_snapshot_json is not None:
            raise FlowError("失败事件不接受参数 --worktree-snapshot-json")
    else:
        if result not in REVIEW_PASS_RESULTS:
            raise FlowError("通过事件只允许 --result passed 或 passed_with_notes")
    counts = derive_state(state)["review_rounds"]
    round_number = counts[mode] + 1
    disallow_args(f"{mode}_review", args, ["title", "plan_file", "repo_scope_json"])
    payload = {
        "result": result,
        "round": round_number,
        "report_file": normalize_path(require_arg(args.report_file, "report_file")),
        "engine": require_arg(args.engine, "engine"),
        "model": require_arg(args.model, "model"),
    }
    if args.worktree_snapshot_json is not None:
        try:
            payload["worktree_snapshot"] = json.loads(require_arg(args.worktree_snapshot_json, "worktree_snapshot_json"))
        except json.JSONDecodeError as exc:
            raise FlowError("--worktree-snapshot-json 不是合法 JSON") from exc
    return payload


def build_transition_payload(event: str, state: dict[str, Any] | None, args: argparse.Namespace) -> dict[str, Any]:
    if event == "plan_created":
        if state is not None:
            raise FlowError(f"状态文件已存在: {state_path_for_slug(args.slug)}")
        disallow_args(event, args, ["result", "report_file", "engine", "model"])
        try:
            execution_scope = json.loads(require_arg(args.repo_scope_json, "repo_scope_json"))
        except json.JSONDecodeError as exc:
            raise FlowError("--repo-scope-json 不是合法 JSON") from exc
        payload = {
            "title": require_arg(args.title, "title"),
            "plan_file": normalize_path(require_arg(args.plan_file, "plan_file")),
            "execution_scope": execution_scope,
        }
        validate_payload(event, payload)
        return payload
    if state is None:
        raise FlowError(f"状态文件不存在: {state_path_for_slug(args.slug)}")
    if event == "plan_review_passed":
        return build_plan_review_payload(state, args, failed_only=False)
    if event == "plan_review_failed":
        return build_plan_review_payload(state, args, failed_only=True)
    if event == "review_passed":
        return build_review_payload(state, args, mode="regular", failed_only=False)
    if event == "review_failed":
        return build_review_payload(state, args, mode="regular", failed_only=True)
    if event == "recheck_passed":
        return build_review_payload(state, args, mode="recheck", failed_only=False)
    if event == "recheck_failed":
        return build_review_payload(state, args, mode="recheck", failed_only=True)
    disallow_args(
        event,
        args,
        ["title", "plan_file", "repo_scope_json", "result", "report_file", "engine", "model", "worktree_snapshot_json"],
    )
    return {}


def get_nested(value: Any, field: str) -> Any:
    current = value
    for part in field.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
            continue
        if isinstance(current, list) and part.isdigit():
            index = int(part)
            if 0 <= index < len(current):
                current = current[index]
                continue
        raise FlowError(f"字段不存在: {field}")
    return current


def cmd_transition(args: argparse.Namespace) -> int:
    slug = ensure_slug(args.slug)
    event = args.event
    at = args.at.strip() if isinstance(args.at, str) and args.at.strip() else now_iso()
    parse_iso(at, "at")
    note = (args.note or "").strip()

    def mutator(current_state: dict[str, Any] | None) -> dict[str, Any]:
        payload = build_transition_payload(event, current_state, args)
        if event == "plan_created":
            state_file_path = state_path_for_slug(slug)
            if state_file_path.exists():
                raise FlowError(f"状态文件已存在（同名 slug 当天已有记录）: {state_file_path}，请更换 slug")
            return {
                "schema_version": SCHEMA_VERSION,
                "slug": slug,
                "title": payload["title"],
                "plan_file": payload["plan_file"],
                "execution_scope": payload["execution_scope"],
                "current_status": "AWAITING_PLAN_REVIEW",
                "created_at": at,
                "updated_at": at,
                "transitions": [
                    {
                        "seq": 1,
                        "at": at,
                        "event": "plan_created",
                        "from": None,
                        "to": "AWAITING_PLAN_REVIEW",
                        "actor": ACTOR,
                        "payload": payload,
                        "note": note,
                    }
                ],
            }
        assert current_state is not None
        append_transition(current_state, event=event, at=at, payload=payload, note=note)
        return current_state

    state = with_lock(slug, mutator)
    sys.stdout.write(f"{slug}: {state['current_status']}\n")

    # best-effort 触发 status HTML 渲染，不阻塞主流程
    if _get_config_value is not None:
        auto_render = _get_config_value("html.auto_render.status", False)
        if auto_render:
            home = Path(os.environ.get("AI_FLOW_HOME", Path.home() / ".config" / "ai-flow"))
            flow_html_sh = home / "scripts" / "flow-html.sh"
            if flow_html_sh.is_file():
                try:
                    subprocess.run(
                        ["bash", str(flow_html_sh), "status"],
                        capture_output=True, text=True, timeout=30,
                        cwd=str(PROJECT_DIR),
                    )
                except Exception:
                    pass

    return 0


def cmd_show(args: argparse.Namespace) -> int:
    if args.slug and args.all:
        raise FlowError("show 不能同时使用 --slug 与 --all")
    if not args.slug and not args.all:
        raise FlowError("show 需要提供 --slug 或 --all")

    def render_one(slug: str) -> Any:
        state = require_valid_v4_state(slug)
        payload: Any = state if args.raw else materialize_view(state)
        if args.field:
            payload = get_nested(payload, args.field)
        return payload

    if args.all:
        files = sorted(STATE_DIR.glob("*.json")) if STATE_DIR.exists() else []
        payload = [render_one(path.stem) for path in files]
    else:
        payload = render_one(ensure_slug(args.slug))

    if isinstance(payload, (dict, list)):
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    elif payload is None:
        sys.stdout.write("null\n")
    else:
        sys.stdout.write(f"{payload}\n")
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    if args.slug and args.all:
        raise FlowError("validate 不能同时使用 --slug 与 --all")
    if not args.slug and not args.all:
        raise FlowError("validate 需要提供 --slug 或 --all")
    if args.all:
        files = sorted(STATE_DIR.glob("*.json")) if STATE_DIR.exists() else []
        invalid = False
        for path in files:
            try:
                validate_state(read_json(path), expected_slug=path.stem)
                sys.stdout.write(f"OK {path.stem}\n")
            except FlowError as exc:
                invalid = True
                sys.stderr.write(f"INVALID {path.stem}: {exc}\n")
        if invalid:
            raise FlowError("存在无效状态文件")
        sys.stdout.write(f"validated {len(files)} state file(s)\n")
        return 0
    slug = ensure_slug(args.slug)
    validate_state(load_state_by_slug(slug), expected_slug=slug)
    sys.stdout.write(f"OK {slug}\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    transition_examples = """示例:
  flow-state.sh transition --slug 20260518-user-auth --event plan_created --title "用户认证改造" --plan-file .ai-flow/plans/20260518-user-auth.md --repo-scope-json '<json>'
  flow-state.sh transition --slug 20260518-user-auth --event plan_review_passed --result passed --engine ai-flow-claude-plan-review --model qwen3.6-plus
  flow-state.sh transition --slug 20260518-user-auth --event execute_started
  flow-state.sh transition --slug 20260518-user-auth --event implementation_completed
  flow-state.sh transition --slug 20260518-user-auth --event review_failed --result failed --report-file .ai-flow/reports/20260518-user-auth-review.md --engine ai-flow-claude-plan-coding-review --model qwen3.6-plus
  flow-state.sh transition --slug 20260518-user-auth --event plan_reopened --note "需求变更：新增短信登录"
  flow-state.sh transition --slug 20260518-user-auth --event implementation_reopened --note "需求变更：补充审查后新增实现项"
"""
    parser = argparse.ArgumentParser(
        prog="flow-state.sh",
        description="AI Flow 状态机 v4。唯一写入口是 transition。",
    )
    subparsers = parser.add_subparsers(dest="command")

    transition = subparsers.add_parser(
        "transition",
        description="统一状态写入口",
        formatter_class=argparse.RawTextHelpFormatter,
        epilog=transition_examples,
    )
    transition.add_argument("--slug", required=True)
    transition.add_argument("--event", required=True, choices=sorted(TRANSITION_EVENTS))
    transition.add_argument("--note")
    transition.add_argument("--at")
    transition.add_argument("--title")
    transition.add_argument("--plan-file")
    transition.add_argument("--repo-scope-json")
    transition.add_argument("--result")
    transition.add_argument("--report-file")
    transition.add_argument("--engine")
    transition.add_argument("--model")
    transition.add_argument("--worktree-snapshot-json")
    transition.set_defaults(func=cmd_transition)

    show = subparsers.add_parser("show", description="查看状态文件")
    show.add_argument("--slug")
    show.add_argument("--all", action="store_true")
    show.add_argument("--field")
    show.add_argument("--raw", action="store_true")
    show.set_defaults(func=cmd_show)

    validate = subparsers.add_parser("validate", description="校验状态文件")
    validate.add_argument("--slug")
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
