---
name: ai-flow-plan
description: 生成或修订 draft plan；skill 只定义委派规则，实际执行由 plan subagent 完成
---

# AI Flow - Draft Plan

**触发时机**：用户输入 `/ai-flow-plan`，或明确要求“分析需求写 plan”“修订 plan 草案”。

**Announce at start:** "正在使用 ai-flow-plan 技能，委派 subagent 生成或修订 draft plan。"

## 运行目录

- 单仓模式：在目标 Git 仓库根目录运行。
- 多仓模式（plan_repos）：在 owner repo 的 Git 根目录运行，跨仓范围在 plan 文件中声明。
- 当前目录必须有 `.ai-flow/` 目录或可识别的项目根标记（`.git`、`pom.xml`、`package.json` 等）。

## 行为准则

> 生成或修订计划时请遵守当前宿主的全局行为准则：Claude Code 使用 `~/.claude/CLAUDE.md`，Codex 使用 `$CODEX_HOME/AGENTS.md`（默认 `~/.codex/AGENTS.md`）— 先思考再编码、简洁优先、精准修改、目标驱动执行。

## 输入约束

- 需求描述必填；`slug` 可选，不提供时自动从需求描述生成，建议显式提供以保证命名一致性
- 如果用户以本地文件路径形式提供需求，委派 subagent 前必须读取该文件完整正文，并把正文作为“需求描述（已澄清版）”传入；同时保留文件路径作为需求来源说明。禁止只把文件路径当作需求描述传给 subagent。
- `/ai-flow-plan` 每次都生成新的 draft plan；只有用户显式提供同名 `slug` 且状态允许时，才进入原地修订
- **禁止复用旧 plan**：不允许搜索 `.ai-flow/plans/` 下的历史 plan 文件并直接沿用。每次都必须根据当前需求内容从头生成新的 plan。`slug` 仅用于状态关联，不用于查找已有 plan 内容。
- 同名 `slug` 只有在 `AWAITING_PLAN_REVIEW` 或 `PLAN_REVIEW_FAILED` 时允许原地修订

## 修订前确认策略

- 当任务是原地修订已有 draft plan 时，先读取原 plan、`## 8. 计划审核记录` 与原始需求，再决定是否需要先询问用户
- 当任务来源于 `/ai-flow-plan-review` 未通过后的回流修订时，**仍然必须先读取最终生效配置（项目级优先，用户级回退）的 `engine_mode`，再按下方委派规则选择 plan subagent；禁止因为”修订”语义直接固定指派 `ai-flow-claude-plan` 或任何其他 agent**
- 默认不要对每个偏差逐条询问；只在会改变决策或结果时打断
- 高优先级偏差：先合并后一次性询问用户，再委派修订
  - 适用：目标变更、范围增减、优先级重排、验收标准变化、关键 tradeoff、高误改风险
- 中优先级偏差：若存在多个差异明显的可行修订方向，给出推荐方案并快速确认；若修订方向唯一且能从原始需求直接推出，则直接委派修订
  - 适用：实现路径明显变化，但最终目标不变
- 低优先级偏差：直接委派修订
  - 适用：措辞、结构、顺序、细化、补漏、消歧，且不改变原意
- 用户偏好一旦明确，同类问题默认沿用，不重复确认

## 生成前澄清策略

- 在委派 subagent 之前，先探索项目上下文：至少检查需求涉及的代码文件、相关文档和必要的最近提交，避免脱离当前仓库事实直接写 plan
- 先判断需求规模是否适合一次生成单份 plan：如果需求横跨多个相对独立的模块、子系统或仓库，必须先帮助用户拆分范围、明确依赖顺序，并只为当前优先级最高的第一阶段/第一子项目生成 draft plan
- **长任务判断（计划组）**：如果需求显式包含 `--group` 参数，或需求描述中明确提及"长任务"、"计划组"、"拆分"、"多阶段"等关键词，或需求横跨 3 个以上独立模块/子系统，则判定为长任务：
  - 调用 `plan-executor.sh --group "需求" [slug]` 创建计划组，而非由 subagent 直接调用 flow-plan-group-state.sh
  - 长任务不会立即生成任何子计划
  - 子计划由计划组在 `GROUP_PLANNED` 后按依赖顺序逐个创建
- 在委派 subagent 之前，先做一次头脑风暴式 intake：基于需求、项目上下文和已有规则，主动识别会影响目标、范围、文件边界、验证方式、验收标准、仓库边界和风险控制的不确定项
- intake 不是自由发挥，必须至少逐项扫描以下决策维度：`目标/交付物`、`非目标/明确不做`、`范围与优先级`、`文件边界/模块边界`、`仓库边界`、`依赖与前置约束`、`验证方式与证据`、`验收标准`、`高风险路径/回滚或兜底策略`
- 每个维度都必须落入以下三种状态之一后，才算 intake 完成：`已由用户明确确认`、`可由当前代码/文档直接证实且不会改变实施决策`、`明确不适用且原因已说明`
- 只要存在任何会改变决策或结果的不确定项，就必须先向用户询问，不能直接把假设写进 plan
- 特别是以下情况，一律视为“必须先问”的关键不确定项：需求同时存在多种可行落地路径、范围可能扩散到相邻模块/仓库、验证方式不明确、验收口径不唯一、风险兜底方式不同会影响步骤拆分
- 对于存在多条可行落地路径的需求，必须先输出 `2-3` 个可行方案、各自 trade-off 和推荐方案；在用户确认方向前，禁止直接委派 subagent 生成 plan
- 询问时必须给出可行性分析、推荐选项和备选项，优先用表格或清单让用户交互式选择
- 每次优先只问一个关键决策或一组强相关决策；若有多个独立不确定项，按影响面从高到低分轮询问，避免一次抛给用户多个互不相关的问题
- 若一次扫描识别出 3 个及以上独立不确定项，先向用户输出 intake 摘要：`已确认事项`、`待确认决策`、`建议先确认的第一项`，再开始分轮询问
- 在正式委派前，先输出一版“已理解需求摘要”，至少明确：`目标`、`范围`、`非目标`、`验收口径`、`验证方式`；只有用户确认或这些内容已被仓库事实直接证实且不会改变实施决策时，才允许进入委派
- 用户确认后，把确认结果汇总进需求描述，再委派 subagent 生成或修订 draft plan
- 只有低风险、且能被当前仓库事实直接证实、并且不会改变步骤顺序/文件边界/验证命令的内容，才允许作为默认前提写入“已澄清版需求”；任何会影响 plan 结构的假设都禁止默认带入
- 只有在所有不确定项都已确认后，才允许进入委派步骤
- 生成 plan 时必须遵循当前代码与文档中的既有模式；如果发现与目标直接相关的结构问题，可以在 plan 中加入有边界的整理动作，但禁止引入与当前需求无关的重构或范围扩张
- 进入委派前，必须确认计划目标能被具体证据验证：至少要能对应到命令、测试、检查脚本、接口调用、页面操作或明确的人工核验方式；若验证证据无法定义，禁止继续生成 draft plan
- 进入委派前，必须拒绝任何明显不可执行的 plan 倾向：例如使用占位路径、虚构函数名、模糊动作、无法判断结果的验收语句；发现这类倾向时应先补充上下文或回问用户

## 委派规则

**先读取最终生效配置（项目级优先，用户级回退）的 `engine_mode`，再按当前宿主决定目标 subagent。不要跳过这一步，也不得替换为任何其他 agent（包括内置 Plan agent）。**

**这条规则同时适用于新建 draft 与原地修订 draft 两种场景；尤其是 plan-review 失败后重新进入 `/ai-flow-plan` 时，不得绕过配置选择逻辑，也不得默认改派 `ai-flow-claude-plan`。**

- 读取 `engine_mode` 时，必须复用已安装共享库，固定执行：

```bash
source "$HOME/.config/ai-flow/lib/config-loader.sh"
load_all_settings
get_setting "engine_mode" "auto"
```

- 若需要向用户说明配置来源，继续执行：

```bash
get_setting_source_label "engine_mode"
```

- 禁止通过 `cat .ai-flow/settings.json`、`cat .ai-flow/setting.json`、`cat ~/.claude/skills/.../setting.json`、`cat ~/.claude/skills/.../settings.json`、`cat ~/.config/ai-flow/setting.json` 等方式自行拼装或猜测配置结果
- 禁止把“未读取共享加载器”说成“未设置 engine_mode”

### 宿主分流

- Claude Code 宿主：使用 Claude Code `Agent(...)` subagent 委派。`ai-flow-codex-plan` 在此宿主中表示“通过共享 executor 调用外部 Codex”的 Claude agent bundle。
- Codex 宿主：使用 Codex native subagent spawn，目标必须是已安装到 `$CODEX_HOME/agents/ai-flow-codex-plan.toml` 的 custom agent；不得通过 `codex exec`、`claude`、`opencode` 或任何外部模型 CLI 模拟 subagent。
- Codex 宿主中若 `engine_mode=claude`，必须直接失败并提示：“当前在 Codex 宿主中，engine_mode=claude 不可用；请切换到 Claude Code，或将 engine_mode 改为 auto/codex 后重试。” 禁止 shell 到 `claude`。
- Codex 宿主中若 native agent 未注册或不可用，必须直接失败并提示重新运行 `bash install.sh` 并重启 Codex；禁止回退到 `codex exec` 或 Claude agent。

Claude Code 宿主：

| `engine_mode` | 首次委派 | `RESULT: degraded` 处理 |
|---|---|---|
| `claude` | `ai-flow-claude-plan` | 不回退；直接报告 `SUMMARY` |
| `codex` | `ai-flow-codex-plan` | 报告失败，不降级到 claude |
| `auto` 或未设置 | `ai-flow-codex-plan` | 自动改委派 `ai-flow-claude-plan` |

Codex 宿主：

| `engine_mode` | 首次委派 | 不可用处理 |
|---|---|---|
| `claude` | 不委派 | 直接失败，提示切换 Claude Code 或改配置 |
| `codex` | native subagent `ai-flow-codex-plan` | 直接失败，提示安装并重启 Codex |
| `auto` 或未设置 | native subagent `ai-flow-codex-plan` | 直接失败，提示安装并重启 Codex |

**长任务（计划组）委派**：

当需求被判定为长任务时，不生成单份 plan，而是调用 plan-executor.sh 创建计划组：

- 调用 `plan-executor.sh --group "需求描述" [group_slug]`
- plan-executor.sh 负责生成计划组文档、调用 flow-plan-group.sh create 创建计划组状态
- 长任务不会立即生成任何子计划

**子 plan 创建（由计划组触发）**：

当计划组在 `GROUP_PLANNED` 后创建子 plan 时，调用 `plan-executor.sh --child-of-group` 模式：

```bash
plan-executor.sh --child-of-group <group_slug> --child-id <child_id> --child-meta-json <json> "child需求" <child_slug>
```

- plan-executor.sh 负责创建子 plan 文件（带"所属计划组"和"计划组子项"元数据头）和状态
- 子 plan 仍然由 `flow-state.sh` 管理状态，不向子 plan state 增加字段
- 子 plan 的生成流程与普通 plan 一致，只是多了计划组元数据头

Claude Code 宿主调用格式固定为：

```text
Agent(
    description="生成或修订 draft plan",
    subagent_type="<按上表选择>",
    prompt="需求描述（已澄清版）：{需求描述；如果用户输入是本地需求文件路径，这里必须是文件完整正文，不是路径}\n需求来源：{需求文件路径或口头描述}\n已确认事项：{用户确认的选项摘要}\nslug：{slug 或留空自动生成}\n\n--- 以下是 subagent 执行指令 ---\n你必须在写入 plan 之前完成以下动作：\n1. 检查并初始化 .ai-flow/rule.yaml；\n2. 完整读取需求描述中涉及的文件内容；\n3. 严格遵循 templates/plan-template.md 的章节结构与元数据格式；\n4. 严格遵循 prompts/plan-generation.md 中的硬门禁规则（特别是 Step 的 9 个子字段）；\n5. 状态文件由 plan-executor.sh 统一初始化，严禁 subagent 手工操作 JSON。"
)
```

Codex 宿主调用格式固定为：

```text
Spawn a native Codex subagent named "ai-flow-codex-plan".

Prompt:
需求描述（已澄清版）：{需求描述；如果用户输入是本地需求文件路径，这里必须是文件完整正文，不是路径}
需求来源：{需求文件路径或口头描述}
已确认事项：{用户确认的选项摘要}
slug：{slug 或留空自动生成}

--- 以下是 subagent 执行指令 ---
你必须在写入 plan 之前完成以下动作：
1. 检查并初始化 .ai-flow/rule.yaml；
2. 完整读取需求描述中涉及的文件内容；
3. 严格遵循 templates/plan-template.md 的章节结构与元数据格式；
4. 严格遵循 prompts/plan-generation.md 中的硬门禁规则（特别是 Step 的 9 个子字段）；
5. 状态文件由 flow-state.sh 统一初始化或流转，严禁手工操作 JSON；
6. 禁止调用 codex exec、claude、opencode 或任何外部模型 CLI。
```

完成后读取 `ARTIFACT`、`STATE`、`NEXT`、`SUMMARY`。`RESULT: success` 时下一步固定进入 `/ai-flow-plan-review`；`RESULT: failed` 时直接报告 `SUMMARY` 并停止，不手工补跑任何中间脚本。

### subagent 职责

- 读取工作区与 `.ai-flow` 上下文
- 渲染 prompt / template
- 生成或修订 `.ai-flow/plans/*`
- 创建或保持 `.ai-flow/state/{slug}.json`（内部自动添加日期前缀）
- 在返回结果前先做一次 draft 自检：检查占位符未替换、章节缺失、前后矛盾、边界遗漏、验证步骤缺证据、步骤顺序不合理、路径/命名失真、2.6 与 4.4 不对应、验收标准不可证明等问题；未通过自检时先在 subagent 内修正，再返回固定摘要协议
- 返回固定摘要协议，而不是回传 plan 正文

## 固定输出协议

plan 生成/修订完成后，用一行自然语言总结结果并给出下一步，示例：

- 成功 → `✅ 计划草案已生成，状态进入 AWAITING_PLAN_REVIEW。`
- 修订成功 → `✅ 计划已修订，状态已自动回到 AWAITING_PLAN_REVIEW。`
- 失败 → `❌ 计划生成失败，缺少需求描述。`

然后根据 `NEXT` 值追加下一步提示：

- `NEXT: ai-flow-plan-review` → 输出 `下一步：运行 /ai-flow-plan-review 审核 draft plan。`
- `NEXT: none` → 不输出下一步提示

机器可读协议块只用于 skill/subagent 间解析和自动化推进，不是面向用户的主要内容。面向用户的最终回复必须只保留上面的自然语言摘要与下一步提示，禁止直接输出 `RESULT:`、`STATE:`、`NEXT:`、`SUMMARY:` 等协议字段；只有用户明确要求查看协议字段时才可额外展示。

内部在末尾追加机器可读的协议块：

```text
RESULT: success|failed|degraded
AGENT: ai-flow-plan
ARTIFACT: <plan-path|none>
STATE: <status|none>
NEXT: ai-flow-plan-review|none
SUMMARY: <one-line-summary>
```

## 计划版本管理

每次 plan 修订时，`plan-executor.sh` 会自动将修订前的内容备份到 `.ai-flow/plans/history/<slug>/` 目录。

- 若生成或修订过程中为了安全临时复制 plan 文件，允许创建 `.ai-flow/plans/<slug>.md.bak` 这类临时文件
- `.bak` 文件只能在单次操作内部临时存在；无论生成/修订最终成功、失败、降级或中止，流程结束前都必须删除本次创建的 `.bak`
- 禁止把 `.bak` 文件作为持久版本历史；持久版本备份只能写入 `.ai-flow/plans/history/<slug>/vN.md`
- 返回 `RESULT:` 协议前必须确认 `.ai-flow/plans/` 下没有本次操作遗留的 `.bak` 文件

| 工具 | 用途 | 示例 |
|------|------|------|
| `flow-plan-history.sh` | 列出指定 slug 的所有历史版本 | `bash runtime/scripts/flow-plan-history.sh --slug <slug>` |
| `flow-plan-history.sh --json` | 以 JSON 格式输出版本历史 | `bash runtime/scripts/flow-plan-history.sh --slug <slug> --json` |
| `flow-plan-diff.sh` | 对比两个历史版本差异 | `bash runtime/scripts/flow-plan-diff.sh --slug <slug> --from v1 --to v2` |
| `flow-plan-diff.sh --to current` | 对比历史版本与当前 plan（依赖 `flow-state.sh`） | `bash runtime/scripts/flow-plan-diff.sh --slug <slug> --from v1 --to current` |

版本历史保存在 `.ai-flow/plans/history/<slug>/` 目录，包含 `manifest.json`（版本元数据）和 `vN.md`（版本化 plan 快照）。

## 完成后

- `RESULT: success`：读取 `ARTIFACT`、`STATE`、`NEXT`、`SUMMARY`，确认 draft 已落盘
- 下一步固定进入 `/ai-flow-plan-review`
- `RESULT: failed`：直接报告 `SUMMARY` 并停止，不手工补跑任何中间脚本
