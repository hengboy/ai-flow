#!/bin/bash
# flow-plan-group-state.sh — AI Flow 计划组状态机 v1 入口

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/flow_plan_group_state_cli.py" "$@"
