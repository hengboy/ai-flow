#!/bin/bash
# test_flow_plan_orchestrate.sh — queue helper and launcher smoke tests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

ORCH_SH="$SCRIPTS_DIR/flow-plan-orchestrate.sh"
LAUNCH_SH="$SCRIPTS_DIR/flow-plan-orchestrate-launch.sh"
FLOW_STATE_SH="$SCRIPTS_DIR/flow-state.sh"

echo "=== flow-plan-orchestrate.sh 测试 ==="
echo ""

test_queue_create_and_status() {
    local dir output exit_code=0
    dir="$(create_temp_project "orch-queue")"
    create_minimal_state "$dir" "20260609-orch-a"
    create_minimal_state "$dir" "20260609-orch-b"
    (
        cd "$dir" || exit 1
        bash "$FLOW_STATE_SH" transition --slug "20260609-orch-a" \
            --event plan_review_passed --result passed --engine test --model test-model >/dev/null
        bash "$FLOW_STATE_SH" transition --slug "20260609-orch-b" \
            --event plan_review_passed --result passed --engine test --model test-model >/dev/null
    )

    output="$(
        cd "$dir" || exit 1
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" bash "$ORCH_SH" --queue queue-smoke 20260609-orch-a 20260609-orch-b 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "创建编排队列"
    assert_contains "$output" "queue_slug=queue-smoke" "输出队列 slug"
    assert_contains "$output" "active_slug=20260609-orch-a" "保留传入顺序"
    assert_contains "$output" $'item[1]=20260609-orch-b\tPENDING' "第二项 pending"

    cleanup_temp_project "$dir"
}

test_launcher_dry_run_codex_template() {
    local dir home_dir output exit_code=0
    dir="$(create_temp_project "orch-launch-codex")"
    home_dir="$(mktemp -d)"
    mkdir -p "$home_dir/lib" "$home_dir/scripts"
    cp "$PROJECT_ROOT/runtime/lib/flow_config.py" "$home_dir/lib/"
    cp "$PROJECT_ROOT/runtime/lib/flow-root-helper.sh" "$home_dir/lib/"
    cat > "$home_dir/setting.json" <<'EOF'
{
  "engine_mode": "claude",
  "orchestration": {
    "tool": "codex",
    "launcher": "none",
    "command_templates": {
      "codex": "codex --cd {cwd} {prompt}",
      "claude": "claude {prompt}",
      "custom": ""
    }
  }
}
EOF

    output="$(
        cd "$dir" || exit 1
        AI_FLOW_HOME="$home_dir" bash "$LAUNCH_SH" --queue queue-dry --dry-run 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "launcher dry-run 成功"
    assert_contains "$output" "tool=codex" "显式 tool=codex 生效"
    assert_contains "$output" "launcher=none" "显式 launcher=none 生效"
    assert_contains "$output" "codex --cd" "生成 codex 命令"
    assert_contains "$output" "/ai-flow-plan-orchestrate --resume queue-dry" "prompt 包含 resume"
    assert_not_contains "$output" "codex exec" "launcher 不调用 codex exec"

    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

test_launcher_auto_uses_tmux_when_available() {
    local dir home_dir bin_dir output exit_code=0
    dir="$(create_temp_project "orch-launch-tmux")"
    home_dir="$(mktemp -d)"
    bin_dir="$(mktemp -d)"
    mkdir -p "$home_dir/lib" "$home_dir/scripts"
    cp "$PROJECT_ROOT/runtime/lib/flow_config.py" "$home_dir/lib/"
    cp "$PROJECT_ROOT/runtime/lib/flow-root-helper.sh" "$home_dir/lib/"
    printf '#!/bin/sh\nexit 0\n' > "$bin_dir/tmux"
    chmod +x "$bin_dir/tmux"
    cat > "$home_dir/setting.json" <<'EOF'
{
  "engine_mode": "codex",
  "orchestration": {
    "tool": "codex",
    "launcher": "auto"
  }
}
EOF

    output="$(
        cd "$dir" || exit 1
        PATH="$bin_dir:$PATH" AI_FLOW_HOME="$home_dir" bash "$LAUNCH_SH" --queue queue-tmux --dry-run 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "launcher auto dry-run 成功"
    assert_contains "$output" "launcher=tmux" "auto 优先 tmux"
    assert_contains "$output" "tmux new-session" "生成 tmux 新会话命令"

    cleanup_temp_project "$dir"
    rm -rf "$home_dir" "$bin_dir"
}

test_launcher_auto_tool_uses_engine_mode() {
    local dir home_dir output exit_code=0
    dir="$(create_temp_project "orch-launch-engine")"
    home_dir="$(mktemp -d)"
    mkdir -p "$home_dir/lib" "$home_dir/scripts"
    cp "$PROJECT_ROOT/runtime/lib/flow_config.py" "$home_dir/lib/"
    cp "$PROJECT_ROOT/runtime/lib/flow-root-helper.sh" "$home_dir/lib/"
    cat > "$home_dir/setting.json" <<'EOF'
{
  "engine_mode": "claude",
  "orchestration": {
    "tool": "auto",
    "launcher": "none"
  }
}
EOF

    output="$(
        cd "$dir" || exit 1
        AI_FLOW_HOME="$home_dir" bash "$LAUNCH_SH" --queue queue-engine --dry-run 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "launcher tool=auto dry-run 成功"
    assert_contains "$output" "tool=claude" "tool=auto 按 engine_mode 推导"
    assert_contains "$output" "claude " "生成 claude 命令"

    cleanup_temp_project "$dir"
    rm -rf "$home_dir"
}

test_queue_reopen_current() {
    local dir output exit_code=0
    dir="$(create_temp_project "orch-reopen")"
    create_minimal_state "$dir" "20260609-orch-reopen"
    (
        cd "$dir" || exit 1
        bash "$FLOW_STATE_SH" transition --slug "20260609-orch-reopen" \
            --event plan_review_passed --result passed --engine test --model test-model >/dev/null
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" bash "$ORCH_SH" --queue queue-reopen 20260609-orch-reopen >/dev/null
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" bash "$ORCH_SH" --start-current queue-reopen >/dev/null
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" bash "$ORCH_SH" --fail queue-reopen --reason blocked >/dev/null
    )

    output="$(
        cd "$dir" || exit 1
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" bash "$ORCH_SH" --reopen-current queue-reopen --reason fixed 2>&1
    )" || exit_code=$?

    assert_exit_code "$exit_code" 0 "reopen-current 恢复失败队列"
    assert_contains "$output" "queue-reopen: RUNNING 20260609-orch-reopen" "reopen-current 输出 running"

    cleanup_temp_project "$dir"
}

test_queue_create_and_status
test_launcher_dry_run_codex_template
test_launcher_auto_uses_tmux_when_available
test_launcher_auto_tool_uses_engine_mode
test_queue_reopen_current

print_summary
exit "$fail_count"
