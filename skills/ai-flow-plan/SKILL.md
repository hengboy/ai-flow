---
name: ai-flow-plan
description: 生成或修订 draft plan；skill 只定义委派规则，实际执行由 plan subagent 完成
---

# AI Flow - Draft Plan

**触发时机**：用户输入 `/ai-flow-plan`，或明确要求“分析需求写 plan”“修订 plan 草案”。

**Announce at start:** "正在使用 ai-flow-plan 技能，委派 subagent 生成或修订 draft plan。"

## 输入约束

- 需求描述必填；`slug` 可选，但建议显式提供
- 当前目录必须是目标项目根目录
- 同名 `slug` 只有在 `AWAITING_PLAN_REVIEW` 或 `PLAN_REVIEW_FAILED` 时允许原地修订

## 委派目标

- 首选 `ai-flow-codex-plan`
- Codex 不可用时降级到 `ai-flow-opencode-plan`
- subagent 必须负责：
  - 读取工作区与 `.ai-flow` 上下文
  - 渲染 prompt / template
  - 生成或修订 `.ai-flow/plans/*`
  - 创建或保持 `.ai-flow/state/<slug>.json`
  - 返回固定摘要协议，而不是回传 plan 正文

## 完成后

- `RESULT: success`：读取 `ARTIFACT`、`STATE`、`NEXT`、`SUMMARY`，确认 draft 已落盘
- 下一步固定进入 `/ai-flow-plan-review`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止，不手工补跑任何中间脚本
