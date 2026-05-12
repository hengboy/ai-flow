---
name: ai-flow-plan
description: 生成或修订 draft plan；skill 只定义委派规则，实际执行由 plan subagent 完成
---

# AI Flow - Draft Plan

**触发时机**：用户输入 `/ai-flow-plan`，或明确要求“分析需求写 plan”“修订 plan 草案”。

**Announce at start:** "正在使用 ai-flow-plan 技能，委派 subagent 生成或修订 draft plan。"

## 运行目录

- 单仓模式：在目标 Git 仓库根目录运行。
- 多仓模式（workspace）：在包含 `.ai-flow/workspace.json` 的 workspace 根目录运行。
- 当前目录必须有 `.ai-flow/` 目录或可识别的项目根标记（`.git`、`pom.xml`、`package.json` 等）。

## 行为准则

> 生成或修订计划时请遵守 `~/.claude/CLAUDE.md` — 先思考再编码、简洁优先、精准修改、目标驱动执行。

## 输入约束

- 需求描述必填；`slug` 可选，不提供时自动从需求描述生成，建议显式提供以保证命名一致性
- `/ai-flow-plan` 每次都生成新的 draft plan；只有用户显式提供同名 `slug` 且状态允许时，才进入原地修订
- **禁止复用旧 plan**：不允许搜索 `.ai-flow/plans/` 下的历史 plan 文件并直接沿用。每次都必须根据当前需求内容从头生成新的 plan。`slug` 仅用于状态关联，不用于查找已有 plan 内容。
- 同名 `slug` 只有在 `AWAITING_PLAN_REVIEW` 或 `PLAN_REVIEW_FAILED` 时允许原地修订

## 修订前确认策略

- 当任务是原地修订已有 draft plan 时，先读取原 plan、`## 8. 计划审核记录` 与原始需求，再决定是否需要先询问用户
- 默认不要对每个偏差逐条询问；只在会改变决策或结果时打断
- 高优先级偏差：先合并后一次性询问用户，再委派修订
  - 适用：目标变更、范围增减、优先级重排、验收标准变化、关键 tradeoff、高误改风险
- 中优先级偏差：若存在多个差异明显的可行修订方向，给出推荐方案并快速确认；若修订方向唯一且能从原始需求直接推出，则直接委派修订
  - 适用：实现路径明显变化，但最终目标不变
- 低优先级偏差：直接委派修订
  - 适用：措辞、结构、顺序、细化、补漏、消歧，且不改变原意
- 用户偏好一旦明确，同类问题默认沿用，不重复确认

## 引擎模式决策（第一步）

**先读取环境变量 `AI_FLOW_ENGINE_MODE`，再决定走哪个分支。不要跳过这一步。**

- **`claude`** → 直接走 [引擎模式：claude](#引擎模式claude) 分支
- **`codex`** → 直接走 [引擎模式：codex](#引擎模式codex) 分支
- **`auto` 或未设置** → 走 [引擎模式：auto](#引擎模式auto) 分支

必须按以下格式调用指定的 subagent，不得替换为任何其他 agent（包括内置 Plan agent）。

## 引擎模式：claude

> 当 `AI_FLOW_ENGINE_MODE=claude` 时执行此分支。跳过 codex，不尝试 codex subagent。

```
Agent(
    description="生成或修订 draft plan（claude 直连）",
    subagent_type="ai-flow-claude-plan",
    prompt="需求描述：{需求描述}\nslug：{slug 或留空自动生成}"
)
```

完成后：
- 读取 `ARTIFACT`、`STATE`、`NEXT`、`SUMMARY`
- 下一步固定进入 `/ai-flow-plan-review`
- 任何非成功结果：直接报告 `SUMMARY` 并停止，不回退到 codex

## 引擎模式：auto

> 当 `AI_FLOW_ENGINE_MODE=auto` 或未设置时执行此分支。

### 首选

```
Agent(
    description="生成或修订 draft plan",
    subagent_type="ai-flow-codex-plan",
    prompt="需求描述：{需求描述}\nslug：{slug 或留空自动生成}"
)
```

### 降级

当 subagent 返回 `RESULT: degraded` 时，自动委派到 `ai-flow-claude-plan`：

```
Agent(
    description="生成或修订 draft plan（Codex 不可用，降级）",
    subagent_type="ai-flow-claude-plan",
    prompt="需求描述：{需求描述}\nslug：{slug 或留空自动生成}"
)
```

完成后：
- 读取 `ARTIFACT`、`STATE`、`NEXT`、`SUMMARY`
- 下一步固定进入 `/ai-flow-plan-review`

## 引擎模式：codex

> 当 `AI_FLOW_ENGINE_MODE=codex` 时执行此分支。仅使用 codex subagent。

```
Agent(
    description="生成或修订 draft plan（codex 模式）",
    subagent_type="ai-flow-codex-plan",
    prompt="需求描述：{需求描述}\nslug：{slug 或留空自动生成}"
)
```

- 如果 codex subagent 返回 `RESULT: degraded`，报告失败，不降级到 claude
- 成功后：读取 `ARTIFACT`、`STATE`、`NEXT`、`SUMMARY`，下一步进入 `/ai-flow-plan-review`

### subagent 职责

- 读取工作区与 `.ai-flow` 上下文
- 渲染 prompt / template
- 生成或修订 `.ai-flow/plans/*`
- 创建或保持 `.ai-flow/state/{日期}-{slug}.json`
- 返回固定摘要协议，而不是回传 plan 正文

## 固定输出协议

plan 生成/修订完成后，用一行自然语言总结结果并给出下一步，示例：

- 成功 → `✅ 计划草案已生成，状态进入 AWAITING_PLAN_REVIEW。`
- 修订成功 → `✅ 计划已修订，状态进入 AWAITING_PLAN_REVIEW。`
- 失败 → `❌ 计划生成失败，缺少需求描述。`

然后根据 `NEXT` 值追加下一步提示：

- `NEXT: ai-flow-plan-review` → 输出 `下一步：运行 /ai-flow-plan-review 审核 draft plan。`
- `NEXT: none` → 不输出下一步提示

机器可读协议块只用于 skill/subagent 间解析和自动化推进，不是面向用户的主要内容。面向用户的回复必须优先使用上面的自然语言摘要与下一步提示；除非用户明确要求查看协议字段，最终回复不要直接暴露协议块，或应折叠/隐藏显示。

内部在末尾追加机器可读的协议块：

```text
RESULT: success|failed|degraded
AGENT: ai-flow-plan
ARTIFACT: <plan-path|none>
STATE: <status|none>
NEXT: ai-flow-plan-review|none
SUMMARY: <one-line-summary>
```

## 完成后

- `RESULT: success`：读取 `ARTIFACT`、`STATE`、`NEXT`、`SUMMARY`，确认 draft 已落盘
- 下一步固定进入 `/ai-flow-plan-review`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止，不手工补跑任何中间脚本
