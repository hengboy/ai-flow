#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/testkit.bash"

build_groups_json() {
    local prepared_json="$1"
    local mode="${2:-default}"
    python3 - "$prepared_json" "$mode" <<'PY'
import json
import sys
from collections import OrderedDict

prepared = json.loads(sys.argv[1])
mode = sys.argv[2]
repos = prepared.get("repos", [])

def topdir(path: str) -> str:
    return path.split("/", 1)[0]

output = {"repos": []}

for repo_index, repo in enumerate(repos):
    repo_id = repo["repo_id"]
    changed = list(repo.get("changed_files", []))
    if not changed:
        continue

    repo_groups = []
    if mode == "split-topdir":
        buckets = OrderedDict()
        support_files = []
        for path in changed:
            top = topdir(path)
            if top in {"tests", "docs", ".github"}:
                support_files.append(path)
                continue
            buckets.setdefault(top, []).append(path)
        if not buckets:
            buckets["support"] = []
        if support_files:
            first_bucket = next(iter(buckets))
            buckets[first_bucket].extend(support_files)
        for idx, (bucket, files) in enumerate(buckets.items(), start=1):
            repo_groups.append({
                "group_title": f"{bucket} 变更",
                "reason": f"按目录拆分第 {idx} 组",
                "files": files,
            })
    elif mode == "duplicate-file":
        if len(changed) < 2:
            raise SystemExit("duplicate-file 模式需要至少 2 个文件")
        repo_groups = [
            {
                "group_title": "首组",
                "reason": "第一组",
                "files": [changed[0]],
            },
            {
                "group_title": "次组",
                "reason": "第二组",
                "files": [changed[0], changed[1]],
            },
        ]
    elif mode == "missing-last-file":
        repo_groups = [{
            "group_title": "主组",
            "reason": "故意漏掉文件",
            "files": changed[:-1],
        }]
    elif mode == "empty-title":
        repo_groups = [{
            "group_title": "",
            "reason": "标题为空",
            "files": changed,
        }]
    elif mode == "empty-reason":
        repo_groups = [{
            "group_title": "空原因",
            "reason": "",
            "files": changed,
        }]
    elif mode == "too-many":
        repo_groups = []
        for idx, path in enumerate(changed, start=1):
            repo_groups.append({
                "group_title": f"第{idx}组",
                "reason": f"拆出第{idx}组",
                "files": [path],
            })
    else:
        repo_groups = [{
            "group_title": "主改动",
            "reason": "同一业务变更",
            "files": changed,
        }]

    output["repos"].append({
        "repo_id": repo_id,
        "groups": repo_groups,
    })

if mode == "cross-repo":
    if len(output["repos"]) < 2:
        raise SystemExit("cross-repo 模式需要至少 2 个 repo")
    foreign_file = output["repos"][1]["groups"][0]["files"][0]
    output["repos"][0]["groups"][0]["files"].append(foreign_file)

print(json.dumps(output, ensure_ascii=False))
PY
}

build_message_map_json() {
    local validated_json="$1"
    local mode="${2:-default}"
    python3 - "$validated_json" "$mode" <<'PY'
import json
import sys

validated = json.loads(sys.argv[1])
mode = sys.argv[2]
repos = validated.get("repos", [])
payload = {}

flat = []
for repo in repos:
    repo_id = repo["repo_id"]
    for group in repo.get("groups", []):
        flat.append((repo_id, group.get("message_agent_input", group)))

for idx, (repo_id, group) in enumerate(flat):
    group_id = group["group_id"]
    files = group["files"]
    diff = group["staged_diff"]
    repo_bucket = payload.setdefault(repo_id, {})

    if mode == "missing" and idx == len(flat) - 1:
        continue
    if mode == "invalid-verb" and idx == len(flat) - 1:
        repo_bucket[group_id] = {
            "subject": ":sparkles: 新增代码变更",
            "body": ["同步提交本组改动"],
            "footer": [],
        }
        continue

    if "refreshSession" in diff:
        repo_bucket[group_id] = {
            "subject": ":bug: 修复session 逻辑",
            "body": ["补充过期判空保护", "保持续期判断行为"],
            "footer": [],
        }
    elif any(path.endswith(".md") for path in files):
        repo_bucket[group_id] = {
            "subject": ":memo: 更新文档说明",
            "body": ["同步整理提交说明"],
            "footer": [],
        }
    elif any(path.startswith("scripts/") for path in files):
        repo_bucket[group_id] = {
            "subject": ":wrench: 调整scripts 配置",
            "body": ["同步整理脚本入口"],
            "footer": [],
        }
    elif any(path.startswith("tests/") for path in files):
        repo_bucket[group_id] = {
            "subject": ":white_check_mark: 补充测试覆盖",
            "body": ["同步整理验证脚本"],
            "footer": [],
        }
    else:
        repo_bucket[group_id] = {
            "subject": ":sparkles: 添加代码变更",
            "body": ["同步提交本组改动"],
            "footer": [],
        }

print(json.dumps(payload, ensure_ascii=False))
PY
}

run_commit_with_generated_messages() {
    local commit_script="$1"
    local output_file="$2"
    shift 2
    local group_mode="default"
    local message_mode="default"
    if [ "$#" -gt 0 ]; then
        group_mode="$1"
        shift
    fi
    if [ "$#" -gt 0 ]; then
        message_mode="$1"
        shift
    fi
    local prepared_json groups_json validated_json message_map_json session_id
    prepared_json="$(bash "$commit_script" "$@" --prepare-json)"
    session_id="$(python3 - "$prepared_json" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["session_id"])
PY
)"
    groups_json="$(build_groups_json "$prepared_json" "$group_mode")"
    validated_json="$(bash "$commit_script" "$@" --session-id "$session_id" --validate-groups-json "$groups_json")"
    message_map_json="$(build_message_map_json "$validated_json" "$message_mode")"
    bash "$commit_script" "$@" --session-id "$session_id" --groups-json "$validated_json" --message-map-json "$message_map_json" >"$output_file" 2>&1
    [ -s "$output_file" ] || fail "Expected commit output file to be non-empty: $output_file"
}

assert_line_order() {
    local file="$1"
    local first="$2"
    local second="$3"
    local first_line second_line
    first_line="$(grep -nF "$first" "$file" | head -n1 | cut -d: -f1)"
    second_line="$(grep -nF "$second" "$file" | head -n1 | cut -d: -f1)"
    [ -n "$first_line" ] || fail "Expected to find '$first' in $file"
    [ -n "$second_line" ] || fail "Expected to find '$second' in $file"
    [ "$first_line" -lt "$second_line" ] || fail "Expected '$first' before '$second' in $file"
}

test_prepare_json_returns_repo_context_not_groups() {
    local temp_root repo commit_script prepared_json
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "prepare-shape")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        python3 - "$prepared_json" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
repos = payload.get("repos", [])
assert len(repos) == 1
repo = repos[0]
assert repo["repo_id"] == "owner"
assert payload["session_id"]
assert "changed_files" in repo
assert "file_diffs" in repo
assert repo["group_agent_input"]["mode"] == "group"
assert repo["group_agent_input"]["session_id"] == payload["session_id"]
assert "src/app.txt" in repo["changed_files"]
diff_map = {item["path"]: item["diff"] for item in repo["file_diffs"]}
assert "src/app.txt" in diff_map
assert "local change" in diff_map["src/app.txt"]
assert "group_id" not in repo
assert "staged_diff" not in repo
print("ok")
PY
    )

    rm -rf "$temp_root"
}

test_validate_groups_json_adds_group_id_and_staged_diff() {
    local temp_root repo commit_script prepared_json groups_json validated_json session_id
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "validate-shape")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json")"
        validated_json="$(bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json")"
        python3 - "$validated_json" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
repos = payload["repos"]
assert len(repos) == 1
groups = repos[0]["groups"]
assert len(groups) == 1
group = groups[0]
assert group["group_id"] == "owner-1"
assert group["group_title"] == "主改动"
assert group["reason"] == "同一业务变更"
assert "src/app.txt" in group["files"]
assert "local change" in group["staged_diff"]
assert group["message_agent_input"]["mode"] == "message"
assert group["message_agent_input"]["group_id"] == "owner-1"
print("ok")
PY
    )

    rm -rf "$temp_root"
}

test_validate_groups_json_rejects_missing_file() {
    local temp_root repo commit_script prepared_json groups_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "missing-file")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    mkdir -p "$repo/billing" "$repo/search"
    printf 'invoice\n' > "$repo/billing/invoice.txt"
    printf 'index\n' > "$repo/search/index.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json" missing-last-file)"
        bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json" >"$temp_root/missing-file.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected validate-groups-json to reject missing file"
    assert_contains "$temp_root/missing-file.out" "存在未分组文件"
    rm -rf "$temp_root"
}

test_validate_groups_json_rejects_duplicate_file() {
    local temp_root repo commit_script prepared_json groups_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "duplicate-file")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    mkdir -p "$repo/billing" "$repo/search"
    printf 'invoice\n' > "$repo/billing/invoice.txt"
    printf 'index\n' > "$repo/search/index.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json" duplicate-file)"
        bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json" >"$temp_root/duplicate-file.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected validate-groups-json to reject duplicate file assignment"
    assert_contains "$temp_root/duplicate-file.out" "文件重复归组"
    rm -rf "$temp_root"
}

test_validate_groups_json_rejects_cross_repo_group() {
    local temp_root workspace runtime_script commit_script scope state_slug prepared_json groups_json session_id rc
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-cross-repo"

    setup_workspace_root_with_repos "$workspace" "workspace-test" "20260503" "repo-alpha::repo-alpha" "repo-beta::repo-beta"
    printf "repo-alpha/\nrepo-beta/\nrepos/\n" > "$workspace/.gitignore"
    (
        cd "$workspace"
        git add .gitignore
        git commit -q -m "ignore nested repos"
    )
    mkdir -p "$workspace/repos"
    mv "$(setup_git_remote_pair "$workspace/repos" "repo-alpha")" "$workspace/repo-alpha"
    mv "$(setup_git_remote_pair "$workspace/repos" "repo-beta")" "$workspace/repo-beta"
    write_plan_repos_commit_plan "$workspace" "cross-repo" "20260503" "1"
    scope="$(repo_scope_json "$workspace" "owner::." "repo-alpha::repo-alpha" "repo-beta::repo-beta")"
    (
        cd "$workspace"
        bash "$runtime_script" create --slug cross-repo --title "cross repo" --plan-file ".ai-flow/plans/20260503-cross-repo.md" --repo-scope-json "$scope" >/dev/null
        python3 - ".ai-flow/state/${state_slug}.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["current_status"] = "DONE"
p.write_text(json.dumps(s))
PY
    )
    printf 'alpha local\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta local\n' > "$workspace/repo-beta/src/beta.txt"

    set +e
    (
        cd "$workspace"
        prepared_json="$(bash "$commit_script" --slug "$state_slug" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json" cross-repo)"
        bash "$commit_script" --slug "$state_slug" --session-id "$session_id" --validate-groups-json "$groups_json" >"$temp_root/cross-repo.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected validate-groups-json to reject cross-repo files"
    assert_contains "$temp_root/cross-repo.out" "不属于当前仓库"
    rm -rf "$temp_root"
}

test_validate_groups_json_rejects_empty_title() {
    local temp_root repo commit_script prepared_json groups_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "empty-title")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json" empty-title)"
        bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json" >"$temp_root/empty-title.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected validate-groups-json to reject empty title"
    assert_contains "$temp_root/empty-title.out" "缺少 group_title"
    rm -rf "$temp_root"
}

test_validate_groups_json_rejects_empty_reason() {
    local temp_root repo commit_script prepared_json groups_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "empty-reason")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json" empty-reason)"
        bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json" >"$temp_root/empty-reason.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected validate-groups-json to reject empty reason"
    assert_contains "$temp_root/empty-reason.out" "缺少 reason"
    rm -rf "$temp_root"
}

test_validate_groups_json_rejects_more_than_five_groups() {
    local temp_root repo commit_script prepared_json groups_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "too-many-groups")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    mkdir -p "$repo/feature"
    printf '1\n' > "$repo/feature/1.txt"
    printf '2\n' > "$repo/feature/2.txt"
    printf '3\n' > "$repo/feature/3.txt"
    printf '4\n' > "$repo/feature/4.txt"
    printf '5\n' > "$repo/feature/5.txt"
    printf '6\n' > "$repo/feature/6.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json" too-many)"
        bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json" >"$temp_root/too-many-groups.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected validate-groups-json to reject more than five groups"
    assert_contains "$temp_root/too-many-groups.out" "分组数量超过上限 5，请按业务关联性合并为最多 5 组后重试"
    rm -rf "$temp_root"
}

test_validate_groups_json_rejects_workspace_drift_after_prepare() {
    local temp_root repo commit_script prepared_json groups_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "prepare-drift")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        printf 'second change\n' > "$repo/src/other.txt"
        groups_json="$(build_groups_json "$prepared_json")"
        bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json" >"$temp_root/prepare-drift.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected validate-groups-json to reject workspace drift"
    assert_contains "$temp_root/prepare-drift.out" "prepare 之后工作区已变化"
    rm -rf "$temp_root"
}

test_commit_rejects_tampered_validated_groups_json() {
    local temp_root repo commit_script prepared_json groups_json validated_json message_map_json tampered_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "tampered-groups")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json")"
        validated_json="$(bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json")"
        tampered_json="$(python3 - "$validated_json" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
payload["repos"][0]["groups"][0]["message_agent_input"]["staged_diff"] = "tampered"
print(json.dumps(payload, ensure_ascii=False))
PY
)"
        message_map_json="$(build_message_map_json "$validated_json")"
        bash "$commit_script" --session-id "$session_id" --groups-json "$tampered_json" --message-map-json "$message_map_json" >"$temp_root/tampered-groups.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected commit to reject tampered validated groups json"
    assert_contains "$temp_root/tampered-groups.out" "必须使用 runtime 最近一次校验后的原样输出"
    rm -rf "$temp_root"
}

test_validate_groups_json_accepts_explicit_session_id_without_json_top_level_session() {
    local temp_root repo commit_script prepared_json groups_json validated_json session_id
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "explicit-session-validate")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json")"
        validated_json="$(bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json")"
        python3 - "$validated_json" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["session_id"]
assert payload["repos"][0]["groups"][0]["group_id"] == "owner-1"
print("ok")
PY
    )

    rm -rf "$temp_root"
}

test_validate_groups_json_rejects_session_id_mismatch_between_flag_and_json() {
    local temp_root repo commit_script prepared_json groups_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "session-mismatch-validate")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(python3 - "$(build_groups_json "$prepared_json")" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
payload["session_id"] = "wrong-session-id"
print(json.dumps(payload, ensure_ascii=False))
PY
)"
        bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json" >"$temp_root/session-mismatch-validate.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected validate-groups-json to reject mismatched session_id"
    assert_contains "$temp_root/session-mismatch-validate.out" "--session-id 不匹配"
    rm -rf "$temp_root"
}

test_prepare_json_rejects_session_id_flag() {
    local temp_root repo commit_script rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "prepare-session-id")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    set +e
    (
        cd "$repo"
        bash "$commit_script" --session-id invalid --prepare-json >"$temp_root/prepare-session-id.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected prepare-json to reject session-id flag"
    assert_contains "$temp_root/prepare-session-id.out" "--prepare-json 阶段不允许传入 --session-id"
    rm -rf "$temp_root"
}

test_standalone_commit_single_group() {
    local temp_root repo commit_script subject
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "standalone")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/standalone.out"
    )

    assert_protocol_field "$temp_root/standalone.out" "RESULT" "success"
    assert_protocol_field "$temp_root/standalone.out" "SCOPE" "standalone"
    assert_protocol_field "$temp_root/standalone.out" "COMMITS" "1"
    assert_contains "$temp_root/standalone.out" "verify: git diff --check"
    assert_contains "$temp_root/standalone.out" "committed:"
    assert_contains "$temp_root/standalone.out" "本次提交结果"
    assert_contains "$temp_root/standalone.out" "[owner]"
    subject="$(git_head_subject "$repo")"
    assert_not_contains "$temp_root/standalone.out" "完成"
    [[ "$subject" == :* ]] || fail "Expected commit subject to start with emoji code, got: $subject"
    [[ "$subject" != *"完成"* ]] || fail "Expected commit subject not to contain 完成, got: $subject"
    assert_equals "2" "$(git_commit_count "$repo")"
    rm -rf "$temp_root"
}

test_standalone_commit_with_non_git_root_and_direct_child_repos() {
    local temp_root workspace commit_script alpha beta
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"

    mkdir -p "$workspace"
    setup_project_dirs "$workspace" "20260515"
    mkdir -p "$workspace/repos"
    alpha="$(setup_git_remote_pair "$workspace/repos" "repo-alpha")"
    beta="$(setup_git_remote_pair "$workspace/repos" "repo-beta")"
    mv "$alpha" "$workspace/repo-alpha"
    mv "$beta" "$workspace/repo-beta"

    printf 'alpha local\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta local\n' > "$workspace/repo-beta/src/beta.txt"

    (
        cd "$workspace"
        run_commit_with_generated_messages "$commit_script" "$temp_root/non-git-standalone.out"
    )

    assert_protocol_field "$temp_root/non-git-standalone.out" "RESULT" "success"
    assert_protocol_field "$temp_root/non-git-standalone.out" "SCOPE" "standalone"
    assert_protocol_field "$temp_root/non-git-standalone.out" "REPOS" "2"
    assert_protocol_field "$temp_root/non-git-standalone.out" "COMMITS" "2"
    assert_contains "$temp_root/non-git-standalone.out" "[repo-alpha]"
    assert_contains "$temp_root/non-git-standalone.out" "[repo-beta]"
    assert_line_order "$temp_root/non-git-standalone.out" "处理仓库 [repo-alpha]" "处理仓库 [repo-beta]"
    assert_equals "2" "$(git_commit_count "$workspace/repo-alpha")"
    assert_equals "2" "$(git_commit_count "$workspace/repo-beta")"
    rm -rf "$temp_root"
}

test_commit_message_uses_diff_and_keeps_body_concise() {
    local temp_root repo commit_script body_lines subject
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "message-body")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    cat > "$repo/src/session.js" <<'EOF'
export function refreshSession(expireAt, now) {
  return expireAt > now;
}
EOF
    (
        cd "$repo"
        git add src/session.js
        git commit -q -m "add session base"
    )
    cat > "$repo/src/session.js" <<'EOF'
export function refreshSession(expireAt, now) {
  if (!expireAt) {
    return false;
  }
  return expireAt > now;
}
EOF

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/message-body.out"
    )

    subject="$(git_head_subject "$repo")"
    [[ "$subject" == :bug:\ 修复* ]] || fail "Expected bug-fix style subject, got: $subject"
    assert_not_contains "$temp_root/message-body.out" "完成"
    body_lines="$(git -C "$repo" log -1 --pretty=%B | tail -n +3 | sed '/^$/d')"
    [ -n "$body_lines" ] || fail "Expected generated commit body"
    printf '%s\n' "$body_lines" | while IFS= read -r line; do
        [ "${#line}" -le 30 ] || fail "Expected concise commit body line, got: $line"
    done
    rm -rf "$temp_root"
}

test_commit_rejects_subject_verb_outside_whitelist() {
    local temp_root repo commit_script prepared_json groups_json validated_json message_map_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "invalid-verb")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local change\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json")"
        validated_json="$(bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json")"
        message_map_json="$(build_message_map_json "$validated_json" invalid-verb)"
        set +e
        bash "$commit_script" --session-id "$session_id" --groups-json "$validated_json" --message-map-json "$message_map_json" >"$temp_root/invalid-verb.out" 2>&1
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "Expected invalid subject verb to fail"
    )

    assert_contains "$temp_root/invalid-verb.out" "subject 格式不合法；动词只允许：添加/修复/更新/调整/重构/优化/补充/回滚"
    rm -rf "$temp_root"
}

test_bound_done_rejects_non_done_status() {
    local temp_root project runtime_script commit_script state_slug rc
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-demo"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "AWAITING_REVIEW" "20260503" "demo"
    setup_git_repo_with_change "$project"
    write_simple_test_runner "$project"

    set +e
    (
        cd "$project"
        bash "$commit_script" --slug "$state_slug" --prepare-json >"$temp_root/not-done.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected non-DONE slug commit to fail"
    assert_protocol_field "$temp_root/not-done.out" "RESULT" "failed"
    assert_contains "$temp_root/not-done.out" "只有 DONE 允许提交"
    rm -rf "$temp_root"
}

test_bound_done_single_repo_commit() {
    local temp_root project runtime_script commit_script state_slug
    temp_root=$(make_temp_root)
    project="$temp_root/project"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-demo"
    setup_project_dirs "$project" "20260503"
    create_state_with_status "$runtime_script" "$project" "demo" "DONE" "20260503" "demo"
    write_simple_test_runner "$project"
    printf 'done change\n' > "$project/src/review-target.txt"

    (
        cd "$project"
        run_commit_with_generated_messages "$commit_script" "$temp_root/bound-single.out" default default --slug "$state_slug"
    )

    assert_protocol_field "$temp_root/bound-single.out" "RESULT" "success"
    assert_protocol_field "$temp_root/bound-single.out" "SCOPE" "bound"
    assert_protocol_field "$temp_root/bound-single.out" "SLUG" "$state_slug"
    assert_protocol_field "$temp_root/bound-single.out" "COMMITS" "1"
    assert_equals "2" "$(git_commit_count "$project")"
    rm -rf "$temp_root"
}

test_standalone_splits_unrelated_changes_into_multiple_groups() {
    local temp_root repo commit_script
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "unrelated")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    mkdir -p "$repo/billing" "$repo/search"
    printf 'invoice\n' > "$repo/billing/invoice.txt"
    printf 'index\n' > "$repo/search/index.txt"

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/unrelated-group.out" split-topdir
    )

    assert_protocol_field "$temp_root/unrelated-group.out" "RESULT" "success"
    assert_protocol_field "$temp_root/unrelated-group.out" "SCOPE" "standalone"
    assert_protocol_field "$temp_root/unrelated-group.out" "COMMITS" "2"
    assert_contains "$temp_root/unrelated-group.out" "提交组 owner-1:"
    assert_contains "$temp_root/unrelated-group.out" "提交组 owner-2:"
    assert_contains "$temp_root/unrelated-group.out" "file: billing/invoice.txt"
    assert_contains "$temp_root/unrelated-group.out" "file: search/index.txt"
    assert_equals "3" "$(git_commit_count "$repo")"
    rm -rf "$temp_root"
}

test_plan_repos_commit_uses_dependency_order() {
    local temp_root workspace runtime_script commit_script scope state_slug first_beta first_alpha
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-multi-demo"

    setup_workspace_root_with_repos "$workspace" "workspace-test" "20260503" "repo-alpha::repo-alpha" "repo-beta::repo-beta"
    printf "repo-alpha/\nrepo-beta/\nrepos/\n" > "$workspace/.gitignore"
    (
        cd "$workspace"
        git add .gitignore
        git commit -q -m "ignore nested repos"
    )
    mkdir -p "$workspace/repos"
    mv "$(setup_git_remote_pair "$workspace/repos" "repo-alpha")" "$workspace/repo-alpha"
    mv "$(setup_git_remote_pair "$workspace/repos" "repo-beta")" "$workspace/repo-beta"
    write_plan_repos_commit_plan "$workspace" "multi-demo" "20260503" "1"
    scope="$(repo_scope_json "$workspace" "owner::." "repo-alpha::repo-alpha" "repo-beta::repo-beta")"
    (
        cd "$workspace"
        bash "$runtime_script" create --slug multi-demo --title "multi demo" --plan-file ".ai-flow/plans/20260503-multi-demo.md" --repo-scope-json "$scope" >/dev/null
        bash "$runtime_script" record-plan-review --slug "$state_slug" --result passed --engine Fixture --model fixture-model >/dev/null
        bash "$runtime_script" start-execute "$state_slug" >/dev/null
        bash "$runtime_script" finish-implementation "$state_slug" >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503-multi-demo-review.md" "multi-demo" ".ai-flow/plans/20260503-multi-demo.md" "regular" "1" "passed" "multi-demo"
        bash "$runtime_script" record-review --slug "$state_slug" --mode regular --result passed --report-file ".ai-flow/reports/20260503-multi-demo-review.md" >/dev/null
    )
    printf 'alpha local\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta local\n' > "$workspace/repo-beta/src/beta.txt"

    (
        cd "$workspace"
        run_commit_with_generated_messages "$commit_script" "$temp_root/multi.out" default default --slug "$state_slug"
    )

    assert_protocol_field "$temp_root/multi.out" "RESULT" "success"
    assert_protocol_field "$temp_root/multi.out" "COMMITS" "2"
    assert_contains "$temp_root/multi.out" "verify: git diff --check"
    first_beta="$(git -C "$workspace/repo-beta" rev-parse --short HEAD)"
    first_alpha="$(git -C "$workspace/repo-alpha" rev-parse --short HEAD)"
    assert_contains "$temp_root/multi.out" "repo-beta] (participant)"
    assert_contains "$temp_root/multi.out" "repo-alpha] (participant)"
    assert_line_order "$temp_root/multi.out" "处理仓库 [repo-beta]" "处理仓库 [repo-alpha]"
    assert_contains "$temp_root/multi.out" "[repo-beta] $first_beta"
    assert_contains "$temp_root/multi.out" "[repo-alpha] $first_alpha"
    rm -rf "$temp_root"
}

test_plan_repos_commit_falls_back_to_scope_order_without_dependency_table() {
    local temp_root workspace runtime_script commit_script scope state_slug
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-multi-no-dep"

    setup_workspace_root_with_repos "$workspace" "workspace-test" "20260503" "repo-alpha::repo-alpha" "repo-beta::repo-beta"
    printf "repo-alpha/\nrepo-beta/\n" > "$workspace/.gitignore"
    (
        cd "$workspace"
        git add .gitignore
        git commit -q -m "ignore nested repos"
    )
    rm -rf "$workspace/repo-alpha" "$workspace/repo-beta"
    setup_workspace_single_git_repo "$workspace" "repo-alpha"
    setup_workspace_single_git_repo "$workspace" "repo-beta"
    write_simple_test_runner "$workspace/repo-alpha"
    write_simple_test_runner "$workspace/repo-beta"
    write_plan_repos_commit_plan "$workspace" "multi-no-dep" "20260503" "0"
    scope="$(repo_scope_json "$workspace" "owner::." "repo-alpha::repo-alpha" "repo-beta::repo-beta")"
    (
        cd "$workspace"
        bash "$runtime_script" create --slug multi-no-dep --title "multi no dep" --plan-file ".ai-flow/plans/20260503-multi-no-dep.md" --repo-scope-json "$scope" >/dev/null
        bash "$runtime_script" record-plan-review --slug "$state_slug" --result passed --engine Fixture --model fixture-model >/dev/null
        bash "$runtime_script" start-execute "$state_slug" >/dev/null
        bash "$runtime_script" finish-implementation "$state_slug" >/dev/null
        write_review_report_fixture ".ai-flow/reports/20260503-multi-no-dep-review.md" "multi-no-dep" ".ai-flow/plans/20260503-multi-no-dep.md" "regular" "1" "passed" "multi-no-dep"
        bash "$runtime_script" record-review --slug "$state_slug" --mode regular --result passed --report-file ".ai-flow/reports/20260503-multi-no-dep-review.md" >/dev/null
    )
    printf 'alpha local\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta local\n' > "$workspace/repo-beta/src/beta.txt"

    (
        cd "$workspace"
        run_commit_with_generated_messages "$commit_script" "$temp_root/multi-no-dep.out" default default --slug "$state_slug"
    )

    assert_protocol_field "$temp_root/multi-no-dep.out" "RESULT" "success"
    assert_contains "$temp_root/multi-no-dep.out" "plan 未声明跨仓依赖表"
    assert_line_order "$temp_root/multi-no-dep.out" "处理仓库 [repo-alpha]" "处理仓库 [repo-beta]"
    rm -rf "$temp_root"
}

test_bound_prepare_skips_repo_without_changes() {
    local temp_root workspace runtime_script commit_script scope state_slug prepared_json
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260503-skip-empty"

    setup_workspace_root_with_repos "$workspace" "workspace-test" "20260503" "repo-alpha::repo-alpha" "repo-beta::repo-beta"
    printf "repo-alpha/\nrepo-beta/\nrepos/\n" > "$workspace/.gitignore"
    (
        cd "$workspace"
        git add .gitignore
        git commit -q -m "ignore nested repos"
    )
    mkdir -p "$workspace/repos"
    mv "$(setup_git_remote_pair "$workspace/repos" "repo-alpha")" "$workspace/repo-alpha"
    mv "$(setup_git_remote_pair "$workspace/repos" "repo-beta")" "$workspace/repo-beta"
    write_plan_repos_commit_plan "$workspace" "skip-empty" "20260503" "1"
    scope="$(repo_scope_json "$workspace" "owner::." "repo-alpha::repo-alpha" "repo-beta::repo-beta")"
    (
        cd "$workspace"
        bash "$runtime_script" create --slug skip-empty --title "skip empty" --plan-file ".ai-flow/plans/20260503-skip-empty.md" --repo-scope-json "$scope" >/dev/null
        python3 - ".ai-flow/state/${state_slug}.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["current_status"] = "DONE"
p.write_text(json.dumps(s))
PY
    )
    (
        cd "$workspace/repo-alpha"
        git add tests/run.sh
        git commit -q -m "track test runner alpha"
    )
    (
        cd "$workspace/repo-beta"
        git add tests/run.sh
        git commit -q -m "track test runner beta"
    )
    printf 'alpha local\n' > "$workspace/repo-alpha/src/alpha.txt"

    (
        cd "$workspace"
        prepared_json="$(bash "$commit_script" --slug "$state_slug" --prepare-json)"
        python3 - "$prepared_json" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
repo_ids = [repo["repo_id"] for repo in payload.get("repos", [])]
assert repo_ids == ["repo-alpha"], repo_ids
print("ok")
PY
    )

    rm -rf "$temp_root"
}

test_standalone_auto_conflict_preserves_both_sides() {
    local temp_root repo remote_dir commit_script
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "conflict")"
    remote_dir="$temp_root/conflict-remote.git"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local line\n' > "$repo/src/app.txt"
    make_remote_change "$remote_dir" "src/app.txt" "remote line"

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/conflict.out" default default --conflict-mode auto
    )

    assert_protocol_field "$temp_root/conflict.out" "RESULT" "success"
    assert_contains "$repo/src/app.txt" "local line"
    assert_contains "$repo/src/app.txt" "remote line"
    rm -rf "$temp_root"
}

test_standalone_manual_conflict_requires_user_action() {
    local temp_root repo remote_dir commit_script rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "manual-conflict")"
    remote_dir="$temp_root/manual-conflict-remote.git"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    printf 'local line\n' > "$repo/src/app.txt"
    make_remote_change "$remote_dir" "src/app.txt" "remote line"

    set +e
    (
        cd "$repo"
        bash "$commit_script" --conflict-mode manual --prepare-json >"$temp_root/manual-conflict.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected manual conflict mode to stop"
    assert_protocol_field "$temp_root/manual-conflict.out" "RESULT" "failed"
    assert_contains "$temp_root/manual-conflict.out" "发生冲突"
    rm -rf "$temp_root"
}

test_commit_rejects_missing_message_map_entry() {
    local temp_root repo commit_script prepared_json groups_json validated_json message_map_json session_id rc
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "missing-message")"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    mkdir -p "$repo/billing" "$repo/search"
    printf 'invoice\n' > "$repo/billing/invoice.txt"
    printf 'index\n' > "$repo/search/index.txt"

    set +e
    (
        cd "$repo"
        prepared_json="$(bash "$commit_script" --prepare-json)"
        session_id="$(python3 - "$prepared_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["session_id"])
PY
)"
        groups_json="$(build_groups_json "$prepared_json" split-topdir)"
        validated_json="$(bash "$commit_script" --session-id "$session_id" --validate-groups-json "$groups_json")"
        message_map_json="$(build_message_map_json "$validated_json" missing)"
        bash "$commit_script" --session-id "$session_id" --groups-json "$validated_json" --message-map-json "$message_map_json" >"$temp_root/missing-message.out" 2>&1
    )
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || fail "Expected commit to fail when a message entry is missing"
    assert_protocol_field "$temp_root/missing-message.out" "RESULT" "partial"
    assert_contains "$temp_root/missing-message.out" "缺少合法的 commit message"
    rm -rf "$temp_root"
}

test_plan_repos_commit_with_non_git_root() {
    local temp_root workspace runtime_script commit_script scope alpha beta alpha_git_root beta_git_root state_slug
    temp_root=$(make_temp_root)
    workspace="$temp_root/workspace"
    runtime_script="$SOURCE_FLOW_STATE_SCRIPT"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"
    state_slug="20260514-non-git-root"

    mkdir -p "$workspace"
    setup_project_dirs "$workspace" "20260514"
    mkdir -p "$workspace/repos"
    alpha="$(setup_git_remote_pair "$workspace/repos" "repo-alpha")"
    beta="$(setup_git_remote_pair "$workspace/repos" "repo-beta")"
    mv "$alpha" "$workspace/repo-alpha"
    mv "$beta" "$workspace/repo-beta"

    alpha_git_root=$(git -C "$workspace/repo-alpha" rev-parse --show-toplevel)
    beta_git_root=$(git -C "$workspace/repo-beta" rev-parse --show-toplevel)
    scope=$(cat <<EOF
{
  "mode": "plan_repos",
  "repos": [
    { "id": "owner", "path": ".", "git_root": "$workspace", "role": "owner" },
    { "id": "repo-alpha", "path": "repo-alpha", "git_root": "$alpha_git_root", "role": "participant" },
    { "id": "repo-beta", "path": "repo-beta", "git_root": "$beta_git_root", "role": "participant" }
  ]
}
EOF
)
    write_plan_repos_commit_plan "$workspace" "non-git-root" "20260514" "1"
    (
        cd "$workspace"
        bash "$runtime_script" create --slug non-git-root --title "non-git-root" --plan-file ".ai-flow/plans/20260514-non-git-root.md" --repo-scope-json "$scope" >/dev/null
        python3 - ".ai-flow/state/${state_slug}.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["current_status"] = "DONE"
p.write_text(json.dumps(s))
PY
    )
    printf 'alpha change\n' > "$workspace/repo-alpha/src/alpha.txt"
    printf 'beta change\n' > "$workspace/repo-beta/src/beta.txt"

    (
        cd "$workspace"
        run_commit_with_generated_messages "$commit_script" "$temp_root/non-git-root.out" default default --slug "$state_slug"
    )

    assert_protocol_field "$temp_root/non-git-root.out" "RESULT" "success"
    assert_protocol_field "$temp_root/non-git-root.out" "COMMITS" "2"
    rm -rf "$temp_root"
}

test_stash_pop_conflict_auto_resolve_cleans_up_stash() {
    local temp_root repo remote_dir commit_script
    temp_root=$(make_temp_root)
    repo="$(setup_git_remote_pair "$temp_root" "stash-cleanup")"
    remote_dir="$temp_root/stash-cleanup-remote.git"
    commit_script="$SOURCE_FLOW_COMMIT_SCRIPT"

    printf 'line 1\n' > "$repo/src/app.txt"
    (cd "$repo" && git add . && git commit -q -m "base" && git push -q origin main)
    make_remote_change "$remote_dir" "src/app.txt" "remote change\nline 1"
    printf 'local change\nline 1\n' > "$repo/src/app.txt"

    (
        cd "$repo"
        run_commit_with_generated_messages "$commit_script" "$temp_root/stash-cleanup.out" default default --conflict-mode auto
    )

    assert_protocol_field "$temp_root/stash-cleanup.out" "RESULT" "success"
    [ -z "$(git -C "$repo" stash list)" ] || fail "Expected stash list to be empty after auto-resolve"
    rm -rf "$temp_root"
}

test_prepare_json_returns_repo_context_not_groups
test_validate_groups_json_adds_group_id_and_staged_diff
test_validate_groups_json_rejects_missing_file
test_validate_groups_json_rejects_duplicate_file
test_validate_groups_json_rejects_cross_repo_group
test_validate_groups_json_rejects_empty_title
test_validate_groups_json_rejects_empty_reason
test_validate_groups_json_rejects_more_than_five_groups
test_validate_groups_json_rejects_workspace_drift_after_prepare
test_commit_rejects_tampered_validated_groups_json
test_validate_groups_json_accepts_explicit_session_id_without_json_top_level_session
test_validate_groups_json_rejects_session_id_mismatch_between_flag_and_json
test_prepare_json_rejects_session_id_flag
test_standalone_commit_single_group
test_standalone_commit_with_non_git_root_and_direct_child_repos
test_commit_message_uses_diff_and_keeps_body_concise
test_commit_rejects_subject_verb_outside_whitelist
test_bound_done_rejects_non_done_status
test_bound_done_single_repo_commit
test_standalone_splits_unrelated_changes_into_multiple_groups
test_plan_repos_commit_uses_dependency_order
test_plan_repos_commit_falls_back_to_scope_order_without_dependency_table
test_bound_prepare_skips_repo_without_changes
test_standalone_auto_conflict_preserves_both_sides
test_standalone_manual_conflict_requires_user_action
test_commit_rejects_missing_message_map_entry
test_plan_repos_commit_with_non_git_root
test_stash_pop_conflict_auto_resolve_cleans_up_stash
