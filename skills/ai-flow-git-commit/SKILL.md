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
  - 绑定 slug：仅当用户显式传入 `/ai-flow-git-commit <slug>` 时绑定
  - 独立模式：不绑定 slug，直接提交当前 Git 仓库的本地变更
- 未显式提供 `slug` 时，禁止扫描、检索或列出 `.ai-flow/state` 下的候选 slug；必须直接按独立模式处理当前仓库改动
- 绑定 slug 时只允许 `current_status == DONE`
- 若前一步是 `standalone review`，必须继续使用无 `slug` 的独立提交模式，不得重新绑定原 `DONE` plan
- 提交前必须先同步远程：直接在当前工作区执行 `git pull --no-rebase`，禁止执行任何 `git stash` 相关动作
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
2. 运行 `git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'` 确认当前分支已配置上游；若未配置，停止流程并提示用户先处理上游分支配置
3. 运行 `git pull --no-rebase`
   - 若 `pull` 成功，继续后续分组与提交
   - 若 `pull` 因本地修改会被覆盖而失败，必须停止自动提交流程，列出受影响文件并提示进入冲突处理
   - 若 `pull` 进入 merge conflict，必须停止自动提交流程，列出冲突文件并进入冲突处理
4. 冲突处理规则：
   - 不得丢弃任一侧代码，不得使用 `git checkout --ours`、`git checkout --theirs`、`git reset --hard` 之类会直接覆盖另一侧内容的快捷做法
   - 模型必须先读取每个冲突文件的冲突片段，给出合并建议与可选方案，明确说明本地修改、远端修改及推荐保留方式
   - 用户只负责对存在取舍的冲突进行人工判断；在用户确认取舍后，模型负责实际编辑冲突文件、移除冲突标记并完成合并
   - 所有冲突文件解决后，必须运行最小必要验证，确认最终结果同时吸收需要保留的本地与远端修改
   - 若用户未完成判断、冲突仍未解决或验证无法证明两端修改都已妥善保留，必须停止流程，不得继续提交

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
- 若提交前发现验证失败、`git pull` 冲突未完成处理、工作区与 review 结论不一致或存在无法解释的额外改动，必须停止提交流程，不得带着未澄清风险继续提交

## 提交规范

commit message 必须遵循约定式提交（Conventional Commits）1.0.0 规范：

```text
<type>[optional scope][!]: <description>

[optional body]

[optional footer(s)]
```

生成 commit message 时必须满足以下要求：

- 每个提交都必须以 `type` 开头，后接可选的 `(scope)`、可选的 `!`、以及必需的 `: ` 分隔符
- 新功能必须使用 `feat`
- 修复缺陷必须使用 `fix`
- 其它改动按规范选择合适类型，例如 `build`、`chore`、`ci`、`docs`、`style`、`refactor`、`perf`、`test`、`revert`
- `scope` 用于标识受影响模块或区域，没有明确范围时可以省略
- `description` 必须紧跟在 `: ` 后，默认使用中文对本次改动做简短总结；不再要求 Emoji 或动词白名单
- 需要补充上下文时，可以在标题后空一行编写正文，正文默认使用中文解释改动原因、背景或行为差异
- 需要脚注时，必须在正文后空一行编写，并采用 trailer 风格，例如 `Refs: #123`
- 存在破坏性变更时，必须使用标题中的 `!` 或脚注中的 `BREAKING CHANGE: ` 显式标记；破坏性影响说明默认使用中文
- 生成时推荐统一使用小写类型，例如 `feat`、`fix`、`docs`

### 示例

```text
feat(auth): 添加令牌刷新流程

当访问令牌过期时自动刷新。
串行化并发刷新请求，避免重复调用。

Refs: #45
```

```text
fix(ws): 修复重连时的空指针异常
```

```text
feat(api)!: 移除旧版会话令牌支持

BREAKING CHANGE: 客户端必须改用 JWT 令牌进行鉴权请求。
```

## 固定输出协议

完成后，用一行自然语言总结结果，示例：

- 成功 → `✅ 已按业务关联性完成提交，共生成 3 个 commit。`
- 失败 → `❌ 当前状态不是 DONE，拒绝提交流程内代码。`

成功提交后，还必须按仓库输出本次 commit 列表，格式为 `repo_id + commit id + message`。
