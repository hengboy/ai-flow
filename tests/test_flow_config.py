"""flow_config.py 单元测试。"""

import json
import os
import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "runtime", "lib"))

from flow_config import (
    _deep_merge,
    _get_nested,
    _load_json,
    get_config_source,
    get_config_value,
    load_config,
    resolve_project_dir,
)


# --- _deep_merge ---

def test_deep_merge_scalar_override():
    assert _deep_merge({"a": 1}, {"a": 2}) == {"a": 2}


def test_deep_merge_dict_recursive():
    u = {"html": {"enabled": True, "theme": "dark"}}
    p = {"html": {"enabled": False}}
    result = _deep_merge(u, p)
    assert result == {"html": {"enabled": False, "theme": "dark"}}


def test_deep_merge_list_replace():
    u = {"tags": ["a", "b"]}
    p = {"tags": ["c"]}
    assert _deep_merge(u, p) == {"tags": ["c"]}


def test_deep_merge_null_skip():
    u = {"a": 1, "b": 2}
    p = {"a": None, "c": 3}
    assert _deep_merge(u, p) == {"a": 1, "b": 2, "c": 3}


# --- _get_nested ---

def test_get_nested_found():
    found, val = _get_nested({"html": {"enabled": True}}, "html.enabled")
    assert found and val is True


def test_get_nested_not_found():
    found, _ = _get_nested({"html": {}}, "html.enabled")
    assert not found


# --- _load_json ---

def test_load_json_missing():
    assert _load_json(Path("/nonexistent/path.json")) is None


def test_load_json_invalid():
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        f.write(b"{bad")
        f.flush()
        assert _load_json(Path(f.name)) is None


# --- load_config integration ---

@pytest.fixture()
def isolated_env():
    """创建临时目录模拟用户级+项目级配置。"""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        home = tmp / "home"
        project = tmp / "project"
        home.mkdir()
        project.mkdir()
        (project / ".ai-flow").mkdir()
        (project / ".ai-flow" / "state").mkdir()
        yield home, project


def test_config_project_overrides_user(isolated_env):
    home, project = isolated_env
    (home / "setting.json").write_text(json.dumps({"html": {"enabled": True, "theme": "dark"}}))
    (project / ".ai-flow" / "setting.json").write_text(json.dumps({"html": {"enabled": False}}))

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            config = load_config()
            assert config["html"]["enabled"] is False
            assert config["html"]["theme"] == "dark"


def test_config_project_partial_override(isolated_env):
    home, project = isolated_env
    (home / "setting.json").write_text(json.dumps({"html": {"enabled": True, "theme": "dark", "output": "/tmp"}}))
    (project / ".ai-flow" / "setting.json").write_text(json.dumps({"html": {"enabled": False}}))

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            config = load_config()
            assert config["html"]["enabled"] is False
            assert config["html"]["theme"] == "dark"
            assert config["html"]["output"] == "/tmp"


def test_config_deep_merge(isolated_env):
    home, project = isolated_env
    (home / "setting.json").write_text(json.dumps({"a": {"b": {"c": 1, "d": 2}}}))
    (project / ".ai-flow" / "setting.json").write_text(json.dumps({"a": {"b": {"c": 99}}}))

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            config = load_config()
            assert config["a"]["b"]["c"] == 99
            assert config["a"]["b"]["d"] == 2


def test_config_list_replace(isolated_env):
    home, project = isolated_env
    (home / "setting.json").write_text(json.dumps({"repos": ["a", "b"]}))
    (project / ".ai-flow" / "setting.json").write_text(json.dumps({"repos": ["c", "d", "e"]}))

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            config = load_config()
            assert config["repos"] == ["c", "d", "e"]


def test_config_user_only(isolated_env):
    home, project = isolated_env
    (home / "setting.json").write_text(json.dumps({"html": {"enabled": True}}))

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            config = load_config()
            assert config["html"]["enabled"] is True


def test_config_project_only(isolated_env):
    home, project = isolated_env
    (project / ".ai-flow" / "setting.json").write_text(json.dumps({"state": {"actor": "test"}}))

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            config = load_config()
            assert config["state"]["actor"] == "test"


def test_config_neither(isolated_env):
    home, project = isolated_env
    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            config = load_config()
            assert config == {}


def test_config_json_parse_error(isolated_env):
    home, project = isolated_env
    (home / "setting.json").write_text("{bad json")

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            # JSON 解析失败应返回空配置（_load_json 返回 None）
            config = load_config()
            assert config == {}


# --- get_config_source ---

def test_config_source_project(isolated_env):
    home, project = isolated_env
    (home / "setting.json").write_text(json.dumps({"html": {"enabled": True}}))
    (project / ".ai-flow" / "setting.json").write_text(json.dumps({"html": {"enabled": False}}))

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            assert get_config_source("html.enabled") == "project"


def test_config_source_user(isolated_env):
    home, project = isolated_env
    (home / "setting.json").write_text(json.dumps({"html": {"theme": "dark"}}))

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            assert get_config_source("html.theme") == "user"


def test_config_source_default(isolated_env):
    home, project = isolated_env

    with patch("flow_config.resolve_project_dir", return_value=project):
        with patch.dict(os.environ, {"AI_FLOW_HOME": str(home)}):
            assert get_config_source("nonexistent.key") == "default"
