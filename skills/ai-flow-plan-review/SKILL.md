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
- 运行目录必须与 plan 创建时的目录一致（单仓模式为 Git 根目录，多仓模式为 workspace 根目录）

## Workspace 模式注意

- 如果 plan 顶部 `执行范围` 为 `workspace`，审核重点包括：repo id 是否全部声明在 `.ai-flow/workspace.json` 中、文件路径是否相对于 workspace 根目录、跨仓库依赖是否合理。

## 审核后偏差处理策略

- 审核动作本身仍由 plan-review subagent 完成；skill 层不手工改写审核结论
- 默认不要针对每条偏差逐条征求用户意见
- 若审核项涉及高优先级偏差，先向用户汇总并确认修订方向，再进入 `/ai-flow-plan`
  - 适用：目标变更、范围增减、优先级重排、验收标准变化、关键 tradeoff、高误改风险
- 若审核项属于中优先级偏差且存在多个可行修订方向，合并成一次确认；若修订方向唯一，则直接返回 `/ai-flow-plan`
  - 适用：实现路径明显变化，但最终目标不变
- 若审核项仅为低优先级偏差，直接返回 `/ai-flow-plan` 修订，无需额外确认
  - 适用：措辞、结构、顺序、细化、补漏、消歧，且不改变原意

## 引擎模式决策（第一步）

**先读取环境变量 `AI_FLOW_ENGINE_MODE`，再决定走哪个分支。不要跳过这一步。**

- **`claude`** → 直接走 [引擎模式：claude](#引擎模式claude) 分支
- **`codex`** → 直接走 [引擎模式：codex](#引擎模式codex) 分支
- **`auto` 或未设置** → 走 [引擎模式：auto](#引擎模式auto) 分支

必须按以下格式调用指定的 subagent，不得替换为任何其他 agent（包括内置 Code Reviewer 等）。

## 引擎模式：claude

> 当 `AI_FLOW_ENGINE_MODE=claude` 时执行此分支。跳过 codex，不尝试 codex subagent。

```
Agent(
    description="审核 draft plan（claude 直连）",
    subagent_type="ai-flow-claude-plan-review",
    prompt="slug：{日期}-{slug}"
)
```

完成后：
- `REVIEW_RESULT: passed|passed_with_notes`：下一步进入 `/ai-flow-plan-coding`
- `REVIEW_RESULT: failed`：按"审核后偏差处理策略"决定
- 任何非成功结果：直接报告 `SUMMARY` 并停止

## 引擎模式：auto

> 当 `AI_FLOW_ENGINE_MODE=auto` 或未设置时执行此分支。

### 首选

```
Agent(
    description="审核 draft plan",
    subagent_type="ai-flow-codex-plan-review",
    prompt="slug：{日期}-{slug}"
)
```

### 降级

当 subagent 返回 `RESULT: degraded` 时，自动委派到 `ai-flow-claude-plan-review`：

```
Agent(
    description="审核 draft plan（Codex 不可用，降级）",
    subagent_type="ai-flow-claude-plan-review",
    prompt="slug：{日期}-{slug}"
)
```

完成后：
- `REVIEW_RESULT: passed|passed_with_notes`：下一步进入 `/ai-flow-plan-coding`
- `REVIEW_RESULT: failed`：按"审核后偏差处理策略"决定

## 引擎模式：codex

> 当 `AI_FLOW_ENGINE_MODE=codex` 时执行此分支。仅使用 codex subagent。

```
Agent(
    description="审核 draft plan（codex 模式）",
    subagent_type="ai-flow-codex-plan-review",
    prompt="slug：{日期}-{slug}"
)
```

- 如果 codex subagent 返回 `RESULT: degraded`，报告失败，不降级到 claude
- 成功后：读取 `REVIEW_RESULT`，进入下一步

### subagent 职责

- 读取 plan 与状态文件
- 执行计划审核
- 回写 `## 8. 计划审核记录`
- 推进 `.ai-flow/state/{日期}-{slug}.json`
- 返回固定摘要协议，且包含 `REVIEW_RESULT`

## 完成后

- `REVIEW_RESULT: passed|passed_with_notes`：下一步进入 `/ai-flow-plan-coding`
- `REVIEW_RESULT: failed`：按“审核后偏差处理策略”决定是否先确认，再回到 `/ai-flow-plan`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止
