# AI Flow

> 通用 AI 协作编码工作流。唯一流程状态源是 `.ai-flow/state/<slug>.json`。

## 概览

本仓库当前采用两层执行模型：

- `skills/` 负责声明触发条件、输入约束、委派目标和后续动作。
- `subagents/` 负责 plan / review 的完整执行，包括读取上下文、调用模型、落盘产物、推进状态和返回摘要协议。
- `runtime/scripts/` 只保留确定性公共能力：
  - `flow-state.sh`
  - `flow-status.sh`
  - `flow-change.sh`

稳定边界如下：

- `ai-flow-plan`、`ai-flow-plan-review`、`ai-flow-plan-coding-review` 已重构为 thin skill。
- 这三个 skill 不再暴露 `scripts/`、`prompts/`、`templates/` 公开入口。
- 多 agent 复用的执行器、prompt、template 保持在 `subagents/shared/`。
- `subagents/shared/lib/` 只放跨所有 agent 通用的 helper。
- 安装时只会把与当前角色匹配的共享子集叠加到对应 agent，不会把全部共享资产广播到所有 agent。
- plan 和 review markdown 只承担证据文档职责，不再承担状态语义。

## 当前角色分工

| 能力 | Skill 层 | Subagent / Runtime 层 |
|------|----------|-----------------------|
| Draft plan | `ai-flow-plan` 只声明委派 | `plan-executor.sh` 生成或修订 `.ai-flow/plans/*` 并创建/保持状态 |
| Plan review | `ai-flow-plan-review` 只声明委派 | `plan-review-executor.sh` 审核 plan、回写第 8 章并推进状态 |
| Coding review | `ai-flow-plan-coding-review` 只声明委派 | `coding-review-executor.sh` 生成 `.ai-flow/reports/*`、推导结果并推进状态 |
| Change | `ai-flow-change` 直接编排 | `flow-change.sh` 追加计划审计记录 |
| Status | `ai-flow-status` 直接编排 | `flow-status.sh` 只按状态 JSON 展示 |
| Plan coding | `ai-flow-plan-coding` 直接编排 | `flow-state.sh` 负责状态迁移 |

6 个 engine-specific agent 现在都使用 Claude 原生 `AGENT.md` frontmatter 作为定义入口：

- `name`
- `description`
- `tools`

运行时语义不再由 `meta.yaml` 或 `index.yaml` 提供，而是由：

- agent 名称约定推导 `codex` / `opencode`
- agent 名称约定推导 `plan` / `plan_review` / `coding_review`
- 与角色匹配的共享执行器 `bin/*.sh` 承担完整执行逻辑

## 状态机

### 状态枚举

| 状态 | 含义 |
|------|------|
| `AWAITING_PLAN_REVIEW` | draft plan 已生成，等待计划审核 |
| `PLAN_REVIEW_FAILED` | 最近一次计划审核失败，待修订 plan |
| `PLANNED` | plan 已审核通过，允许进入 plan-coding；无论第几轮最终通过都统一回到该状态 |
| `IMPLEMENTING` | 首轮开发进行中 |
| `AWAITING_REVIEW` | 开发或修复已完成，等待常规 review |
| `REVIEW_FAILED` | 最近一次 review / recheck 失败，尚未开始修复 |
| `FIXING_REVIEW` | 正在修复最近一次失败的 review |
| `DONE` | 审查已通过，或仅带 Minor 建议通过 |

补充约束：

- 状态机中不存在 `AWAITING_PLAN_CODING`
- plan 多轮审核后只要最终结果是 `passed` / `passed_with_notes`，状态都必须进入 `PLANNED`
- 真正开始编码时，再由 `ai-flow-plan-coding` 调用 `start-execute` 把 `PLANNED` 推进到 `IMPLEMENTING`

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

### 审查结果映射

`record-review` 只接受：

- `passed`
- `passed_with_notes`
- `failed`

映射规则：

- 存在 `Critical` / `Important` 缺陷，或存在阻塞性 `[待修复]` 标记：`failed`
- 仅有 `Minor` 建议：`passed_with_notes`
- 无缺陷：`passed`

状态语义只来自 `.ai-flow/state/<slug>.json`，不要再从 markdown 首行、header 或旧目录推断流程状态。

## 结果摘要协议

plan / review subagent 最终只回传固定摘要协议，不回传完整正文：

```text
RESULT: success|failed
AGENT: <name>
ARTIFACT: <path>
STATE: <status|none>
NEXT: <skill|none>
SUMMARY: <text>
```

`plan-review` 与 `coding-review` 额外返回：

```text
REVIEW_RESULT: passed|passed_with_notes|failed
```

其中：

- `ARTIFACT` 指向新生成或修订的 plan / report 路径
- `STATE` 是状态推进后的结果；adhoc review 固定为 `none`
- `NEXT` 是推荐进入的下一个 skill；没有下一步时为 `none`

## 仓库结构

```text
ai-flow/
├── install.sh
├── README.md
├── runtime/
│   └── scripts/
│       ├── flow-change.sh
│       ├── flow-state.sh
│       └── flow-status.sh
├── skills/
│   ├── ai-flow-plan/
│   │   └── SKILL.md
│   ├── ai-flow-plan-review/
│   │   └── SKILL.md
│   ├── ai-flow-plan-coding-review/
│   │   └── SKILL.md
│   ├── ai-flow-plan-coding/
│   │   └── SKILL.md
│   ├── ai-flow-change/
│   │   └── SKILL.md
│   ├── ai-flow-status/
│   │   └── SKILL.md
│   ├── ai-flow-bug-fix/
│   │   └── SKILL.md
│   └── ai-flow-code-refactor/
│       └── SKILL.md
├── subagents/
│   ├── ai-flow-codex-*/
│   │   └── AGENT.md
│   ├── ai-flow-opencode-*/
│   │   └── AGENT.md
│   └── shared/
│       ├── lib/agent-common.sh
│       ├── plan/
│       │   ├── bin/plan-executor.sh
│       │   ├── prompts/
│       │   └── templates/plan-template.md
│       ├── plan-review/
│       │   └── bin/plan-review-executor.sh
│       └── coding-review/
│           ├── bin/coding-review-executor.sh
│           ├── prompts/
│           └── templates/review-template.md
└── tests/
    ├── lib/testkit.bash
    ├── run.sh
    ├── test_install_layout.sh
    ├── test_runtime_change.sh
    ├── test_runtime_state.sh
    ├── test_runtime_status.sh
    ├── test_subagent_coding_review.sh
    ├── test_subagent_plan.sh
    └── test_subagent_plan_review.sh
```

运行时产物：

```text
.ai-flow/
├── plans/YYYYMMDD/<slug>.md
├── reports/YYYYMMDD/<slug>-review*.md
├── reports/adhoc/YYYYMMDD/*.md
└── state/<slug>.json
```

## 安装

```bash
bash install.sh
```

安装脚本会执行以下动作：

1. 安装全部 `skills/*/SKILL.md` 到 Claude 和 OneSpace skill 目录。
2. 不再安装任何 `skills/*/scripts/*`、`skills/*/prompts/*`、`skills/*/templates/*` 旧公开入口。
3. 安装 `runtime/scripts/flow-state.sh`、`flow-status.sh`、`flow-change.sh` 到 `$AI_FLOW_HOME/scripts/`。
4. 安装全部 subagent 到 Claude / OpenCode / OneSpace agents 目录。
5. 将 `subagents/shared/lib/*` 与当前角色需要的共享子集叠加到每个已安装 agent 目录。
6. 删除旧的 `~/.claude/workflows`、`~/.claude/templates` 和遗留 skill 名称 `ai-flow-execute`、`ai-flow-review`。

可自定义的环境变量：

- `CLAUDE_HOME`
- `AI_FLOW_HOME`
- `CLAUDE_AGENTS_DIR`
- `OPENCODE_AGENTS_DIR`
- `ONSPACE_SKILLS_DIR`
- `ONSPACE_SUBAGENTS_CLAUDE_DIR`
- `ONSPACE_SUBAGENTS_OPENCODE_DIR`

安装后布局：

- `~/.claude/skills/<skill>/`：skill 定义
- `$AI_FLOW_HOME/scripts/`：公共 runtime
- `~/.claude/agents/<agent>/`：`AGENT.md`、该角色所需的 `bin/`、`prompts/`、`templates/`，以及共享 `lib/`
- `~/.config/opencode/agents/<agent>/`：同上

## Runtime 契约

### `flow-state.sh`

唯一状态写入口。提供：

- `create`
- `record-plan-review`
- `start-execute`
- `finish-implementation`
- `record-review`
- `start-fix`
- `finish-fix`
- `show`
- `validate`
- `repair`
- `normalize`

特性：

- 锁保护
- 原子写入
- 写前写后结构校验
- `repair` 保持严格模式，只接受当前已合法的状态文件
- `normalize` 用于显式修复历史坏数据或非标准事件，再回到严格状态机
- `record-plan-review`、`record-review`、`repair`、`normalize` 均受测试覆盖

### `flow-status.sh`

- 只扫描 `.ai-flow/state/*.json`
- 不受旧 plan / report 文本污染
- 遇到坏 state 文件时继续展示其他合法任务，并给出 `normalize` 修复提示
- 输出每个状态的下一步 skill 映射

### `flow-change.sh`

- 通过 `slug` 找到 plan
- 向 `## 7. 需求变更记录` 追加审计记录
- 支持 `[root-cause-review-loop]` 记录
- 不直接承担状态推进，状态调整由 `flow-state.sh repair` / `normalize` 负责

## Subagent 执行面

### Plan

`bin/plan-executor.sh` 负责：

- 读取工作区、`.ai-flow` 上下文和模板资产
- 生成或修订 `.ai-flow/plans/*`
- 首次成功时创建 `AWAITING_PLAN_REVIEW`
- `PLAN_REVIEW_FAILED` 时原地修订已有 plan
- 主引擎不可用时只进行一次 fallback

### Plan Review

`bin/plan-review-executor.sh` 负责：

- 只接受 `AWAITING_PLAN_REVIEW` / `PLAN_REVIEW_FAILED`
- 执行计划审核
- 回写 plan 第 8 章审核记录
- 只能通过 `flow-state.sh record-plan-review` 推进状态，禁止手工编辑 `.ai-flow/state/*.json`
- 审核通过后统一推进到 `PLANNED`，审核失败时推进到 `PLAN_REVIEW_FAILED`

### Coding Review

`bin/coding-review-executor.sh` 负责：

- `AWAITING_REVIEW` 走 regular review
- `DONE` 走 recheck
- 无 `slug` 时走 adhoc review
- 要求存在非 `.ai-flow/` 的 Git 未提交变更
- 只能通过 `flow-state.sh record-review` 推进状态，禁止手工编辑 `.ai-flow/state/*.json`
- `failed` 推进到 `REVIEW_FAILED`
- `passed` / `passed_with_notes` 推进或保持 `DONE`
- regular 第 3 轮仍要求已有 `[root-cause-review-loop]` 审计记录

每个 agent 目录本身只靠 `AGENT.md` frontmatter 暴露定义；跨多个同类 agent 复用的 executor / prompt / template 保持在 `subagents/shared/<role>/`，安装时按角色叠加，只有通用 helper 会装到所有 agent。

## Skill 语义

| Skill | 下一步 |
|-------|--------|
| `ai-flow-plan` | 成功后进入 `ai-flow-plan-review` |
| `ai-flow-plan-review` | `passed` / `passed_with_notes` 进入 `ai-flow-plan-coding`，且状态统一落到 `PLANNED`；`failed` 返回 `ai-flow-plan` |
| `ai-flow-plan-coding` | `PLANNED` / `IMPLEMENTING` / `REVIEW_FAILED` / `FIXING_REVIEW` 执行编码或修复 |
| `ai-flow-plan-coding-review` | 绑定 `slug` 时推进流程内 review；不绑定 `slug` 时输出 adhoc 报告 |
| `ai-flow-change` | 更新 plan 正文并追加变更审计 |
| `ai-flow-status` | 展示状态分类和下一步动作 |

### 偏差分级与确认策略

- 默认不对每个 plan 偏差逐条询问用户；只在会改变决策或结果时打断确认
- 高优先级偏差需要先确认：目标、范围、优先级、验收标准、关键 tradeoff、高误改风险
- 中优先级偏差按需合并确认：实现路径明显变化但目标不变，且存在多个可行修订方向
- 低优先级偏差直接修订：措辞、结构、顺序、细化、补漏、消歧，且不改变原意

## 测试

统一入口：

```bash
bash tests/run.sh
```

测试文件与覆盖职责：

- `tests/test_runtime_state.sh`
  - 合法 / 非法状态迁移
  - `record-plan-review`、`record-review`、`repair`
  - 锁冲突与结构校验失败保护
- `tests/test_runtime_status.sh`
  - 只按 `.ai-flow/state/*.json` 分类
  - `next action` 映射
- `tests/test_runtime_change.sh`
  - 审计记录追加
  - `[root-cause-review-loop]` 记录
- `tests/test_install_layout.sh`
  - 新安装布局
  - 自定义 `AI_FLOW_HOME` / agents / OneSpace 目录
- `tests/test_subagent_plan.sh`
  - 首次 plan 生成
  - `PLAN_REVIEW_FAILED` 后原地修订
  - fallback 与缺失 runtime 错误
  - 固定摘要协议字段
- `tests/test_subagent_plan_review.sh`
  - 首轮审核失败/通过
  - `PLAN_REVIEW_FAILED` 复审通过后统一回到 `PLANNED`
  - 第 8 章审核记录回写
  - `REVIEW_RESULT` / `STATE` / `NEXT` 协议一致性
- `tests/test_subagent_coding_review.sh`
  - regular review
  - recheck
  - adhoc review
  - 无 Git 变更拒绝
  - root-cause gate
  - fallback 到 OpenCode

`tests/lib/testkit.bash` 提供新架构专用夹具和 helper：

- `installed_runtime_script`
- `installed_subagent_asset`
- `installed_subagent_executor`
- fake Codex / OpenCode
- 临时项目、Git 仓库、状态文件、计划 / 报告夹具

## 兼容性说明

- 不再支持从 plan / review markdown header 读取流程状态。
- 不再保留 `installed_skill_script` 这类旧测试假设。
- 不再安装 `skills/ai-flow-plan/scripts/*`、`skills/ai-flow-plan-review/scripts/*`、`skills/ai-flow-plan-coding-review/scripts/*`。
- 共享执行器和模板只会安装到需要它们的角色 agent，不会向所有 agent 扩散。
- `runtime/scripts/*` 仍然是唯一公共、确定性的流程脚本层。
