---
name: ai-flow-plan-review
description: 审核 draft plan 并推进状态；skill 只定义委派规则，实际执行由 plan-review subagent 完成
---

# AI Flow - 计划审核

**触发时机**：用户输入 `/ai-flow-plan-review`，或明确要求“审核计划”“放行 plan”。

**Announce at start:** "正在使用 ai-flow-plan-review 技能，委派 subagent 审核 draft plan。"

## 行为准则

> 审核计划时请遵守 `~/.claude/CLAUDE.md` — 先思考再编码、简洁优先、精准修改、目标驱动执行。

## 输入约束

- 按以下步骤自动确定 `slug`，不确定则报错退出：
  1. 运行 `ls .ai-flow/state/*.json 2>/dev/null` 列出所有状态文件
  2. 仅 1 个：自动使用该 slug
  3. 多个：向用户列出所有 slug 及其 `current_status`，请用户选择
  4. 0 个：报错退出，提示先使用 `/ai-flow-plan` 创建计划
- 只允许选择 `AWAITING_PLAN_REVIEW` 或 `PLAN_REVIEW_FAILED` 的 `slug`
- skill 本身不修订 plan，不手工调用 `flow-state.sh record-plan-review`
- 运行目录必须与 plan 创建时的目录一致（单仓模式为 Git 根目录，多仓模式为 owner repo 根目录）

## Plan 审核注意

- 如果 plan 顶部 `执行范围` 为 `plan_repos`，审核重点包括：plan 中声明的 repo 是否全部在 `execution_scope.repos` 中列出、文件路径是否相对于对应 repo 根目录、跨仓库依赖是否合理。

## 审核后偏差处理策略

- 审核动作本身仍由 plan-review subagent 完成；skill 层不手工改写审核结论
- 默认不要针对每条偏差逐条征求用户意见
- 若审核项涉及高优先级偏差，先向用户汇总并确认修订方向，再进入 `/ai-flow-plan`
  - 适用：目标变更、范围增减、优先级重排、验收标准变化、关键 tradeoff、高误改风险
- 若审核项属于中优先级偏差且存在多个可行修订方向，合并成一次确认；若修订方向唯一，则直接返回 `/ai-flow-plan`
  - 适用：实现路径明显变化，但最终目标不变
- 若审核项仅为低优先级偏差，直接返回 `/ai-flow-plan` 修订，无需额外确认
  - 适用：措辞、结构、顺序、细化、补漏、消歧，且不改变原意

## 委派规则

**先读取 `~/.config/ai-flow/setting.json` 中的 `engine_mode`，再决定目标 subagent。不要跳过这一步，也不得替换为任何其他 agent（包括内置 Code Reviewer 等）。**

| `engine_mode` | 首次委派 | `RESULT: degraded` 处理 |
|---|---|---|
| `claude` | `ai-flow-claude-plan-review` | 不回退；直接报告 `SUMMARY` |
| `codex` | `ai-flow-codex-plan-review` | 报告失败，不降级到 claude |
| `auto` 或未设置 | `ai-flow-codex-plan-review` | 自动改委派 `ai-flow-claude-plan-review` |

调用格式固定为：

```text
Agent(
    description="审核 draft plan",
    subagent_type="<按上表选择>",
    prompt="slug：{YYYYMMDD}-{slug}"
)
```

完成后读取 `REVIEW_RESULT`、`STATE`、`NEXT`、`SUMMARY`。`REVIEW_RESULT: passed|passed_with_notes` 时下一步进入 `/ai-flow-plan-coding`；`REVIEW_RESULT: failed` 时按"审核后偏差处理策略"决定；任何非成功结果直接报告 `SUMMARY` 并停止。

### subagent 职责

- 读取 plan 与状态文件
- 执行计划审核
- 回写 `## 8. 计划审核记录`
- 推进 `.ai-flow/state/{YYYYMMDD}-{slug}.json`
- 返回固定摘要协议，且包含 `REVIEW_RESULT`

## 固定输出协议

审核完成后，用一行自然语言总结结果并给出下一步，示例：

- 通过 → `✅ 计划审核通过，状态进入 PLANNED，可以开始实施。`
- 通过但有备注 → `✅ 计划审核通过，有 1 条建议。状态进入 PLANNED。`
- 失败 → `❌ 计划审核未通过，发现 2 个问题，请回到 /ai-flow-plan 修订。`

然后根据 `NEXT` 值追加下一步提示：

- `NEXT: ai-flow-plan-coding` → 输出 `下一步：运行 /ai-flow-plan-coding 开始实施计划。`
- `NEXT: ai-flow-plan` → 输出 `下一步：运行 /ai-flow-plan 修订计划后重新审核。`
- `NEXT: none` → 不输出下一步提示

机器可读协议块只用于 skill/subagent 间解析和自动化推进，不是面向用户的主要内容。面向用户的最终回复必须只保留上面的自然语言摘要与下一步提示，禁止直接输出 `RESULT:`、`STATE:`、`NEXT:`、`SUMMARY:`、`REVIEW_RESULT:` 等协议字段；只有用户明确要求查看协议字段时才可额外展示。

内部在末尾追加机器可读的协议块：

```text
RESULT: success|failed
AGENT: ai-flow-plan-review
REVIEW_RESULT: passed|passed_with_notes|failed
STATE: <status|none>
NEXT: ai-flow-plan-coding|ai-flow-plan|none
SUMMARY: <one-line-summary>
```

## 完成后

- `REVIEW_RESULT: passed|passed_with_notes`：下一步进入 `/ai-flow-plan-coding`
- `REVIEW_RESULT: failed`：按”审核后偏差处理策略”决定是否先确认，再回到 `/ai-flow-plan`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止
