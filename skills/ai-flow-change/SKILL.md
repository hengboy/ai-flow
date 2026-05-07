---
name: ai-flow-change
description: 处理需求变更，更新实施计划各章节（步骤/文件边界/测试/验收标准），推进 JSON 状态并记录变更审计
---

# AI Flow - 需求变更

**触发时机**：用户输入 `/ai-flow-change` 或要求"变更需求""追加需求""修改计划""改需求"。

**Announce at start:** "正在使用 ai-flow-change 技能，处理需求变更并更新实施计划。"

## 流程

### 1. 选择目标

运行：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-status.sh
```

根据 `.ai-flow/state/*.json` 选择要变更的 `slug`。

所有状态均允许变更，但处理方式不同。

### 2. 读取当前计划并确认变更内容

- 读取 `.ai-flow/state/{slug}.json` 获取 `current_status` 和 `plan_file`
- 读取完整计划文件
- 与用户确认变更内容：
  - 新增了什么需求？
  - 修改了什么已有需求？
  - 删除了什么需求？
  - 是否涉及新的文件、接口或数据结构？

### 3. 状态转换

根据 `current_status` 决定是否需要状态转换：

| 当前状态 | 操作 |
|----------|------|
| `PLANNED` | 无需转换，直接编辑计划 |
| `IMPLEMENTING` | 无需转换，直接编辑计划 |
| `AWAITING_REVIEW` | repair 转换到 `IMPLEMENTING` |
| `DONE` | repair 转换到 `IMPLEMENTING` |
| `REVIEW_FAILED` | repair 转换到 `IMPLEMENTING` |
| `FIXING_REVIEW` | repair 转换到 `IMPLEMENTING`（同时清除 active_fix）|

仅在 `AWAITING_REVIEW` / `DONE` / `REVIEW_FAILED` / `FIXING_REVIEW` 状态时执行：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh repair \
  --slug {slug} \
  --status IMPLEMENTING \
  --clear-active-fix \
  --note "需求变更：{一句话描述变更内容}"
```

转换后确认：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh show {slug} --field current_status
```

预期输出：`IMPLEMENTING`

### 4. 更新计划内容

根据变更内容，逐节编辑计划文件。变更是**增量编辑**，保留已有已完成步骤和验收记录。

#### 4.1 更新需求概述（## 1.）

- 如果变更改变了目标范围，更新 **目标**、**非目标**
- 只记录变更增量

#### 4.2 更新技术分析（## 2.）

- 更新 **2.1 涉及模块**：新增模块或变更类型
- 更新 **2.5 文件边界总览**：新增文件行，或追加说明
- 如果变更来自 review 循环根因补录，必须同步更新 **2.6 高风险路径与缺陷族**
- 如有新的数据模型或 API 变更，更新 **2.2 / 2.3 / 2.4**

#### 4.3 更新实施步骤（## 3.）— 核心操作

**新增需求**：在现有步骤之后追加新的 Step，编号递增。新步骤必须保持当前 plan 模板结构，至少包含目标、文件边界、`本轮 review 预期关注面`、执行动作（`- [ ]` 复选框）、验证命令、预期结果、本步自检、验收条件、`本步关闭条件` 和阻塞条件。

**修改已有需求**：在对应 Step 标题追加标记 `*(需求变更修订)*`，更新执行动作：
- 已完成的动作保持 `- [x]`
- 需要新增的动作追加 `- [ ]`
- 需要修改的动作，保留原动作 `- [x]`，在其后追加修改后的新动作 `- [ ]`

**删除需求**：在对应 Step 标题追加标记 `*(已移除)*`，并处理动作：
- 未完成的动作：改为 `~~动作描述~~ *(已移除：原因)*`，不保留 `- [ ]` 格式，避免 execute 误执行
- 已完成的动作：保持 `- [x]` 不变，但在该 Step 末尾追加撤销动作 `- [ ]`（如删除已创建的文件、回滚已修改的代码、移除已添加的配置）
- 如果删除的需求涉及已实现代码，必须追加撤销 Step（编号递增），包含具体的撤销动作、验证命令和预期结果

#### 4.4 更新测试计划（## 4.）

- 新增需求：追加新增的测试项
- 修改需求：在旧测试项后追加 `*(已废弃：替换为下方新测试项)*`，然后追加新的测试项
- 删除需求：在旧测试项后追加 `*(已废弃：需求已移除)*`
- 保留旧的测试项文字用于追溯，但标记废弃后 review 不会按旧标准判定
- 如果变更来自 review 循环根因补录，必须同步更新 **4.4 定向验证矩阵**

#### 4.5 更新验收标准（## 6.）

- 新增需求：追加新的验收标准项
- 修改需求：在旧验收标准后追加 `*(已废弃：替换为下方新标准)*`，然后追加新的验收标准
- 删除需求：在旧验收标准后追加 `*(已废弃：需求已移除)*`
- 保留旧的验收标准文字用于追溯，但标记废弃后 review 不会按旧标准判定

#### 4.6 更新风险（## 5.）

- 如果变更引入新风险，追加条目

### 5. 记录变更审计

位置参数约定：

- `flow-change.sh` 第 1 个参数统一传 `slug`
- 脚本也支持唯一关键词匹配，但示例和推荐用法都用 `slug`，避免误匹配到多个状态文件

运行：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-change.sh {slug} "变更描述"
```

变更描述格式建议：`[新增/修改/删除] {具体内容} — 影响步骤: Step N, M`

如果是 regular 第 2 轮失败后的根因补录，必须使用：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-change.sh {slug} "[root-cause-review-loop] 根因：...；受影响缺陷族：...；前两轮遗漏原因：...；补充验证：..."
```

该记录是进入 regular 第 3 轮 review 的硬门禁，不能只改代码不补录。

### 6. 变更后确认

- 重新读取计划文件，确认所有更新的章节内容正确
- 读取状态文件，确认 `current_status` 符合预期
- 向用户报告变更摘要：更新了哪些章节、新增/修改了哪些步骤、当前状态

### 7. 后续指引

- 如果状态为 `IMPLEMENTING`：提示使用 `/ai-flow-plan-coding` 继续执行
- 如果状态为 `PLANNED`：提示使用 `/ai-flow-plan-coding` 开始执行

## 约束

- 只能通过 `flow-state.sh` 调用 `repair`（状态转换）和 `show`（状态查询）子命令，禁止调用 `create`、`record-plan-review`、`record-review`、`start-execute` 等其他子命令
- 禁止直接编辑 `.ai-flow/state/*.json` 文件
- 计划文件是执行和审查的唯一依据；变更必须写入计划各章节，不能仅记录在 `## 7` 审计表
- 不得修改 `.ai-flow/state/{slug}.json` 中的固定 schema 字段（repair 状态转换除外）
- 不得修改已有的审查报告
- 新增步骤必须遵循当前 plan 模板的格式（目标、文件边界、`本轮 review 预期关注面`、执行动作、验证命令、预期结果、本步自检、验收条件、`本步关闭条件`、阻塞条件）
- 新增或修改的动作必须用 `- [ ]` 未勾选状态，确保 execute 能识别为待执行
- repair 只在需要从非执行状态转到 `IMPLEMENTING` 时使用；`PLANNED` 和 `IMPLEMENTING` 状态不需要 repair
- root-cause-review-loop 不只是审计备注；必须把根因对应的缺陷族和定向验证矩阵同步补进 plan 正文

## 注意事项

- 变更是增量编辑，不是重写。保留已有的已完成步骤和验收记录。
- 如果用户要求完全推翻原有计划，建议使用 `/ai-flow-plan` 重新生成。
- 变更后 execute 会从第一个未完成的 `- [ ]` 动作开始，确保新增和修改的动作都是未勾选状态。
- review 会对比计划内容，所以变更后的步骤必须足够详细（文件路径、具体改动、验证命令）。
- 如果当前有未提交的 Git 变更，变更计划后这些变更仍然存在，后续 execute 和 review 会基于最新的工作区状态操作。
