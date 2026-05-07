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

## 审核后偏差处理策略

- 审核动作本身仍由 plan-review subagent 完成；skill 层不手工改写审核结论
- 默认不要针对每条偏差逐条征求用户意见
- 若审核项涉及高优先级偏差，先向用户汇总并确认修订方向，再进入 `/ai-flow-plan`
  - 适用：目标变更、范围增减、优先级重排、验收标准变化、关键 tradeoff、高误改风险
- 若审核项属于中优先级偏差且存在多个可行修订方向，合并成一次确认；若修订方向唯一，则直接返回 `/ai-flow-plan`
  - 适用：实现路径明显变化，但最终目标不变
- 若审核项仅为低优先级偏差，直接返回 `/ai-flow-plan` 修订，无需额外确认
  - 适用：措辞、结构、顺序、细化、补漏、消歧，且不改变原意

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
- `REVIEW_RESULT: failed`：按“审核后偏差处理策略”决定是否先确认，再回到 `/ai-flow-plan`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止
