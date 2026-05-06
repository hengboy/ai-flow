# AI Flow

> 通用 AI 协作编码工作流。唯一流程状态源是 `.ai-flow/state/<slug>.json`。

## 概览

AI Flow 将协作拆成五类动作：

1. `Plan`：用 `codex-plan.sh` 分析需求、生成 draft plan，并在同一入口内完成计划审核、必要修订和放行。
2. `Change`：用 `/ai-flow-change` 处理需求变更，更新计划各章节并推进状态，确保后续 execute 和 review 可用。
3. `Execute`：按计划实施或修复代码，执行者只读 `current_status` 决定下一步。
4. `Review`：用 `codex-review.sh` 审查代码变更并生成报告，通过严重度推导审查结果，并写回状态迁移。
5. `Status`：用 `flow-status.sh` 扫描 `.ai-flow/state/*.json`，按状态分类展示待办和统计。

`plan` 和 `review report` 都是证据文档，不再承担状态语义。不要再从 Markdown 首行或文件头推断流程状态。

## 状态机

### 状态枚举

| 状态 | 含义 |
|------|------|
| `AWAITING_PLAN_REVIEW` | draft plan 已生成，等待计划审核 |
| `PLAN_REVIEW_FAILED` | 最近一次计划审核失败，待修订 plan |
| `PLANNED` | plan 已审核通过，允许进入 execute |
| `IMPLEMENTING` | 首轮开发进行中 |
| `AWAITING_REVIEW` | 开发或修复已完成，等待常规 review |
| `REVIEW_FAILED` | 最近一次 review/recheck 失败，尚未开始修复 |
| `FIXING_REVIEW` | 正在修复最近一次失败的 review |
| `DONE` | 审查已通过（或带 Minor 建议通过），可提交或发起 recheck |

### 允许迁移

| From | Event | To |
|------|-------|----|
| `null` | `plan_created` | `AWAITING_PLAN_REVIEW` |
| `AWAITING_PLAN_REVIEW` | `plan_review_failed` | `PLAN_REVIEW_FAILED` |
| `PLAN_REVIEW_FAILED` | `plan_review_failed` | `PLAN_REVIEW_FAILED` |
| `AWAITING_PLAN_REVIEW` | `plan_review_passed` | `PLANNED` |
| `PLAN_REVIEW_FAILED` | `plan_review_passed` | `PLANNED` |
| `PLANNED` | `execute_started` | `IMPLEMENTING` |
| `IMPLEMENTING` | `implementation_completed` | `AWAITING_REVIEW` |
| `AWAITING_REVIEW` | `review_passed` | `DONE` |
| `AWAITING_REVIEW` | `review_failed` | `REVIEW_FAILED` |
| `REVIEW_FAILED` | `fix_started` | `FIXING_REVIEW` |
| `FIXING_REVIEW` | `fix_completed` | `AWAITING_REVIEW` |
| `DONE` | `recheck_passed` | `DONE` |
| `DONE` | `recheck_failed` | `REVIEW_FAILED` |

### 审查结果与状态映射

`record-review` 接受三种审查结果：

| 审查结果 | 含义 | 常规 review 目标状态 | recheck 目标状态 |
|----------|------|---------------------|-----------------|
| `passed` | 无任何缺陷 | `DONE` | `DONE` |
| `passed_with_notes` | 仅有 Minor 建议，无 Critical/Important | `DONE` | `DONE` |
| `failed` | 存在 Critical/Important 缺陷或阻塞待修复项 | `REVIEW_FAILED` | `REVIEW_FAILED` |

审查结果不由 AI 自评决定，而是由 `codex-review.sh` 根据报告中的缺陷严重度独立推导：

- 报告中存在 Critical/Important 缺陷或阻塞性 `[待修复]` 标记 → `failed`
- 仅存在 Minor 建议（未处理项标记为 `[可选]`）→ `passed_with_notes`
- 无任何缺陷 → `passed`

如果 Codex 自评结果与 shell 推导结果不一致，以 shell 推导为准。

## 状态文件

每个需求简称只对应一个真实状态文件：

```text
.ai-flow/state/<slug>.json
```

### 关键字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `schema_version` | int | 当前为 `1` |
| `slug` | string | 需求英文简称，小写字母+数字+连字符 |
| `title` | string | 需求标题 |
| `current_status` | string | 当前状态枚举值 |
| `created_at` | ISO string | 创建时间，等于第一条 transition.at |
| `updated_at` | ISO string | 更新时间，等于最后一条 transition.at |
| `plan_file` | string | 关联的计划文档路径（相对项目根） |
| `review_rounds` | object | `{ "regular": N, "recheck": M }` 审查轮次计数 |
| `latest_regular_review_file` | string? | 最近一次常规审查报告路径 |
| `latest_recheck_review_file` | string? | 最近一次再审查报告路径 |
| `last_review` | object? | 最近一次审查结果摘要（mode/round/result/report_file/at） |
| `active_fix` | object? | 仅在 `FIXING_REVIEW` 状态存在（mode/round/report_file/at） |
| `transitions` | array | 迁移日志，固定字段：seq/at/event/from/to/actor/artifacts/note |

### 约束

- `updated_at` 必须等于最后一条 `transition.at`。
- `current_status` 必须等于最后一条 `transition.to`。
- `created_at` 必须等于第一条 `transition.at`。
- `active_fix` 只能在 `FIXING_REVIEW` 状态存在。
- `review_rounds`、`last_review`、`latest_*_review_file` 都必须和 `transitions` 一致。
- `slug` 必须匹配 `^[a-z0-9][a-z0-9-]*$`。

## 仓库结构

```text
ai-flow/
├── install.sh                    # 安装脚本（Claude + Runtime + OneSpace 三通道）
├── README.md                     # 本文档
├── runtime/                      # 公共运行时源码（共享脚本单一来源）
│   └── scripts/
│       ├── flow-change.sh
│       ├── flow-state.sh
│       └── flow-status.sh
├── skills/                       # Skill 源码目录（每个 skill 自包含）
│   ├── ai-flow-plan/
│   │   ├── SKILL.md
│   │   ├── scripts/
│   │   │   └── codex-plan.sh
│   │   ├── templates/plan-template.md
│   │   └── prompts/
│   │       ├── plan-generation.md
│   │       ├── plan-review.md
│   │       └── plan-revision.md
│   ├── ai-flow-review/
│   │   ├── SKILL.md
│   │   ├── scripts/
│   │   │   ├── codex-review.sh
│   │   │   └── opencode-review.sh
│   │   ├── templates/review-template.md
│   │   └── prompts/review-generation.md
│   ├── ai-flow-change/
│   │   └── SKILL.md
│   ├── ai-flow-execute/
│   │   └── SKILL.md
│   └── ai-flow-status/
│       └── SKILL.md
├── tests/                        # 测试套件
│   ├── helpers.bash              # 测试辅助函数
│   ├── run.sh                    # 测试运行入口
│   ├── test_flow_state.sh        # 状态引擎测试
│   ├── test_flow_status.sh       # 状态展示测试
│   ├── test_flow_change.sh       # 需求变更测试
│   ├── test_plan_workflow.sh     # Plan 创建流程测试
│   ├── test_review_workflow.sh   # Review 工作流测试
│   └── test_install.sh           # 安装流程测试
```

项目运行时目录：

```text
.ai-flow/
├── plans/YYYYMMDD/<slug>.md                # 实施计划
├── reports/YYYYMMDD/<slug>-review.md       # 常规审查报告（第 1 轮）
├── reports/YYYYMMDD/<slug>-review-vN.md    # 常规审查报告（第 N 轮）
├── reports/YYYYMMDD/<slug>-review-recheck.md      # 再审查报告（第 1 轮）
├── reports/YYYYMMDD/<slug>-review-recheck-vN.md   # 再审查报告（第 N 轮）
└── state/<slug>.json                       # JSON 状态文件
```

## 安装

```bash
bash install.sh
```

安装脚本执行以下操作：

1. 扫描 `skills/*/SKILL.md`，把每个 skill 目录完整复制到 `~/.claude/skills/<skill>/`
2. 为复制后的 `scripts/*.sh` 统一补可执行权限
3. 扫描 `runtime/`，把共享运行时安装到 `$AI_FLOW_HOME/`（默认 `~/.config/ai-flow`，仅包含公共状态脚本）
4. 创建 OneSpace 目标目录（`$ONSPACE_DIR`，默认 `~/.config/onespace/skills/local_state/models/claude`），并把每个 skill 目录完整同步到 `$ONSPACE_DIR/<skill>/`
5. 安装时会删除过时的 `~/.claude/workflows`、`~/.claude/templates` 以及 OneSpace 根目录旧入口，也不再向 OneSpace 根目录写入脚本或模板

可通过环境变量自定义路径：
- `CLAUDE_HOME`：Claude 配置目录，默认 `~/.claude`
- `AI_FLOW_HOME`：AI Flow 公共运行时目录，默认 `~/.config/ai-flow`
- `ONSPACE_DIR`：OneSpace 目录，默认 `~/.config/onespace/skills/local_state/models/claude`

安装后路径分层：

- 公共脚本安装到 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/`
- skill 私有脚本、prompt、template 安装到 `${CLAUDE_HOME:-$HOME/.claude}/skills/<skill>/`
- `codex-plan.sh`、`codex-review.sh`、`opencode-review.sh` 只安装在对应 skill 的 `scripts/` 目录，调用时应直接使用 `${CLAUDE_HOME:-$HOME/.claude}/skills/<skill>/scripts/...`

## Skill 运行时

### `runtime/scripts/flow-state.sh`

JSON 状态机唯一写入口，内嵌 Python 实现。所有写操作加锁（`mkdir` 锁），原子写入（`os.replace`），写前写后结构校验。

支持的子命令：

| 子命令 | 说明 | 必要参数 |
|--------|------|----------|
| `create` | 创建新状态，初始 `AWAITING_PLAN_REVIEW` | `--slug`, `--title`, `--plan-file` |
| `record-plan-review` | 记录计划审核结果；`passed/passed_with_notes` 推进到 `PLANNED`，`failed` 推进到 `PLAN_REVIEW_FAILED` | `--slug`, `--result`, `--engine`, `--model` |
| `start-execute` | `PLANNED` → `IMPLEMENTING` | `slug`（位置参数） |
| `finish-implementation` | `IMPLEMENTING` → `AWAITING_REVIEW` | `slug`（位置参数） |
| `record-review` | 记录审查结果，推进状态 | `--slug`, `--mode (regular\|recheck)`, `--result (passed\|failed\|passed_with_notes)`, `--report-file` |
| `start-fix` | `REVIEW_FAILED` → `FIXING_REVIEW`，设置 `active_fix` | `slug`（位置参数） |
| `finish-fix` | `FIXING_REVIEW` → `AWAITING_REVIEW`，清除 `active_fix` | `slug`（位置参数） |
| `show [slug]` | 显示状态 JSON（不指定则显示全部） | 可选 `--field` |
| `validate` | 校验指定或全部状态文件结构一致性 | `slug` 或 `--all` |
| `repair` | 修复异常状态或元数据 | `--slug`, 可选 `--status`, `--title`, `--plan-file`, `--clear-active-fix`, `--active-fix-*`, `--note` |

安装后：

- 共享实现位于 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh`
- 所有 skill 和文档都应直接调用这条公共路径，不再在 skill 目录内复制 `flow-state.sh`

### `skills/ai-flow-plan/scripts/codex-plan.sh`

调用 Codex 分析需求并生成实施计划。

```bash
${CLAUDE_HOME:-$HOME/.claude}/skills/ai-flow-plan/scripts/codex-plan.sh "需求描述" [英文简称] [模型名]
```

核心流程：

1. **自动 slug 生成**：如果未指定简称，从需求描述中提取前 3 个英文单词组合；无英文时使用 `plan-YYYYMMDD`；自动去重（追加 `-2`、`-3`…）。
2. **技术栈检测**：自动扫描项目文件（`package.json`、`go.mod`、`Cargo.toml`、`pom.xml`、`pyproject.toml` 等），识别框架和语言组合，注入到 Codex prompt 中确保计划使用正确技术栈。
3. **计划生成**：从当前 skill 目录读取 `templates/plan-template.md` 和 `prompts/plan-generation.md`，通过 Codex 生成结构化 draft plan 文档。
4. **draft 结构校验**：
   - 首行必须为 `# 实施计划：...`
   - 必须包含 `原始需求（原文）` 和 `## 8. 计划审核记录`
   - 必须有可执行 Step 和 `- [ ]` 复选框
   - 必须有验证命令（`命令：`）和预期结果（`预期：`）
   - 不允许携带状态码、未替换占位符、不可执行描述（TBD/TODO 等）
   - 不得为状态 JSON 设计自定义 schema 字段
5. **状态初始化**：校验通过后调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh create`，创建 `AWAITING_PLAN_REVIEW` 状态文件。
6. **计划审核闭环**：继续在同一脚本内执行计划审核；默认用 Codex，只有审核阶段 Codex 不可用时才降级到 OpenCode。审核失败时按 `prompts/plan-revision.md` 修订 plan 并复审，默认最多自动复审 3 轮。
7. **执行门禁**：只有计划审核结果为 `passed` 或 `passed_with_notes` 时，状态才推进到 `PLANNED`；否则保持 `PLAN_REVIEW_FAILED`，禁止进入 `/ai-flow-execute`。

使用约束：

- `ai-flow-plan` 必须只调用一次 `codex-plan.sh`，禁止手工拆分为 “先 `flow-state.sh create`、再 `codex exec` 审核” 的多步流程
- `flow-state.sh create` / `record-plan-review` 仅作为 `codex-plan.sh` 的内部子步骤，不应由执行者单独调用来补流程
- 如果 `codex-plan.sh` 失败，应直接修正运行目录、slug 或依赖问题后整体重跑，不要在父目录、子目录之间切换着补跑
- 多模块仓库必须进入目标模块根目录执行，例如 `isp-case/`，不要在聚合父目录执行

### `skills/ai-flow-review/scripts/codex-review.sh`

调用审查引擎生成代码审查报告。

```bash
${CLAUDE_HOME:-$HOME/.claude}/skills/ai-flow-review/scripts/codex-review.sh {需求关键词} [模型名] [推理强度] [轮次]
```

核心流程：

1. **状态匹配**：通过关键词在 `.ai-flow/state/` 中匹配状态文件，支持多匹配时交互选择。
2. **审查模式判定**：只从状态 JSON 的 `current_status` 决定：
   - `AWAITING_REVIEW` → 常规 review
   - `DONE` → recheck
   - 其他 → 拒绝审查
3. **Git 变更校验**：必须存在非 `.ai-flow/` 的未提交变更，否则拒绝审查。
4. **审查引擎选择**：
   - 优先使用 Codex（可指定模型和推理强度）
   - Codex 不可用时降级使用 OpenCode（`zhipuai-coding-plan/glm-5.1`，推理强度映射为 variant）
   - 均不可用时报错退出
5. **上一轮参考选择**：
   - `last_review.result == failed` 时优先使用失败报告
   - recheck 优先 `latest_recheck_review_file`，再回退 `latest_regular_review_file`
   - 常规 review 使用 `latest_regular_review_file`
   - 只提取上一轮报告的 `## 4. 缺陷清单` 与 `## 6. 缺陷修复追踪` 部分，不注入整份旧报告
6. **报告生成**：从当前 skill 目录读取共享的 `templates/review-template.md` 和 `prompts/review-generation.md`，通过审查引擎生成结构化报告。
7. **结构校验**：
   - 首行必须为 `# 审查报告：...`
   - 必须包含 6 个标准章节（含 `## 2.1 计划外变更识别`）
   - 不得有未替换占位符
   - 元数据（需求简称、审查模式、审查轮次、对比计划）必须与状态文件一致
   - 审查结果只能是 `passed`、`passed_with_notes` 或 `failed`
   - 一致性交叉校验：passed 报告不能包含 `[待修复]` 或需要修复结论；failed 报告必须有缺陷标记
8. **严重度推导**：独立于 AI 自评，根据报告中的缺陷严重级别推导最终结果（见上方"审查结果与状态映射"）。
9. **状态推进**：调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh record-review` 推进状态，校验最终状态一致性。

报告文件命名规则：

- 常规第 1 轮：`<slug>-review.md`
- 常规第 N 轮：`<slug>-review-vN.md`
- 再审查第 1 轮：`<slug>-review-recheck.md`
- 再审查第 N 轮：`<slug>-review-recheck-vN.md`

### `runtime/scripts/flow-change.sh`

记录执行过程中的需求变更到计划文档。

```bash
flow-change.sh {需求关键词} "变更描述"
```

- 通过状态文件匹配目标 plan
- 自动在 plan 中创建 `## 7. 需求变更记录` 表格（不存在时新建）
- 清除模板占位行后追加变更记录
- 不修改流程状态

安装后：

- 共享实现位于 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-change.sh`
- 所有 skill 和文档都应直接调用这条公共路径，不再在 skill 目录内复制 `flow-change.sh`

### `runtime/scripts/flow-status.sh`

扫描并展示所有 JSON 状态。

```bash
flow-status.sh
```

- 先调用 sibling script `flow-state.sh validate --all` 校验全部状态文件
- 按 `current_status` 分类展示，附带 plan 文件和最新报告路径
- 底部输出各状态计数统计

安装后：

- 共享实现位于 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-status.sh`
- 所有 skill 和文档都应直接调用这条公共路径，不再在 skill 目录内复制 `flow-status.sh`
- `codex-plan.sh`、`codex-review.sh`、`opencode-review.sh` 不再安装到 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/`；应直接调用 `${CLAUDE_HOME:-$HOME/.claude}/skills/<skill>/scripts/` 下的实现

## 模板约束

### plan 模板（7 节）

首行：`# 实施计划：{需求名称}`

| 章节 | 内容 |
|------|------|
| `## 1. 需求概述` | 目标、背景、非目标 |
| `## 2. 技术分析` | 涉及模块、数据模型、API 变更、依赖影响、文件边界总览 |
| `## 3. 实施步骤` | 按 Step 组织，每个 Step 含目标、文件边界、前置阅读、执行动作（复选框）、验收条件、阻塞条件 |
| `## 4. 测试计划` | 单元测试、集成测试、回归验证 |
| `## 5. 风险与注意事项` | 潜在风险和边界情况 |
| `## 6. 验收标准` | 可验证的验收条件 |
| `## 7. 需求变更记录` | 执行过程中的需求变更追踪表 |

约束：
- 不允许任何状态码文件头
- 每个 Step 动作用 `- [ ]` 复选框，粒度 2-5 分钟
- 验证动作必须给出确切命令和预期结果
- 不得为 `.ai-flow/state/<slug>.json` 设计自定义字段
- 禁止 TBD、TODO、后续补充等不可执行描述

### review 模板（6 节）

首行：`# 审查报告：{需求名称}`

顶部元数据必须包含：`需求简称`、`审查模式`、`审查轮次`、`审查结果`、`对比计划`、`审查工具`。

| 章节 | 内容 |
|------|------|
| `## 1. 总体评价` | 审查结论 + 审查上下文表 |
| `## 2. 计划覆盖度检查` | 逐 Step 检查实现状态 + 覆盖率 |
| `## 2.1 计划外变更识别` | git diff 中 plan 未描述的变更，判定接受/需确认/回退 |
| `## 3. 代码质量审查` | 架构、规范、安全、性能、逻辑正确性（8 项逐项检查表） |
| `## 4. 缺陷清单` | 严重缺陷（DEF-N）+ 建议改进（SUG-N），含严重级别和修复状态 |
| `## 5. 审查结论` | 通过/通过（附建议）/需要修复勾选 |
| `## 6. 缺陷修复追踪` | 多轮缺陷状态追踪表（待修复/可选/已修复） |

约束：
- `审查结果` 只允许 `passed`、`passed_with_notes` 或 `failed`
- Minor 未处理项必须标记为 `[可选]`，不得使用 `[待修复]`
- 逻辑正确性检查表（3.5）必须逐项填写
- 计划外变更判定遵循严格规则：计划内/接受/需确认/回退

## 技能语义

| 技能 | 触发 | 行为 |
|------|------|------|
| `ai-flow-plan` | `/ai-flow-plan` | 生成 draft plan + 创建 `AWAITING_PLAN_REVIEW` 状态，并在同一入口内完成计划审核/修订/放行 |
| `ai-flow-change` | `/ai-flow-change` | 处理需求变更，更新计划各章节，必要时 repair 到 `IMPLEMENTING` |
| `ai-flow-execute` | `/ai-flow-execute` | 只读 `current_status` 决定开始开发、继续开发或开始修复 |
| `ai-flow-review` | `/ai-flow-review` | 只允许 `AWAITING_REVIEW` 走常规审查，`DONE` 走 recheck |
| `ai-flow-status` | `/ai-flow-status` | 查看 JSON 状态分类和最近关联文档 |

### 需求变更

`/ai-flow-change` 可在以下时机使用：

| 当前状态 | 操作 |
|----------|------|
| `AWAITING_PLAN_REVIEW` | 直接编辑计划，不改变状态 |
| `PLAN_REVIEW_FAILED` | 直接编辑计划，不改变状态 |
| `PLANNED` | 直接编辑计划，不改变状态 |
| `IMPLEMENTING` | 直接编辑计划，不改变状态 |
| `AWAITING_REVIEW` | 编辑计划 + repair 到 `IMPLEMENTING` |
| `DONE` | 编辑计划 + repair 到 `IMPLEMENTING` |
| `REVIEW_FAILED` | 编辑计划 + repair 到 `IMPLEMENTING` |
| `FIXING_REVIEW` | 编辑计划 + repair 到 `IMPLEMENTING`（清除 active_fix）|

核心流程：

1. 选择目标 slug
2. 确认变更内容（新增/修改/删除）
3. 按 `current_status` 决定是否 repair 状态
4. 增量编辑计划文件：
   - `## 1.` 更新目标/非目标
   - `## 2.` 更新技术分析和文件边界
   - `## 3.` 追加新 Step 或标记修改/删除的 Step（`*(需求变更修订)*` / `*(已移除)*`）
   - `## 4.` 追加测试项，废弃旧测试项（标记 `*(已废弃)*`）
   - `## 6.` 追加验收标准，废弃旧验收标准（标记 `*(已废弃)*`）
5. 调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-change.sh {slug}` 记录 `## 7` 审计行
6. 确认变更摘要

变更后 `ai-flow-execute` 从第一个未勾选的 `- [ ]` 动作继续执行，`ai-flow-review` 对比更新后的计划审查。

### 提交门禁

- `PLANNED`、`IMPLEMENTING`、`AWAITING_REVIEW`、`REVIEW_FAILED`、`FIXING_REVIEW` 状态下一律禁止提交
- 只有 `current_status == DONE` 才允许提交
- 提交前必须有新鲜验证证据
- 优先使用 `git-commit` 技能

### 缺陷修复追踪

- 失败状态只读 `last_review` / `active_fix` 追踪最近失败报告
- 可以更新旧报告中的"缺陷修复追踪"表
- 不得把旧报告改写成"通过"
- 是否通过必须由下一轮新 review 决定

## 测试

回归命令：

```bash
bash tests/run.sh
for f in install.sh runtime/scripts/*.sh skills/*/scripts/*.sh tests/*.sh tests/*.bash; do bash -n "$f" || exit 1; done
```

当前测试覆盖：

| 测试文件 | 覆盖范围 |
|----------|----------|
| `test_flow_state.sh` | 状态引擎合法/非法迁移、锁冲突、写失败保护、结构校验、repair |
| `test_plan_workflow.sh` | plan 创建后生成 `PLANNED` 状态、结构校验失败不创建状态 |
| `test_review_workflow.sh` | 常规 review、recheck、失败修复链路、严重度推导 |
| `test_flow_status.sh` | 状态展示只按 JSON 分类，不被旧报告污染 |
| `test_flow_change.sh` | 需求变更登记到计划文档 |
| `test_install.sh` | 安装流程（Claude、OneSpace、AI_FLOW_HOME 三目标部署） |

## 兼容性说明

- 这是全量替换，不再支持从 plan/review 文件头读取状态。
- 不提供双轨状态源，不接受旧 header 作为运行时输入。
- 安装后只保证 `~/.claude/skills/<skill>/...`、`$AI_FLOW_HOME/...` 和 `$ONSPACE_DIR/<skill>/...` 可用。
- 共享运行时脚本只放在 `runtime/`，安装后只会出现在 `$AI_FLOW_HOME/scripts/`；其中仅 `flow-state.sh` / `flow-status.sh` / `flow-change.sh` 属于公共实现。
- 非公共实现仍然位于 `~/.claude/skills/<skill>/scripts/`（或 `$ONSPACE_DIR/<skill>/scripts/`），skill 目录不再包含公共 `flow-state.sh` / `flow-status.sh` / `flow-change.sh`。
- skill 私有 prompt/template 继续留在 `skills/<skill>/prompts`、`skills/<skill>/templates`，不进入公共 runtime。
- 安装脚本会删除旧的 `~/.claude/workflows/*`、`~/.claude/templates/*` 和 OneSpace 根级旧脚本/模板；skill 和脚本均不允许再依赖这些旧路径。
- OneSpace 根级脚本/模板路径不再提供兼容层。
- 旧数据若要继续使用，应离线迁移或人工重建状态文件。
