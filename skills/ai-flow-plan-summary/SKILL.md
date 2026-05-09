---
name: ai-flow-plan-summary
description: 总结 AI Flow 流程的完整生命周期，含实施变动、Review 历史与统计；纯只读输出，不修改任何文件
---

# AI Flow - 流程生命周期总结

**触发时机**：用户输入 `/ai-flow-plan-summary`，或要求"总结流程"、"查看流程历史"、"查看某流程的完整生命周期"。可选提供 `slug` 参数指定流程。

**Announce at start:** "正在使用 ai-flow-plan-summary 技能，总结流程生命周期。"

**纯只读保证**：本 skill 不执行任何文件写入操作，不调用 `flow-state.sh` 的写子命令，不保存报告文件，不修改 plan/review/state 文件。

## 运行目录

- 单仓模式：在目标 Git 仓库根目录运行。
- 多仓模式（workspace）：在包含 `.ai-flow/workspace.json` 的 workspace 根目录运行。

## 输入约束与 Slug 解析

1. 若用户提供了 slug，验证 `.ai-flow/state/<slug>.json` 是否存在，存在则直接进入完整总结。
2. 若未提供 slug，运行 `ls .ai-flow/state/*.json 2>/dev/null`：
   - 0 个：报错退出，提示先使用 `/ai-flow-plan` 创建计划。
   - **多个：进入"列表模式"，仅列出所有 slug（不带简介），然后要求用户明确选择其中一个。必须等待用户选择后才输出完整总结，不得自动选择或跳过。**

## 列表模式（不带 slug 且存在多个流程时）

对每个 state JSON 文件，仅提取 slug（文件名去掉 `.json` 后缀）和 `current_status`，输出简洁列表：

```
| slug | 状态 |
|------|------|
```

列出后，使用 `AskUserQuestion` 让用户选择要展开总结的流程，不得自动选择。

## 完整生命周期总结（选定 slug 后）

按以下顺序输出，每个章节用 markdown 标题分隔。整体风格：精简、要点化，避免大段原文引用。

### 1. 流程概览（一行式）

```
{slug} | {需求标题} | 状态: {current_status} | {created_at} → {updated_at} | 范围: {execution_scope.mode}
```

### 2. 原始需求与实现目标

从 plan 文件 `## 1. 需求概述` 提取：

- **原始需求**：`{原文摘录，控制在 100 字内}`
- **实现目标**：`{目标描述，控制在 80 字内}`

### 3. 流程时序（紧凑单行式）

按时间顺序合并所有状态转换和 Review 事件，每条一行紧凑输出：

```
{时间} | {事件简写} | {结果/目标状态} | {备注，≤30字}
```

- 事件简写：`Plan审核✓`、`Plan审核✗`、`Coding审核✓`、`Coding审核✗`、`→{目标状态}`
- 仅 Review 事件在"结果"列显示通过/失败/缺陷数，状态转换显示目标状态名
- 无备注显示 `-`，不输出表头和分隔线

## 完成

- 不进入任何后续 skill
- 不执行任何状态转换
- 用户可根据总结内容决定下一步操作
