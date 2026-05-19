#!/bin/bash
# config-loader.sh — 从 ~/.config/ai-flow/setting.json 和项目级 .ai-flow/setting.json 加载配置。
# 项目级配置优先级高于用户级配置。
# 使用前需先设置 AI_FLOW_HOME（默认 $HOME/.config/ai-flow）。

_ai_flow_config_file() {
    printf '%s' "${AI_FLOW_HOME:-$HOME/.config/ai-flow}/setting.json"
}

_ai_flow_config_loaded=0

_ai_flow_setting_source_var_name() {
    local key="$1"
    printf 'AI_FLOW_SETTING_SOURCE_%s' "$(echo "$key" | tr '.' '_' | tr '[:lower:]' '[:upper:]')"
}

load_all_settings() {
    [ "$_ai_flow_config_loaded" -eq 0 ] || return 0
    local config_file
    config_file="$(_ai_flow_config_file)"

    # Resolve flow root: find nearest .ai-flow/state from cwd
    local project_config_file=""
    local _cwd
    _cwd="$(pwd)"
    local _candidate="$_cwd"
    while true; do
        if [ -d "$_candidate/.ai-flow/state" ]; then
            if [ -f "$_candidate/.ai-flow/setting.json" ]; then
                project_config_file="$_candidate/.ai-flow/setting.json"
            fi
            break
        fi
        if [ "$_candidate" = "/" ] || [ "$_candidate" = "//" ]; then
            break
        fi
        local _parent
        _parent="$(cd "$_candidate/.." 2>/dev/null && pwd)" || break
        if [ -z "$_parent" ] || [ "$_parent" = "$_candidate" ]; then
            break
        fi
        _candidate="$_parent"
    done

    eval "$(python3 -c "
import json, sys
from pathlib import Path

user_path = Path(sys.argv[1]).expanduser() if sys.argv[1] else None
project_path = Path(sys.argv[2]) if sys.argv[2] else None

source_map = {}

def deep_merge(user, project, prefix=''):
    '''dict 递归合并；标量项目级覆盖用户级；list 项目级替换；null 跳过。'''
    if not isinstance(user, dict) or not isinstance(project, dict):
        return project if project is not None else user
    merged = dict(user)
    for k, v in user.items():
        if prefix:
            path = f'{prefix}.{k}'
        else:
            path = k
        if not isinstance(v, dict) and v is not None:
            source_map[path] = 'user'
    for k, v in project.items():
        if prefix:
            path = f'{prefix}.{k}'
        else:
            path = k
        if v is None:
            continue  # null 不覆盖用户级
        if k in merged and isinstance(merged[k], dict) and isinstance(v, dict):
            merged[k] = deep_merge(merged[k], v, path)
        else:
            merged[k] = v
            if not isinstance(v, dict):
                source_map[path] = 'project'
    return merged

user_config = {}
if user_path and user_path.is_file():
    try:
        user_config = json.loads(user_path.read_text(encoding='utf-8'))
    except json.JSONDecodeError:
        print(f'echo \"错误: 用户级配置解析失败: {user_path}\" >&2', file=sys.stderr)
        sys.exit(1)

project_config = {}
if project_path and project_path.is_file():
    try:
        project_config = json.loads(project_path.read_text(encoding='utf-8'))
    except json.JSONDecodeError:
        print(f'echo \"错误: 项目级配置解析失败: {project_path}\" >&2', file=sys.stderr)
        sys.exit(1)

config = deep_merge(user_config, project_config)

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

def flatten_sources(source_dict):
    items = []
    for key, value in source_dict.items():
        env_name = f'AI_FLOW_SETTING_SOURCE_{key.replace(\".\", \"_\").upper()}'
        items.append(f\"{env_name}='{value}'\")
    return items

for line in flatten(config):
    print(line)
for line in flatten_sources(source_map):
    print(line)
" "${config_file:-}" "${project_config_file:-}")"

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

get_setting_source() {
    local key="$1"
    local setting_var
    setting_var="$(_ai_flow_setting_source_var_name "$key")"
    local source="${!setting_var:-}"
    if [ -n "$source" ]; then
        echo "$source"
    else
        echo "fallback"
    fi
}

get_setting_source_label() {
    case "$(get_setting_source "$1")" in
        project) echo "项目级配置" ;;
        user) echo "用户级配置" ;;
        *) echo "默认值" ;;
    esac
}

expand_tilde() {
    eval echo "$1"
}
