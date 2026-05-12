#!/bin/bash
# config-loader.sh — 从 ~/.config/ai-flow/setting.json 加载配置，替代环境变量读取。
# 使用前需先设置 AI_FLOW_HOME（默认 $HOME/.config/ai-flow）。

_ai_flow_config_file() {
    printf '%s' "${AI_FLOW_HOME:-$HOME/.config/ai-flow}/setting.json"
}

_ai_flow_config_loaded=0

load_all_settings() {
    [ "$_ai_flow_config_loaded" -eq 0 ] || return 0
    local config_file
    config_file="$(_ai_flow_config_file)"
    [ -f "$config_file" ] || return 0

    eval "$(python3 -c "
import json, sys
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser()
if not config_path.is_file():
    sys.exit(0)
config = json.loads(config_path.read_text(encoding='utf-8'))

def flatten(obj, prefix=''):
    items = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            new_key = f'{prefix}_{k}' if prefix else k
            if isinstance(v, dict):
                items.extend(flatten(v, new_key))
            elif v is not None:
                env_name = f'AI_FLOW_SETTING_{new_key.upper()}'
                escaped = str(v).replace(\"'\", \"'\\\"'\\\"'\")
                items.append(f\"{env_name}='{escaped}'\")
    return items

for line in flatten(config):
    print(line)
" "$config_file")"

    _ai_flow_config_loaded=1
}

# get_setting <dot.key> <fallback>
# 优先级：setting.json > fallback
get_setting() {
    local key="$1"
    local fallback="$2"
    local setting_var
    setting_var="AI_FLOW_SETTING_$(echo "$key" | tr '.' '_' | tr '[:lower:]' '[:upper:]')"
    local val="${!setting_var:-}"
    if [ -n "$val" ]; then
        echo "$val"
    else
        echo "$fallback"
    fi
}

expand_tilde() {
    eval echo "$1"
}
