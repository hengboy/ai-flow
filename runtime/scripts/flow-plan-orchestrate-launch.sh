#!/bin/bash
# flow-plan-orchestrate-launch.sh — 自动开启新会话继续队列

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_FLOW_HOME="${AI_FLOW_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
    cat >&2 <<'EOF'
用法:
  flow-plan-orchestrate-launch.sh --queue <queue_slug> [--dry-run]
EOF
    exit 1
}

queue_slug=""
dry_run=0
while [ $# -gt 0 ]; do
    case "$1" in
        --queue) queue_slug="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        *) usage ;;
    esac
done
[ -n "$queue_slug" ] || usage

if [ ! -f "${AI_FLOW_HOME}/lib/flow-root-helper.sh" ]; then
    echo "错误: 缺少 flow-root-helper.sh: ${AI_FLOW_HOME}/lib/flow-root-helper.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${AI_FLOW_HOME}/lib/flow-root-helper.sh"
PROJECT_DIR="$(resolve_flow_root)" || {
    echo "当前目录不在包含 .ai-flow/state 的 flow root 内。" >&2
    exit 1
}

resolver_output="$(
    cd "$PROJECT_DIR" && AI_FLOW_HOME="$AI_FLOW_HOME" python3 - "$queue_slug" <<'PY'
import json
import os
import shlex
import shutil
import sys
from pathlib import Path

queue_slug = sys.argv[1]
runtime_lib = Path(os.environ.get("AI_FLOW_HOME", Path.home() / ".config" / "ai-flow")) / "lib"
if str(runtime_lib) not in sys.path:
    sys.path.insert(0, str(runtime_lib))

try:
    from flow_config import get_config_source, load_config
except Exception as exc:
    raise SystemExit(f"配置加载失败: {exc}")

config = load_config()
orchestration = config.get("orchestration") or {}
engine_mode = str(config.get("engine_mode") or "auto")
tool_setting = str(orchestration.get("tool") or "auto")
launcher_setting = str(orchestration.get("launcher") or "auto")
templates = {
    "codex": "codex --cd {cwd} {prompt}",
    "claude": "claude {prompt}",
    "custom": "",
}
templates.update(orchestration.get("command_templates") or {})

prompt_text = (
    f"/ai-flow-plan-orchestrate --resume {queue_slug}\n\n"
    "继续执行该队列，不等待人工介入；遇到需要业务取舍、权限、密钥、pull conflict、"
    "验证失效或额外改动不明等硬阻塞时，调用 flow-plan-orchestrate.sh --fail 写入 FAILED 并停止。"
)
prompt = shlex.quote(prompt_text)
cwd = shlex.quote(str(Path.cwd()))

def available(name: str) -> bool:
    return shutil.which(name) is not None

def infer_tool() -> str:
    if tool_setting != "auto":
        return tool_setting
    if get_config_source("orchestration.tool") in {"project", "user"} and tool_setting != "auto":
        return tool_setting
    if engine_mode in templates and engine_mode != "auto":
        return engine_mode
    for candidate in ("codex", "claude"):
        if available(candidate):
            return candidate
    custom_template = templates.get("custom", "")
    if custom_template:
        return "custom"
    return "codex"

tool = infer_tool()
template = str(templates.get(tool) or "")
if not template:
    raise SystemExit(f"orchestration.command_templates.{tool} 为空")
command = template.format(cwd=cwd, prompt=prompt, queue_slug=shlex.quote(queue_slug))

def infer_launcher() -> str:
    if launcher_setting != "auto":
        return launcher_setting
    if available("tmux"):
        return "tmux"
    if sys.platform == "darwin" and available("osascript"):
        return "terminal"
    return "none"

launcher = infer_launcher()
session_name = "ai-flow-" + "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in queue_slug)
if launcher == "tmux":
    launch_command = "tmux new-session -d -s " + shlex.quote(session_name) + " " + shlex.quote(command)
elif launcher == "terminal":
    launch_command = "osascript -e " + shlex.quote(
        'tell application "Terminal" to do script ' + json.dumps(command)
    )
elif launcher == "none":
    launch_command = command
else:
    template_launcher = str((orchestration.get("launcher_templates") or {}).get(launcher) or "")
    if not template_launcher:
        raise SystemExit(f"不支持的 orchestration.launcher: {launcher}")
    launch_command = template_launcher.format(command=shlex.quote(command), queue_slug=shlex.quote(queue_slug))

print(f"tool={tool}")
print(f"launcher={launcher}")
print(f"command={command}")
print(f"launch_command={launch_command}")
PY
)"

printf '%s\n' "$resolver_output"
launch_command="$(printf '%s\n' "$resolver_output" | awk -F= '$1=="launch_command"{sub(/^launch_command=/,""); print; exit}')"
[ -n "$launch_command" ] || {
    echo "无法生成 launch_command" >&2
    exit 1
}

if [ "$dry_run" -eq 1 ]; then
    exit 0
fi

eval "$launch_command"
