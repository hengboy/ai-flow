---
name: ai-flow-status
description: 查看当前项目 .ai-flow/state/ 下所有流程状态，并按 JSON 状态分类展示待办
---

# AI Flow - 流程状态查看

**触发时机**：用户输入 `/ai-flow-status` 或询问“流程状态”“有什么待处理任务”。

**Announce at start:** "正在使用 ai-flow-status 技能查看当前项目的 AI 协作流程状态。"

## 运行目录

- 单仓模式：在目标 Git 仓库根目录运行。
- 多仓模式（workspace）：在包含 `.ai-flow/workspace.json` 的 workspace 根目录运行。
- workspace 根目录本身不必是 Git 仓库。

## 流程

### 1. 执行扫描

运行：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-status.sh
```

### 2. 读取分类

输出只基于 `.ai-flow/state/*.json` 的 `current_status` 分类：

- `AWAITING_PLAN_REVIEW`：待计划审核
- `PLAN_REVIEW_FAILED`：待修订计划
- `PLANNED`：计划已审核通过，待编码
- `IMPLEMENTING`：开发中
- `AWAITING_REVIEW`：待审查
- `REVIEW_FAILED`：待修复
- `FIXING_REVIEW`：修复中
- `DONE`：可再审查

### 3. 选择后续动作

- 选中 `AWAITING_PLAN_REVIEW`：进入 `/ai-flow-plan-review`
- 选中 `PLAN_REVIEW_FAILED`：进入 `/ai-flow-plan`
- 选中 `PLANNED` / `IMPLEMENTING` / `REVIEW_FAILED` / `FIXING_REVIEW`：进入 `/ai-flow-plan-coding`
- 选中 `AWAITING_REVIEW` / `DONE`：进入 `/ai-flow-plan-coding-review`

## 注意事项

- 不再根据 plan 或 report 首行判断状态
- 历史失败报告不会单独形成“待修复”项
- 展示的 plan/report 路径只是辅助信息，真实状态仍以 JSON 文件为准
