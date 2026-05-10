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

## 行为准则

> 审查代码时请遵守 [CLAUDE.md](~/.claude/CLAUDE.md) — 先思考再编码、简洁优先、精准修改、目标驱动执行。

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

## 引擎模式

通过环境变量 `AI_FLOW_ENGINE_MODE` 控制引擎选择行为：

- **`auto`（默认）**：按下方"首选"委派到 codex subagent；当返回 `RESULT: degraded` 时按"降级"委派到 claude subagent。
- **`claude`**：跳过 codex subagent，直接按下方"claude 直连"委派到 claude subagent。如果 claude subagent 返回非成功结果，立即报告失败。
- **`codex`**：仅使用 codex subagent。如果 codex subagent 返回 `RESULT: degraded`，报告失败而非降级到 claude。

### claude 直连（当 AI_FLOW_ENGINE_MODE=claude 时）

```
Agent(
    description="审查代码改动（claude 直连）",
    subagent_type="ai-flow-claude-plan-coding-review",
    prompt="slug：{slug 或留空自动选择}"
)
```

完成后：
- `REVIEW_RESULT: failed`：回到 `/ai-flow-plan-coding`
- `REVIEW_RESULT: passed|passed_with_notes`：状态进入或保持 `DONE`
- 任何非成功结果：直接报告 `SUMMARY` 并停止

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

当 subagent 返回 `RESULT: degraded` 时，自动委派到 `ai-flow-claude-plan-coding-review`：

```
Agent(
    description="审查代码改动（Codex 不可用，降级）",
    subagent_type="ai-flow-claude-plan-coding-review",
    prompt="slug：{slug 或留空自动选择}"
)
```

完成后：
- `REVIEW_RESULT: failed`：回到 `/ai-flow-plan-coding`
- `REVIEW_RESULT: passed|passed_with_notes`：状态进入或保持 `DONE`

### subagent 职责

- 读取工作区、Git 变更、plan / review 上下文
- 生成 `.ai-flow/reports/*` 下的审查报告
- 推导 `REVIEW_RESULT` 并在绑定 `slug` 时推进状态
- 返回固定摘要协议，而不是回传报告全文

## 完成后

- `REVIEW_RESULT: failed` 且绑定 `slug`：下一步回到 `/ai-flow-plan-coding`
- `REVIEW_RESULT: passed|passed_with_notes` 且绑定 `slug`：状态应进入或保持 `DONE`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止
