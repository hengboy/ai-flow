---
name: ai-flow-code-optimize
description: 在不改变既有架构和公共契约的前提下执行代码优化；绑定 slug 时遵守 review 前后的状态门禁，无 slug 时允许独立运行且不写 AI Flow 状态
---

# AI Flow - Code Optimize

**触发时机**：用户输入 `/ai-flow-code-optimize`，或明确要求“代码优化”“提升可读性”“安全性加固”“结构整理”“提高可维护性”。

**Announce at start:** "正在使用 ai-flow-code-optimize 技能，在不违背仓库既有架构的前提下执行代码优化。"

## 输入形式

- `/ai-flow-code-optimize <slug> "优化描述"`
- `/ai-flow-code-optimize "优化描述"`

## 规则

> **行为准则**：编码前请遵守 [CLAUDE.md](`~/.claude/CLAUDE.md`) — 先思考再编码、简洁优先、精准修改、目标驱动执行。

### 1. 优化范围

- 默认优化范围仅包含：可读性、安全性加固、局部结构整理、重复消除、可维护性提升
- 可读性优化包括：命名规范化、函数拆分、消除魔法数字、简化条件表达式
- 结构优化包括：消除重复代码、局部结构整理
- 可维护性优化包括：错误处理规范化、日志规范化
- **不默认包含性能优化**
- 只有用户或 plan 明确要求性能优化时，才允许处理性能相关改动
- 解耦、依赖注入、设计模式引入仅限局部优化场景，且不得改变既有架构、依赖方向、公共接口或跨模块职责
- 如果某项优化需要引入新的核心抽象层、重组模块边界、升级依赖注入骨架，或显著改变调用关系，应转 `/ai-flow-code-refactor`

### 2. 架构硬约束

- 开始前必须先读取 plan 或当前仓库结构，识别既有分层、模块边界、依赖方向、命名风格和抽象层次
- 只能做**架构内优化**
- 不得为了“更优雅”改变模块归属、依赖方向、公共接口、跨仓职责或业务语义
- **不允许出现硬编码**
- 优化过程中不得新增或扩散硬编码的常量、路径、环境值、密钥、业务阈值、魔法数字、魔法字符串
- 如某个值本就应配置化、常量化、枚举化或从现有上下文推导，必须优先复用仓库里已有的配置源、常量定义、领域模型或辅助函数
- 如果当前代码里的问题根因就是硬编码，优化目标应包含消除该硬编码，而不是仅调整写法
- 如果最佳方案需要架构级调整、公共契约变更或需求语义变化，必须立即停止当前优化，回退到 `/ai-flow-plan-coding`；必要时提示用户先走 `/ai-flow-change`

### 3. 绑定模式（有 slug）

- 显式传入 `slug` 时按该状态文件绑定
- 未显式传入 `slug` 且当前仅有 1 个状态文件时，可自动绑定
- 若有多个状态文件，必须先让用户选择，不能猜测

允许进入的绑定状态：

- `AWAITING_REVIEW`
  - 允许执行优化
  - **不推进状态**
  - 完成后下一步进入 `/ai-flow-plan-coding-review`
- `REVIEW_FAILED`
  - 仅当最近失败报告中的**全部阻塞缺陷**都明确路由到 `ai-flow-code-optimize` 时允许进入
  - 进入前先沿用 `/ai-flow-plan-coding` 的修复语义，调用 `flow-state.sh start-fix <slug>` 进入 `FIXING_REVIEW`
  - 完成后调用 `flow-state.sh finish-fix <slug>` 回到 `AWAITING_REVIEW`
- `FIXING_REVIEW`
  - 允许继续执行优化修复
  - 完成后调用 `flow-state.sh finish-fix <slug>` 回到 `AWAITING_REVIEW`

禁止进入的绑定状态：

- `AWAITING_PLAN_REVIEW`
- `PLAN_REVIEW_FAILED`
- `PLANNED`
- `IMPLEMENTING`
- `DONE`

遇到上述状态时，必须拒绝进入绑定优化，并提示正确回流方向。

### 4. 独立模式（无 slug）

- 不创建、不修改 `.ai-flow/state`
- 只允许在用户**明确指定文件、模块或问题范围**时运行
- 拒绝“全仓随意扫一遍”“帮我整体优化一下”这类无边界请求
- 独立优化完成后，如需审查，统一提示使用 `/ai-flow-plan-coding-review`

### 5. 与其他技能的边界

- 需要修复功能错误、逻辑错误、契约错误、需求偏差时，应回到 `/ai-flow-plan-coding`
- 需要架构级重构、模块搬迁、依赖方向调整、公共接口重塑时，应优先考虑 `/ai-flow-code-refactor`
- 解耦如果涉及模块级重组、接口层升级、依赖注入框架化，不属于本技能范围
- 设计模式应用如果会新增系统级抽象、提高整体复杂度或改变主要调用关系，不属于本技能范围
- 只有在**既有架构内**做优化类收敛时，才应使用本技能

## 固定输出协议

完成后先给出自然语言摘要，再在内部追加协议块：

```text
RESULT: success|failed|partial
AGENT: ai-flow-code-optimize
SCOPE: bound|standalone
STATE: <status|none>
NEXT: ai-flow-plan-coding-review|ai-flow-plan-coding|ai-flow-change|none
SUMMARY: <one-line-summary>
```
