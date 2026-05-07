---
name: ai-flow-plan-review
description: 审核 draft plan 并推进状态；skill 只定义委派规则，实际执行由 plan-review subagent 完成
---

# AI Flow - 计划审核

**触发时机**：用户输入 `/ai-flow-plan-review`，或明确要求“审核计划”“放行 plan”。

**Announce at start:** "正在使用 ai-flow-plan-review 技能，委派 subagent 审核 draft plan。"

## 输入约束

- 只允许选择 `AWAITING_PLAN_REVIEW` 或 `PLAN_REVIEW_FAILED` 的 `slug`
- skill 本身不修订 plan，不手工调用 `flow-state.sh record-plan-review`

## 委派目标

- 首选 `ai-flow-codex-plan-review`
- Codex 不可用时降级到 `ai-flow-opencode-plan-review`
- subagent 必须负责：
  - 读取 plan 与状态文件
  - 执行计划审核
  - 回写 `## 8. 计划审核记录`
  - 推进 `.ai-flow/state/<slug>.json`
  - 返回固定摘要协议，且包含 `REVIEW_RESULT`

## 完成后

- `REVIEW_RESULT: passed|passed_with_notes`：下一步进入 `/ai-flow-plan-coding`
- `REVIEW_RESULT: failed`：下一步回到 `/ai-flow-plan`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止
