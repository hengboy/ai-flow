---
name: ai-flow-plan-coding
description: 读取实施计划并按 JSON 状态机执行计划内编码或审查修复
---

# AI Flow - Plan Coding

**触发时机**：用户输入 `/ai-flow-plan-coding` 或要求“执行计划”“开始编码”“实施计划”。

**Announce at start:** "正在使用 ai-flow-plan-coding 技能，读取实施计划并开始编码。"

## 流程

### 1. 扫描任务

运行：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-status.sh
```

只根据 `.ai-flow/state/*.json` 选择任务，不再读取 plan/review 文件头状态。

### 2. 读取状态并决定动作

从 `.ai-flow/state/<slug>.json` 读取 `current_status`：

- `AWAITING_PLAN_REVIEW`：拒绝进入编码，提示回到 `/ai-flow-plan-review`
- `PLAN_REVIEW_FAILED`：拒绝进入 execute，提示回到 `/ai-flow-plan` 修订并复审
- `PLANNED`：表示计划已审核通过；先调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh start-execute {slug}`，进入 `IMPLEMENTING`
- `IMPLEMENTING`：继续开发，不新增 transition
- `REVIEW_FAILED`：先调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh start-fix {slug}`，进入 `FIXING_REVIEW`
- `FIXING_REVIEW`：继续修复，不新增 transition
- `AWAITING_REVIEW`：拒绝进入 execute，提示先做 review
- `DONE`：拒绝进入编码，提示如需再审查走 `/ai-flow-plan-coding-review`

### 3. 执行计划

- 读取 `.ai-flow/plans/{日期}/{slug}.md`
- 批判性检查 plan 是否可执行
- 按 Step 顺序实施
- 更新计划文档中的复选框
- `REVIEW_FAILED` / `FIXING_REVIEW` 阶段默认按“缺陷族”收敛修复，不按单个 DEF 编号孤立修补
- 如果用户追加需求，先运行：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-change.sh {slug} "变更描述"
```

### 4. 完成后的状态推进

- 首轮开发完成：调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh finish-implementation {slug}`，状态进入 `AWAITING_REVIEW`
- 修复完成：调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh finish-fix {slug}`，状态进入 `AWAITING_REVIEW`

### 5. 缺陷修复原则

- 失败状态只读 `last_review` / `active_fix` 追踪最近失败报告
- 可以更新旧报告中的“缺陷修复追踪”表
- 每次修复至少同时完成三件事：修阻塞缺陷、补对应缺陷族的最小必要测试/验证、更新旧报告 `## 6. 缺陷修复追踪`
- `Critical` / `Important` 属于阻塞缺陷，必须修复完成后才能结束当前 plan；`Minor` 属于非阻塞建议，可选择修复部分、全部或暂不处理
- Minor 若暂不处理，应在 review 报告中保持 `[可选]`，不得再作为 `REVIEW_FAILED` 的阻塞原因
- 如果最近一次失败是 regular 第 2 轮，继续修复前必须先运行 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-change.sh {slug}` 补录 root cause，变更描述统一使用前缀 `[root-cause-review-loop]`
- root cause 补录内容至少说明：根因、受影响缺陷族、为什么前两轮没打全、补充了哪些验证
- 不得把旧报告改写成“通过”
- 是否通过必须由下一轮新 review 决定

### 6. 提交门禁

- `PLANNED`、`IMPLEMENTING`、`AWAITING_REVIEW`、`REVIEW_FAILED`、`FIXING_REVIEW` 一律禁止提交
- 只有状态进入 `DONE`，并且最新 review 已覆盖当前未提交变更后，才允许提交

## 约束

- 只能通过 `flow-state.sh` 调用以下 4 个子命令：`start-execute`、`start-fix`、`finish-implementation`、`finish-fix`
- 禁止调用 `create`、`record-plan-review`、`record-review`、`repair` 等其他子命令
- 禁止直接编辑 `.ai-flow/state/*.json` 文件
- 状态转换必须严格按第 2 节的规则执行，不得跳过或逆向

## 注意事项

- 完成前必须有新鲜验证证据
- 计划文档只是执行证据，不是状态源
- 遇到 plan 缺口、验证方式缺失或关键歧义时，应停止并向用户确认
