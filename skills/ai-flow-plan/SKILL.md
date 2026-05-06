---
name: ai-flow-plan
description: 调用 Codex 生成 draft plan，并在同一入口内完成计划审核、修订和放行
---

# AI Flow - 需求分析与计划生成

**触发时机**：用户输入 `/ai-flow-plan` 或要求“分析需求写 plan”。

**Announce at start:** "正在使用 ai-flow-plan 技能，调用 Codex 分析需求并生成实施计划。"

## 流程

### 1. 收集需求

- 明确目标、非目标、约束、成功标准。
- 如果需求明显跨多个独立子系统，先拆成多个 plan。
- 生成或确认英文简称 `slug`。

### 2. 检查当前状态

运行：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-status.sh
```

如果存在同名 `slug` 的状态文件，提示用户改名或清理旧状态。

### 3. 生成计划

运行：

```bash
${CLAUDE_HOME:-$HOME/.claude}/skills/ai-flow-plan/scripts/codex-plan.sh "需求描述" "英文简称" [模型名]
```

参数顺序固定：

- 第 1 个参数是需求描述
- 第 2 个参数是英文简称 `slug`（可选，但示例和推荐用法都显式传入）
- 第 3 个参数才是模型名（可选）

强制约束：

- `ai-flow-plan` 只能通过这一个入口执行，禁止把流程拆成多条命令手工运行
- 禁止手工调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh create`、`record-plan-review`
- 禁止手工调用 `codex exec` 生成 draft plan、审核 plan 或修订 plan
- 如果 `${CLAUDE_HOME:-$HOME/.claude}/skills/ai-flow-plan/scripts/codex-plan.sh` 失败，应该直接报告失败原因并停止；不要继续在别的目录重试其中某一步
- 必须在目标项目根目录执行；如果当前目录只是多模块父目录，先进入目标模块根目录再运行
- 完整流程内的 plan 生成、状态初始化、计划审核、失败修订和复审，都必须由 `${CLAUDE_HOME:-$HOME/.claude}/skills/ai-flow-plan/scripts/codex-plan.sh` 自己串联完成

脚本职责：

- 生成 `.ai-flow/plans/{日期}/{slug}.md`
- 校验 draft plan 结构
- 使用同 skill 目录下的 `templates/plan-template.md` 和 `prompts/plan-generation.md` 渲染 prompt
- 调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh create` 创建 `.ai-flow/state/{slug}.json`
- 初始化状态为 `AWAITING_PLAN_REVIEW`
- 在同一脚本内执行计划审核；默认用 Codex，只有审核阶段 Codex 不可用时才降级到 OpenCode
- 审核失败时在同一流程里按审核意见修订 plan 并复审；默认最多自动复审 3 轮
- 只有审核结果为 `passed` 或 `passed_with_notes` 时才推进到 `PLANNED`
- 审核结果为 `failed` 时保持 `PLAN_REVIEW_FAILED`，禁止进入 execute

### 4. 计划格式要求

- 首行必须是 `# 实施计划：{需求名称}`
- 不允许任何状态码文件头
- `## 1. 需求概述` 必须包含 `原始需求（原文）`
- 技术分析必须包含 `2.6 高风险路径与缺陷族`
- 测试计划必须包含 `4.4 定向验证矩阵`
- 必须包含 `## 8. 计划审核记录`，并由脚本回写当前结论、偏差建议和审核历史
- 每个 Step 必须写清文件边界、`本轮 review 预期关注面`、动作、验证命令、`本步关闭条件` 和预期结果
- 允许保留元数据，但文档只作为执行证据，不作为状态真源
- 不得在 plan 中为 `.ai-flow/state/{slug}.json` 设计 `requirement_key`、`status`、`steps`、`verification_results`、`change_register` 等自定义字段
- plan 必须按需求定义缺陷族，并把每个缺陷族绑定到至少一个定向验证命令

### 5. 完成后确认

- 读取生成的 plan 文件
- 读取 `.ai-flow/state/{slug}.json`
- 审核通过时确认 `current_status == PLANNED`，再提示后续使用 `/ai-flow-execute`
- 审核未通过时确认 `current_status == PLAN_REVIEW_FAILED`，提示继续运行 `/ai-flow-plan` 修订

## 注意事项

- 运行目录必须是项目根目录
- 不再接受 `# [PENDING] ...` 这类旧 header
- 缺少 `2.6`、`4.4`、`原始需求（原文）` 或 `## 8` 的 plan 必须视为无效
- 如果 plan 校验失败，不得创建状态文件
