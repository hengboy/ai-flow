---
name: ai-flow-bug-fix
description: 执行缺陷修复；绑定 slug 时遵守 plan-coding 状态门禁，无 slug 时允许独立运行且不写 AI Flow 状态
---

# AI Flow - Bug Fix

**触发时机**：用户输入 `/ai-flow-bug-fix`，或明确要求“修 bug”“修复问题”。

**Announce at start:** "正在使用 ai-flow-bug-fix 技能，执行缺陷修复。"

## 规则

> **行为准则**：编码前请遵守 `~/.claude/CLAUDE.md` — 先思考再编码、简洁优先、精准修改、目标驱动执行。

- 绑定 `slug` 时：第一执行动作必须是调用 `$HOME/.config/ai-flow/scripts/flow-bug-fix.sh {YYYYMMDD}-{slug}`；该 runtime 入口沿用 `/ai-flow-plan-coding` 的状态门禁和执行前规则校验
- 无 `slug` 时：允许独立执行，不创建也不修改 `.ai-flow/state`
- 若目标 repo 存在 `.ai-flow/rule.yaml`，修复时必须同时遵守其中的项目级边界与验证要求
- 若当前修改用于处理 `DONE` 后遗留的 Minor 缺陷建议，应保持无 `slug` 独立执行
- 独立修复完成后，如需审查，统一使用 `/ai-flow-plan-coding-review`；若要保持独立链路，显式使用 standalone review
- 如果修复暴露出计划缺口、验收条件缺失或需求变化，应先回到 `/ai-flow-plan` 或 `/ai-flow-change`
