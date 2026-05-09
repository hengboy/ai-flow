#!/bin/bash

ai_flow_sanitize_for_filename() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

ai_flow_normalize_dir() {
    local value
    value="$(printf '%s' "${1:-}" | sed 's#//*#/#g')"
    if [ -z "$value" ]; then
        printf '/\n'
        return 0
    fi
    if [ "$value" != "/" ]; then
        value="${value%/}"
    fi
    printf '%s\n' "$value"
}

ai_flow_resolve_existing_root() {
    local candidate="${1:-$(pwd)}"
    local parent

    candidate="$(cd "$candidate" 2>/dev/null && pwd -P)" || return 1
    candidate="$(ai_flow_normalize_dir "$candidate")"
    while true; do
        if [ -d "$candidate/.ai-flow" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        parent="$(cd "$candidate/.." 2>/dev/null && pwd -P)" || break
        parent="$(ai_flow_normalize_dir "$parent")"
        if [ "$parent" = "$candidate" ]; then
            break
        fi
        candidate="$parent"
    done
    return 1
}

ai_flow_runtime_log_path() {
    local log_file="${1:-${AI_FLOW_LOG_FILE:-}}"
    if [ -z "$log_file" ]; then
        return 1
    fi
    case "$log_file" in
        "${AI_FLOW_LOG_ROOT:-}/"*)
            printf '%s\n' "${log_file#${AI_FLOW_LOG_ROOT}/}"
            ;;
        *)
            printf '%s\n' "$log_file"
            ;;
    esac
}

ai_flow_setup_runtime_logging() {
    local script_name="$1"
    local root_mode="${2:-existing}"
    local start_dir="${3:-$(pwd)}"
    local slug="${4:-}"
    local root="" safe_name logs_dir timestamp

    if root="$(ai_flow_resolve_existing_root "$start_dir")"; then
        :
    elif [ "$root_mode" = "create" ]; then
        root="$(cd "$start_dir" 2>/dev/null && pwd -P)" || return 0
        root="$(ai_flow_normalize_dir "$root")"
    else
        return 0
    fi

    if [ -n "$slug" ]; then
        safe_name="$(ai_flow_sanitize_for_filename "$slug")"
    else
        safe_name="$(ai_flow_sanitize_for_filename "${script_name##*/}")"
    fi
    [ -n "$safe_name" ] || safe_name="runtime"

    logs_dir="$root/.ai-flow/logs/$(date +%Y%m%d)"
    mkdir -p "$logs_dir"

    timestamp="$(date +%H%M%S)"
    AI_FLOW_LOG_ROOT="$root"
    AI_FLOW_LOG_FILE="$logs_dir/${timestamp}-${safe_name}-$$.log"
    export AI_FLOW_LOG_ROOT AI_FLOW_LOG_FILE

    : > "$AI_FLOW_LOG_FILE"
    exec 9>&2
    exec 2> >(tee -a "$AI_FLOW_LOG_FILE" >&9)
    trap 'rc=$?; if [ "$rc" -ne 0 ] && [ -n "${AI_FLOW_LOG_FILE:-}" ]; then echo "完整日志: $(ai_flow_runtime_log_path)" >&2; fi' EXIT
}
