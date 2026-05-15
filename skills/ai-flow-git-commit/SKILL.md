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
- commit message 必须由 `ai-flow-claude-git-commit` 子代理生成；禁止在 skill 内凭规则、模板或硬编码文案直接拼接 `subject/body/footer`

## 执行硬约束

- 触发本 skill 后，唯一合法执行入口是：

```bash
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto]
```

- 第一执行动作必须是直接调用上面的 runtime 脚本 `--prepare-json`
- 不要先自行运行 `git status`、`git diff`、`git add`、`git stash`、`git rebase`、`git commit`
- Git 状态检查、远程同步、冲突处理、分组校验、验证和提交都属于 `flow-commit.sh` 的职责，必须由脚本内部完成

## 三阶段调用

必须按以下三阶段调用 runtime 脚本：

```bash
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --prepare-json
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --session-id <session_id> --validate-groups-json '<json>'
$HOME/.config/ai-flow/scripts/flow-commit.sh [--slug <slug>] [--conflict-mode manual|auto] --session-id <session_id> --groups-json '<json>' --message-map-json '<json>'
```

默认 `--conflict-mode manual`。

## 编排顺序

1. 调用 `--prepare-json` 获取 repo 级上下文。返回值按 repo 顺序提供：
   - `repo_id`
   - `repo_git_root`
   - `role`
   - `changed_files`
   - `file_diffs`
   - `plan_context`

2. 按 repo 顺序逐个调用 `ai-flow-claude-git-commit`。
   - 调用参数必须直接使用 runtime 返回的 `group_agent_input`
   - 不得手工拼接、裁剪、补写或跨 repo 合并输入
   - 输出必须是 JSON
   - 每个 repo 最多返回 5 个 group；超出时必须先按业务关联性合并
   - 每组至少包含：
     - `group_title`
     - `reason`
     - `files`

3. 将所有 repo 的分组结果组装为：

```json
{
  "repos": [
    {
      "repo_id": "repo-alpha",
      "groups": [
        {
          "group_title": "支付重试",
          "reason": "同一业务变更",
          "files": ["src/payments/retry.ts"]
        }
      ]
    }
  ]
}
```

4. 记录 `prepare-json` 返回的 `session_id`，后续两阶段都必须显式透传为 `--session-id`。

5. 将第 3 步的结果组装为：

```json
{
  "repos": [...]
}
```

   - `groups-json` 顶层不再要求必须携带 `session_id`
   - 如为兼容旧调用，允许保留顶层 `session_id`，但不得与 `--session-id` 不一致

6. 调用 `--validate-groups-json`。如果校验失败：
   - 当前 repo 只重试 `mode=group` 1 次
   - 仍失败则整体停止

7. runtime 校验通过后会返回规范化结果。每组至少包含：
   - `repo_id`
   - `group_id`
   - `group_title`
   - `reason`
   - `files`
   - `staged_diff`
   - `message_agent_input`

8. 按 `repo -> group` 顺序逐个调用 `ai-flow-claude-git-commit`。
   - 调用参数必须直接使用 runtime 返回的 `message_agent_input`
   - 不得手工改写 `staged_diff`、`group_id`、`reason` 或 `files`
   - 输出只能是固定文本协议：

```text
SUBJECT: ...
BODY:
...
FOOTER:
...
```

9. 解析子代理输出并组装成：

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

10. 调用 `--session-id '<prepare-json.session_id>' --groups-json '<validated-json>' --message-map-json '<json>'` 执行提交。

## 子代理约束

- commit 子代理固定使用 `ai-flow-claude-git-commit`
- `mode=group` 与 `mode=message` 的输入都必须原样转发 runtime 产出的 agent input，禁止 skill 层自行补充边界信息
- `session_id` 只允许来自 `prepare-json` 返回值；不得自行生成、改写或遗漏
- `mode=message` 必须同步 runtime 当前 message 校验规则：
  - emoji 白名单：`:sparkles:`、`:bug:`、`:memo:`、`:art:`、`:recycle:`、`:zap:`、`:white_check_mark:`、`:package:`、`:construction_worker:`、`:wrench:`、`:rewind:`
  - subject 动词白名单：`添加`、`修复`、`更新`、`调整`、`重构`、`优化`、`补充`、`回滚`
  - 禁止包含“完成”
  - body 最多 2 行且每行不超过 30 个字符
  - footer 只允许 `Refs #123`、`Fixes #123`
- 某个 group 的 message 输出不合法时，只重试当前 group 2 次；仍失败则停止当前 repo 与后续 repo
- footer 缺失时保持为空，不得臆造 issue 编号

## 固定输出协议

完成后，用一行自然语言总结结果，示例：

- 成功 → `✅ 已按业务关联性完成提交，共生成 3 个 commit。`
- 部分完成 → `⚠️ repo-alpha 第 2 个提交组验证失败，已停止后续提交。`
- 失败 → `❌ 当前状态不是 DONE，拒绝提交流程内代码。`

成功提交后，还必须按仓库输出本次 commit 列表，格式为 `repo_id + commit id + message`。
