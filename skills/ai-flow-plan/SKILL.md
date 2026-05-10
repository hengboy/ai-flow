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

## 输入约束

- 需求描述必填；`slug` 可选（不提供时自动从需求描述生成），建议显式提供以保证命名一致性
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

## 引擎模式

通过环境变量 `AI_FLOW_ENGINE_MODE` 控制引擎选择行为：

- **`auto`（默认）**：按下方"首选"委派到 codex subagent；当返回 `RESULT: degraded` 时按"降级"委派到 claude subagent。
- **`claude`**：跳过 codex subagent，直接按下方"claude 直连"委派到 claude subagent。如果 claude subagent 返回非成功结果，立即报告失败，不回退到 codex。
- **`codex`**：仅使用 codex subagent。如果 codex subagent 返回 `RESULT: degraded`，报告失败而非降级到 claude。

### claude 直连（当 AI_FLOW_ENGINE_MODE=claude 时）

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
- 任何非成功结果：直接报告 `SUMMARY` 并停止

## 强制委派

必须按以下格式调用指定的 subagent，不得替换为任何其他 agent（包括内置 Plan agent）：

### 首选（默认）

```
Agent(
    description="生成或修订 draft plan",
    subagent_type="ai-flow-codex-plan",
    prompt="需求描述：{需求描述}\nslug：{slug 或留空自动生成}"
)
```

### 降级（Codex 不可用时）

当 subagent 返回 `RESULT: degraded` 时，自动委派到 `ai-flow-claude-plan`：

```
Agent(
    description="生成或修订 draft plan（Codex 不可用，降级）",
    subagent_type="ai-flow-claude-plan",
    prompt="需求描述：{需求描述}\nslug：{slug 或留空自动生成}"
)
```

claude subagent 完成后：
- 读取 `ARTIFACT`、`STATE`、`NEXT`、`SUMMARY`
- 下一步固定进入 `/ai-flow-plan-review`

### subagent 职责

- 读取工作区与 `.ai-flow` 上下文
- 渲染 prompt / template
- 生成或修订 `.ai-flow/plans/*`
- 创建或保持 `.ai-flow/state/<slug>.json`
- 返回固定摘要协议，而不是回传 plan 正文

## 完成后

- `RESULT: success`：读取 `ARTIFACT`、`STATE`、`NEXT`、`SUMMARY`，确认 draft 已落盘
- 下一步固定进入 `/ai-flow-plan-review`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止，不手工补跑任何中间脚本
