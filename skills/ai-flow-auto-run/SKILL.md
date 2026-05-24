---
name: ai-flow-auto-run
description: 在 PLANNED 到 DONE 区间内由主 agent 自动闭环推进 coding、review 与修复，直到进入 DONE 或遇到必须人工决策的阻塞
---

# AI Flow - Auto Run

**触发时机**：用户输入 `/ai-flow-auto-run`、`/ai-flow-auto-run <slug或唯一关键词>`，或明确要求“自动执行 plan”“自动从 coding 跑到 done”“自动闭环修复 review 问题”。

**Announce at start:** "正在使用 ai-flow-auto-run 技能，自动推进当前 flow 从 coding/review 闭环到 DONE。"

## 定位

- 这是 **新增能力**，不是替换能力；**保留现有分步入口** `ai-flow-plan-coding`、`ai-flow-plan-coding-review`、`ai-flow-code-optimize`、`ai-flow-git-commit`
- 本 skill 只负责编排 `PLANNED -> DONE` 区间，不覆盖 plan 生成、plan review 和 git commit
- 自动闭环范围固定为：`coding/fix -> review/recheck -> 按失败路由继续修复 -> 再 review`
- **主 agent 自动循环到 DONE**，直到成功、遇到必须人工决策的硬阻塞，或现有 runtime / subagent 返回失败
- 禁止递归调用其他 skill；必须直接复用现有 runtime 脚本、计划状态机和 `ai-flow-plan-coding-review` 的 review subagent 选择规则
- 自动循环不代表允许猜测推进；任何一步只要缺少可执行 plan、缺少本轮验证证据、缺少回流方向或遇到含义不清的 review 反馈，都必须立即停下并把阻塞原因暴露给用户

## 运行目录

- 单仓模式：在目标 Git 仓库根目录运行
- 多仓模式（plan_repos）：在 owner repo 的 Git 根目录运行

## 固定起手动作

### 1. 确定 flow root 与候选集

第一执行动作必须是调用只读 helper：

```bash
$HOME/.config/ai-flow/scripts/flow-auto-run.sh list
```

- helper 只读取当前工作目录所属 flow root 下的 `.ai-flow/state/*.json`
- 候选状态只允许：`PLANNED`、`IMPLEMENTING`、`AWAITING_REVIEW`、`REVIEW_FAILED`、`FIXING_REVIEW`
- `DONE` 默认不进入候选列表；只有 `DONE` 且 `dirty`、仍需 recheck 的 flow 才允许作为候选列出
- 候选表固定字段：`slug`、`当前状态`、`标题`、`更新时间`、`plan 路径`
- 候选必须按 `updated_at` 倒序展示
- helper 若发现无效 state，必须跳过该项并把错误原因转述给用户

### 2. 解析 slug

- 用户显式提供 `slug/唯一关键词` 时，必须调用：

```bash
$HOME/.config/ai-flow/scripts/flow-auto-run.sh resolve "<slug或唯一关键词>"
```

- 无显式参数时，**无 slug 必须列出候选并等待用户选择**
- 即使候选只有 1 个，也不得自动代选
- 解析成功后，检查返回值是否以 `group:` 开头：
  - 若返回 `group:<group_slug>` 格式，进入 **group 模式**（见下方"group 模式状态驱动循环"章节）
  - 若返回普通 slug，继续普通 plan 模式
- 普通 plan 模式下，内部后续动作一律绑定到解析出的完整 slug

## 状态驱动循环

循环中只以 `.ai-flow/state/<slug>.json` 的 `current_status` 为真实状态源；plan / review markdown 首行不是状态源。

### Group 模式状态驱动循环

当 resolve 返回 `group:<group_slug>` 格式时，进入 group 模式。group 模式下后续所有动作绑定到 group slug，不再使用普通 plan slug。

**核心原则**：group 模式下只调用 `flow-plan-group.sh` 的手动入口（start-child / child-completed / final-review），不实现第二套状态逻辑。子 plan 的 coding/review 仍走普通 plan 流程。

1. 获取 group 当前状态：

```bash
bash "$HOME/.config/ai-flow/scripts/flow-plan-group-state.sh" show --group-slug <group_slug> --field current_status
```

2. 根据状态分支处理：

- **`AWAITING_GROUP_REVIEW`**：委派 `ai-flow-plan-review` 执行 group review（复用既有 review 委派规则，mode=group_review）。review 通过后回到循环起点。

- **`GROUP_PLANNED` / `RUNNING_CHILD`**：
  1. 调用 `flow-plan-group.sh start-child --group-slug <group_slug>` 创建下一个 child
  2. 子 plan 创建后进入 `AWAITING_PLAN_REVIEW`
  3. 委派 `ai-flow-plan-review` 审核子 plan
  4. 子 plan 审核通过后，调用 `flow-plan-coding.sh <child-dated-slug>` 执行 coding
  5. coding 完成后，委派 `ai-flow-plan-coding-review` 审核
  6. review 通过（子 plan 进入 DONE）：调用 `flow-plan-group.sh child-completed --group-slug <group_slug>`
  7. 回到循环起点，检查是否还有下一个 child

- **`AWAITING_GROUP_FINAL_REVIEW`**：所有 child 已完成，委派 `ai-flow-plan-review` 执行 final review（mode=group_final_review）。review 通过后循环成功结束。

- **`GROUP_DONE`**：循环成功结束，输出总结。

- **`GROUP_FINAL_REVIEW_FAILED`**：输出总结报告和下一步建议，**不自动改代码，不自动追加 child**，停止循环。

3. 循环终止条件：
   - 成功：`GROUP_DONE`
   - 失败：`GROUP_FINAL_REVIEW_FAILED`
   - 人工阻塞：子 plan review failed 且无回流方向

4. 每轮循环必须重新获取 group 状态证据，不缓存上一轮结论。

### A. `PLANNED` / `IMPLEMENTING`

1. 先调用：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-coding.sh <slug>
```

2. 若 runtime 失败，直接转述 `SUMMARY` 并停止
3. 若 runtime 成功，主 agent 按 `ai-flow-plan-coding` 既有规则继续：
   - 读取 plan
   - 按 Step 顺序实施
   - 更新复选框
   - 执行新鲜验证
   - 处理未完成任务确认逻辑
4. 完成后仅允许通过 `flow-state.sh transition --slug <dated-slug> --event implementation_completed` 推进到 `AWAITING_REVIEW`

### B. `AWAITING_REVIEW`

按 `ai-flow-plan-coding-review` 的既有规则执行 regular review：

- 先读取最终生效配置（项目级优先，用户级回退）的 `engine_mode`；必须固定执行：

```bash
source "$HOME/.config/ai-flow/lib/config-loader.sh"
load_all_settings
get_setting "engine_mode" "auto"
```

- 如需说明来源，继续执行 `get_setting_source_label "engine_mode"`
- 禁止通过 `cat .ai-flow/settings.json`、`cat .ai-flow/setting.json`、`cat ~/.claude/skills/.../setting.json`、`cat ~/.claude/skills/.../settings.json` 等方式自行拼装或猜测配置结果
- 仅允许按既有映射委派 `ai-flow-codex-plan-coding-review` 或 `ai-flow-claude-plan-coding-review`
- 读取返回的 `RESULT`、`REVIEW_RESULT`、`STATE`、`NEXT`、`SUMMARY`
- `REVIEW_RESULT: passed|passed_with_notes`：状态进入 `DONE`，本轮循环成功结束
- `REVIEW_RESULT: failed`：根据 `NEXT` 决定回到 coding 修复还是 optimize 修复，并继续下一轮循环

### C. `REVIEW_FAILED` / `FIXING_REVIEW`，且失败路由为 `ai-flow-plan-coding`

1. 先调用：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-coding.sh <slug>
```

2. 若 runtime 失败，直接停止
3. 主 agent 按 `ai-flow-plan-coding` 的 review 修复规则处理阻塞缺陷族：
   - 修阻塞缺陷
   - 补最小必要测试/验证
   - 更新旧报告 `## 6. 缺陷修复追踪`
4. 完成后仅允许通过 `flow-state.sh transition --slug <dated-slug> --event fix_completed` 回到 `AWAITING_REVIEW`

### D. `REVIEW_FAILED` / `FIXING_REVIEW`，且失败路由为 `ai-flow-code-optimize`

1. 先调用：

```bash
$HOME/.config/ai-flow/scripts/flow-code-optimize.sh <slug>
```

2. 若 runtime 失败，直接停止
3. 主 agent 自动处理最近失败报告中**全部阻塞缺陷**里路由到 `ai-flow-code-optimize` 的项
4. `Minor` / `[可选]` 项默认不自动接单，除非它是修复阻塞项的必要配套
5. 完成后仅允许通过 `flow-state.sh transition --slug <dated-slug> --event fix_completed` 回到 `AWAITING_REVIEW`

### E. `DONE`

先调用：

```bash
$HOME/.config/ai-flow/scripts/flow-auto-run.sh dirty <slug>
```

- 返回 `clean`：直接提示“已完成，无需继续”，并停止
- 返回 `dirty`：说明 `DONE` 之后仍有未提交且需要复审的代码改动，必须自动走 recheck

recheck 规则：

- 仍按 `ai-flow-plan-coding-review` 的 engine/subagent 规则执行
- 当前状态保持 `DONE` 时，review mode 应为 `recheck`
- `REVIEW_RESULT: passed|passed_with_notes`：状态保持 `DONE`
- `REVIEW_RESULT: failed`：根据 `NEXT` 回流到 `ai-flow-plan-coding` 或 `ai-flow-code-optimize`

## 终止条件

- 成功：状态进入或保持 `DONE`
- 部分完成：遇到 `ai-flow-plan-coding` 既有“未完成任务需人工决策”场景，停止并保留当前状态
- 失败：runtime 门禁失败、slug 解析失败、review 结果缺少可执行回流方向、外部依赖不可用，或任何现有执行器返回失败
- 失败还包括：缺少本轮新鲜验证证据、plan 与仓库事实冲突且无法自行收敛、review 反馈存在关键歧义且无法安全判断修改方向

## 边界与约束

- 不新增工作目录 `state.json`；真实状态源仍是 `.ai-flow/state/*.json`
- 不修改 `ai-flow-status` 现有 `next:` 映射；本 skill 只是额外入口
- 自动闭环止于 `DONE`，**不自动提交代码**；需要提交时仍由 `/ai-flow-git-commit` 单独处理
- 禁止直接编辑 `.ai-flow/state/*.json`
- 禁止绕过 `flow-plan-coding.sh` / `flow-code-optimize.sh` / `flow-state.sh` 直接推进状态
- 每轮 coding / fix / review / recheck 都必须重新获取本轮证据；不得复用上一轮成功结论直接跳过验证
- **group 模式隔离**：
  - group 模式下禁止对 group 层使用普通 plan 的 `flow-state.sh transition`（子 plan 的 coding/review 仍走普通 plan 流程）
  - group 层状态只通过 `flow-plan-group.sh` 的 start-child / child-completed / final-review 入口推进
  - `GROUP_FINAL_REVIEW_FAILED` 场景不包含任何代码修改或自动追加 child 的指令

## 固定输出协议

面向用户的主要回复应是自然语言摘要，说明当前结果、最终状态和是否需要人工接手。内部仍需在末尾追加机器可读协议块：

```text
RESULT: success|failed|partial
AGENT: ai-flow-auto-run
SLUG: <dated-slug|none>
GROUP_SLUG: <group_slug|none>
STATE: <final-status|none>
NEXT: ai-flow-plan-coding|ai-flow-code-optimize|ai-flow-plan-coding-review|ai-flow-git-commit|none
SUMMARY: <one-line-summary>
LOOPS: <number>
```

- `RESULT: success`：最终进入或保持 `DONE`
- `RESULT: partial`：因未完成任务确认、权限/资源缺失等人工决策场景而停止
- `NEXT: ai-flow-git-commit`：仅在本轮自动执行刚完成且最新 review 已覆盖当前未提交变更时使用
- `NEXT: none`：已完成且无未提交变更需处理，或流程失败无法继续
