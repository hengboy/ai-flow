---
name: ai-flow-plan-coding
description: 读取实施计划并按 JSON 状态机执行计划内编码或审查修复
---

# AI Flow - Plan Coding

**触发时机**：用户输入 `/ai-flow-plan-coding` 或要求“执行计划”“开始编码”“实施计划”。

**Announce at start:** "正在使用 ai-flow-plan-coding 技能，读取实施计划并开始编码。"

## 流程

### 0. 先调用 runtime 入口

触发本 skill 后，第一执行动作必须是：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {YYYYMMDD}-{slug}
```

- 该脚本负责统一处理 `PLANNED -> IMPLEMENTING`、`REVIEW_FAILED -> FIXING_REVIEW` 的状态推进
- 该脚本同时负责执行前的 `rule.yaml` 门禁：`required_reads`、`protected_paths`、`forbidden_changes`
- 如果 runtime 返回失败，必须直接向用户转述失败摘要并停止；不得绕过脚本自行推进状态
- 如果 runtime 返回成功，再继续执行下面的计划读取、编码实现、计划勾选和后续收尾
### 1. 确定 slug

运行 `ls .ai-flow/state/*.json 2>/dev/null` 列出所有状态文件：

- 仅 1 个：自动使用该 slug
- 多个：向用户列出所有 slug 及其 `current_status`，请用户选择
- 0 个：报错退出，提示先使用 `/ai-flow-plan` 创建计划

### 2. 扫描任务

运行：

```bash
$HOME/.config/ai-flow/scripts/flow-status.sh
```

只根据 `.ai-flow/state/*.json` 选择任务，不再读取 plan/review 文件头状态。

### 3. 读取状态并决定动作

从 `.ai-flow/state/{YYYYMMDD}-{slug}.json` 读取 `current_status`：

- `AWAITING_PLAN_REVIEW`：拒绝进入编码，提示回到 `/ai-flow-plan-review`
- `PLAN_REVIEW_FAILED`：拒绝进入 execute，提示回到 `/ai-flow-plan` 修订并复审
- `PLANNED`：表示计划已审核通过；必须先调用 `$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {YYYYMMDD}-{slug}`，由 runtime 推进到 `IMPLEMENTING`
- `IMPLEMENTING`：先调用 `$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {YYYYMMDD}-{slug}` 做规则门禁校验，再继续开发
- `REVIEW_FAILED`：必须先调用 `$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {YYYYMMDD}-{slug}`，由 runtime 推进到 `FIXING_REVIEW`
- `FIXING_REVIEW`：先调用 `$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {YYYYMMDD}-{slug}` 做规则门禁校验，再继续修复
- `AWAITING_REVIEW`：拒绝进入 execute，提示先做 review
- `DONE`：拒绝进入编码，提示如需再审查走 `/ai-flow-plan-coding-review`

### 4. 执行计划

- 读取 `.ai-flow/plans/{YYYYMMDD}-{slug}.md`
- 批判性检查 plan 是否可执行
- 按 Step 顺序实施
- 更新计划文档中的复选框
- `REVIEW_FAILED` / `FIXING_REVIEW` 阶段默认按”缺陷族”收敛修复，不按单个 DEF 编号孤立修补
- 如果 plan 的 `执行范围` 为 `workspace`，文件路径相对于 workspace 根目录；修改文件时需确保路径包含正确的 repo 前缀
- 如果用户追加需求，先运行：

```bash
$HOME/.config/ai-flow/scripts/flow-change.sh {YYYYMMDD}-{slug} “变更描述”
```

### 5. 未完成任务检测与用户确认

在调用 `finish-implementation` / `finish-fix` **之前**，必须对照计划逐项检查是否全部完成。以下情况视为未完成：

- 任务涉及当前 workspace 之外的目录或仓库，无法在当前会话中修改
- 任务依赖的外部服务/资源不可用
- 任务需要的权限/密钥缺失
- 计划中明确标注但实际未执行的其他步骤

检测到未完成任务时：

1. 将全部未完成任务合并为一次确认，向用户逐一列出跳过原因
2. 让用户选择处理方式：
   - **继续**：不推进状态，保留当前 `IMPLEMENTING` / `FIXING_REVIEW`，用户补充路径或资源后可重新调用 `/ai-flow-plan-coding` 继续执行
   - **跳过并进入 review**：将未完成项记录到 plan 文档末尾的 `## 未完成任务` 章节，然后调用状态推进命令进入 `AWAITING_REVIEW`
   - **中止**：不做状态推进，输出 `RESULT: failed` + `NEXT: none`，保留当前状态供后续继续执行
3. 只有用户选择"跳过并进入 review"后，才可调用状态推进命令

### 6. 完成后的状态推进

- 首轮开发完成：调用 `$HOME/.config/ai-flow/scripts/flow-state.sh finish-implementation {YYYYMMDD}-{slug}`，状态进入 `AWAITING_REVIEW`
- 修复完成：调用 `$HOME/.config/ai-flow/scripts/flow-state.sh finish-fix {YYYYMMDD}-{slug}`，状态进入 `AWAITING_REVIEW`

### 7. 缺陷修复原则

- 失败状态只读 `last_review` / `active_fix` 追踪最近失败报告
- 可以更新旧报告中的”缺陷修复追踪”表
- 每次修复至少同时完成三件事：修阻塞缺陷、补对应缺陷族的最小必要测试/验证、更新旧报告 `## 6. 缺陷修复追踪`
- `Critical` / `Important` 属于阻塞缺陷，必须修复完成后才能结束当前 plan；`Minor` 属于非阻塞建议，可选择修复部分、全部或暂不处理
- Minor 若暂不处理，应在 review 报告中保持 `[可选]`，不得再作为 `REVIEW_FAILED` 的阻塞原因
- 如果最近一次失败是 regular 第 2 轮，继续修复前必须先运行 `$HOME/.config/ai-flow/scripts/flow-change.sh {YYYYMMDD}-{slug}` 补录 root cause，变更描述统一使用前缀 `[root-cause-review-loop]`
- root cause 补录内容至少说明：根因、受影响缺陷族、为什么前两轮没打全、补充了哪些验证
- 不得把旧报告改写成”通过”
- 是否通过必须由下一轮新 review 决定

### 8. 提交门禁

- `PLANNED`、`IMPLEMENTING`、`AWAITING_REVIEW`、`REVIEW_FAILED`、`FIXING_REVIEW` 一律禁止提交
- 只有状态进入 `DONE`，并且最新 review 已覆盖当前未提交变更后，才允许提交

## 固定输出协议

完成状态推进后，用一行自然语言总结结果并给出下一步，示例：

- 成功 → `✅ 微信统一响应改造完成，64 个测试全部通过，状态进入 AWAITING_REVIEW。`
- 部分完成 → `⚠️ step_id=repo-sync 涉及跨仓库改动未完成，已记录到计划文档，状态进入 AWAITING_REVIEW。`
- 失败/被拒 → `❌ 当前状态为 AWAITING_REVIEW，需先完成代码审查后再继续。`

然后根据 `NEXT` 值追加下一步提示：

- `NEXT: ai-flow-code-optimize` → 输出 `下一步：运行 /ai-flow-code-optimize 在既有架构内完成代码优化。`
- `NEXT: ai-flow-code-optimize` 后应继续补充一句：`优化完成后：运行 /ai-flow-plan-coding-review 对最终代码变更进行审查。`
- `NEXT: ai-flow-plan-coding` → 输出 `下一步：继续运行 /ai-flow-plan-coding 执行剩余任务。`
- `NEXT: none` → 不输出下一步提示

机器可读协议块只用于 skill/subagent 间解析和自动化推进，不是面向用户的主要内容。面向用户的最终回复必须只保留上面的自然语言摘要与下一步提示，禁止直接输出 `RESULT:`、`STATE:`、`NEXT:`、`SUMMARY:`、`INCOMPLETE:` 等协议字段；只有用户明确要求查看协议字段时才可额外展示。

内部仍需在末尾追加机器可读的协议块：

```text
RESULT: success|failed|partial
AGENT: ai-flow-plan-coding
ARTIFACT: <plan-path|none>
STATE: <status|none>
NEXT: ai-flow-code-optimize|ai-flow-plan-coding|none
SUMMARY: <one-line-summary>
INCOMPLETE: <仅 RESULT=partial 时输出>
```

## 行为准则

> 编码前请遵守 `~/.claude/CLAUDE.md` — 先思考再编码、简洁优先、精准修改、目标驱动执行。

## 约束

- 若当前 repo 存在 `.ai-flow/rule.yaml`，执行前必须遵守其中的项目级规则；绑定 `slug` 时按 `execution_scope.repos` 聚合参与仓库各自规则
- 命中 `protected_paths`、`forbidden_changes` 或缺失 `required_reads` 时，必须由 `flow-plan-coding.sh` 直接失败；不得绕过 runtime 继续执行
- 只能通过 `flow-state.sh` 调用以下 4 个子命令：`start-execute`、`start-fix`、`finish-implementation`、`finish-fix`
- 禁止调用 `create`、`record-plan-review`、`record-review`、`repair` 等其他子命令
- 禁止直接编辑 `.ai-flow/state/*.json` 文件
- 状态转换必须严格按第 3 节的规则执行，不得跳过或逆向

## 注意事项

- 完成前必须有新鲜验证证据
- 计划文档只是执行证据，不是状态源
- 遇到 plan 缺口、验证方式缺失或关键歧义时，应停止并向用户确认
