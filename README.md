# AI Flow

> 通用 AI 协作编码工作流系统。为 Claude Code / Codex 提供"需求 → 计划 → 审核 → 编码 → 审查"全生命周期管理，流程状态由严格状态机驱动，唯一状态源是 `.ai-flow/state/{slug}.json`。

## 目录

- [概览](#概览)
- [核心架构](#核心架构)
- [Skills 系统](#skills-系统)
- [Subagent 系统](#subagent-系统)
- [状态机](#状态机)
- [运行模式](#运行模式)
- [安装](#安装)
- [使用指南](#使用指南)
- [Runtime 脚本](#runtime-脚本)
- [执行器](#执行器)
- [测试](#测试)
- [目录结构](#目录结构)
- [HTML 阅读视图](#html-阅读视图)

---

## 概览

AI Flow 是一套结构化的 AI 编程工作流框架，解决的核心问题是：**让 AI 编码过程遵循正规软件工程流程**。

传统 AI 编程往往是"想到哪写到哪"，AI Flow 引入了强制的中间步骤：

1. **Plan（计划）**：先写实施计划，明确文件边界、步骤顺序、验收标准
2. **Plan Review（计划审核）**：审核计划是否合理，通过后才允许编码
3. **Plan Coding（编码实施）**：按计划实施代码，状态推进受状态机保护
4. **Code Optimize（代码优化）**：在既有架构内完成可读性、安全性和可维护性优化
5. **Coding Review（代码审查）**：审查代码是否符合计划和质量标准

整个流程由 **12 个 Skill** + **Claude Code agent bundle** + **Codex native custom agent** + **Runtime 脚本** + **共享执行器** 协作完成。

项目级规则来源支持 repo-local `.ai-flow/rule.yaml`。该文件只在 AI Flow 内生效，不影响普通 Codex / Claude 会话；当前已接入 plan、plan-review、coding-review 的 prompt 注入与核心硬校验，并已在 `flow-change.sh`、`flow-plan-coding.sh`、`flow-bug-fix.sh`、`flow-code-optimize.sh`、`flow-code-refactor.sh` 中接入 direct runtime 的基础门禁。

**关键设计原则：**

- **状态与文档分离**：状态只由 JSON 文件承担，plan/review markdown 只做证据文档
- **原子写入 + 锁保护**：所有状态修改通过 `flow-state.sh` 严格保护
- **Thin Skill 架构**：plan/review 类 skill 只做委派声明，执行逻辑集中在共享执行器
- **双宿主分流**：Claude Code 宿主保留 Codex executor → Claude fallback 链路；Codex 宿主使用 native custom agent
- **HARD-GATE**：Claude Code 内的 Codex executor agent 必须通过共享执行器；Codex native agent 禁止调用 `codex exec` 或外部模型 CLI

---

## 核心架构

```
用户指令 → Skill 层（触发/委派/编排）
              ↓
         Agent 层（Claude Code subagent 或 Codex native custom agent）
              ↓
         Runtime 层（状态/变更/查询）
              ↓
         .ai-flow/state/*.json（唯一状态源）
```

**三层职责：**

| 层级 | 组件 | 职责 |
|------|------|------|
| **Skill 层** | `skills/*/SKILL.md` | 声明触发条件、输入约束、委派目标、后续动作 |
| **Agent 层** | `subagents/*/AGENT.md`、`codex/agents/*.toml` | 读取上下文、落盘产物、推进状态、返回摘要协议 |
| **Runtime 层** | `runtime/scripts/*.sh` | 确定性公共能力：状态读写、变更审计、状态展示 |

**Thin Skill vs 直接编排 Skill：**

- `ai-flow-plan`、`ai-flow-plan-review`、`ai-flow-plan-coding-review` → **Thin Skill**（只委派给 subagent）
- `ai-flow-plan-coding`、`ai-flow-auto-run`、`ai-flow-code-optimize`、`ai-flow-change`、`ai-flow-status`、`ai-flow-bug-fix`、`ai-flow-code-refactor` → **直接编排**（skill 层直接编排 runtime 脚本）
- `ai-flow-git-commit` → **直接编排**（skill 层通过提示词直接驱动 git pull → 冲突辅助处理 → add → commit 全流程，不再依赖 runtime 脚本或 subagent）
- `ai-flow-plan-summary` → **只读总结**（纯展示，不修改任何文件）

---

## Skills 系统

共 11 个 Skill，每个是一个目录含 `SKILL.md`：

| Skill | 文件 | 类型 | 职责 |
|-------|------|------|------|
| `ai-flow-plan` | `skills/ai-flow-plan/SKILL.md` | Thin | 生成或修订 draft plan，委派给 subagent 执行 |
| `ai-flow-plan-review` | `skills/ai-flow-plan-review/SKILL.md` | Thin | 审核 draft plan，委派给 plan-review subagent |
| `ai-flow-plan-coding-review` | `skills/ai-flow-plan-coding-review/SKILL.md` | Thin | 审查代码改动，委派给 coding-review subagent |
| `ai-flow-plan-coding` | `skills/ai-flow-plan-coding/SKILL.md` | 编排 | 按状态机执行计划内编码或修复（最复杂的 skill） |
| `ai-flow-auto-run` | `skills/ai-flow-auto-run/SKILL.md` | 编排 | 在 `PLANNED` 到 `DONE` 区间自动闭环推进 coding、review 与按路由修复 |
| `ai-flow-code-optimize` | `skills/ai-flow-code-optimize/SKILL.md` | 编排 | 在既有架构内执行代码优化，作为编码后的强制优化关与优化类 review 修复入口 |
| `ai-flow-change` | `skills/ai-flow-change/SKILL.md` | 编排 | 处理需求变更，增量编辑 plan 并记录变更审计 |
| `ai-flow-status` | `skills/ai-flow-status/SKILL.md` | 编排 | 查看所有流程状态和下一步动作 |
| `ai-flow-plan-summary` | `skills/ai-flow-plan-summary/SKILL.md` | 只读 | 总结流程完整生命周期，含实施变动与统计 |
| `ai-flow-bug-fix` | `skills/ai-flow-bug-fix/SKILL.md` | 编排 | 独立缺陷修复，可绑定 slug 或独立运行 |
| `ai-flow-code-refactor` | `skills/ai-flow-code-refactor/SKILL.md` | 编排 | 重构类改动，可绑定 slug 或独立运行 |
| `ai-flow-git-commit` | `skills/ai-flow-git-commit/SKILL.md` | 编排 | 在 `DONE` 后按仓库依赖顺序和业务关联性拆分提交代码，通过提示词直接驱动 git 提交流程 |

---

## Agent 系统

目录分工保持为“共享入口 + 宿主专属 agent”：
- `skills/`：Claude Code 与 Codex 共同使用的 thin skill / 编排 skill 定义，不按宿主拆分。
- `subagents/`：Claude Code 可识别的 `AGENT.md` bundle；其中 `ai-flow-codex-*` 是 Claude Code 宿主里的 Codex executor 链路，不是 Codex native agent。
- `codex/agents/`：Codex native custom agent 源文件，安装到 `$CODEX_HOME/agents/*.toml`。
- `runtime/` 与 `subagents/shared/`：两端复用的确定性脚本、模板和校验资产。

### Claude Code agent bundle（6 个）

每个 agent 由 `AGENT.md` 定义（Claude 原生 frontmatter 格式），按执行链路分为 Codex executor 和 Claude native 两组：

| Agent | 文件 | 引擎 | 角色 |
|-------|------|------|------|
| `ai-flow-codex-plan` | `subagents/ai-flow-codex-plan/AGENT.md` | Codex executor | Plan 生成（Claude Code 宿主中通过共享执行器调用 Codex） |
| `ai-flow-claude-plan` | `subagents/ai-flow-claude-plan/AGENT.md` | Claude | Plan 生成（直接执行） |
| `ai-flow-codex-plan-review` | `subagents/ai-flow-codex-plan-review/AGENT.md` | Codex executor | Plan 审核（Claude Code 宿主中通过共享执行器调用 Codex） |
| `ai-flow-claude-plan-review` | `subagents/ai-flow-claude-plan-review/AGENT.md` | Claude | Plan 审核（直接执行） |
| `ai-flow-codex-plan-coding-review` | `subagents/ai-flow-codex-plan-coding-review/AGENT.md` | Codex executor | Code 审查（Claude Code 宿主中通过共享执行器调用 Codex） |
| `ai-flow-claude-plan-coding-review` | `subagents/ai-flow-claude-plan-coding-review/AGENT.md` | Claude | Code 审查（直接执行） |

**Claude Code 宿主中的 Codex executor vs Claude 区别：**
- Codex executor agent 通过 **HARD-GATE** 强制运行共享执行器脚本，由执行器调用 `codex exec`
- Claude agent 直接使用 Claude Code 内置能力完成工作
- `engine_mode=auto` 时 Codex executor 不可用会自动降级到对应的 Claude agent

### Codex native custom agents（3 个）

Codex 宿主使用 `codex/agents/*.toml`，安装到 `$CODEX_HOME/agents/*.toml`。这些 agent 在 Codex 内原生 spawn，不通过 `codex exec` 模拟 subagent。

| Agent | 文件 | 角色 |
|-------|------|------|
| `ai-flow-codex-plan` | `codex/agents/ai-flow-codex-plan.toml` | Plan 生成或修订 |
| `ai-flow-codex-plan-review` | `codex/agents/ai-flow-codex-plan-review.toml` | Plan 审核 |
| `ai-flow-codex-plan-coding-review` | `codex/agents/ai-flow-codex-plan-coding-review.toml` | Code 审查 |

Codex native agent 未注册时不会回退到 `codex exec`；请重新运行 `bash install.sh` 并重启 Codex。

### Shared 共享资产

位于 `subagents/shared/`：

| 路径 | 文件 | 职责 |
|------|------|------|
| `lib/agent-common.sh` | 通用 helper | 引擎推导、角色推导、默认模型选择、协议输出 |
| `lib/config-loader.sh` | 配置加载器 | 从 `setting.json` 加载引擎模型和推理强度配置 |
| `plan/bin/plan-executor.sh` | Plan 执行器（1738 行） | 生成/修订 plan、状态创建、引擎 fallback |
| `plan/prompts/` | Plan 提示词 | generation、review、revision 三种 prompt |
| `plan/templates/plan-template.md` | Plan 模板 | 8 章标准计划模板 |
| `plan-review/bin/plan-review-executor.sh` | Plan 审核执行器 | 审核 plan、回写第 8 章、推进状态；不生成独立报告文件 |
| `coding-review/bin/coding-review-executor.sh` | 代码审查执行器（1619 行） | 生成 review 报告、缺陷推导、状态推进 |
| `coding-review/prompts/review-generation.md` | 审查提示词 | 审查报告生成 |
| `coding-review/templates/review-template.md` | 审查模板 | 6 章标准审查报告模板 |
| `setting.json.template` | 配置模板 | 各阶段引擎模型和推理强度的默认配置 |

---

## 状态机

### 状态枚举（8 个）

| 状态 | 含义 |
|------|------|
| `AWAITING_PLAN_REVIEW` | Draft plan 已生成，等待计划审核 |
| `PLAN_REVIEW_FAILED` | 最近一次计划审核失败，待修订 plan |
| `PLANNED` | Plan 已审核通过，允许进入编码 |
| `IMPLEMENTING` | 首轮开发进行中 |
| `AWAITING_REVIEW` | 开发或修复已完成，等待常规 review |
| `REVIEW_FAILED` | 最近一次 review / recheck 失败，尚未开始修复 |
| `FIXING_REVIEW` | 正在修复最近一次失败的 review |
| `DONE` | 审查已通过，或仅带 Minor 建议通过 |

### 允许迁移

| From | Event | To |
|------|-------|----|
| `null` | `plan_created` | `AWAITING_PLAN_REVIEW` |
| `AWAITING_PLAN_REVIEW` | `plan_review_failed` | `PLAN_REVIEW_FAILED` |
| `PLAN_REVIEW_FAILED` | `plan_reopened` | `AWAITING_PLAN_REVIEW` |
| `AWAITING_PLAN_REVIEW` | `plan_review_passed` | `PLANNED` |
| `PLANNED` | `execute_started` | `IMPLEMENTING` |
| `IMPLEMENTING` | `implementation_completed` | `AWAITING_REVIEW` |
| `AWAITING_REVIEW` | `review_passed` | `DONE` |
| `AWAITING_REVIEW` | `review_failed` | `REVIEW_FAILED` |
| `REVIEW_FAILED` | `fix_started` | `FIXING_REVIEW` |
| `FIXING_REVIEW` | `fix_completed` | `AWAITING_REVIEW` |
| `DONE` | `recheck_passed` | `DONE` |
| `DONE` | `recheck_failed` | `REVIEW_FAILED` |
| `PLANNED` | `plan_reopened` | `AWAITING_PLAN_REVIEW` |
| `IMPLEMENTING` | `plan_reopened` | `AWAITING_PLAN_REVIEW` |
| `AWAITING_REVIEW` | `implementation_reopened` | `IMPLEMENTING` |
| `DONE` | `implementation_reopened` | `IMPLEMENTING` |
| `REVIEW_FAILED` | `implementation_reopened` | `IMPLEMENTING` |
| `FIXING_REVIEW` | `implementation_reopened` | `IMPLEMENTING` |

### 审查结果映射

`review_*` / `recheck_*` 只接受三种结果：

| 场景 | 结果 |
|------|------|
| 存在 `Critical` / `Important` 缺陷，或阻塞性 `[待修复]` 标记 | `failed` |
| 仅有 `Minor` 建议 | `passed_with_notes` |
| 无缺陷 | `passed` |

---

## 运行模式

### 单仓模式

**适用场景：** 一个功能只修改一个 Git 仓库

**运行约束：**
- 在目标 Git 仓库根目录运行
- `.ai-flow/` 落在仓库根目录下
- 状态 schema 使用统一执行范围模型；单仓等价于只有一个 repo 的 scope：`repos = [{ "id": "root", "path": "." }]`

**推荐步骤：**
1. 进入目标 Git 仓库根目录
2. 运行 `ai-flow-status` 确认当前待办
3. 运行 `ai-flow-plan` 生成或修订 plan
4. 运行 `ai-flow-plan-review` 审核 plan
5. 运行 `ai-flow-plan-coding` 实施代码
6. 运行 `ai-flow-code-optimize` 在既有架构内完成代码优化；无论是否绑定 `slug`，若请求可拆为多个优化点，都应先列出带优先级的候选项并由用户选择
7. 如需求变化，运行 `ai-flow-change` 更新 plan
8. 运行 `ai-flow-plan-coding-review` 完成 review / recheck

### 多仓模式（plan_repos）

**适用场景：** 一个功能同时修改多个 Git 仓库

**运行机制：**
- 在 owner repo 的 Git 根目录运行 `ai-flow-plan`
- Plan 文件中 `2.1 仓库范围表` 和 `2.5 跨仓依赖表` 声明参与 repo
- 所有 plan / report / state 统一落在 owner repo 的 `.ai-flow/` 下
- `execution_scope` 固定为 `mode: "plan_repos"`，包含 owner 和 participant repos

**推荐步骤：**
1. 在 owner repo 中运行 `ai-flow-plan` 生成跨仓 plan
2. 运行 `ai-flow-plan-review` 审核跨仓边界与依赖
3. 运行 `ai-flow-plan-coding`，按 plan 修改多个 repo
4. 运行 `ai-flow-code-optimize`，在不突破既有边界的前提下收敛优化；无论是否绑定 `slug`，若请求可拆为多个优化点，都应先输出带优先级的候选优化项 table 供用户选择，完成后继续以结果 table 汇总状态
5. 运行 `ai-flow-plan-coding-review`，聚合多 repo 变更完成 review

---

## 安装

```bash
bash install.sh
```

### 安装提示词

复制下面这段提示词给 `Claude Code`，即可让它直接把 AI Flow 安装到当前机器：

```text
你现在运行在 Claude Code 中。请直接使用本地终端安装 AI Flow，不要只给我步骤说明。

要求：
1. 先检查当前环境是否可用：确认 `git` 和 `bash` 存在。
2. 先用终端命令检查本地是否已经安装过 ai-flow 系列插件、subagent 和 runtime，不要凭猜测判断。至少检查：
   - `~/.claude/skills/` 下是否已有 `ai-flow-*` 目录
   - `~/.claude/agents/` 下是否已有 `ai-flow-*` 目录
   - `~/.config/ai-flow/scripts/` 是否存在
3. 如果本地未安装或安装不完整，再执行 `git clone https://github.com/hengboy/ai-flow.git` 获取仓库；如果当前工作区已经是该仓库，就直接复用当前仓库，不要重复 clone。
4. 进入 `ai-flow` 目录后执行 `bash install.sh`。
5. 安装完成后，全面检查安装结果，并以 Markdown 表格明确展示每一项是否成功，至少包括：
   - `~/.claude/skills/` 下全部 12 个 `ai-flow-*` skill 目录
   - `~/.claude/agents/` 下全部 7 个 `ai-flow-*` subagent 目录
   - `~/.config/ai-flow/scripts/` 下全部 9 个 runtime 脚本
   - `~/.config/ai-flow/setting.json`
   - `~/.config/ai-flow/rule.yaml`
   - `~/.claude/CLAUDE.md` 是否已同步 AI Flow 行为准则
   - 如果本机存在 OneSpace 目录，也一并检查 OneSpace 下的 skills 和 subagents 是否同步完成
6. 如果安装失败，直接继续排查并修复，直到给出明确的失败原因或安装成功结论。
7. 全程使用中文汇报，且优先执行命令，不要停留在建议阶段。
8. 安装成功后，补充告诉我下一步可以在 Claude Code 中执行的示例命令，例如 `/ai-flow-status`。
```

**安装脚本执行：**
1. 删除各目标目录中旧安装的 `ai-flow-*` 文件和遗留条目，保留用户其他 skill/agent
2. 安装全部 `skills/*/SKILL.md` 到 Claude、Codex official、Codex compatibility 和 OneSpace 目录
3. 安装 `runtime/scripts/` 到 `$AI_FLOW_HOME/scripts/`
4. 安装 Claude Code `AGENT.md` bundle 到 `~/.claude/agents/` 和 OneSpace Claude 目录
5. 安装 Codex native TOML agents 到 `$CODEX_HOME/agents/*.toml` 和 OneSpace Codex 目录
6. 将 `subagents/shared/lib/*` 与角色匹配的共享子集叠加到每个 Claude Code agent bundle
7. 同步 `CLAUDE.md` 行为准则到 `~/.claude/CLAUDE.md`，并用 marker 追加到 `$CODEX_HOME/AGENTS.md`

Codex 在会话启动时读取 custom agents 与 `AGENTS.md`。安装或更新 Codex agent 后，请重启 Codex 或开启新会话。

**安装后目录布局：**
```
~/.claude/skills/<skill>/          # Skill 定义
$HOME/.agents/skills/<skill>/      # Codex official Skill 定义
$CODEX_HOME/skills/<skill>/        # Codex compatibility Skill 定义
$AI_FLOW_HOME/scripts/             # 公共 runtime 脚本
~/.claude/agents/<agent>/          # AGENT.md + bin/ + prompts/ + templates/ + lib/
$CODEX_HOME/agents/<agent>.toml    # Codex native custom agent
```

**可自定义的环境变量：**
| 变量 | 用途 | 默认值 |
|------|------|--------|
| `CLAUDE_HOME` | Claude 配置根目录，Skill 和 CLAUDE.md 安装路径的基准 | `~/.claude` |
| `AI_FLOW_HOME` | Runtime 脚本安装目录（flow-state.sh / flow-status.sh 等） | `~/.config/ai-flow` |
| `CLAUDE_AGENTS_DIR` | Subagent 安装目录（AGENT.md + bin/ + prompts/ + templates/） | `~/.claude/agents` |
| `CODEX_HOME` | Codex 配置根目录，AGENTS.md 和 native agent 安装路径的基准 | `~/.codex` |
| `CODEX_AGENTS_DIR` | Codex native custom agent 安装目录（*.toml） | `$CODEX_HOME/agents` |
| `CODEX_SKILLS_DIR` | Codex official Skill 安装目录 | `$HOME/.agents/skills` |
| `CODEX_LEGACY_SKILLS_DIR` | Codex compatibility Skill 安装目录 | `$CODEX_HOME/skills` |
| `ONSPACE_DIR` | OneSpace 配置根目录，未单独指定 OneSpace 子路径时作为派生根 | `~/.config/onespace` |
| `ONSPACE_SKILLS_DIR` | OneSpace 平台的 Claude Skill 安装目录 | `$ONSPACE_DIR/skills/local_state/models/claude` |
| `ONSPACE_SUBAGENTS_CLAUDE_DIR` | OneSpace 平台的 Claude Subagent 安装目录 | `$ONSPACE_DIR/subagents/local_state/models/claude` |
| `ONSPACE_SKILLS_CODEX_DIR` | OneSpace 平台的 Codex Skill 安装目录 | `$ONSPACE_DIR/skills/local_state/models/codex` |
| `ONSPACE_SUBAGENTS_CODEX_DIR` | OneSpace 平台的 Codex native agent 安装目录 | `$ONSPACE_DIR/subagents/local_state/models/codex` |

使用示例：
```bash
# 自定义 runtime 脚本安装位置
AI_FLOW_HOME=/opt/ai-flow bash install.sh

# 自定义所有安装路径
CLAUDE_HOME=/custom/.claude \
AI_FLOW_HOME=/opt/ai-flow \
CLAUDE_AGENTS_DIR=/opt/ai-flow/agents \
CODEX_HOME=/custom/.codex \
bash install.sh
```

### 配置

AI Flow 采用双层配置体系：用户级 `~/.config/ai-flow/setting.json` 为全局默认，项目级 `<flow-root>/.ai-flow/setting.json` 覆盖项目特定设置。

**配置优先级**：项目级 > 用户级 > 代码内默认。

**flow root 定位**：从当前工作目录向上查找 `.ai-flow/state`，找到即确定 flow root；在 git 仓库中但无 `.ai-flow/state` 时回退到 git toplevel；否则使用当前工作目录。

**合并规则**：
- 字典字段递归合并（项目级未设置的字段继承用户级）
- 标量字段项目级覆盖用户级
- 数组字段项目级整体替换用户级
- `null` 值视为未设置，不删除用户级已有字段

安装脚本会在首次安装时自动创建用户级默认配置。配置模板位于 `subagents/shared/setting.json.template`。

```json
{
  "version": 1,
  "engine_mode": "auto",
  "plan": {
    "codex": { "model": "gpt-5.4", "reasoning": "high" },
    "claude": { "model": "opus", "reasoning": "high" }
  },
  "plan_review": {
    "codex": { "model": "gpt-5.4", "reasoning": "high" },
    "claude": { "model": "opus", "reasoning": "high" }
  },
  "coding_review": {
    "codex": { "model": "gpt-5.4", "reasoning": "high" },
    "claude": { "model": "opus", "reasoning": "high" }
  },
  "state": {
    "actor": "flow-state.sh"
  }
}
```

| 配置项 | 用途 | 默认值 | 说明 |
|--------|------|--------|------|
| `engine_mode` | 强制指定执行引擎 | `auto` | Claude Code 宿主：`auto` 先走 Codex executor，失败后降级 Claude；Codex 宿主：`auto`/`codex` 走 Codex native subagent，`claude` 直接失败并提示切换宿主或改配置 |
| `plan.codex.model` | Plan 阶段 Codex 模型 | `gpt-5.4` | 按执行步骤独立配置 |
| `plan.claude.model` | Plan 阶段 Claude 模型 | `opus` | 按执行步骤独立配置 |
| `plan_review.*` | Plan 审核阶段配置 | 同上 | 按引擎分别配置模型和推理强度 |
| `coding_review.*` | 代码审查阶段配置 | 同上 | 按引擎分别配置模型和推理强度 |
| `state.actor` | 状态变更操作者 | `flow-state.sh` | 审计追踪用，也受项目级配置覆盖 |

**示例**：项目级配置只覆盖 `state.actor`：

```json
{
  "state": {
    "actor": "my-project-actor"
  }
}
```

修改 `setting.json` 后立即生效，无需重启。

### 双宿主执行语义

- 在 Claude Code 中，`engine_mode=auto` 会先委派到 `subagents/ai-flow-codex-*`，由共享执行器调用外部 Codex；Codex 不可用时再降级到 `ai-flow-claude-*`。
- 在 Codex 中，`engine_mode=auto` 和 `engine_mode=codex` 会 spawn `$CODEX_HOME/agents/ai-flow-codex-*.toml` native subagent；不会调用 `codex exec`。
- 在 Codex 中，`engine_mode=claude` 是明确配置错误：请切换到 Claude Code，或将配置改为 `auto` / `codex`。
- “Codex via executor” 只适用于 Claude Code 宿主中的外部 Codex 路径。

---

## 使用指南

### 标准流程

```bash
# 1. 生成实施计划
/ai-flow-plan <slug> "需求描述"

# 2. 审核计划
/ai-flow-plan-review <slug>

# 3. 按计划编码
/ai-flow-plan-coding <slug>

# 4. 在既有架构内完成优化
/ai-flow-code-optimize <slug> "优化描述"

# 5. 审查代码
/ai-flow-plan-coding-review <slug>

# 可选：自动从 coding/review 闭环推进到 DONE
/ai-flow-auto-run <slug或唯一关键词>

# 6. 在 DONE 后提交代码
/ai-flow-git-commit <slug>
```

其中 `<slug>` 是流程的唯一标识符，格式为小写字母 + 数字 + 连字符（如 `user-auth-refactor`），会作为 `.ai-flow/state/{slug}.json` 文件名。`/ai-flow-plan` 不传 slug 时会自动生成；其他流程步骤不传 slug 时会列出现有流程供选择，最终调用 subagent 时必须带明确 slug。

`/ai-flow-auto-run` 是可选的一键推进入口，只负责把已通过 plan-review 的 flow 从 `PLANNED` / `IMPLEMENTING` / `AWAITING_REVIEW` / `REVIEW_FAILED` / `FIXING_REVIEW` / `DONE` 自动闭环推进到 `DONE`。无参数时必须先列出候选并等待用户明确选择，即使只有一个候选也不自动代选。该入口不会替代现有分步 skill，也不会自动执行 `/ai-flow-git-commit`。

`/ai-flow-plan-coding` 执行编码或 review 修复时，必须主动识别本次触达范围内的硬编码；状态值、类型值、配置项、路径、命令名、错误码、固定文案、魔法数字等应优先复用或补充现有枚举/常量，不存在合适定义时再抽取为语义明确的新枚举或常量，避免新增或扩散硬编码。

`/ai-flow-code-optimize` 支持绑定 `slug` 和不带 `slug` 独立运行。独立模式下既支持按文件/目录/关注点缩小范围，也支持用户显式授权“扫描整个项目”；全仓模式只允许先做候选项扫描并输出 table，不得直接改代码。两种模式下，只要请求可拆为多个优化点，技能都必须先输出合并后的候选优化项 table，按 `P1`/`P2`/`P3` 区分优先级，并让用户选择“全部优化”或按序号执行部分优化。优化完成后仍需继续用 table 汇总执行结果，并新增 `完成状态` 列：成功显示 `✅`，失败显示 `❌`。绑定 `slug` 且处于 review 修复场景时，阻塞缺陷对应项必须标记为必选，不能跳过。

### 查看状态

```bash
/ai-flow-status
```

展示所有活跃流程的当前状态和下一步动作。

### 处理变更

```bash
/ai-flow-change <slug> "变更描述"
```

按当前状态修订 plan，并向 `## 7. 需求变更记录` 追加审计记录；必要时通过 `plan_reopened` 或 `implementation_reopened` 调整流程状态。

### 独立修复 / 重构

```bash
/ai-flow-bug-fix "修复描述"
/ai-flow-code-optimize "优化描述"
/ai-flow-code-refactor "重构描述"
```

不绑定 slug 时可独立运行，不写 AI Flow 状态。`/ai-flow-code-refactor` 必须主动治理本次触达范围内的硬编码：优先复用或更新已有枚举/常量，不存在合适定义时再抽取新的枚举或常量。

### 查看流程摘要

```bash
/ai-flow-plan-summary <slug>
```

只读总结流程的完整生命周期，含实施变动、Review 历史与统计。

### DONE 后提交代码

```bash
/ai-flow-git-commit <slug>
```

- 仅当状态为 `DONE` 时允许绑定 slug 提交
- 只有显式传入 `slug` 时才绑定 plan；未显式提供 `slug` 时一律走独立提交模式，不扫描、不检索 `.ai-flow/state` 候选列表
- 多仓 plan 会优先按 plan 的跨仓依赖表排序；未声明依赖表时回退到 `execution_scope.repos` 顺序
- 每个仓库内部按业务关联性或改动关联性拆分多个 commit，而不是按目录机械拆分或整仓一次提交
- 提交前自动暂存本地变更、同步远程最新代码、恢复本地改动，并在每个 commit 前生成符合规范的 commit message
- 不再依赖 runtime 脚本或 subagent，全流程由 skill 通过提示词驱动

### DONE 后独立处理 Minor 建议

如果某个 plan 已经处于 `DONE`，但你仍想独立处理 review 留下的 Minor 建议，推荐链路是：

```bash
/ai-flow-code-optimize "优化描述"
# 或
/ai-flow-bug-fix "修复描述"

/ai-flow-plan-coding-review --standalone
/ai-flow-git-commit
```

- 这条链路不重新绑定原 `DONE` plan
- review 阶段使用 `standalone review`
- commit 阶段使用无 `slug` 的独立提交模式

### 结果摘要协议

除 subagent 完成后都返回统一协议。该协议用于 skill/subagent 间解析、状态推进和自动化汇总，不是面向用户的主要阅读内容；最终给用户的回复应优先使用自然语言摘要和下一步提示，除非用户明确要求查看协议字段，否则不直接暴露协议块。

注意：当前 plan / review / commit 执行器、运行时脚本与测试都直接从命令输出中解析这些协议字段。因此可以在用户最终展示层隐藏协议块，但不能直接移除或隐藏命令输出里的协议字段；若要改动命令输出，必须先同步调整解析链路与测试。

统一协议的基础字段如下；具体 skill 可在此基础上补充额外字段，但必须在各自文档中显式声明。当前 `ai-flow-code-optimize` 额外补充 `SCOPE: bound|standalone`，并固定输出 `ARTIFACT: none`；当 `RESULT: partial` 时同样必须输出 `INCOMPLETE`。

```text
RESULT: success|failed|degraded|partial
AGENT: <name>
ARTIFACT: <path|none>
STATE: <status|none>
NEXT: <skill|none>
REVIEW_RESULT: passed|passed_with_notes|failed  (仅 review 类型)
SUMMARY: <one-line-summary>
INCOMPLETE: <text>  (仅 partial 时)
```

---

## Runtime 脚本

位于 `runtime/scripts/`，公共状态脚本已统一为 v4 接口：

### `flow-state.sh`

**唯一状态入口。** 只提供子命令：

| 子命令 | 职责 |
|--------|------|
| `transition` | 唯一写入口 |
| `show` | 展示状态详情或派生视图 |
| `validate` | 校验状态合法性 |

**特性：**
- 锁保护（`.ai-flow/state/.locks/`）
- 原子写入
- 写前写后结构校验
- Schema version 4

### 状态 JSON 字段（schema v4）

磁盘状态文件 `.ai-flow/state/{slug}.json` 固定字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `schema_version` | number | 固定为 4 |
| `slug` | string | 流程唯一标识（完整 dated slug） |
| `title` | string | 流程标题 |
| `plan_file` | string | 关联的 plan markdown 路径 |
| `execution_scope` | object | 执行范围（`mode: "plan_repos"`、`repos` 数组） |
| `current_status` | string | 当前状态，8 个枚举值之一 |
| `created_at` | string | 创建时间（ISO 8601） |
| `updated_at` | string | 最后更新时间（ISO 8601） |
| `transitions` | array | 状态迁移历史数组（含 `event`、`from`、`to`、`at`、`payload`） |

`show` 默认返回物化视图，并额外暴露：

- `derived.review_rounds`
- `derived.latest_regular_review_file`
- `derived.latest_recheck_review_file`
- `derived.last_review`
- `derived.active_fix`
- `derived.next_events`

### `flow-status.sh`（207 行）

只读状态扫描：
- 扫描 `.ai-flow/state/*.json` 按 `current_status` 分类展示
- 展示执行范围信息（plan_repos 模式、参与 repo 数量）
- 遇到坏 state 文件继续展示其他合法任务
- 输出每个状态的下一步 skill 映射

### `flow-auto-run.sh`

只读自动编排辅助脚本：
- `list`：列出当前 flow root 下可自动编排的候选 state
- `list` 默认只列进行中的 flow；`DONE` 仅在存在未提交且需 recheck 的改动时才进入候选
- `resolve <slug或唯一关键词>`：解析为唯一完整 slug；0 个或多个匹配都失败
- `dirty <slug>`：按 `execution_scope.repos` 检查是否仍有需要 recheck 的未提交代码变更

该脚本只负责选择与判定，不直接实施代码，也不会调用任何 `flow-state.sh` 写命令。

### `flow-change.sh`（153 行）

需求变更审计：
- 通过 `slug` 找到 plan
- 向 `## 7. 需求变更记录` 追加审计记录
- 支持 `[root-cause-review-loop]` 特殊标记
- 不直接承担状态推进

### `flow-plan-coding.sh`

执行前统一门禁：
- 通过 `slug` 找到 plan 与 state
- 对 `PLANNED` / `REVIEW_FAILED` 执行统一状态推进
- 在真正开始编码前执行 `rule.yaml` 门禁
- 当前硬化的 direct runtime 约束包括：`required_reads`、`protected_paths`、`forbidden_changes`

### `flow-bug-fix.sh`

缺陷修复绑定入口：
- 绑定 `slug` 时复用 `flow-plan-coding.sh`
- 统一执行状态门禁与执行前规则校验

### `flow-code-optimize.sh`

代码优化绑定入口：
- 通过 `slug` 找到 state
- 允许 `AWAITING_REVIEW` 无状态推进进入优化
- 仅当最近失败报告的全部阻塞缺陷都路由到 `ai-flow-code-optimize` 时，才允许从 `REVIEW_FAILED` 进入 `FIXING_REVIEW`
- 执行前执行 `rule.yaml` 的 `required_reads` 门禁

### `flow-code-refactor.sh`

重构绑定入口：
- 绑定 `slug` 时复用 `flow-plan-coding.sh`
- 统一执行状态门禁与执行前规则校验
- skill 执行层必须治理本次触达范围内的硬编码，优先复用或更新已有枚举/常量，不存在合适定义时再抽取新的枚举或常量

### `flow-suggest-slug.sh`

智能 slug 建议脚本，基于需求描述自动生成符合规范的 slug。

### `flow-html.sh`

HTML 渲染脚本，将 Plan/Review/状态文件渲染为浏览器可读的静态页面。

---

## 执行器

### Plan 执行器（`subagents/shared/plan/bin/plan-executor.sh`，1738 行）

- 读取 `.ai-flow` 上下文和模板资产
- 生成或修订 `.ai-flow/plans/*`
- 首次成功时创建 `AWAITING_PLAN_REVIEW`
- `PLAN_REVIEW_FAILED` 时原地修订已有 plan，修订成功后自动推进回 `AWAITING_PLAN_REVIEW`
- 主引擎不可用时只进行一次 fallback
- 模型选择由执行器依据当前 agent、默认环境变量和 fallback 规则决定

### Plan Review 执行器（`subagents/shared/plan-review/bin/plan-review-executor.sh`）

- 只接受 `AWAITING_PLAN_REVIEW`
- 执行计划审核
- 回写 plan 第 8 章审核记录
- 只能通过 `flow-state.sh transition --event plan_review_passed|plan_review_failed` 推进状态
- 审核通过后统一推进到 `PLANNED`

### Coding Review 执行器（`subagents/shared/coding-review/bin/coding-review-executor.sh`，1619 行）

- `AWAITING_REVIEW` 走 regular review
- `DONE` 走 recheck（审查后状态仍是 `DONE` 或降级到 `REVIEW_FAILED`）
- 显式 `--standalone` 时走 standalone review；未显式指定时仍优先按 state 自动绑定，只有 0 个状态文件时才回落到 standalone review（不推进状态，`STATE` 固定为 `none`），报告写入 `.ai-flow/reports/standalone/{YYYYMMDD}-standalone-review-{N}.md`
- standalone 审查通过（`passed` / `passed_with_notes`）时，`NEXT` 显式返回 `ai-flow-git-commit`，用于引导无 `slug` 的独立提交链路
- 要求存在非 `.ai-flow/` 的 Git 未提交变更
- 缺陷严重度推导：Critical / Important / Minor
- 审查报告中的阻塞缺陷必须声明 `修复流向`：`ai-flow-plan-coding` 或 `ai-flow-code-optimize`
- 当 failed 且全部阻塞缺陷都路由到 `ai-flow-code-optimize` 时，下一步回 optimize；只要混入任一 `ai-flow-plan-coding` 阻塞缺陷，就统一回 coding
- 只能通过 `flow-state.sh transition --event review_passed|review_failed|recheck_passed|recheck_failed` 推进状态
- 审查 `mode` 取值：`regular`（常规审查）、`recheck`（DONE 状态复验）、`standalone`（独立审查）
- 审查 `result` 取值：`passed`、`passed_with_notes`、`failed`
- regular 第 3 轮仍失败时，要求已有 `[root-cause-review-loop]` 审计记录才允许继续
- 当前已硬化的 rule.yaml review 约束包括：`required_reads`、`protected_paths`、`forbidden_changes`、`test_policy.require_tests_for_code_change`、`review.required_evidence`
- `review.severity_rules` 与 `review.fail_conditions` 当前已接入 `missing_tests_when_required` 的结果推导；`protected_paths`、`forbidden_changes`、缺失 `required_reads` 仍走执行前硬失败，不经过报告后置映射

---

## 测试

**统一入口：**
```bash
bash tests/run.sh
```

**测试覆盖：**

| 测试文件 | 覆盖内容 |
|----------|----------|
| `tests/run.sh` | 统一测试入口 |
| `tests/lib/testkit.bash` | Shell 测试夹具 |
| `tests/lib/fixtures.py` | Python 测试夹具 |
| `tests/test_install_layout.sh` | 安装后目录布局、自定义路径 |
| `tests/test_flow_status.sh` | 状态分类、next action 映射 |
| `tests/test_flow_state_cli.py` | Python 状态机内核 |
| `tests/test_flow_config.py` | 配置加载 |
| `tests/test_flow_html.py` | HTML 渲染 |
| `tests/test_runtime_html.sh` | HTML runtime |
| `tests/test_flow_change.sh` | 变更审计 |
| `tests/test_flow_plan_coding.sh` | plan-coding 门禁 |
| `tests/test_flow_auto_run.sh` | auto-run 编排 |
| `tests/test_flow_code_optimize.sh` | code-optimize 绑定 |
| `tests/test_flow_suggest_slug.sh` | slug 建议 |
| `tests/test_flow_root_helper.sh` | flow-root-helper |
| `tests/test_agent_common.sh` | agent-common |
| `tests/test_config_loader.sh` | config-loader |

`tests/lib/testkit.bash` 提供专用测试夹具和 helper。

---

## 目录结构

```
ai-flow/
├── install.sh                          # 安装脚本
├── README.md                           # 本文档
├── CLAUDE.md                           # 行为准则
├── .mcp.json                           # MCP 配置
├── .gitignore                          # Git 忽略规则
│
├── skills/                             # 11 个 Skill 定义
│   ├── ai-flow-plan/
│   ├── ai-flow-plan-review/
│   ├── ai-flow-plan-coding-review/
│   ├── ai-flow-plan-coding/
│   ├── ai-flow-code-optimize/
│   ├── ai-flow-change/
│   ├── ai-flow-status/
│   ├── ai-flow-plan-summary/
│   ├── ai-flow-bug-fix/
│   ├── ai-flow-code-refactor/
│   └── ai-flow-git-commit/
│
├── subagents/                          # Claude Code AGENT.md bundles + Shared 资产
│   ├── ai-flow-codex-plan/
│   ├── ai-flow-codex-plan-review/
│   ├── ai-flow-codex-plan-coding-review/
│   ├── ai-flow-claude-plan/
│   ├── ai-flow-claude-plan-review/
│   ├── ai-flow-claude-plan-coding-review/
│   └── shared/
│       ├── lib/                        # 通用 helper（agent-common.sh、config-loader.sh）
│       ├── plan/                       # Plan 共享资产（执行器 + prompts + 模板）
│       ├── plan-review/                # Plan Review 共享资产
│       └── coding-review/              # Coding Review 共享资产
│
├── codex/
│   └── agents/                         # Codex native custom agents (*.toml)
│       ├── ai-flow-codex-plan.toml
│       ├── ai-flow-codex-plan-review.toml
│       └── ai-flow-codex-plan-coding-review.toml
│
├── runtime/
│   └── scripts/                        # 11 个 Runtime 脚本
│       ├── flow-state.sh               # 唯一状态写入口
│       ├── flow-status.sh              # 只读状态展示
│       ├── flow-change.sh              # 需求变更审计
│       ├── flow-plan-coding.sh         # plan-coding 执行前门禁
│       ├── flow-bug-fix.sh             # bug-fix 绑定入口
│       ├── flow-code-optimize.sh       # code-optimize 绑定入口
│       ├── flow-code-refactor.sh       # code-refactor 绑定入口
│       ├── flow-auto-run.sh            # 自动编排辅助
│       ├── flow-suggest-slug.sh        # 智能 slug 建议
│       ├── flow-html.sh                # HTML 渲染
│       └── flow_state_cli.py           # Python 状态机内核
│
└── tests/                              # 17 个测试文件
    ├── run.sh                          # 测试统一入口
    ├── lib/                            # 测试夹具（testkit.bash、fixtures.py）
    ├── test_install_layout.sh          # 安装布局测试
    ├── test_flow_*.sh                  # Runtime/脚本层测试（7 个）
    ├── test_flow_*.py                  # Python 层测试（3 个）
    ├── test_runtime_html.sh            # HTML runtime 测试
    ├── test_agent_common.sh            # agent-common 测试
    └── test_config_loader.sh           # config-loader 测试
```

### 运行时产物

```
.ai-flow/
├── plans/{slug}.md                            # 实施计划（8 章模板）
├── reports/{slug}-review*.md                  # Coding Review 审查报告（6 章模板，扁平存放）
├── reports/standalone/{slug}-standalone-review-{N}.md  # Standalone 审查报告
├── state/{slug}.json                          # 流程状态（schema v4，磁盘最小 schema）
├── html/                                      # HTML 阅读视图（派生产物，默认关闭）
│   ├── index.html                             # 状态总览页面
│   ├── plans/{slug}.html                      # Plan HTML 镜像
│   └── reports/{slug}-review*.html            # Review HTML 镜像
```

说明：`plan-review` 不会在 `reports/` 下生成独立文件，审核结论与历史统一写入对应 plan 的 `## 8. 计划审核记录`。

### Plan 模板（8 章）

1. 需求概述（目标、背景、原文、非目标）
2. 技术分析（模块、数据模型、API、依赖、文件边界、高风险路径）
3. 实施步骤（每步使用纯三级标题 `### 标题`；必须包含唯一 `Step ID`，并包含目标、文件边界、review 关注面、执行动作、验收、关闭条件、阻塞条件；`2.5 文件边界总览` 使用 `Step ID` 引用步骤）
4. 测试计划（单元、集成、回归、定向验证矩阵）
5. 风险与注意事项
6. 验收标准
7. 需求变更记录
8. 计划审核记录（结论、偏差、历史）

### Review 报告模板（6 章）

1. 总体评价（上下文、定向验证执行证据）
2. 计划覆盖度检查 + 计划外变更识别
3. 代码质量审查（架构、规范性、安全、性能、逻辑正确性、缺陷族覆盖度）
4. 缺陷清单（严重缺陷 + 建议改进）
5. 审查结论（含跨仓库概览、per-repo 验证命令）
6. 缺陷修复追踪

## HTML 阅读视图

AI Flow 提供零依赖、静态、自包含的 HTML 阅读视图，将 Plan/Review/状态文件渲染为浏览器可直接打开的页面。**默认关闭，配置驱动，失败不阻塞主流程。**

### 配置

在 `setting.json`（用户级 `$AI_FLOW_HOME/setting.json` 或项目级 `.ai-flow/setting.json`）中设置：

```json
{
  "html": {
    "enabled": true,
    "auto_render": {
      "plan": true,
      "review": true,
      "status": true
    }
  }
}
```

### 产物目录

HTML 产物统一输出到 `.ai-flow/html/` 目录，按源路径镜像：
- `.ai-flow/plans/xxx.md` → `.ai-flow/html/plans/xxx.html`
- `.ai-flow/reports/xxx.md` → `.ai-flow/html/reports/xxx.html`
- 状态总览 → `.ai-flow/html/index.html`

该目录被视为标准派生产物，自动追加到 `.git/info/exclude`，不污染审查基线。

### 手动命令

```bash
flow-html.sh plan --input .ai-flow/plans/xxx.md     # 渲染指定 plan
flow-html.sh review --input .ai-flow/reports/xxx.md # 渲染指定 review
flow-html.sh status                                  # 渲染状态总览
flow-html.sh all --slug xxx                          # 渲染 plan + status
```

### 失败策略

- **手动调用**：`html.enabled` 为 false 或文件不存在时返回非 0
- **自动调用**：所有触发点均采用 best-effort 模式，不检查返回码，失败只告警不阻塞主流程
