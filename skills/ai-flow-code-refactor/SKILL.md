---
name: ai-flow-code-refactor
description: 执行重构类改动；绑定 slug 时遵守 plan-coding 状态门禁，无 slug 时允许独立运行且不写 AI Flow 状态
---

# AI Flow - Code Refactor

**触发时机**：用户输入 `/ai-flow-code-refactor`，或明确要求“做重构”“整理代码结构”。

**Announce at start:** "正在使用 ai-flow-code-refactor 技能，执行重构类改动。"

## 规则

- 绑定 `slug` 时：沿用 `/ai-flow-plan-coding` 的状态门禁和收尾方式
- 无 `slug` 时：允许独立执行，不创建也不修改 `.ai-flow/state`
- 独立重构完成后，如需审查，统一使用 `/ai-flow-plan-coding-review`
- 如果重构过程中引入新需求或业务语义变化，应先回到 `/ai-flow-plan` 补充或修订计划
