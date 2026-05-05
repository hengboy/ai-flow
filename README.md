# AI Flow

> 通用 AI 协作编码工作流。唯一流程状态源是 `.ai-flow/state/<slug>.json`。

## 概览

AI Flow 将协作拆成五类动作：

1. `Plan`：用 `codex-plan.sh` 分析需求、生成实施计划文档，并初始化 JSON 状态为 `PLANNED`。
2. `Change`：用 `/ai-flow-change` 处理需求变更，更新计划各章节并推进状态，确保后续 execute 和 review 可用。
3. `Execute`：按计划实施或修复代码，执行者只读 `current_status` 决定下一步。
4. `Review`：用 `codex-review.sh` 审查代码变更并生成报告，通过严重度推导审查结果，并写回状态迁移。
5. `Status`：用 `flow-status.sh` 扫描 `.ai-flow/state/*.json`，按状态分类展示待办和统计。

`plan` 和 `review report` 都是证据文档，不再承担状态语义。不要再从 Markdown 首行或文件头推断流程状态。

## 状态机

### 状态枚举

| 状态 | 含义 |
|------|------|
| `PLANNED` | plan 已生成，尚未开始执行 |
| `IMPLEMENTING` | 首轮开发进行中 |
| `AWAITING_REVIEW` | 开发或修复已完成，等待常规 review |
| `REVIEW_FAILED` | 最近一次 review/recheck 失败，尚未开始修复 |
| `FIXING_REVIEW` | 正在修复最近一次失败的 review |
| `DONE` | 审查已通过（或带 Minor 建议通过），可提交或发起 recheck |

### 允许迁移

| From | Event | To |
|------|-------|----|
| `null` | `plan_created` | `PLANNED` |
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
| `failed` | 存在 Critical/Important 缺陷或待修复项 | `REVIEW_FAILED` | `REVIEW_FAILED` |

审查结果不由 AI 自评决定，而是由 `codex-review.sh` 根据报告中的缺陷严重度独立推导：

- 报告中存在 Critical/Important 缺陷或 `[待修复]` 标记 → `failed`
- 仅存在 Minor 建议 → `passed_with_notes`
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
├── install.sh                    # 安装脚本（Claude + OneSpace 双通道）
├── README.md                     # 本文档
├── skills/                       # Claude Code 技能定义
│   ├── ai-flow-plan.md           # /ai-flow-plan：需求分析与计划生成
│   ├── ai-flow-change.md         # /ai-flow-change：需求变更与计划更新
│   ├── ai-flow-execute.md        # /ai-flow-execute：按计划执行开发或修复
│   ├── ai-flow-review.md         # /ai-flow-review：代码审查与报告生成
│   └── ai-flow-status.md         # /ai-flow-status：流程状态查看
├── workflows/                    # Shell 工作流脚本
│   ├── flow-state.sh             # JSON 状态机唯一写入口（内嵌 Python）
│   ├── codex-plan.sh             # 调用 Codex 生成实施计划
│   ├── codex-review.sh           # 调用审查引擎生成审查报告
│   ├── flow-change.sh            # 记录需求变更到计划文档
│   └── flow-status.sh            # 扫描并展示所有 JSON 状态
├── templates/                    # 文档模板
│   ├── plan-template.md          # 实施计划模板（7 节）
│   └── review-template.md        # 审查报告模板（6 节）
├── tests/                        # 测试套件
│   ├── helpers.bash              # 测试辅助函数
│   ├── run.sh                    # 测试运行入口
│   ├── test_flow_state.sh        # 状态引擎测试
│   ├── test_flow_status.sh       # 状态展示测试
│   ├── test_flow_change.sh       # 需求变更测试
│   ├── test_plan_workflow.sh     # Plan 创建流程测试
│   ├── test_review_workflow.sh   # Review 工作流测试
│   └── test_install.sh           # 安装流程测试
└── docs/                         # 文档
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

1. 将 5 个 skills 安装到 `~/.claude/skills/<name>/SKILL.md`
2. 将 workflows 脚本复制到 `~/.claude/workflows/` 并设置可执行权限
3. 将 templates 复制到 `~/.claude/templates/`
4. 如果检测到 OneSpace 目录（`$ONSPACE_DIR`，默认 `~/.config/onespace/skills/local_state/models/claude`），同步 skills、workflows 和 templates 到该目录

可通过环境变量自定义路径：
- `CLAUDE_HOME`：Claude 配置目录，默认 `~/.claude`
- `ONSPACE_DIR`：OneSpace 目录，默认 `~/.config/onespace/skills/local_state/models/claude`

## 工作流脚本

### `workflows/flow-state.sh`

JSON 状态机唯一写入口，内嵌 Python 实现。所有写操作加锁（`mkdir` 锁），原子写入（`os.replace`），写前写后结构校验。

支持的子命令：

| 子命令 | 说明 | 必要参数 |
|--------|------|----------|
| `create` | 创建新状态，初始 `PLANNED` | `--slug`, `--title`, `--plan-file` |
| `start-execute` | `PLANNED` → `IMPLEMENTING` | `slug`（位置参数） |
| `finish-implementation` | `IMPLEMENTING` → `AWAITING_REVIEW` | `slug`（位置参数） |
| `record-review` | 记录审查结果，推进状态 | `--slug`, `--mode (regular\|recheck)`, `--result (passed\|failed\|passed_with_notes)`, `--report-file` |
| `start-fix` | `REVIEW_FAILED` → `FIXING_REVIEW`，设置 `active_fix` | `slug`（位置参数） |
| `finish-fix` | `FIXING_REVIEW` → `AWAITING_REVIEW`，清除 `active_fix` | `slug`（位置参数） |
| `show [slug]` | 显示状态 JSON（不指定则显示全部） | 可选 `--field` |
| `validate` | 校验指定或全部状态文件结构一致性 | `slug` 或 `--all` |
| `repair` | 修复异常状态或元数据 | `--slug`, 可选 `--status`, `--title`, `--plan-file`, `--clear-active-fix`, `--active-fix-*`, `--note` |

### `workflows/codex-plan.sh`

调用 Codex 分析需求并生成实施计划。

```bash
codex-plan.sh "需求描述" [英文简称] [模型名]
```

核心流程：

1. **自动 slug 生成**：如果未指定简称，从需求描述中提取前 3 个英文单词组合；无英文时使用 `plan-YYYYMMDD`；自动去重（追加 `-2`、`-3`…）。
2. **技术栈检测**：自动扫描项目文件（`package.json`、`go.mod`、`Cargo.toml`、`pom.xml`、`pyproject.toml` 等），识别框架和语言组合，注入到 Codex prompt 中确保计划使用正确技术栈。
3. **计划生成**：使用 plan 模板，通过 Codex 生成结构化计划文档。
4. **结构校验**：
   - 首行必须为 `# 实施计划：...`
   - 必须包含 6 个标准章节
   - 必须有可执行 Step 和 `- [ ]` 复选框
   - 必须有验证命令（`命令：`）和预期结果（`预期：`）
   - 不允许携带状态码、未替换占位符、不可执行描述（TBD/TODO 等）
   - 不得为状态 JSON 设计自定义 schema 字段
5. **状态初始化**：校验通过后调用 `flow-state.sh create`，创建 `PLANNED` 状态文件。

### `workflows/codex-review.sh`

调用审查引擎生成代码审查报告。

```bash
codex-review.sh {需求关键词} [模型名] [推理强度] [轮次]
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
   - Codex 不可用时降级使用 OpenCode（`alibaba-cn/glm-5.1`，推理强度映射为 variant）
   - 均不可用时报错退出
5. **上一轮参考选择**：
   - `last_review.result == failed` 时优先使用失败报告
   - recheck 优先 `latest_recheck_review_file`，再回退 `latest_regular_review_file`
   - 常规 review 使用 `latest_regular_review_file`
   - 只提取上一轮报告的 `## 6. 缺陷修复追踪` 部分，不注入整份旧报告
6. **报告生成**：使用 review 模板，通过审查引擎生成结构化报告。
7. **结构校验**：
   - 首行必须为 `# 审查报告：...`
   - 必须包含 6 个标准章节（含 `## 2.1 计划外变更识别`）
   - 不得有未替换占位符
   - 元数据（需求简称、审查模式、审查轮次、对比计划）必须与状态文件一致
   - 审查结果只能是 `passed`、`passed_with_notes` 或 `failed`
   - 一致性交叉校验：passed 报告不能包含 `[待修复]` 或需要修复结论；failed 报告必须有缺陷标记
8. **严重度推导**：独立于 AI 自评，根据报告中的缺陷严重级别推导最终结果（见上方"审查结果与状态映射"）。
9. **状态推进**：调用 `flow-state.sh record-review` 推进状态，校验最终状态一致性。

报告文件命名规则：

- 常规第 1 轮：`<slug>-review.md`
- 常规第 N 轮：`<slug>-review-vN.md`
- 再审查第 1 轮：`<slug>-review-recheck.md`
- 再审查第 N 轮：`<slug>-review-recheck-vN.md`

### `workflows/flow-change.sh`

记录执行过程中的需求变更到计划文档。

```bash
flow-change.sh {需求关键词} "变更描述"
```

- 通过状态文件匹配目标 plan
- 自动在 plan 中创建 `## 7. 需求变更记录` 表格（不存在时新建）
- 清除模板占位行后追加变更记录
- 不修改流程状态

### `workflows/flow-status.sh`

扫描并展示所有 JSON 状态。

```bash
flow-status.sh
```

- 先调用 `flow-state.sh validate --all` 校验全部状态文件
- 按 `current_status` 分类展示，附带 plan 文件和最新报告路径
- 底部输出各状态计数统计

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
| `## 5. 审查结论` | 通过/需要修复勾选 |
| `## 6. 缺陷修复追踪` | 多轮缺陷状态追踪表（待修复/已修复） |

约束：
- `审查结果` 只允许 `passed`、`passed_with_notes` 或 `failed`
- 逻辑正确性检查表（3.5）必须逐项填写
- 计划外变更判定遵循严格规则：计划内/接受/需确认/回退

## 技能语义

| 技能 | 触发 | 行为 |
|------|------|------|
| `ai-flow-plan` | `/ai-flow-plan` | 生成 plan + 创建 `PLANNED` 状态 |
| `ai-flow-change` | `/ai-flow-change` | 处理需求变更，更新计划各章节，必要时 repair 到 `IMPLEMENTING` |
| `ai-flow-execute` | `/ai-flow-execute` | 只读 `current_status` 决定开始开发、继续开发或开始修复 |
| `ai-flow-review` | `/ai-flow-review` | 只允许 `AWAITING_REVIEW` 走常规审查，`DONE` 走 recheck |
| `ai-flow-status` | `/ai-flow-status` | 查看 JSON 状态分类和最近关联文档 |

### 需求变更

`/ai-flow-change` 可在以下时机使用：

| 当前状态 | 操作 |
|----------|------|
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
5. 调用 `flow-change.sh {slug}` 记录 `## 7` 审计行
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
for f in install.sh workflows/*.sh tests/*.sh tests/*.bash; do bash -n "$f" || exit 1; done
```

当前测试覆盖：

| 测试文件 | 覆盖范围 |
|----------|----------|
| `test_flow_state.sh` | 状态引擎合法/非法迁移、锁冲突、写失败保护、结构校验、repair |
| `test_plan_workflow.sh` | plan 创建后生成 `PLANNED` 状态、结构校验失败不创建状态 |
| `test_review_workflow.sh` | 常规 review、recheck、失败修复链路、严重度推导 |
| `test_flow_status.sh` | 状态展示只按 JSON 分类，不被旧报告污染 |
| `test_flow_change.sh` | 需求变更登记到计划文档 |
| `test_install.sh` | 安装流程（skills、workflows、templates 部署） |

## 兼容性说明

- 这是全量替换，不再支持从 plan/review 文件头读取状态。
- 不提供双轨状态源，不接受旧 header 作为运行时输入。
- 旧数据若要继续使用，应离线迁移或人工重建状态文件。
