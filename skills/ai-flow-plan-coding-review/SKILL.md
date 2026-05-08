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

- 绑定 `slug` 时：
  - `AWAITING_REVIEW` 执行常规 review
  - `DONE` 执行 recheck
  - 其他状态拒绝进入流程内审查
- 不绑定 `slug` 时进入 `adhoc` 模式，不读取或修改 `.ai-flow/state`
- 单仓模式必须存在非 `.ai-flow/` 的未提交 Git 变更
- 多仓模式至少一个声明的仓库有未提交变更

## 委派目标

- 首选 `ai-flow-codex-plan-coding-review`
- Codex 不可用时降级到 `ai-flow-opencode-plan-coding-review`
- subagent 必须负责：
  - 读取工作区、Git 变更、plan / review 上下文
  - 生成 `.ai-flow/reports/*` 或 `.ai-flow/reports/adhoc/*`
  - 推导 `REVIEW_RESULT` 并在绑定 `slug` 时推进状态
  - 返回固定摘要协议，而不是回传报告全文

## 完成后

- `REVIEW_RESULT: failed` 且绑定 `slug`：下一步回到 `/ai-flow-plan-coding`
- `REVIEW_RESULT: passed|passed_with_notes` 且绑定 `slug`：状态应进入或保持 `DONE`
- `adhoc` 模式：只确认 `ARTIFACT` 与 `SUMMARY`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止
