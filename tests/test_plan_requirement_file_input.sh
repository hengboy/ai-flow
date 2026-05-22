#!/bin/bash
# test_plan_requirement_file_input.sh — plan executor requirement file input tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/testkit.bash"

echo "=== plan requirement file input 测试 ==="
echo ""

PLAN_EXECUTOR="$PROJECT_ROOT/subagents/shared/plan/bin/plan-executor.sh"

run_dump() {
    local project_dir="$1"
    local requirement_arg="$2"
    (
        cd "$project_dir" || exit 1
        AI_FLOW_PLAN_EXECUTOR_DUMP_NORMALIZED_REQUIREMENT=1 \
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" \
        bash "$PLAN_EXECUTOR" "$requirement_arg"
    )
}

test_requirement_file_is_expanded() {
    local dir
    dir="$(create_temp_project "plan-req-file")"
    git -C "$dir" init >/dev/null 2>&1
    cat > "$dir/requirements.md" <<'EOF'
# 完整需求

- 目标：支持文件形式传递需求。
- 验收：plan 中必须保留这一行。
EOF

    local output exit_code=0
    output="$(run_dump "$dir" "requirements.md" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "文件路径输入归一化成功"
    assert_contains "$output" "SOURCE:requirements.md" "需求来源记录相对路径"
    assert_contains "$output" "# 完整需求" "读取需求文件标题"
    assert_contains "$output" "plan 中必须保留这一行" "读取需求文件正文"
    assert_not_contains "$output" "REQUIREMENT_BEGIN"$'\n'"requirements.md" "需求正文不是路径本身"

    cleanup_temp_project "$dir"
}

test_literal_requirement_is_preserved() {
    local dir
    dir="$(create_temp_project "plan-req-literal")"
    git -C "$dir" init >/dev/null 2>&1

    local output exit_code=0
    output="$(run_dump "$dir" "直接输入需求文本" 2>&1)" || exit_code=$?
    assert_exit_code "$exit_code" 0 "普通文本输入归一化成功"
    assert_contains "$output" "SOURCE:需求描述" "普通文本来源保持默认"
    assert_contains "$output" "REQUIREMENT_BEGIN"$'\n'"直接输入需求文本"$'\n'"REQUIREMENT_END" "普通文本保持原样"

    cleanup_temp_project "$dir"
}

test_relative_file_prefers_original_working_directory() {
    local dir
    dir="$(create_temp_project "plan-req-subdir")"
    git -C "$dir" init >/dev/null 2>&1
    mkdir -p "$dir/docs"
    printf '根目录需求\n' > "$dir/req.md"
    printf '子目录需求\n' > "$dir/docs/req.md"

    local output exit_code=0
    output="$(
        cd "$dir/docs" || exit 1
        AI_FLOW_PLAN_EXECUTOR_DUMP_NORMALIZED_REQUIREMENT=1 \
        AI_FLOW_HOME="$PROJECT_ROOT/runtime" \
        bash "$PLAN_EXECUTOR" "req.md" 2>&1
    )" || exit_code=$?
    assert_exit_code "$exit_code" 0 "子目录相对路径输入归一化成功"
    assert_contains "$output" "SOURCE:docs/req.md" "需求来源优先记录调用目录下文件"
    assert_contains "$output" "REQUIREMENT_BEGIN"$'\n'"子目录需求"$'\n'"REQUIREMENT_END" "读取调用目录下的相对路径文件"
    assert_not_contains "$output" "根目录需求" "不误读项目根同名文件"

    cleanup_temp_project "$dir"
}

test_requirement_file_is_expanded
test_literal_requirement_is_preserved
test_relative_file_prefers_original_working_directory

print_summary
exit "$fail_count"
