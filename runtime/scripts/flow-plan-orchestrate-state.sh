#!/bin/bash
# flow-plan-orchestrate-state.sh — AI Flow 多普通 plan 队列状态机入口

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/flow_plan_orchestration_state_cli.py" "$@"
