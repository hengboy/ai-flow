---
name: ai-flow-review
description: 调用审查引擎审查代码变更并生成报告，同时推进 JSON 状态。支持 codex-review.sh（Codex 优先）和 opencode-review.sh（OpenCode 专用）
---

# AI Flow - 代码审查

**触发时机**：用户输入 `/ai-flow-review` 或要求”做 code review”。

**Announce at start:** “正在使用 ai-flow-review 技能，对比实施计划审查代码变更。”

## 流程

### 1. 选择目标

运行：

```bash
${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-status.sh
```

根据 `.ai-flow/state/*.json` 选择要审查的 `slug`。

状态限制：

- `AWAITING_REVIEW`：允许常规 review
- `DONE`：允许 recheck
- 其他状态：拒绝进入 review

### 2. 检查变更

- 运行 `git status --porcelain`
- 必须存在非 `.ai-flow/` 的未提交变更
- review 必须基于未提交代码执行

### 3. 生成报告

运行：

```bash
# 使用 codex-review.sh（Codex 优先，OpenCode 降级）
${CLAUDE_HOME:-$HOME/.claude}/skills/ai-flow-review/scripts/codex-review.sh {slug} [模型名] [推理强度] [轮次]

# 或直接使用 opencode-review.sh（OpenCode 专用）
${CLAUDE_HOME:-$HOME/.claude}/skills/ai-flow-review/scripts/opencode-review.sh {slug} [模型名] [推理强度] [轮次]
```

参数顺序固定：

- 第 1 个位置参数统一传状态文件名里的 `slug`
- 脚本也支持唯一关键词匹配，但示例和推荐用法都用 `slug`，避免误匹配
- 第 2 个位置参数才是模型名
- 第 3 个位置参数才是推理强度
- 第 4 个位置参数才是轮次

脚本会：

- **codex-review.sh**：自动检测审查引擎：Codex 可用时使用 Codex，否则降级为 OpenCode (`zhipuai-coding-plan/glm-5.1`)
- **opencode-review.sh**：直接使用 OpenCode，默认模型 `zhipuai-coding-plan/glm-5.1`，默认推理 `max`
- 降级时推理强度自动映射：`xhigh` → `max`，`high` → `high`，`medium`/`low` → `minimal`
- 只从状态 JSON 决定审查模式和轮次
- 上一轮失败后会同时提取 `## 4. 缺陷清单` 和 `## 6. 缺陷修复追踪` 作为历史参考
- 使用同 skill 目录下共享的 `templates/review-template.md` 和 `prompts/review-generation.md`
- 生成 `.ai-flow/reports/{日期}/{slug}-review*.md`
- 校验报告元数据和结构
- regular 第 3 轮及以后会检查是否存在晚于第 2 轮失败时间的 `[root-cause-review-loop]` 变更记录
- 调用 `${AI_FLOW_HOME:-$HOME/.config/ai-flow}/scripts/flow-state.sh record-review` 推进状态

### 4. 报告要求

- 首行必须是 `# 审查报告：{需求名称}`
- 顶部必须包含：
  - `需求简称`
  - `审查模式`
  - `审查轮次`
  - `审查结果`
- `1.2 定向验证执行证据` 必须记录本轮实际执行的定向验证命令和结果
- `3.6 缺陷族覆盖度` 必须覆盖 plan 中相关缺陷族，以及上一轮严重缺陷涉及的缺陷族
- 计划外变更、缺陷清单、修复追踪都要完整填写

### 5. 状态结果

- 常规 review：
  - `passed` → `DONE`
  - `passed_with_notes` → `DONE`
  - `failed` → `REVIEW_FAILED`
- recheck：
  - `passed` → 保持 `DONE`
  - `passed_with_notes` → 保持 `DONE`
  - `failed` → `REVIEW_FAILED`

### 6. 缺陷追踪规则

- 如果 `last_review.result == failed`，下一轮优先读取失败报告作为修复追踪参考
- recheck 失败修复后，下一次常规 review 必须读取失败的 recheck 报告
- 第 1 轮 regular review 要尽量按缺陷族打全；第 2 轮 regular review 既验证修复，也要复扫上一轮受影响缺陷族与相邻回归面
- `Critical` / `Important` 必须用 `[待修复]` 或 `[已修复]` 跟踪；`Minor` 未处理时必须标记为 `[可选]`，不阻塞 `DONE`
- review 允许执行有边界的定向验证：`test-compile`、单个测试类/用例、单个 Mapper/集成用例、轻量 build/check；默认禁止无边界全量回归
- 不得把旧报告首行或元数据手改成通过来推动状态

### 7. 提交门禁

- 只有 `current_status == DONE` 才允许提交
- 优先使用 `git-commit` 技能

## 注意事项

- 不再从 plan/review 文件头读取状态
- 如果报告元数据和状态 JSON 不一致，必须失败
- 非文档代码变更的 review 报告若缺少 `1.2` 验证证据，必须失败
- 如果没有 Git 变更，不得为了触发 review 而提前提交代码
