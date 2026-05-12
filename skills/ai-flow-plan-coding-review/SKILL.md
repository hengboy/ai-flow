---
name: ai-flow-plan-coding-review
description: 审查计划内编码或独立改动；skill 只定义委派规则，实际执行由 coding-review subagent 完成
---

# AI Flow - Coding Review

**触发时机**：用户输入 `/ai-flow-plan-coding-review`，或明确要求“做 code review”“审查当前改动”。

**Announce at start:** "正在使用 ai-flow-plan-coding-review 技能，委派 subagent 审查当前代码改动。"

## 运行目录

- 单仓模式：在目标 Git 仓库根目录运行。
- 多仓模式（plan_repos）：在 owner repo 的 Git 根目录运行。
- 多仓模式下，审查会遍历 `execution_scope.repos` 中声明的所有仓库，聚合 Git 变更到一份报告。

## 行为准则

> 审查代码时请遵守 `~/.claude/CLAUDE.md` — 先思考再编码、简洁优先、精准修改、目标驱动执行。

## 输入约束

- 按以下步骤自动确定 `slug`：
  1. 运行 `ls .ai-flow/state/*.json 2>/dev/null` 列出所有状态文件
  2. 仅 1 个：自动使用该 slug
  3. 多个：向用户列出所有 slug 及其 `current_status`，请用户选择
  4. 0 个：走 adhoc review 模式（不绑定计划，STATE 固定为 `none`）
- 绑定 `slug` 时：
  - `AWAITING_REVIEW` 执行常规 review
  - `DONE` 执行 recheck
  - 其他状态拒绝进入流程内审查
- 单仓模式必须存在非 `.ai-flow/` 的未提交 Git 变更
- 多仓模式至少一个声明的仓库有未提交变更
- adhoc review：不传入 slug，审查当前未提交变更，产物写入 `.ai-flow/reports/adhoc/{YYYYMMDD}-adhoc-review-{N}.md`

## 委派规则

**先读取 `~/.config/ai-flow/setting.json` 中的 `engine_mode`，再决定目标 subagent。不要跳过这一步，也不得替换为任何其他 agent（包括内置 Code Reviewer 等）。**

| `engine_mode` | 首次委派 | `RESULT: degraded` 处理 |
|---|---|---|
| `claude` | `ai-flow-claude-plan-coding-review` | 不回退；直接报告 `SUMMARY` |
| `codex` | `ai-flow-codex-plan-coding-review` | 报告失败，不降级到 claude |
| `auto` 或未设置 | `ai-flow-codex-plan-coding-review` | 自动改委派 `ai-flow-claude-plan-coding-review` |

调用格式固定为：

```text
Agent(
    description="审查当前代码改动",
    subagent_type="<按上表选择>",
    prompt="slug：{slug 或留空自动选择；无状态文件时走 adhoc review}"
)
```

完成后读取 `REVIEW_RESULT`、`STATE`、`NEXT`、`SUMMARY`。`REVIEW_RESULT: failed` 时回到 `/ai-flow-plan-coding`；`REVIEW_RESULT: passed|passed_with_notes` 时状态进入或保持 `DONE`；任何非成功结果直接报告 `SUMMARY` 并停止。

### subagent 职责

- 读取工作区、Git 变更、plan / review 上下文
- 生成 `.ai-flow/reports/*` 下的审查报告
- 推导 `REVIEW_RESULT` 并在绑定 `slug` 时推进状态
- 返回固定摘要协议，而不是回传报告全文

## 固定输出协议

审查完成后，用一行自然语言总结结果并给出下一步，示例：

- 通过 → `✅ 代码审查通过，64 个测试全部通过，状态已进入 DONE。`
- 通过但有备注 → `✅ 代码审查通过，有 2 条建议性备注。状态已进入 DONE。`
- 失败 → `❌ 代码审查未通过，发现 3 个问题，请回到 /ai-flow-plan-coding 修复。`

然后根据 `NEXT` 值追加下一步提示：

- `NEXT: ai-flow-plan-coding` → 输出 `下一步：运行 /ai-flow-plan-coding 修复审查中发现的问题。`
- `NEXT: none` 且状态进入 DONE → 输出 `⚠️ 请提交当前 plan 所涉及全部代码仓库的代码后再结束流程。`
- `NEXT: none` 且非 DONE → 不输出下一步提示

机器可读协议块只用于 skill/subagent 间解析和自动化推进，不是面向用户的主要内容。面向用户的回复必须优先使用上面的自然语言摘要与下一步提示；除非用户明确要求查看协议字段，最终回复不要直接暴露协议块，或应折叠/隐藏显示。

内部在末尾追加机器可读的协议块：

```text
RESULT: success|failed
AGENT: ai-flow-plan-coding-review
REVIEW_RESULT: passed|passed_with_notes|failed
STATE: <status|none>
NEXT: ai-flow-plan-coding|none
SUMMARY: <one-line-summary>
```

## 完成后

- `REVIEW_RESULT: failed` 且绑定 `slug`：下一步回到 `/ai-flow-plan-coding`
- `REVIEW_RESULT: passed|passed_with_notes` 且绑定 `slug`：状态应进入或保持 `DONE`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止
