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
        plan_dir = self.ai_flow / "plans"
        plan_dir.mkdir(parents=True, exist_ok=True)
        plan_file = plan_dir / "test.md"
        if not plan_file.exists():
            plan_file.write_text(
                """# 实施计划：测试功能

> 创建日期：2026-05-19
> 创建时间：10:00:00
> 需求简称：测试功能
> 需求来源：测试
> 执行范围：owner
> Plan 参与仓库：owner
> 状态文件：.ai-flow/state/test.json
> 文档角色：实施计划
> 状态文件约束：仅 flow-state.sh transition 可修改
> 执行约定：按 Step 顺序执行
> 验证约定：运行计划中的验证命令
> 规则标识：test

## 1. 需求概述

**目标**：测试

**背景**：测试

**原始需求（原文）**：
测试

**非目标**：无

## 2. 技术分析

### 2.1 涉及模块

| 模块 | 仓库 | 职责 | 变更类型 |
|------|------|------|----------|
| test | owner | test | 修改 |

### 2.2 数据模型变更

不涉及数据库变更

### 2.3 API 变更

| 接口 | 方法 | 路径 | 说明 |
|------|------|------|------|
| 无新增/修改接口 | - | - | - |

### 2.4 依赖影响

无

### 2.5 文件边界总览

| 文件 | 仓库 | 操作 | 职责 | 对应 Step ID |
|------|------|------|------|----------|
| `a.txt` | owner | Modify | test | `step-one` |

### 2.6 高风险路径与缺陷族

| 高风险能力/路径 | 影响面 | 典型失效模式 | 对应缺陷族 | 必须覆盖的验证方式 |
|----------------|--------|--------------|------------|--------------------|
| test | test | test | test-family | 单测 |

## 3. 实施步骤

### 第一步

**Step ID**：`step-one`

**目标**：测试

**文件边界**：
- Modify: `a.txt` — test
- Test: `tests/a_test.py` — test

**本轮 review 预期关注面**：test-family

**执行动作**：
- [x] **实现**
  - 命令：`echo ok`
  - 预期：PASS

**本步验收**：
- [x] 命令成功

**本步关闭条件**：命令通过

**阻塞条件**：- 无

## 4. 测试计划

### 4.1 单元测试

- [ ] test

### 4.2 集成测试

- [ ] 无

### 4.3 回归验证

- [ ] `echo ok`

### 4.4 定向验证矩阵

| 缺陷族 | 目标风险路径 | 定向验证命令 | 验证类型 | 通过标准 |
|--------|--------------|--------------|----------|----------|
| test-family | test | `echo ok` | 单测 | 输出 ok |

## 5. 风险与注意事项

- 无

## 6. 验收标准

- [ ] test

## 7. 需求变更记录

| 时间 | 变更描述 | 确认方式 |
|------|----------|----------|

## 8. 计划审核记录

### 8.1 当前审核结论

- 待审核

### 8.2 偏差与建议

- 无

### 8.3 审核历史

- 无
""",
                encoding="utf-8",
            )
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
