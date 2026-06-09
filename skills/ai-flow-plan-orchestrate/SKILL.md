---
name: ai-flow-plan-orchestrate
description: 编排多个已存在普通 plan，按队列逐个自动执行到 DONE、提交并开启新会话继续下一个 plan
---

# AI Flow - Plan Orchestrate

**触发时机**：用户输入 `/ai-flow-plan-orchestrate --queue <queue_slug> <plan_slug_1> <plan_slug_2> ...`、`/ai-flow-plan-orchestrate --resume <queue_slug>`、`/ai-flow-plan-orchestrate --status <queue_slug>`，或明确要求“按顺序自动跑多个已有 plan 并提交”。

**Announce at start:** "正在使用 ai-flow-plan-orchestrate 技能，按队列顺序编排多个已有普通 plan。"

## 定位

- 本 skill 只编排“已有普通 plan 队列”，不创建 plan，不复用计划组 children，不接受计划组 slug。
- 队列 item 只引用 `.ai-flow/state/<slug>.json` 中的普通 plan slug，不复制 plan state。
- 每个 plan 必须完成 `coding -> coding review/recheck/fix loop -> DONE -> ai-flow-git-commit <slug>` 后，才允许推进下一个 plan。
- `ai-flow-auto-run` 的单 plan 语义保持不变：它只负责推进到 `DONE`，不负责提交。
- 多 plan 自动提交只由本 orchestrator 负责，并且必须在每个 plan 提交完成后开启新终端会话继续下一个 item。

## 公共入口

启动队列：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --queue <queue_slug> <plan_slug_1> <plan_slug_2> ...
```

恢复队列：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --resume <queue_slug>
```

只读查看：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --status <queue_slug>
```

队列状态文件固定落在：

```text
.ai-flow/orchestrations/state/{queue_slug}.json
```

## 入队约束

允许入队的普通 plan 状态：

- `PLANNED`
- `IMPLEMENTING`
- `AWAITING_REVIEW`
- `REVIEW_FAILED`
- `FIXING_REVIEW`
- `DONE`

`DONE` 只有在仍需提交或复审时才允许入队；如果 dirty 检查为 clean，说明当前 plan 已完成且没有待处理改动，必须拒绝入队。

必须拒绝：

- `AWAITING_PLAN_REVIEW`
- `PLAN_REVIEW_FAILED`
- 无效 slug 或不存在的普通 plan state
- 重复 slug
- 计划组 slug

## 队列状态

item 状态：

- `PENDING`
- `RUNNING`
- `DONE_REVIEWED`
- `COMMITTED`
- `FAILED`

queue 状态：

- `READY`
- `RUNNING`
- `FAILED`
- `DONE`

禁止直接编辑 `.ai-flow/orchestrations/state/*.json`。所有写入必须通过 `flow-plan-orchestrate.sh` 或 `flow-plan-orchestrate-state.sh`。

## 状态驱动循环

### 1. 解析当前 item

每轮必须先读取队列：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --resume <queue_slug>
```

- 如果 `current_status=DONE`：输出总结，不启动新会话。
- 如果 `current_status=FAILED`：输出失败原因，不继续；人工处理失败原因后，可显式调用 `--reopen-current` 恢复当前 item。
- 如果存在 active item：读取 `active_slug`，后续动作绑定该 slug。

### 2. 启动当前 item

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --start-current <queue_slug>
```

如果队列此前因硬阻塞进入 `FAILED`，人工处理阻塞后恢复当前 item：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --reopen-current <queue_slug> --reason "<恢复原因>"
```

### 3. 复用 auto-run 到 DONE

对当前 active slug 执行普通单 plan 自动闭环：

```bash
/ai-flow-auto-run <active_slug>
```

必须严格遵守 `ai-flow-auto-run` 规则：coding/review/recheck/fix loop 直到 `DONE`，或遇到硬阻塞停止。

若 auto-run 未返回 `RESULT: success` 或最终状态不是 `DONE`，必须调用：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --fail <queue_slug> --reason "<原因>"
```

然后停止，不启动下一个会话。

auto-run 成功后调用：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --mark-reviewed <queue_slug>
```

该写入口会重新校验 active plan 的真实状态必须是 `DONE`；不得只凭上一步口头结论推进。

### 4. 提交前记录 HEAD

commit 前必须记录每个参与 repo 的 HEAD。按当前 plan state 的 `execution_scope.repos` 逐仓读取 `git_root`，运行 `git rev-parse HEAD`，组装 JSON：

```json
[
  { "repo_id": "owner", "git_root": "/abs/path", "head": "abc123..." }
]
```

写回队列：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --record-heads <queue_slug> --heads-json '<json>'
```

### 5. 提交当前 plan

执行：

```bash
/ai-flow-git-commit <active_slug>
```

本调用属于“编排非交互模式”。遇到 pull conflict、上游缺失、验证失效、额外改动不明、权限/密钥缺失等需要人工判断的场景，必须失败返回，不进入交互式取舍。

commit 成功后，对每个参与 repo 用提交前 HEAD 推导提交列表：

```bash
git -C <git_root> log --oneline <old_head>..HEAD
```

组装 JSON：

```json
[
  { "repo_id": "owner", "git_root": "/abs/path", "commits": ["abc123 message"] }
]
```

写回队列并推进 active index：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --mark-committed <queue_slug> --commits-json '<json>'
```

该写入口要求已记录 `head_before_commit`，否则必须拒绝推进。

### 6. 启动下一会话

重新查看队列状态：

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate.sh --status <queue_slug>
```

- 如果 queue 已是 `DONE`：输出总结，不再启动新会话。
- 如果还有下一个 item：调用 launcher 开启新终端会话继续。

```bash
$HOME/.config/ai-flow/scripts/flow-plan-orchestrate-launch.sh --queue <queue_slug>
```

launcher 生成的 resume prompt 必须包含：

```text
/ai-flow-plan-orchestrate --resume <queue_slug>
```

并声明：无人工介入；遇硬阻塞写入队列 `FAILED` 并停止。

## 配置

项目级 `.ai-flow/setting.json` 覆盖用户级 `$AI_FLOW_HOME/setting.json`：

```json
{
  "orchestration": {
    "tool": "auto",
    "launcher": "auto",
    "command_templates": {
      "codex": "codex --cd {cwd} {prompt}",
      "claude": "claude {prompt}",
      "custom": ""
    }
  }
}
```

- `tool=auto`：优先使用显式 tool；未配置时按 `engine_mode` 推导；`engine_mode=auto` 时按宿主/可用 CLI 检测。
- `launcher=auto`：优先使用可用 `tmux` 创建新会话；macOS 可配置 Terminal/osascript；测试可使用 `--dry-run`。
- 不得写死只支持 Codex 或 Claude；自定义 tool 应通过 `command_templates.custom` 或扩展模板配置接入。

## 失败规则

无人工介入不代表强行解决冲突。以下场景必须标记队列 `FAILED` 并停止：

- auto-run 失败、partial 或缺少可执行回流方向
- git pull conflict 或上游分支缺失
- 验证失效，或 review 未覆盖当前待提交变更
- 额外改动不明，无法判断是否属于当前 plan
- 权限、密钥、环境依赖缺失
- 任何需要业务取舍的情况

## 固定输出协议

最终回复自然语言总结当前队列结果，并追加机器可读协议块：

```text
RESULT: success|failed|partial
AGENT: ai-flow-plan-orchestrate
QUEUE_SLUG: <queue_slug>
ACTIVE_SLUG: <slug|none>
STATE: READY|RUNNING|FAILED|DONE
NEXT: ai-flow-plan-orchestrate|none
SUMMARY: <one-line-summary>
```
