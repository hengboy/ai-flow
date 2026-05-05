---
name: ai-flow-plan
description: 调用 Codex 分析需求并生成详细实施计划到 .ai-flow/plans/，同时初始化 JSON 状态文件
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
~/.claude/workflows/flow-status.sh
```

如果存在同名 `slug` 的状态文件，提示用户改名或清理旧状态。

### 3. 生成计划

运行：

```bash
~/.claude/workflows/codex-plan.sh "需求描述" "英文简称"
```

脚本职责：

- 生成 `.ai-flow/plans/{日期}/{slug}.md`
- 校验 plan 结构
- 调用 `flow-state.sh create` 创建 `.ai-flow/state/{slug}.json`
- 初始化状态为 `PLANNED`

### 4. 计划格式要求

- 首行必须是 `# 实施计划：{需求名称}`
- 不允许任何状态码文件头
- 技术分析必须包含 `2.6 高风险路径与缺陷族`
- 测试计划必须包含 `4.4 定向验证矩阵`
- 每个 Step 必须写清文件边界、`本轮 review 预期关注面`、动作、验证命令、`本步关闭条件` 和预期结果
- 允许保留元数据，但文档只作为执行证据，不作为状态真源
- 不得在 plan 中为 `.ai-flow/state/{slug}.json` 设计 `requirement_key`、`status`、`steps`、`verification_results`、`change_register` 等自定义字段
- plan 必须按需求定义缺陷族，并把每个缺陷族绑定到至少一个定向验证命令

### 5. 完成后确认

- 读取生成的 plan 文件
- 读取 `.ai-flow/state/{slug}.json`
- 确认 `current_status == PLANNED`
- 提示后续使用 `/ai-flow-execute`

## 注意事项

- 运行目录必须是项目根目录
- 不再接受 `# [PENDING] ...` 这类旧 header
- 缺少 `2.6` 或 `4.4` 的 plan 必须视为无效
- 如果 plan 校验失败，不得创建状态文件
