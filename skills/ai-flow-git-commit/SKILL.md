---
name: ai-flow-git-commit
description: 按 AI Flow 规则提交代码；支持 DONE 计划提交和独立直接提交
---

# AI Flow - Git Commit

**触发时机**：用户输入 `/ai-flow-git-commit`，或在 plan 进入 `DONE` 后按提示提交代码。

**Announce at start:** "正在使用 ai-flow-git-commit 技能，按业务关联性与仓库依赖顺序提交代码。"

## 运行目录

- 绑定 slug 模式：在 owner repo 的 Git 根目录运行。
- 独立模式：在当前目标 Git 仓库根目录运行。

## 行为准则

> 提交代码前请遵守 `~/.claude/CLAUDE.md` — 先思考再编码、简洁优先、精准修改、目标驱动执行。

## 输入约束

- 支持两种模式：
  - 绑定 slug：`/ai-flow-git-commit <slug>` 或当前仅有 1 个状态文件时自动绑定
  - 独立模式：不绑定 slug，直接提交当前 Git 仓库的本地变更
- 绑定 slug 时只允许 `current_status == DONE`
- 提交前必须先同步远程：暂存本地变更、拉取远程最新代码、恢复本地改动
- 多仓模式必须根据 plan 依赖关系逐仓提交；若 plan 未声明跨仓依赖表，则按 `execution_scope.repos` 顺序提交并明确提示用户
- 每个仓库内部必须按业务关联性拆分提交，禁止把无关改动混进同一个 commit
- 每个业务提交组在 commit 之前统一执行 `git diff --check`，不运行仓库测试或 plan 内自定义验证命令

## 交互规则

- 发生冲突时，必须让用户决定：
  - 手动解决
  - 自动解决
- 自动解决时必须保证本地与远程改动都不丢失，解决后重新运行 `git diff --check`
- 未绑定 slug 时，默认按当前仓库的业务根目录自动拆分多个 commit group；`tests/docs/.github` 等支撑文件应尽量归并到对应业务组，无法归并时单独成组

## 执行硬约束

- 触发本 skill 后，唯一合法执行入口是：

```bash
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto]
```

- 第一执行动作必须是直接调用上面的 runtime 脚本，不允许先手工编排 Git 提交流程
- 不要先自行运行 `git status`、`git diff`、`git add`、`git stash`、`git rebase`、`git commit` 来替代脚本
- Git 状态检查、远程同步、冲突处理、业务分组、验证和提交都属于 `flow-commit.sh` 的职责，必须由脚本内部完成
- 只有在脚本执行失败之后，才允许读取失败信息并向用户解释阻塞原因或请求用户选择冲突处理方式
- 如果当前目录不是预期运行目录，也必须优先通过脚本报错或脚本内解析来处理；不要绕过脚本改走手工提交流程

## 调用方式

必须直接调用 runtime 脚本：

```bash
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto]
```

默认 `--conflict-mode manual`。

## 提交规范

`ai-flow-git-commit` 的 message 规范与现有 `git-commit` skill 对齐。

### 提交格式

```text
<emoji> <subject>

<body>

<footer>
```

### Emoji 类型

| Emoji | 代码 | 说明 |
| :---: | :--- | :--- |
| ✨ | `:sparkles:` | 新功能 |
| 🐛 | `:bug:` | 修补 bug |
| 📝 | `:memo:` | 文档更新 |
| 🎨 | `:art:` | 代码格式/样式调整 |
| ♻️ | `:recycle:` | 代码重构 |
| ⚡️ | `:zap:` | 性能优化 |
| ✅ | `:white_check_mark:` | 增加/修复测试 |
| 📦️ | `:package:` | 构建/依赖更新 |
| 👷 | `:construction_worker:` | CI 配置/脚本修改 |
| 🔧 | `:wrench:` | 杂项/配置修改 |
| ⏪️ | `:rewind:` | 代码回滚 |

### Subject 规则

- 必须以 Emoji 代码开头，Emoji 后跟一个空格
- 必须使用中文
- 必须以动词开头
- 不超过 50 个字符
- 结尾不加句号
- 可选在描述中携带业务范围，例如 `:sparkles: 添加订单同步能力`

### Body / Footer 规则

- body 可选，用于说明改动动机和前后行为差异
- footer 可选，可包含 `Closes #123`、`Fixes #123`
- 不允许包含提交工具名称

### message demo

```text
:sparkles: 添加订单同步能力
```

```text
:bug: 修复会话重连时的空指针异常
```

```text
:memo: 更新发布流程说明
```

- commit 仍然以业务提交组为单位，不做整仓一次性提交

## 固定输出协议

完成后，用一行自然语言总结结果，示例：

- 成功 → `✅ 已按业务关联性完成提交，共生成 3 个 commit。`
- 部分完成 → `⚠️ owner 仓库第 2 个提交组验证失败，已停止后续提交。`
- 失败 → `❌ 当前状态不是 DONE，拒绝提交流程内代码。`

成功提交后，还必须按仓库输出本次 commit 列表，格式为 `repo_id + commit id + message`。

机器可读协议块只用于内部解析，不是面向用户的主要内容。面向用户的最终回复必须只保留自然语言摘要和 commit 列表，禁止直接输出 `RESULT:`、`SCOPE:`、`SLUG:`、`COMMITS:`、`DETAIL:` 等协议字段；只有用户明确要求查看协议字段时才可额外展示。

内部机器可读协议块：

```text
RESULT: success|failed|partial
AGENT: ai-flow-git-commit
SCOPE: bound|standalone
SLUG: <slug|none>
REPOS: <repo-count>
COMMITS: <commit-count>
NEXT: none
SUMMARY: <one-line-summary>
FAILED_REPO: <repo-id>
FAILED_GROUP: <group-id>
CONFLICT_MODE: manual|auto
DETAIL: <detail>
```
