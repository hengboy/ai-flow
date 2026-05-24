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
$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {slug}
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

从 `.ai-flow/state/{slug}.json` 读取 `current_status`：

- `AWAITING_PLAN_REVIEW`：拒绝进入编码，提示回到 `/ai-flow-plan-review`
- `PLAN_REVIEW_FAILED`：拒绝进入 execute，提示回到 `/ai-flow-plan` 修订并复审
- `PLANNED`：表示计划已审核通过；必须先调用 `$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {slug}`，由 runtime 推进到 `IMPLEMENTING`
- `IMPLEMENTING`：先调用 `$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {slug}` 做规则门禁校验；若计划中仍有未勾选的 step / action，则继续执行这些未完成项，不得因已处于 IMPLEMENTING 而停止
- `REVIEW_FAILED`：必须先调用 `$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {slug}`，由 runtime 推进到 `FIXING_REVIEW`
- `FIXING_REVIEW`：先调用 `$HOME/.config/ai-flow/scripts/flow-plan-coding.sh {slug}` 做规则门禁校验，再继续修复
- `AWAITING_REVIEW`：拒绝进入 execute，提示先做 review
- `DONE`：拒绝进入编码，提示如需再审查走 `/ai-flow-plan-coding-review`

### 4. 执行计划

- 读取 `.ai-flow/plans/{slug}.md`
- 批判性检查 plan 是否可执行
- 按 Step 顺序实施
- 每完成一个 Step 后，必须基于该 Step 的本轮验证证据，立即勾选该 Step 下对应的 `执行动作` 与 `本步验收` 复选框，并保存计划文档
- 禁止等到全部 Step 完成后统一勾选；进入下一个 Step、宣告本 Step 完成或推进状态前，当前 Step 的复选框必须已经更新
- `REVIEW_FAILED` / `FIXING_REVIEW` 阶段默认按”缺陷族”收敛修复，不按单个 DEF 编号孤立修补
- 如果 plan 的 `执行范围` 为 `workspace`，文件路径相对于 workspace 根目录；修改文件时需确保路径包含正确的 repo 前缀
- 执行编码或修复时，必须主动识别本次触达范围内的硬编码；状态值、类型值、配置项、路径、命令名、错误码、固定文案、魔法数字等若已有枚举或常量定义，必须优先复用或补充其定义；若不存在合适定义，应抽取为语义明确的枚举或常量，避免新增或扩散硬编码
- 开始任何修改前，必须先确认当前 Step 的目标、文件边界、验证命令和关闭条件都可执行；若存在 plan 缺口、命名/路径失真、验证方式缺失、验收标准无法证明或与仓库事实冲突，必须停止并向用户确认，不得靠猜测继续实现
- 执行过程中若发现需求实际含义、外部依赖、仓库边界或验证口径与 plan 不一致，必须先停下；属于需求/范围变化时走 `/ai-flow-change`，属于 plan 草案质量问题时回到 `/ai-flow-plan`
- 不得在缺少本轮证据的情况下勾选步骤、宣告某 Step 完成或推进状态；每次勾选前必须先完成该 Step 对应的实际验证
- 如果用户追加需求，先运行：

```bash
$HOME/.config/ai-flow/scripts/flow-change.sh {slug} “变更描述”
```

### 5. 未完成任务检测与用户确认

在调用 `transition --event implementation_completed` / `transition --event fix_completed` **之前**，必须对照计划逐项检查是否全部完成。`IMPLEMENTING` 再次进入 `/ai-flow-plan-coding` 时，也要优先续跑所有未勾选的 step / action。以下情况视为未完成：

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

- 首轮开发完成：调用 `$HOME/.config/ai-flow/scripts/flow-state.sh transition --slug {slug} --event implementation_completed`，状态进入 `AWAITING_REVIEW`
- 修复完成：调用 `$HOME/.config/ai-flow/scripts/flow-state.sh transition --slug {slug} --event fix_completed`，状态进入 `AWAITING_REVIEW`

### 7. 缺陷修复原则

- 失败状态只读 `show --field derived.last_review` / `show --field derived.active_fix` 追踪最近失败报告
- 可以更新旧报告中的”缺陷修复追踪”表
- 每次修复至少同时完成三件事：修阻塞缺陷、补对应缺陷族的最小必要测试/验证、更新旧报告 `## 6. 缺陷修复追踪`
- 收到 review 反馈后，先按缺陷逐项理解问题与证据，再决定修改方案；如果某条反馈与当前代码事实不符、上下文不足或存在多种解释，必须先澄清或在修复说明中给出代码依据，不能机械照单修改
- `Critical` / `Important` 属于阻塞缺陷，必须修复完成后才能结束当前 plan；`Minor` 属于非阻塞建议，可选择修复部分、全部或暂不处理
- Minor 若暂不处理，应在 review 报告中保持 `[可选]`，不得再作为 `REVIEW_FAILED` 的阻塞原因
- 如果最近一次失败是 regular 第 2 轮，继续修复前必须先运行 `$HOME/.config/ai-flow/scripts/flow-change.sh {slug}` 补录 root cause，变更描述统一使用前缀 `[root-cause-review-loop]`
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
- 只能通过 `flow-state.sh transition` 推进 `execute_started`、`fix_started`、`implementation_completed`、`fix_completed`
- 禁止调用 `transition` 之外的写接口
- 禁止直接编辑 `.ai-flow/state/*.json` 文件
- 状态转换必须严格按第 3 节的规则执行，不得跳过或逆向
- 执行计划或 review 修复时不得新增无归属硬编码；发现本次改动相关的既有硬编码时，必须在不扩大无关改动面的前提下抽取或复用枚举、常量
- 任何“已完成”“已修复”“可以进入 review”的结论都必须基于当前工作区的本轮新鲜验证证据；旧截图、旧日志、上一次 review 结果或主观判断都不能替代本轮验证
- 若验证命令无法运行、结果不稳定、输出与预期不符，必须视为未完成；除第 5 节明确允许的人工决策场景外，不得推进状态

## 注意事项

- 完成前必须有新鲜验证证据
- 计划文档只是执行证据，不是状态源
- 遇到 plan 缺口、验证方式缺失或关键歧义时，应停止并向用户确认
