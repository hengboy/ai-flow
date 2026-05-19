#!/bin/bash
# run.sh — AI Flow 测试统一入口
# 用法:
#   ./run.sh                  # 运行所有测试
#   ./run.sh python            # 只运行 Python 测试
#   ./run.sh shell             # 只运行 Shell 测试
#   ./run.sh test_flow_status.sh  # 运行指定测试文件

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 清理旧的测试临时目录
mkdir -p "$PROJECT_ROOT/.ai-flow-tests"
rm -rf "$PROJECT_ROOT/.ai-flow-tests"/*

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

total_pass=0
total_fail=0
total_run=0
failed_tests=()

run_python_tests() {
    echo -e "${BLUE}=== Python 单元测试 ===${NC}"
    echo ""

    for test_file in "$SCRIPT_DIR"/test_*.py; do
        [ -f "$test_file" ] || continue
        local name
        name="$(basename "$test_file")"
        ((total_run++))
        echo -e "${YELLOW}运行: $name${NC}"
        local output exit_code=0
        output="$(cd "$PROJECT_ROOT" && python3 "$test_file" 2>&1)" || exit_code=$?
        echo "$output" | head -80
        if [[ $exit_code -eq 0 ]]; then
            echo -e "${GREEN}$name: 通过${NC}"
            ((total_pass++))
        else
            echo -e "${RED}$name: 失败 (退出码=$exit_code)${NC}"
            ((total_fail++))
            failed_tests+=("$name")
        fi
        echo ""
    done
}

run_shell_tests() {
    echo -e "${BLUE}=== Shell 单元测试 ===${NC}"
    echo ""

    for test_file in "$SCRIPT_DIR"/test_*.sh; do
        [ -f "$test_file" ] || continue
        local name
        name="$(basename "$test_file")"
        ((total_run++))
        echo -e "${YELLOW}运行: $name${NC}"
        local output exit_code=0
        output="$(bash "$test_file" 2>&1)" || exit_code=$?
        echo "$output"
        if [[ $exit_code -eq 0 ]]; then
            echo -e "${GREEN}$name: 通过${NC}"
            ((total_pass++))
        else
            echo -e "${RED}$name: 失败 (退出码=$exit_code)${NC}"
            ((total_fail++))
            failed_tests+=("$name")
        fi
        echo ""
    done
}

# 参数处理
case "${1:-all}" in
    all)
        run_python_tests
        run_shell_tests
        ;;
    python|py)
        run_python_tests
        ;;
    shell|sh)
        run_shell_tests
        ;;
    clean)
        rm -rf "$PROJECT_ROOT/.ai-flow-tests"/*
        echo "已清理 .ai-flow-tests 目录"
        exit 0
        ;;
    *)
        # 尝试作为文件名运行
        if [[ -f "$SCRIPT_DIR/$1" ]]; then
            ((total_run++))
            echo -e "${YELLOW}运行: $1${NC}"
            case "$1" in
                *.py)
                    output="$(cd "$PROJECT_ROOT" && python3 "$SCRIPT_DIR/$1" 2>&1)" || true
                    ;;
                *.sh)
                    output="$(bash "$SCRIPT_DIR/$1" 2>&1)" || true
                    ;;
            esac
            echo "$output"
        else
            echo "未知测试: $1"
            echo "用法: $0 [all|python|shell|clean|<test-file>]"
            exit 1
        fi
        ;;
esac

# 汇总
echo "==============================="
echo -e "  总测试数: $total_run"
echo -e "  ${GREEN}通过: $total_pass${NC}"
echo -e "  ${RED}失败: $total_fail${NC}"
if [[ ${#failed_tests[@]} -gt 0 ]]; then
    echo -e "  失败列表: ${failed_tests[*]}"
fi
echo "==============================="

[[ $total_fail -eq 0 ]] || exit 1
