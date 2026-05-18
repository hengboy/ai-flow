#!/bin/bash
# flow-state.sh — AI Flow JSON 状态机入口

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/flow_state_cli.py" "$@"
