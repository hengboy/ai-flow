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

## 输入约束

- 支持两种模式：
  - 绑定 slug：`/ai-flow-git-commit <slug>` 或当前仅有 1 个状态文件时自动绑定
  - 独立模式：不绑定 slug，直接提交当前 Git 仓库的本地变更
- 绑定 slug 时只允许 `current_status == DONE`
- 若前一步是 `standalone review`，必须继续使用无 `slug` 的独立提交模式，不得重新绑定原 `DONE` plan
- 提交前必须先同步远程：暂存本地变更、拉取远程最新代码、恢复本地改动
- 多仓模式必须根据 plan 依赖关系逐仓提交；若 plan 未声明跨仓依赖表，则按 `execution_scope.repos` 顺序提交并明确提示用户
- 绑定 slug 时，提交前必须确认最新 plan review 已覆盖当前待提交变更；如果 review 之后又新增了未被审查的修改，必须先回到 `/ai-flow-plan-coding-review`
- 独立模式下允许不绑定 slug 直接提交当前仓库改动；若用户此前走过 standalone review，应优先保持同一独立链路；若尚未 review，可直接提交，但仍需自行确认改动范围与提交分组合理
- 两种模式在提交前都必须重新做一次最小必要验证：
  - 绑定 slug：至少确认工作区与最近 review 结论一致
  - 独立模式：至少确认当前工作区改动已按本次提交意图自检，不存在未打算一起提交的额外改动
  - 若关键验证已失效、环境已变化或本地改动超出既有 review/自检覆盖范围，必须先补验证再提交

## 提交流程

按以下步骤执行提交：

### 1. 同步远程

1. 运行 `git status --porcelain` 检查是否有可提交的变更；若无，提示用户并停止
2. 运行 `git stash push -u -m "ai-flow-commit-$(date +%s)"` 暂存本地变更（若无变更则跳过）
3. 运行 `git fetch <remote>` 获取远程最新代码（通过 `git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'` 获取上游分支）
4. 运行 `git rebase <upstream>` 同步远程
   - 若 rebase 失败且有冲突，停止流程，提示用户手动解决冲突后重新运行本 skill
5. 运行 `git stash pop` 恢复本地暂存变更
   - 若 stash pop 失败（冲突），停止流程，提示用户手动解决冲突后重新运行本 skill

### 2. 变更分组

按业务关联性对变更文件进行分组。分组原则：

- 同一功能/修复/重构的文件归为一组
- 独立的改动（如文档更新 + 代码修改）应分为不同组
- 每组文件对应一个 commit
- 多仓模式下，按仓库依赖顺序逐仓分组

### 3. 生成 message 并提交

对每组文件执行以下操作：

1. `git add` 暂存该组文件
2. 根据变更内容生成符合规范的 commit message（见下方"提交规范"）
3. 运行 `git commit -F <message-file>` 提交
4. 若提交失败，停止流程并提示用户

### 4. 验证

- 提交完成后运行 `git log --oneline -N`（N 为 commit 数量）展示最近提交
- 多仓模式下按仓库输出本次 commit 列表
- 若提交前发现验证失败、stash pop 冲突、工作区与 review 结论不一致或存在无法解释的额外改动，必须停止提交流程，不得带着未澄清风险继续提交

## 提交规范

commit message 格式遵循 Gitmoji + Conventional Commits：

```text
<emoji代码> <subject>

<body>

<footer>
```

### Emoji 类型（必须）

subject 必须以以下 Emoji 代码之一开头，后跟一个空格：

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

- 必须以动词开头，使用中文描述
- 动词白名单：`添加`、`修复`、`更新`、`调整`、`重构`、`优化`、`补充`、`回滚`
- 不超过 50 个字符
- 禁止包含"完成"
- 结尾不加句号

### Body 规则（可选）

- 说明代码变动的动机或与之前行为的对比
- 最多 2 行，每行不超过 30 个字符

### Footer 规则（可选）

- 只允许 `Refs #123` 或 `Fixes #123` 格式
- 不允许包含提交工具名称（如 `Co-Authored-By`）

### 示例

```text
:sparkles: 添加 JWT 令牌刷新机制

当访问令牌过期时自动刷新。
支持并发请求的队列处理。

Closes #45
```

```text
:bug: 修复连接断开重连时的空指针异常
```

## 固定输出协议

完成后，用一行自然语言总结结果，示例：

- 成功 → `✅ 已按业务关联性完成提交，共生成 3 个 commit。`
- 失败 → `❌ 当前状态不是 DONE，拒绝提交流程内代码。`

成功提交后，还必须按仓库输出本次 commit 列表，格式为 `repo_id + commit id + message`。
