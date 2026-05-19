#!/usr/bin/env python3
"""AI Flow 统一配置加载模块。

读取用户级 $AI_FLOW_HOME/setting.json 和项目级 .ai-flow/setting.json，
递归深度合并，输出最终配置对象。
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


def resolve_project_dir() -> Path:
    """向上查找 .ai-flow/state，回退 git toplevel，再回退 cwd。"""
    cwd = Path.cwd().resolve()
    candidate = cwd
    while True:
        if (candidate / ".ai-flow" / "state").is_dir():
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


def _deep_merge(user: dict, project: dict) -> dict:
    """dict 递归合并；标量项目级覆盖用户级；list 项目级替换；null 跳过。"""
    if not isinstance(user, dict) or not isinstance(project, dict):
        return project if project is not None else user
    merged = dict(user)
    for k, v in project.items():
        if v is None:
            continue
        if k in merged and isinstance(merged[k], dict) and isinstance(v, dict):
            merged[k] = _deep_merge(merged[k], v)
        else:
            merged[k] = v
    return merged


def _build_source_map(user: dict, project: dict, prefix: str = "") -> dict[str, str]:
    """构建点分路径 -> 来源（user/project）的映射。"""
    source_map: dict[str, str] = {}
    all_keys = set()
    if isinstance(user, dict):
        all_keys.update(user.keys())
    if isinstance(project, dict):
        all_keys.update(project.keys())
    for k in all_keys:
        path = f"{prefix}.{k}" if prefix else k
        uv = user.get(k) if isinstance(user, dict) else None
        pv = project.get(k) if isinstance(project, dict) else None
        if pv is not None:
            if isinstance(uv, dict) and isinstance(pv, dict):
                source_map.update(_build_source_map(uv, pv, path))
            else:
                source_map[path] = "project"
        elif isinstance(uv, dict):
            source_map.update(_build_source_map(uv, {}, path))
        elif uv is not None:
            source_map[path] = "user"
    return source_map


def _load_json(path: Path) -> dict | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def load_config() -> dict:
    """读取用户级+项目级 setting.json，返回合并后的配置。"""
    home = Path(os.environ.get("AI_FLOW_HOME", Path.home() / ".config" / "ai-flow"))
    project_dir = resolve_project_dir()

    user_path = home / "setting.json"
    project_path = project_dir / ".ai-flow" / "setting.json"

    user_config = _load_json(user_path) or {}
    project_config = _load_json(project_path) or {}

    return _deep_merge(user_config, project_config)


def _get_nested(obj: dict, key: str) -> tuple[bool, Any]:
    """按点分路径获取值，返回 (found, value)。"""
    parts = key.split(".")
    current = obj
    for part in parts:
        if isinstance(current, dict) and part in current:
            current = current[part]
        else:
            return False, None
    return True, current


def get_config_value(key: str, default: Any = None) -> Any:
    """按点分路径获取配置值。"""
    config = load_config()
    found, value = _get_nested(config, key)
    return value if found else default


def get_config_source(key: str) -> str:
    """返回配置来源（project/user/default）。"""
    home = Path(os.environ.get("AI_FLOW_HOME", Path.home() / ".config" / "ai-flow"))
    project_dir = resolve_project_dir()

    user_path = home / "setting.json"
    project_path = project_dir / ".ai-flow" / "setting.json"

    user_config = _load_json(user_path) or {}
    project_config = _load_json(project_path) or {}

    source_map = _build_source_map(user_config, project_config)
    return source_map.get(key, "default")


if __name__ == "__main__":
    """__main__ 模式：输出环境变量赋值，供 shell 脚本 eval 使用。"""
    config = load_config()
    source_map = _build_source_map(
        _load_json(Path(os.environ.get("AI_FLOW_HOME", Path.home() / ".config" / "ai-flow")) / "setting.json") or {},
        _load_json(resolve_project_dir() / ".ai-flow" / "setting.json") or {},
    )

    def flatten(obj: dict, prefix: str = "") -> list[str]:
        items = []
        if isinstance(obj, dict):
            for k, v in obj.items():
                new_key = f"{prefix}_{k}" if prefix else k
                if isinstance(v, dict):
                    items.extend(flatten(v, new_key))
                elif v is not None:
                    env_name = f"AI_FLOW_SETTING_{new_key.upper()}"
                    escaped = str(v).replace("'", "'\\\"'\\\"'")
                    items.append(f"{env_name}='{escaped}'")
        return items

    for line in flatten(config):
        print(line)
    for k, v in source_map.items():
        env_name = f"AI_FLOW_SETTING_SOURCE_{k.replace('.', '_').upper()}"
        print(f"{env_name}='{v}'")
