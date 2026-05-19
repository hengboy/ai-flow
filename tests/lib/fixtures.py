#!/usr/bin/env python3
"""测试辅助工具：临时环境构建、setting.json 生成、状态文件创建。"""

import json
import os
import tempfile
from pathlib import Path


class TempProject:
    """创建一个隔离的临时项目环境，位于 .ai-flow-tests 下。"""

    def __init__(self, *, with_git=False):
        # 使用 .ai-flow-tests 作为测试根目录
        project_root = Path(__file__).resolve().parent.parent.parent
        test_root = project_root / ".ai-flow-tests"
        test_root.mkdir(exist_ok=True)
        import tempfile
        prefix = next(iter(tempfile._get_candidate_names()), "test")  # noqa: F841
        self.tmpdir = tempfile.mkdtemp(dir=str(test_root), prefix="tp-")
        self.root = Path(self.tmpdir)
        self.ai_flow = self.root / ".ai-flow"
        self.state_dir = self.ai_flow / "state"
        self.state_dir.mkdir(parents=True)
        self._with_git = with_git

    def cleanup(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    @property
    def env(self):
        """默认环境，不注入 AI_FLOW_ACTOR 让 Python 从 setting.json 读取。"""
        return dict(os.environ)

    def create_state(self, slug, **overrides):
        """创建一个最小合法状态文件，支持字段覆盖。"""
        defaults = {
            "schema_version": 4,
            "slug": slug,
            "title": "测试功能",
            "plan_file": ".ai-flow/plans/test.md",
            "execution_scope": {
                "mode": "plan_repos",
                "repos": [{
                    "id": "owner", "path": ".",
                    "git_root": str(self.root), "role": "owner"
                }]
            },
            "current_status": "AWAITING_PLAN_REVIEW",
            "created_at": "2026-05-19T10:00:00+08:00",
            "updated_at": "2026-05-19T10:00:00+08:00",
            "transitions": [{
                "seq": 1, "at": "2026-05-19T10:00:00+08:00",
                "event": "plan_created", "from": None,
                "to": "AWAITING_PLAN_REVIEW", "actor": "test-runner",
                "payload": {
                    "title": "测试功能", "plan_file": ".ai-flow/plans/test.md",
                    "execution_scope": {
                        "mode": "plan_repos",
                        "repos": [{
                            "id": "owner", "path": ".",
                            "git_root": str(self.root), "role": "owner"
                        }]
                    }
                },
                "note": "创建计划"
            }]
        }

        def _deep_merge(base, override):
            result = dict(base)
            for k, v in override.items():
                if k in result and isinstance(result[k], dict) and isinstance(v, dict):
                    result[k] = _deep_merge(result[k], v)
                else:
                    result[k] = v
            return result

        state = _deep_merge(defaults, overrides) if overrides else defaults
        (self.state_dir / f"{slug}.json").write_text(
            json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        return state

    def create_project_setting(self, **kwargs):
        """在项目级 .ai-flow/setting.json 中写入配置。"""
        setting_path = self.ai_flow / "setting.json"
        setting_path.write_text(json.dumps(kwargs, ensure_ascii=False, indent=2), encoding="utf-8")
        return setting_path

    def create_user_setting(self, home_dir, **kwargs):
        """在用户级 setting.json 中写入配置（AI_FLOW_HOME 直接包含 setting.json）。"""
        setting_path = Path(home_dir) / "setting.json"
        setting_path.parent.mkdir(parents=True, exist_ok=True)
        setting_path.write_text(json.dumps(kwargs, ensure_ascii=False, indent=2), encoding="utf-8")
        return setting_path
