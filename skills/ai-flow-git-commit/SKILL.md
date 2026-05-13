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
- commit message 必须由 `ai-flow-claude-git-message` 子代理按提交组内容生成，禁止在 skill 内凭规则、模板或硬编码文案直接拼接 `subject/body/footer`

## 交互规则

- 发生冲突时，必须让用户决定：
  - 手动解决
  - 自动解决
- 自动解决时必须保证本地与远程改动都不丢失，解决后重新运行 `git diff --check`
- 未绑定 slug 时，默认按当前仓库变更的业务关联性或改动关联性拆分多个 commit group；`tests/docs/.github` 及配置类支撑文件应优先归并到对应主改动组，只有明显无关时才单独成组

## 执行硬约束

- 触发本 skill 后，唯一合法执行入口是：

```bash
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto]
```

- 上面的 runtime 脚本也是 Git 提交流程的唯一合法 runtime 入口。

- 第一执行动作必须是直接调用上面的 runtime 脚本 `--prepare-json`，不允许先手工编排 Git 提交流程
- 不要先自行运行 `git status`、`git diff`、`git add`、`git stash`、`git rebase`、`git commit` 来替代脚本
- Git 状态检查、远程同步、冲突处理、业务分组、验证和提交都属于 `flow-commit.sh` 的职责，必须由脚本内部完成
- skill 层允许做两件额外动作：调用 `ai-flow-claude-git-message` 生成每个提交组的 message，以及把这些结果组装成 `--message-map-json`
- 只有在脚本执行失败之后，才允许读取失败信息并向用户解释阻塞原因或请求用户选择冲突处理方式
- 如果当前目录不是预期运行目录，也必须优先通过脚本报错或脚本内解析来处理；不要绕过脚本改走手工提交流程

## 调用方式

必须按以下两阶段调用 runtime 脚本：

```bash
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --prepare-json
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --message-map-json '<json>'
```

默认 `--conflict-mode manual`。

## 编排顺序

1. 先调用：

```bash
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --prepare-json
```

2. 解析返回的提交组 JSON。每个元素至少包含：
   - `repo_id`
   - `repo_git_root`
   - `group_id`
   - `group_title`
   - `files`
   - `staged_diff`

3. 对每个提交组调用 `ai-flow-claude-git-message` 子代理，prompt 中必须完整传入该组 JSON 内容，并明确要求它只输出：

```text
SUBJECT: ...
BODY:
...
FOOTER:
...
```

   同时必须把 runtime 当前的 message 校验规则原样同步给子代理，至少包括：
   - emoji 白名单：`:sparkles:`、`:bug:`、`:memo:`、`:art:`、`:recycle:`、`:zap:`、`:white_check_mark:`、`:package:`、`:construction_worker:`、`:wrench:`、`:rewind:`
   - subject 动词白名单：`添加`、`修复`、`更新`、`调整`、`重构`、`优化`、`补充`、`回滚`
   - 禁止包含“完成”
   - body 最多 2 行且每行不超过 30 个字符
   - footer 只允许 `Refs #123`、`Fixes #123`

4. 解析子代理输出并组装成：

```json
{
  "<repo_id>": {
    "<group_id>": {
      "subject": "<subject>",
      "body": ["<line1>", "<line2>"],
      "footer": ["<line1>"]
    }
  }
}
```

5. 再调用：

```bash
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --message-map-json '<json>'
```

6. 如果任一提交组未生成合法 message，必须整体失败；不要回退到本地规则生成、不要自动改写成占位文案。

## 子代理约束

- commit message 子代理固定使用 `ai-flow-claude-git-message`，不替换为 Codex CLI、Codex 内置 message 生成或其他外部脚本。
- 传给子代理的信息必须以当前提交组为边界，不得把多个业务组混在一次调用里。
- 传给子代理的规则必须与当前 `flow-commit.sh` 的校验规则保持同步；如果 runtime 白名单变了，这里的调用约束也必须一起更新。
- footer 缺失时保持为空，不得臆造 issue 编号。
- 子代理返回内容只用于组装 `--message-map-json`，不要把它原样展示给用户。
- 如需临时文件承载 shell 参数，使用后必须立即删除；优先直接以内存中的 JSON 字符串传给 `--message-map-json`。

## 提交规范

`ai-flow-git-commit` 的 message 规范由 `flow-commit.sh` 校验，子代理必须严格遵守。

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
- 必须以动词开头，且动词只允许：`添加`、`修复`、`更新`、`调整`、`重构`、`优化`、`补充`、`回滚`
- 不超过 50 个字符
- 结尾不加句号
- 可选在描述中携带业务范围，例如 `:sparkles: 添加订单同步能力`

### Body / Footer 规则

- body 可选，用于说明改动动机和前后行为差异；最多 2 行，每行不超过 30 个字符
- footer 可选，仅允许 `Refs #123`、`Fixes #123`
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
