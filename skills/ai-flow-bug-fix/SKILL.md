---
name: ai-flow-bug-fix
description: 执行缺陷修复；绑定 slug 时遵守 plan-coding 状态门禁，无 slug 时允许独立运行且不写 AI Flow 状态
---

# AI Flow - Bug Fix

**触发时机**：用户输入 `/ai-flow-bug-fix`，或明确要求“修 bug”“修复问题”。

**Announce at start:** "正在使用 ai-flow-bug-fix 技能，执行缺陷修复。"

## 规则

> **行为准则**：编码前请遵守 [CLAUDE.md](~/.claude/CLAUDE.md) — 先思考再编码、简洁优先、精准修改、目标驱动执行。

- 绑定 `slug` 时：沿用 `/ai-flow-plan-coding` 的状态门禁和收尾方式
- 无 `slug` 时：允许独立执行，不创建也不修改 `.ai-flow/state`
- 独立修复完成后，如需审查，统一使用 `/ai-flow-plan-coding-review`
- 如果修复暴露出计划缺口、验收条件缺失或需求变化，应先回到 `/ai-flow-plan` 或 `/ai-flow-change`
