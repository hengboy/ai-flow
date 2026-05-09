---
name: ai-flow-plan-coding-review
description: 审查计划内编码或独立改动；skill 只定义委派规则，实际执行由 coding-review subagent 完成
---

# AI Flow - Coding Review

**触发时机**：用户输入 `/ai-flow-plan-coding-review`，或明确要求“做 code review”“审查当前改动”。

**Announce at start:** "正在使用 ai-flow-plan-coding-review 技能，委派 subagent 审查当前代码改动。"

## 运行目录

- 单仓模式：在目标 Git 仓库根目录运行。
- 多仓模式（workspace）：在包含 `.ai-flow/workspace.json` 的 workspace 根目录运行。
- 多仓模式下，审查会遍历 manifest 中声明的所有仓库，聚合 Git 变更到一份报告。

## 输入约束

- 按以下步骤自动确定 `slug`，不确定则报错退出，不得降级为任何非计划绑定模式：
  1. 运行 `ls .ai-flow/state/*.json 2>/dev/null` 列出所有状态文件
  2. 仅 1 个：自动使用该 slug
  3. 多个：向用户列出所有 slug 及其 `current_status`，请用户选择
  4. 0 个：报错退出，提示先使用 `/ai-flow-plan` 创建计划
- 绑定 `slug` 时：
  - `AWAITING_REVIEW` 执行常规 review
  - `DONE` 执行 recheck
  - 其他状态拒绝进入流程内审查
- 单仓模式必须存在非 `.ai-flow/` 的未提交 Git 变更
- 多仓模式至少一个声明的仓库有未提交变更

## 强制委派

必须按以下格式调用指定的 subagent，不得替换为任何其他 agent（包括内置 Code Reviewer 等）：

### 首选（默认）

```
Agent(
    description="审查当前代码改动",
    subagent_type="ai-flow-codex-plan-coding-review",
    prompt="slug：{slug 或留空自动选择}"
)
```

### 降级（Codex 不可用时）

```
Agent(
    description="审查当前代码改动",
    subagent_type="ai-flow-opencode-plan-coding-review",
    prompt="slug：{slug 或留空自动选择}"
)
```

### 降级触发规则

- 首选 `ai-flow-codex-plan-coding-review` 返回 `RESULT: failed` 时，**必须自动**尝试降级到 `ai-flow-opencode-plan-coding-review`，无需询问用户。
- 降级失败（opencode 也不可用）时，向用户报告 `SUMMARY` 并停止。

### subagent 职责

- 读取工作区、Git 变更、plan / review 上下文
- 生成 `.ai-flow/reports/*` 下的审查报告
- 推导 `REVIEW_RESULT` 并在绑定 `slug` 时推进状态
- 返回固定摘要协议，而不是回传报告全文

## 完成后

- `REVIEW_RESULT: failed` 且绑定 `slug`：下一步回到 `/ai-flow-plan-coding`
- `REVIEW_RESULT: passed|passed_with_notes` 且绑定 `slug`：状态应进入或保持 `DONE`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止
