---
name: ai-flow-change
description: 处理需求变更，更新实施计划各章节（步骤/文件边界/测试/验收标准），推进 JSON 状态并记录变更审计
---

# AI Flow - 需求变更

**触发时机**：用户输入 `/ai-flow-change` 或要求"变更需求""追加需求""修改计划""改需求"。

**Announce at start:** "正在使用 ai-flow-change 技能，处理需求变更并更新实施计划。"

## 运行目录

- 单仓模式：在目标 Git 仓库根目录运行。
- 多仓模式（plan_repos）：在 owner repo 的 Git 根目录运行。
- 必须在创建 flow 时使用的同一目录下运行变更命令。

## 流程

### 1. 确定 slug

运行 `ls .ai-flow/state/*.json 2>/dev/null` 列出所有状态文件：

- 仅 1 个：自动使用该 slug
- 多个：向用户列出所有 slug 及其 `current_status`，请用户选择
- 0 个：报错退出，提示先使用 `/ai-flow-plan` 创建计划

### 2. 选择目标

运行：

```bash
$HOME/.config/ai-flow/scripts/flow-status.sh
```

确认上一步确定的 slug 状态可变更。所有状态均允许变更，但处理方式不同。

### 3. 读取当前计划并确认变更内容

- 读取 `.ai-flow/state/{slug}.json` 获取 `current_status` 和 `plan_file`
- 读取完整计划文件
- 与用户确认变更内容：
  - 新增了什么需求？
  - 修改了什么已有需求？
  - 删除了什么需求？
  - 是否涉及新的文件、接口或数据结构？

### 4. 判断 impact 并决定状态转换

先判断本次变更影响级别：

- `plan`
  - 变更影响目标、范围、非目标、验收标准
  - 变更新增/删除公共接口、数据结构、跨仓边界、关键文件边界
  - 变更会让现有 Step 的关闭条件、验证命令或实施路径失效
- `implementation`
  - 仅补充实现细节、样式、文案、内部实现方式
  - 仅给现有 Step 追加动作，不改变外部契约与验收口径
- `auto`
  - 默认模式；由 runtime 按上述规则自动判定

#### 4.0 技能层执行要求

- 当当前状态为 `IMPLEMENTING` 时，`ai-flow-change` 技能不得直接依赖 runtime 的 `auto` 判定。
- 必须先基于当前 plan、变更内容和上述 impact 定义，明确判定本次变更属于 `plan` 还是 `implementation`。
- 判定完成后，必须显式传入 `--impact plan` 或 `--impact implementation` 调用 `flow-change.sh`。
- `auto` 仅保留给直接使用 CLI 的场景；技能层默认不走 `auto`，避免仅依赖关键词误判。
- 若本次变更是否影响目标/范围/验收/契约存在明显歧义，必须先向用户确认，再执行状态转换。

支持显式传入：

```bash
$HOME/.config/ai-flow/scripts/flow-change.sh --impact plan {slug} "变更描述"
$HOME/.config/ai-flow/scripts/flow-change.sh --impact implementation {slug} "变更描述"
```

根据 `current_status` 与 impact 决定是否需要状态转换：

| 当前状态 | impact | 操作 |
|----------|--------|------|
| `PLANNED` | 任意 | `plan_reopened` 转换到 `AWAITING_PLAN_REVIEW` |
| `IMPLEMENTING` | `plan` | `plan_reopened` 转换到 `AWAITING_PLAN_REVIEW` |
| `IMPLEMENTING` | `implementation` | 保持 `IMPLEMENTING`，仅更新 plan 与审计记录 |
| `AWAITING_REVIEW` | 任意 | `implementation_reopened` 转换到 `IMPLEMENTING` |
| `DONE` | 任意 | `implementation_reopened` 转换到 `IMPLEMENTING` |
| `REVIEW_FAILED` | 任意 | `implementation_reopened` 转换到 `IMPLEMENTING` |
| `FIXING_REVIEW` | 任意 | `implementation_reopened` 转换到 `IMPLEMENTING` |

#### 4.1 非执行状态（AWAITING_REVIEW / DONE / REVIEW_FAILED / FIXING_REVIEW）

仅在 `AWAITING_REVIEW` / `DONE` / `REVIEW_FAILED` / `FIXING_REVIEW` 状态时执行：

```bash
$HOME/.config/ai-flow/scripts/flow-state.sh transition \
  --slug {slug} \
  --event implementation_reopened \
  --note "需求变更：{一句话描述变更内容}"
```

转换后确认：

```bash
$HOME/.config/ai-flow/scripts/flow-state.sh show --slug {slug} --field current_status
```

预期输出：`IMPLEMENTING`

#### 4.2 需要回到计划审核的变更（`PLANNED` 或 `IMPLEMENTING + impact=plan`）

需求变动后若影响 plan 级边界，则必须重新审核方案。在 `PLANNED` 或 `IMPLEMENTING` 且 impact 判定为 `plan` 时执行：

```bash
$HOME/.config/ai-flow/scripts/flow-state.sh transition \
  --slug {slug} \
  --event plan_reopened \
  --note "需求变更：{一句话描述变更内容}"
```

转换后确认：

```bash
$HOME/.config/ai-flow/scripts/flow-state.sh show --slug {slug} --field current_status
```

预期输出：`AWAITING_PLAN_REVIEW`

#### 4.3 实现中增量变更（`IMPLEMENTING + impact=implementation`）

- 仅更新 plan 正文和 `## 7. 需求变更记录`
- 不调用 `flow-state.sh transition`
- 预期状态保持 `IMPLEMENTING`

### 5. 更新计划内容

根据变更内容，逐节编辑计划文件。变更是**增量编辑**，保留已有已完成步骤和验收记录。

#### 5.1 更新需求概述（## 1.）

- 如果变更改变了目标范围，更新 **目标**、**非目标**
- 只记录变更增量

#### 5.2 更新技术分析（## 2.）

- 更新 **2.1 涉及模块**：新增模块或变更类型
- 更新 **2.5 文件边界总览**：新增文件行，或追加说明
- 如果变更来自 review 循环根因补录，必须同步更新 **2.6 高风险路径与缺陷族**
- 如有新的数据模型或 API 变更，更新 **2.2 / 2.3 / 2.4**

#### 5.3 更新实施步骤（## 3.）— 核心操作

**新增需求**：在现有步骤之后追加新的 Step。新步骤必须保持当前 plan 模板结构，分配全局唯一 `Step ID`，并至少包含目标、文件边界、`本轮 review 预期关注面`、执行动作（`- [ ]` 复选框）、验证命令、预期结果、本步自检、验收条件、`本步关闭条件` 和阻塞条件。

**修改已有需求**：优先按 `Step ID` 锁定对应 Step，在对应 Step 标题追加标记 `*(需求变更修订)*`，更新执行动作：
- 已完成的动作保持 `- [x]`
- 需要新增的动作追加 `- [ ]`
- 需要修改的动作，保留原动作 `- [x]`，在其后追加修改后的新动作 `- [ ]`

**删除需求**：优先按 `Step ID` 锁定对应 Step，在对应 Step 标题追加标记 `*(已移除)*`，并处理动作：
- 未完成的动作：改为 `~~动作描述~~ *(已移除：原因)*`，不保留 `- [ ]` 格式，避免 execute 误执行
- 已完成的动作：保持 `- [x]` 不变，但在该 Step 末尾追加撤销动作 `- [ ]`（如删除已创建的文件、回滚已修改的代码、移除已添加的配置）
- 如果删除的需求涉及已实现代码，必须追加撤销 Step（分配新的 `Step ID`），包含具体的撤销动作、验证命令和预期结果

#### 5.4 更新测试计划（## 4.）

- 新增需求：追加新增的测试项
- 修改需求：在旧测试项后追加 `*(已废弃：替换为下方新测试项)*`，然后追加新的测试项
- 删除需求：在旧测试项后追加 `*(已废弃：需求已移除)*`
- 保留旧的测试项文字用于追溯，但标记废弃后 review 不会按旧标准判定
- 如果变更来自 review 循环根因补录，必须同步更新 **4.4 定向验证矩阵**

#### 5.5 更新验收标准（## 6.）

- 新增需求：追加新的验收标准项
- 修改需求：在旧验收标准后追加 `*(已废弃：替换为下方新标准)*`，然后追加新的验收标准
- 删除需求：在旧验收标准后追加 `*(已废弃：需求已移除)*`
- 保留旧的验收标准文字用于追溯，但标记废弃后 review 不会按旧标准判定

#### 5.6 更新风险（## 5.）

- 如果变更引入新风险，追加条目

### 6. 记录变更审计

位置参数约定：

- `flow-change.sh` 第 1 个参数统一传 `slug`
- 脚本也支持唯一关键词匹配，但示例和推荐用法都用 `slug`，避免误匹配到多个状态文件

运行：

```bash
$HOME/.config/ai-flow/scripts/flow-change.sh {slug} "变更描述"
```

当当前状态为 `IMPLEMENTING` 时，技能层应改为：

```bash
$HOME/.config/ai-flow/scripts/flow-change.sh --impact implementation {slug} "变更描述"
$HOME/.config/ai-flow/scripts/flow-change.sh --impact plan {slug} "变更描述"
```

`auto` 用法仅保留给直接命令行调用者；技能执行默认不使用 `auto`。

变更描述格式建议：`[新增/修改/删除] {具体内容} — 影响步骤: {step_id}, {step_id}`

如果是 regular 第 2 轮失败后的根因补录，必须使用：

```bash
$HOME/.config/ai-flow/scripts/flow-change.sh {slug} "[root-cause-review-loop] 根因：...；受影响缺陷族：...；前两轮遗漏原因：...；补充验证：..."
```

该记录是进入 regular 第 3 轮 review 的硬门禁，不能只改代码不补录。

### 7. 变更后确认

- 重新读取计划文件，确认所有更新的章节内容正确
- 读取状态文件，确认 `current_status` 符合预期
- 向用户报告变更摘要：更新了哪些章节、新增/修改了哪些步骤、当前状态

### 8. 后续指引

- 如果变更前状态是 `PLANNED`，或 `IMPLEMENTING` 且 impact=`plan`，变更后状态应为 `AWAITING_PLAN_REVIEW`：提示使用 `/ai-flow-plan-review` 重新审核变更后的计划
- 如果变更前状态是 `IMPLEMENTING` 且 impact=`implementation`，状态保持 `IMPLEMENTING`：继续落地本轮增量变更，完成后再进入审核
- 如果变更前状态是 `AWAITING_REVIEW`、`DONE`、`REVIEW_FAILED` 或 `FIXING_REVIEW`，变更后状态应为 `IMPLEMENTING`：继续增量修订计划与实现，再按后续阶段进入审核
- 审核通过后状态回到 `PLANNED`：提示使用 `/ai-flow-plan-coding` 继续执行

## 约束

- 若当前 repo 或绑定 flow 的参与 repo 存在 `.ai-flow/rule.yaml`，变更计划时必须保留其中要求的关键约束、必读文件和审查门禁，不得通过改 plan 绕开规则
- 只能通过 `flow-state.sh transition` 调用 `plan_reopened` / `implementation_reopened`，以及通过 `show` 查询状态；禁止调用其他写接口
- 禁止直接编辑 `.ai-flow/state/*.json` 文件
- 计划文件是执行和审查的唯一依据；变更必须写入计划各章节，不能仅记录在 `## 7` 审计表
- 不得修改 `.ai-flow/state/{slug}.json` 中的固定 schema 字段
- 不得修改已有的审查报告
- 新增步骤必须遵循当前 plan 模板的格式（`Step ID`、目标、文件边界、`本轮 review 预期关注面`、执行动作、验证命令、预期结果、本步自检、验收条件、`本步关闭条件`、阻塞条件）
- 新增或修改的动作必须用 `- [ ]` 未勾选状态，确保 execute 能识别为待执行
- 需要回到计划审核时使用 `plan_reopened`；需要回到实现阶段时使用 `implementation_reopened`
- `IMPLEMENTING + impact=implementation` 不推进状态，只记录 plan 变更与审计
- root-cause-review-loop 不只是审计备注；必须把根因对应的缺陷族和定向验证矩阵同步补进 plan 正文

## 注意事项

- 变更是增量编辑，不是重写。保留已有的已完成步骤和验收记录。
- 如果用户要求完全推翻原有计划，建议使用 `/ai-flow-plan` 重新生成。
- 只有在变更导致状态进入 `AWAITING_PLAN_REVIEW` 时，才需要立即重新走 `/ai-flow-plan-review`；如果状态保持或回到 `IMPLEMENTING`，则应先完成本轮变更落地，再按后续阶段进入审核。
- 变更后需先通过 `/ai-flow-plan-review` 重新审核计划，审核通过后 execute 才会从第一个未完成的 `- [ ]` 动作开始。
- review 会对比计划内容，所以变更后的步骤必须足够详细（文件路径、具体改动、验证命令）。
- 如果当前有未提交的 Git 变更，变更计划后这些变更仍然存在，后续 execute 和 review 会基于最新的工作区状态操作。
