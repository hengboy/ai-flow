#!/usr/bin/env bash
# flow-suggest-slug.sh — AI Flow 智能 Slug 建议
#
# 从需求描述中提取关键词，生成符合规范的 slug。
#
# 用法:
#   flow-suggest-slug.sh <description>
#   flow-suggest-slug.sh "添加用户登录验证功能"
#
# 输出:
#   建议的 slug（如: user-login-validate）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.ai-flow/state"

# 英文停用词列表
STOP_WORDS_EN="the a an for of in to is it that and or but with at by on from as into about between through during before after above below again further then once here there when where why how all each every both few more most other some such no not only own same so than too very"

# 检查输入
if [[ $# -lt 1 || -z "${1:-}" ]]; then
    echo "ERROR: Missing description" >&2
    echo "Usage: $0 <description>" >&2
    exit 1
fi

DESCRIPTION="$1"
MAX_LENGTH=30

# ---- Step 1: 检测语言 ----
contains_chinese() {
    echo "$1" | grep -qE '[一-龥]' 2>/dev/null
}

# ---- Step 2: 提取关键词 ----
extract_english_keywords() {
    local text="$1"

    # 提取英文单词（含数字）
    local words
    words=$(echo "$text" | grep -oE '[a-zA-Z][a-zA-Z0-9]+' | tr '[:upper:]' '[:lower:]' || true)

    if [[ -z "$words" ]]; then
        return
    fi

    # 过滤停用词
    local result=""
    local count=0
    while IFS= read -r word; do
        [[ -z "$word" ]] && continue

        # 检查是否为停用词
        local is_stop=false
        for stop in $STOP_WORDS_EN; do
            if [[ "$word" == "$stop" ]]; then
                is_stop=true
                break
            fi
        done

        if [[ "$is_stop" == "false" ]]; then
            if [[ -n "$result" ]]; then
                result="${result}-${word}"
            else
                result="$word"
            fi
            ((count++))

            # 最多取 5 个有意义的词
            if [[ $count -ge 5 ]]; then
                break
            fi
        fi
    done <<< "$words"

    echo "$result"
}

extract_chinese_keywords() {
    local text="$1"

    # 方案 1: 尝试使用 Python pinyin 库（可选）
    if command -v python3 &>/dev/null; then
        local pinyin_slug
        pinyin_slug=$(python3 -c "
import sys
try:
    from pypinyin import pinyin, Style
    text = sys.argv[1]
    # 提取中文字符
    chars = [c for c in text if '\\u4e00' <= c <= '\\u9fff']
    if not chars:
        print('')
        sys.exit(0)
    # 取前 5 个字符的拼音首字母
    result = []
    for c in chars[:5]:
        py = pinyin(c, style=Style.FIRST_LETTER)
        if py and py[0]:
            result.append(py[0][0].lower())
    print('-'.join(result))
except ImportError:
    print('')
    sys.exit(0)
" "$text" 2>/dev/null) || true

        if [[ -n "$pinyin_slug" ]]; then
            echo "$pinyin_slug"
            return
        fi
    fi

    # 方案 2: 回退 — 直接取中文字符
    local chars
    chars=$(echo "$text" | grep -oE '[一-龥]' | head -5 | tr -d '\n' || true)
    if [[ -n "$chars" ]]; then
        echo "$chars"
    fi
}

# ---- Step 3: 生成 slug ----
generate_slug() {
    local slug=""

    if contains_chinese "$DESCRIPTION"; then
        # 混合或中文：先尝试提取中文关键词，再提取英文
        local cn_part
        cn_part=$(extract_chinese_keywords "$DESCRIPTION")
        if [[ -n "$cn_part" ]]; then
            slug="$cn_part"
        fi

        # 如果还有英文部分，追加
        local en_part
        en_part=$(extract_english_keywords "$DESCRIPTION")
        if [[ -n "$en_part" ]]; then
            if [[ -n "$slug" ]]; then
                slug="${slug}-${en_part}"
            else
                slug="$en_part"
            fi
        fi
    else
        # 纯英文
        slug=$(extract_english_keywords "$DESCRIPTION")
    fi

    # 如果仍然为空，使用时间戳回退
    if [[ -z "$slug" ]]; then
        slug="flow-$(date +%s)"
    fi

    # 清理非法字符：先过滤中文，再过滤非 a-z0-9- 字符
    # macOS sed 不支持 [一-龥] 范围，改用 Python 或分步处理
    if command -v python3 &>/dev/null; then
        slug=$(python3 -c "
import re, sys
s = sys.argv[1]
# 只保留小写字母、数字、连字符、中文字符
s = re.sub(r'[^a-z0-9一-鿿\-]', '', s)
print(s)
" "$slug" 2>/dev/null) || slug=$(echo "$slug" | sed 's/[^a-z0-9\-]//g')
    else
        slug=$(echo "$slug" | sed 's/[^a-z0-9\-]//g')
    fi

    # 截断到最大长度
    if [[ ${#slug} -gt $MAX_LENGTH ]]; then
        # 优先在连字符处截断
        local truncated="${slug:0:$MAX_LENGTH}"
        local last_hyphen
        last_hyphen=$(echo "$truncated" | grep -oE '[^-]*$' | wc -c)
        if [[ $last_hyphen -gt 10 ]]; then
            slug="${truncated:0:$((MAX_LENGTH - last_hyphen + 1))}"
        else
            slug="$truncated"
        fi
    fi

    # 去除首尾连字符
    slug=$(echo "$slug" | sed 's/^-//;s/-$//')

    echo "$slug"
}

# ---- Step 4: 检查冲突 ----
resolve_conflicts() {
    local slug="$1"

    if [[ ! -d "$STATE_DIR" ]]; then
        echo "$slug"
        return
    fi

    if [[ ! -f "$STATE_DIR/${slug}.json" ]]; then
        echo "$slug"
        return
    fi

    # 追加数字后缀
    local i=1
    while [[ -f "$STATE_DIR/${slug}-${i}.json" ]]; do
        ((i++))
    done

    echo "${slug}-${i}"
}

# ---- 主流程 ----
raw_slug=$(generate_slug)
final_slug=$(resolve_conflicts "$raw_slug")

echo "$final_slug"
