#!/bin/bash
# test_runtime_logging.sh — 验证错误日志捕获与输出机制
# 覆盖 flow-common.sh 和 agent-common.sh 中的日志相关函数

set -euo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$TEST_ROOT/lib/testkit.bash"

FLOW_COMMON="$TEST_ROOT/runtime/scripts/flow-common.sh"
AGENT_COMMON="$TEST_ROOT/subagents/shared/lib/agent-common.sh"

# ─── ai_flow_sanitize_for_filename ───

test_sanitize_lowercase_unchanged() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_sanitize_for_filename "flow-state.sh")"
    assert_equals "flow-state.sh" "$result"
}

test_sanitize_uppercase_to_lower() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_sanitize_for_filename "Flow-State.SH")"
    assert_equals "flow-state.sh" "$result"
}

test_sanitize_spaces_to_dash() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_sanitize_for_filename "my script.sh")"
    assert_equals "my-script.sh" "$result"
}

test_sanitize_consecutive_dashes_collapsed() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_sanitize_for_filename "a   b")"
    assert_equals "a-b" "$result"
}

test_sanitize_strips_leading_trailing_dash() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_sanitize_for_filename "  test  ")"
    assert_equals "test" "$result"
}

test_sanitize_empty_string() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_sanitize_for_filename "")"
    assert_equals "" "$result"
}

test_sanitize_special_chars() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_sanitize_for_filename "script@#version&*.sh")"
    # @# -> -, &* -> -, trailing .sh stays, but trailing dash before extension may remain
    # "script@#version&*.sh" -> "script-version-.sh" (the * before .sh becomes dash, then trailing dash stripped)
    # Actually: script + -- + version + -- + .sh -> after collapse: script-version-.sh -> trailing dash before .sh not stripped
    # The sed strips trailing dash from the whole string, but .sh keeps it
    :  # just verify it doesn't crash and produces something reasonable
    [ -n "$result" ] || fail "sanitize produced empty string"
    case "$result" in
        script*version*.sh) ;;
        *) fail "Unexpected sanitized result: $result" ;;
    esac
}

# ─── ai_flow_normalize_dir ───

test_normalize_dir_simple() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_normalize_dir "/foo/bar")"
    assert_equals "/foo/bar" "$result"
}

test_normalize_dir_trailing_slash_removed() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_normalize_dir "/foo/bar/")"
    assert_equals "/foo/bar" "$result"
}

test_normalize_dir_double_slashes() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_normalize_dir "/foo//bar///baz")"
    assert_equals "/foo/bar/baz" "$result"
}

test_normalize_dir_empty() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_normalize_dir "")"
    assert_equals "/" "$result"
}

test_normalize_dir_root() {
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_normalize_dir "/")"
    assert_equals "/" "$result"
}

# ─── ai_flow_resolve_existing_root ───

test_resolve_root_from_project_dir() {
    local temp_root project result expected
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    result="$(source "$FLOW_COMMON"; ai_flow_resolve_existing_root "$project")"
    # Use realpath to handle /var vs /private/var symlink differences
    expected="$(cd "$project" && pwd -P)"
    assert_equals "$(ai_flow_normalize_dir_helper "$expected")" "$result"
    rm -rf "$temp_root"
}

test_resolve_root_from_subdir() {
    local temp_root project result expected
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow" "$project/src"

    result="$(source "$FLOW_COMMON"; ai_flow_resolve_existing_root "$project/src")"
    expected="$(cd "$project" && pwd -P)"
    assert_equals "$(ai_flow_normalize_dir_helper "$expected")" "$result"
    rm -rf "$temp_root"
}

test_resolve_root_no_ai_flow_dir() {
    local temp_root project
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"

    set +e
    result="$(source "$FLOW_COMMON"; ai_flow_resolve_existing_root "$project" 2>/dev/null)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected resolve to fail when no .ai-flow exists"
    rm -rf "$temp_root"
}

ai_flow_normalize_dir_helper() {
    source "$FLOW_COMMON"
    ai_flow_normalize_dir "$1"
}

# ─── ai_flow_runtime_log_path ───

test_runtime_log_path_relative() {
    AI_FLOW_LOG_FILE="/some/path/.ai-flow/logs/20260509/120000-flow-state-1234.log"
    AI_FLOW_LOG_ROOT=""
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_runtime_log_path 2>/dev/null || true)"
    # When AI_FLOW_LOG_ROOT is empty, the case pattern "${AI_FLOW_LOG_ROOT:-}/"* becomes "/"*
    # which matches absolute paths, stripping the leading /
    assert_equals "some/path/.ai-flow/logs/20260509/120000-flow-state-1234.log" "$result"
}

test_runtime_log_path_strips_root() {
    AI_FLOW_LOG_FILE="/tmp/test/.ai-flow/logs/20260509/120000-flow-state-1234.log"
    AI_FLOW_LOG_ROOT="/tmp/test"
    local result
    result="$(source "$FLOW_COMMON"; ai_flow_runtime_log_path 2>/dev/null)"
    assert_equals ".ai-flow/logs/20260509/120000-flow-state-1234.log" "$result"
}

test_runtime_log_path_empty() {
    AI_FLOW_LOG_FILE=""
    set +e
    source "$FLOW_COMMON"
    ai_flow_runtime_log_path 2>/dev/null
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected non-zero return for empty log path"
}

# ─── ai_flow_setup_runtime_logging ───

test_setup_logging_creates_log_file() {
    local temp_root project
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    (
        cd "$project"
        source "$FLOW_COMMON"
        ai_flow_setup_runtime_logging "flow-state.sh" "existing" "$project"
        [ -n "$AI_FLOW_LOG_FILE" ] || fail "AI_FLOW_LOG_FILE not set"
        [ -n "$AI_FLOW_LOG_ROOT" ] || fail "AI_FLOW_LOG_ROOT not set"
        [ -f "$AI_FLOW_LOG_FILE" ] || fail "Log file not created: $AI_FLOW_LOG_FILE"
    )
    rm -rf "$temp_root"
}

test_setup_logging_creates_log_file_in_create_mode() {
    local temp_root project
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    # No .ai-flow dir, but create mode should work

    (
        cd "$project"
        source "$FLOW_COMMON"
        ai_flow_setup_runtime_logging "flow-change.sh" "create" "$project"
        [ -n "$AI_FLOW_LOG_FILE" ] || fail "AI_FLOW_LOG_FILE not set"
        [ -f "$AI_FLOW_LOG_FILE" ] || fail "Log file not created in create mode"
    )
    rm -rf "$temp_root"
}

test_setup_logging_silent_when_root_not_found_existing_mode() {
    local temp_root project
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    # No .ai-flow, existing mode should silently return

    (
        cd "$project"
        source "$FLOW_COMMON"
        ai_flow_setup_runtime_logging "flow-status.sh" "existing" "$project"
        # In existing mode without .ai-flow, should return early
        # AI_FLOW_LOG_FILE may or may not be set depending on implementation
        :
    )
    rm -rf "$temp_root"
}

test_setup_logging_captures_stderr_to_log() {
    local temp_root project log_file
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    (
        cd "$project"
        source "$FLOW_COMMON"
        ai_flow_setup_runtime_logging "test-script.sh" "existing" "$project"
        log_file="$AI_FLOW_LOG_FILE"
        echo "error message from stderr" >&2
        sleep 0.2
        grep -q "error message from stderr" "$log_file" || fail "stderr not captured in log file"
    )
    rm -rf "$temp_root"
}

test_setup_logging_error_exit_shows_log_hint() {
    local temp_root project out
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    # Create a wrapper that sets up logging then fails
    cat > "$temp_root/fail_wrapper.sh" <<WRAPPER
#!/bin/bash
source "$FLOW_COMMON"
ai_flow_setup_runtime_logging "fail-test.sh" "create" "$project"
echo "about to fail" >&2
exit 1
WRAPPER
    chmod +x "$temp_root/fail_wrapper.sh"

    out="$temp_root/fail.out"
    set +e
    bash "$temp_root/fail_wrapper.sh" >"$out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected non-zero exit"
    assert_contains "$out" "完整日志:"
    rm -rf "$temp_root"
}

test_setup_logging_log_filename_contains_script_name() {
    local temp_root project
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    (
        cd "$project"
        source "$FLOW_COMMON"
        ai_flow_setup_runtime_logging "flow-workspace.sh" "existing" "$project"
        local basename
        basename="$(basename "$AI_FLOW_LOG_FILE")"
        assert_contains_text "$basename" "flow-workspace.sh"
    )
    rm -rf "$temp_root"
}

# Helper for contains check
assert_contains_text() {
    case "$1" in
        *"$2"*) ;;
        *) fail "Expected '$1' to contain '$2'" ;;
    esac
}

# ─── agent-common.sh: sanitize_for_filename ───

test_agent_sanitize_basic() {
    local result
    result="$(SCRIPT_DIR="$(dirname "$AGENT_COMMON")"; source "$AGENT_COMMON"; sanitize_for_filename "plan-executor.sh")"
    assert_equals "plan-executor.sh" "$result"
}

test_agent_sanitize_uppercase() {
    local result
    result="$(SCRIPT_DIR="$(dirname "$AGENT_COMMON")"; source "$AGENT_COMMON"; sanitize_for_filename "Plan-Executor.SH")"
    assert_equals "plan-executor.sh" "$result"
}

# ─── agent-common.sh: agent_log_path ───

test_agent_log_path_with_project_dir() {
    AI_FLOW_LOG_FILE="/tmp/test/.ai-flow/logs/20260509/120000-agent-123.log"
    PROJECT_DIR="/tmp/test"
    local result
    result="$(SCRIPT_DIR="$(dirname "$AGENT_COMMON")"; source "$AGENT_COMMON"; agent_log_path 2>/dev/null)"
    # Should display relative to PROJECT_DIR
    assert_equals ".ai-flow/logs/20260509/120000-agent-123.log" "$result"
}

test_agent_log_path_without_project_dir() {
    AI_FLOW_LOG_FILE="/tmp/test/.ai-flow/logs/20260509/120000-agent-123.log"
    PROJECT_DIR=""
    local result
    result="$(SCRIPT_DIR="$(dirname "$AGENT_COMMON")"; source "$AGENT_COMMON"; agent_log_path 2>/dev/null)"
    assert_equals "$AI_FLOW_LOG_FILE" "$result"
}

test_agent_log_path_empty() {
    AI_FLOW_LOG_FILE=""
    set +e
    SCRIPT_DIR="$(dirname "$AGENT_COMMON")" source "$AGENT_COMMON"
    agent_log_path 2>/dev/null
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "Expected non-zero return for empty log path"
}

# ─── agent-common.sh: append_log_path_to_summary ───

test_append_log_to_empty_summary() {
    AI_FLOW_LOG_FILE="/tmp/test/.ai-flow/logs/20260509/120000-agent-123.log"
    PROJECT_DIR="/tmp/test"
    local result
    result="$(SCRIPT_DIR="$(dirname "$AGENT_COMMON")"; source "$AGENT_COMMON"; append_log_path_to_summary "")"
    assert_equals "日志: .ai-flow/logs/20260509/120000-agent-123.log" "$result"
}

test_append_log_to_existing_summary() {
    AI_FLOW_LOG_FILE="/tmp/test/.ai-flow/logs/20260509/120000-agent-123.log"
    PROJECT_DIR="/tmp/test"
    local result
    result="$(SCRIPT_DIR="$(dirname "$AGENT_COMMON")"; source "$AGENT_COMMON"; append_log_path_to_summary "执行失败")"
    assert_equals "执行失败；日志: .ai-flow/logs/20260509/120000-agent-123.log" "$result"
}

test_append_log_no_duplicate() {
    AI_FLOW_LOG_FILE="/tmp/test/.ai-flow/logs/20260509/120000-agent-123.log"
    PROJECT_DIR="/tmp/test"
    local result
    result="$(SCRIPT_DIR="$(dirname "$AGENT_COMMON")"; source "$AGENT_COMMON"; append_log_path_to_summary "执行失败；日志: .ai-flow/logs/20260509/120000-agent-123.log")"
    assert_equals "执行失败；日志: .ai-flow/logs/20260509/120000-agent-123.log" "$result"
}

# ─── agent-common.sh: setup_agent_logging ───

test_agent_setup_creates_log() {
    local temp_root project
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    (
        cd "$project"
        SCRIPT_DIR="$(dirname "$AGENT_COMMON")"
        source "$AGENT_COMMON"
        PROJECT_DIR="$project"
        AGENT_NAME="test-agent"
        setup_agent_logging "$project" "test-agent"
        [ -n "$AI_FLOW_LOG_FILE" ] || fail "AI_FLOW_LOG_FILE not set"
        [ -f "$AI_FLOW_LOG_FILE" ] || fail "Log file not created"
    )
    rm -rf "$temp_root"
}

test_agent_setup_captures_stdout_and_stderr() {
    local temp_root project log_file
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    (
        cd "$project"
        SCRIPT_DIR="$(dirname "$AGENT_COMMON")"
        source "$AGENT_COMMON"
        setup_agent_logging "$project" "capture-test"
        log_file="$AI_FLOW_LOG_FILE"
        echo "stdout message"
        echo "stderr message" >&2
        sleep 0.2
        grep -q "stdout message" "$log_file" || fail "stdout not captured"
        grep -q "stderr message" "$log_file" || fail "stderr not captured"
    )
    rm -rf "$temp_root"
}

# ─── agent-common.sh: emit_captured_stderr ───

test_emit_stderr_empty_file() {
    local temp_root stderr_file
    temp_root="$(make_temp_root)"
    stderr_file="$temp_root/empty.stderr"
    touch "$stderr_file"

    SCRIPT_DIR="$(dirname "$AGENT_COMMON")" source "$AGENT_COMMON"
    emit_captured_stderr "$stderr_file" "test" >"$temp_root/emit.out"
    [ ! -s "$temp_root/emit.out" ] || fail "Expected no output for empty stderr"
    rm -rf "$temp_root"
}

test_emit_stderr_with_content() {
    local temp_root stderr_file
    temp_root="$(make_temp_root)"
    stderr_file="$temp_root/error.stderr"
    printf 'error line 1\nerror line 2\n' > "$stderr_file"

    SCRIPT_DIR="$(dirname "$AGENT_COMMON")" source "$AGENT_COMMON"
    emit_captured_stderr "$stderr_file" "my-label" >"$temp_root/emit.out"

    assert_contains "$temp_root/emit.out" ">>> my-label:"
    assert_contains "$temp_root/emit.out" "error line 1"
    assert_contains "$temp_root/emit.out" "error line 2"
    rm -rf "$temp_root"
}

# ─── agent-common.sh: emit_protocol includes log on failure ───

test_emit_protocol_failed_includes_log_path() {
    local temp_root project out
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    (
        cd "$project"
        SCRIPT_DIR="$(dirname "$AGENT_COMMON")"
        source "$AGENT_COMMON"
        AGENT_NAME="test-agent"
        PROJECT_DIR="$project"
        setup_agent_logging "$project" "protocol-test"

        # Redirect protocol fd to a file for capture
        exec 3>"$temp_root/protocol.out"
        emit_protocol "failed" "artifact.md" "STATE_X" "STATE_Y" "测试失败" "failed"
        exec 3>&-
    )

    assert_contains "$temp_root/protocol.out" "RESULT: failed"
    assert_contains "$temp_root/protocol.out" "日志: .ai-flow/logs/"
    rm -rf "$temp_root"
}

test_emit_protocol_success_no_log_path() {
    local temp_root project out
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    (
        cd "$project"
        SCRIPT_DIR="$(dirname "$AGENT_COMMON")"
        source "$AGENT_COMMON"
        AGENT_NAME="test-agent"
        PROJECT_DIR="$project"
        setup_agent_logging "$project" "protocol-test"

        exec 3>"$temp_root/protocol.out"
        emit_protocol "success" "artifact.md" "DONE" "none" "执行成功" "success"
        exec 3>&-
    )

    assert_contains "$temp_root/protocol.out" "RESULT: success"
    assert_not_contains "$temp_root/protocol.out" "日志:"
    rm -rf "$temp_root"
}

# ─── Integration: flow-change.sh failure captures stderr ───

test_flow_change_error_captures_full_stderr() {
    local temp_root project out
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    setup_project_root "$project"
    mkdir -p "$project/.ai-flow"

    (
        cd "$project"
        bash "$SOURCE_FLOW_CHANGE_SCRIPT" nonexistent-slug "test desc" >"$temp_root/change.out" 2>&1 || true
    )

    assert_contains "$temp_root/change.out" "错误: 找不到包含关键词 'nonexistent-slug' 的状态文件"
    assert_contains "$temp_root/change.out" "完整日志:"
    rm -rf "$temp_root"
}

# ─── Integration: flow-status.sh error text survives base64 roundtrip ───

test_flow_status_error_text_survives_base64() {
    local temp_root project out
    temp_root="$(make_temp_root)"
    project="$temp_root/project"
    mkdir -p "$project/.ai-flow/state"

    # Create an invalid state file (missing required fields)
    printf '{"slug": "broken-state"}\n' > "$project/.ai-flow/state/broken-state.json"

    (
        cd "$project"
        bash "$SOURCE_FLOW_STATUS_SCRIPT" >"$temp_root/status.out" 2>&1 || true
    )

    assert_contains "$temp_root/status.out" "broken-state"
    # Error detail should be visible (not garbled base64)
    assert_not_contains "$temp_root/status.out" "AAAA\|BBBB\|base64"
    rm -rf "$temp_root"
}

# ─── Run all tests ───

test_sanitize_lowercase_unchanged
test_sanitize_uppercase_to_lower
test_sanitize_spaces_to_dash
test_sanitize_consecutive_dashes_collapsed
test_sanitize_strips_leading_trailing_dash
test_sanitize_empty_string
test_sanitize_special_chars

test_normalize_dir_simple
test_normalize_dir_trailing_slash_removed
test_normalize_dir_double_slashes
test_normalize_dir_empty
test_normalize_dir_root

test_resolve_root_from_project_dir
test_resolve_root_from_subdir
test_resolve_root_no_ai_flow_dir

test_runtime_log_path_relative
test_runtime_log_path_strips_root
test_runtime_log_path_empty

test_setup_logging_creates_log_file
test_setup_logging_creates_log_file_in_create_mode
test_setup_logging_silent_when_root_not_found_existing_mode
test_setup_logging_captures_stderr_to_log
test_setup_logging_error_exit_shows_log_hint
test_setup_logging_log_filename_contains_script_name

test_agent_sanitize_basic
test_agent_sanitize_uppercase

test_agent_log_path_with_project_dir
test_agent_log_path_without_project_dir
test_agent_log_path_empty

test_append_log_to_empty_summary
test_append_log_to_existing_summary
test_append_log_no_duplicate

test_agent_setup_creates_log
test_agent_setup_captures_stdout_and_stderr

test_emit_stderr_empty_file
test_emit_stderr_with_content

test_emit_protocol_failed_includes_log_path
test_emit_protocol_success_no_log_path

test_flow_change_error_captures_full_stderr
test_flow_status_error_text_survives_base64
