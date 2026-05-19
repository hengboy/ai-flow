#!/bin/bash
# testkit.bash — AI Flow 测试通用工具函数。
# 在测试脚本开头 source 即可使用。

set -uo pipefail

TESTKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$TESTKIT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

SCRIPTS_DIR="$PROJECT_ROOT/runtime/scripts"
SHARED_LIB="$PROJECT_ROOT/subagents/shared/lib"
RUNTIME_LIB="$PROJECT_ROOT/runtime/lib"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass_count=0
fail_count=0

test_pass() {
    echo -e "  ${GREEN}PASS${NC} $1"
    ((pass_count++))
}

test_fail() {
    echo -e "  ${RED}FAIL${NC} $1"
    if [[ -n "${2:-}" ]]; then
        echo "    详情: $2"
    fi
    ((fail_count++))
}

test_info() {
    echo -e "  ${YELLOW}INFO${NC} $1"
}

# assert_equal <actual> <expected> <label>
assert_equal() {
    if [[ "$1" == "$2" ]]; then
        test_pass "$3"
    else
        test_fail "$3" "期望='$2' 实际='$1'"
    fi
}

# assert_contains <haystack> <needle> <label>
assert_contains() {
    if [[ "$1" == *"$2"* ]]; then
        test_pass "$3"
    else
        test_fail "$3" "期望包含 '$2' 但实际='$1'"
    fi
}

# assert_not_contains <haystack> <needle> <label>
assert_not_contains() {
    if [[ "$1" != *"$2"* ]]; then
        test_pass "$3"
    else
        test_fail "$3" "不应包含 '$2'"
    fi
}

# assert_exit_code <actual_code> <expected_code> <label>
assert_exit_code() {
    if [[ "$1" -eq "$2" ]]; then
        test_pass "$3"
    else
        test_fail "$3" "期望退出码=$2 实际=$1"
    fi
}

# create_temp_project [name]
# 创建临时项目目录（位于 .ai-flow-tests 下），返回路径。
create_temp_project() {
    local name="${1:-test-$$}"
    local test_root="$PROJECT_ROOT/.ai-flow-tests"
    mkdir -p "$test_root"
    local dir
    dir="$(mktemp -d "${test_root}/${name}.XXXXXX")"
    mkdir -p "$dir/.ai-flow/state"
    printf '%s' "$dir"
}

# cleanup_temp_project <dir>
cleanup_temp_project() {
    rm -rf "$1"
}

# create_minimal_state <project_dir> <slug>
# 创建一个最小合法的状态文件。
create_minimal_state() {
    local project_dir="$1"
    local slug="$2"
    local state_dir="$project_dir/.ai-flow/state"
    mkdir -p "$state_dir"

    python3 - "$state_dir" "$slug" "$project_dir" <<'PY'
import json
import sys
from pathlib import Path

state_dir = Path(sys.argv[1])
slug = sys.argv[2]
project_dir = sys.argv[3]

state = {
    "schema_version": 4,
    "slug": slug,
    "title": "测试功能",
    "plan_file": ".ai-flow/plans/test.md",
    "execution_scope": {
        "mode": "plan_repos",
        "repos": [{
            "id": "owner",
            "path": ".",
            "git_root": project_dir,
            "role": "owner"
        }]
    },
    "current_status": "AWAITING_PLAN_REVIEW",
    "created_at": "2026-05-19T10:00:00+08:00",
    "updated_at": "2026-05-19T10:00:00+08:00",
    "transitions": [{
        "seq": 1,
        "at": "2026-05-19T10:00:00+08:00",
        "event": "plan_created",
        "from": None,
        "to": "AWAITING_PLAN_REVIEW",
        "actor": "test-runner",
        "payload": {
            "title": "测试功能",
            "plan_file": ".ai-flow/plans/test.md",
            "execution_scope": {
                "mode": "plan_repos",
                "repos": [{
                    "id": "owner",
                    "path": ".",
                    "git_root": project_dir,
                    "role": "owner"
                }]
            }
        },
        "note": "创建计划"
    }]
}

(state_dir / f"{slug}.json").write_text(
    json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8"
)
PY
}

print_summary() {
    echo ""
    echo "==============================="
    echo -e "  测试完成: ${GREEN}$pass_count PASS${NC}, ${RED}$fail_count FAIL${NC}"
    echo "==============================="
}
