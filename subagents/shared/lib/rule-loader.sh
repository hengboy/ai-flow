#!/bin/bash
# rule-loader.sh — load repo-local .ai-flow/rule.yaml files and expose merged rule views.

AI_FLOW_RULE_SEVERITY_ORDER_NOTE=1
AI_FLOW_RULE_SEVERITY_ORDER_MINOR=2
AI_FLOW_RULE_SEVERITY_ORDER_IMPORTANT=3
AI_FLOW_RULE_SEVERITY_ORDER_CRITICAL=4

ai_flow_rule_python() {
    python3 - "$@"
}

ai_flow_rule_escape_json_string() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "${1:-}"
}

load_rule_bundle_json() {
    local stage="${1:-generic}"
    local skill_name="${2:-}"
    local subagent_name="${3:-}"
    shift 3 || true
    ai_flow_rule_python "$stage" "$skill_name" "$subagent_name" "$@" <<'PY'
import json
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except Exception:
    yaml = None


def parse_scalar(raw: str):
    value = raw.strip()
    if not value:
        return ""
    if value == "{}":
        return {}
    if value == "[]":
        return []
    if value in {"true", "True"}:
        return True
    if value in {"false", "False"}:
        return False
    if value.isdigit():
        return int(value)
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    return value


def minimal_yaml_load(text: str):
    root = {}
    stack = [(-1, root)]

    def ensure_container(parent, key, next_is_list):
        if key not in parent or parent[key] is None:
            parent[key] = [] if next_is_list else {}
        return parent[key]

    lines = text.splitlines()
    idx = 0
    while idx < len(lines):
        raw_line = lines[idx]
        idx += 1
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        line = raw_line.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]

        if line.startswith("- "):
            if not isinstance(parent, list):
                raise ValueError(f"invalid list item: {line}")
            item_text = line[2:].strip()
            if ": " in item_text:
                key, value = item_text.split(": ", 1)
                item = {key.strip(): parse_scalar(value)}
                parent.append(item)
                stack.append((indent, item))
            elif item_text.endswith(":"):
                key = item_text[:-1].strip()
                item = {key: {}}
                parent.append(item)
                stack.append((indent, item[key]))
            else:
                parent.append(parse_scalar(item_text))
            continue

        if ":" not in line or not isinstance(parent, dict):
            raise ValueError(f"invalid line: {line}")
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if value:
            parent[key] = parse_scalar(value)
            continue

        next_nonempty = ""
        for follow in lines[idx:]:
            if not follow.strip() or follow.lstrip().startswith("#"):
                continue
            next_nonempty = follow.strip()
            break
        next_is_list = next_nonempty.startswith("- ")
        container = [] if next_is_list else {}
        parent[key] = container
        stack.append((indent, container))

    return root


def load_yaml_text(text: str):
    if yaml is not None:
        return yaml.safe_load(text)
    return minimal_yaml_load(text)


def severity_rank(value: str) -> int:
    order = {"note": 1, "minor": 2, "important": 3, "critical": 4}
    return order.get((value or "").strip().lower(), 0)


def unique_keep_order(items):
    seen = set()
    result = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        result.append(item)
    return result


stage = sys.argv[1]
skill_name = sys.argv[2]
subagent_name = sys.argv[3]
repo_args = sys.argv[4:]

repos = []
for raw in repo_args:
    repo_id, repo_root = raw.split("::", 1)
    repos.append({"repo_id": repo_id, "repo_root": str(Path(repo_root).resolve())})

bundle = {
    "stage": stage,
    "repos": [],
    "merged": {
        "prompt_shared_context": [],
        "prompt_skill_overrides": [],
        "prompt_subagent_overrides": [],
        "required_reads": [],
        "protected_paths": [],
        "forbidden_changes": [],
        "review_required_checks": [],
        "review_required_evidence": [],
        "severity_rules": {},
        "fail_conditions": [],
        "test_policy": {
            "require_tests_for_code_change": False,
            "allow_testless_paths": [],
        },
    },
}

for repo in repos:
    repo_root = Path(repo["repo_root"])
    rule_path = repo_root / ".ai-flow" / "rule.yaml"
    repo_entry = {
        "repo_id": repo["repo_id"],
        "repo_root": str(repo_root),
        "rule_path": str(rule_path),
        "exists": rule_path.is_file(),
        "prompt": {
            "shared_context": [],
            "skill_overrides": [],
            "subagent_overrides": [],
        },
        "constraints": {
            "required_reads": [],
            "protected_paths": [],
            "forbidden_changes": [],
            "test_policy": {
                "require_tests_for_code_change": False,
                "allow_testless_paths": [],
            },
        },
        "review": {
            "required_checks": [],
            "required_evidence": [],
            "severity_rules": {},
            "fail_conditions": [],
        },
        "required_read_files": [],
        "errors": [],
    }
    if not rule_path.is_file():
        bundle["repos"].append(repo_entry)
        continue

    try:
        raw = load_yaml_text(rule_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(
            json.dumps(
                {
                    "error": f"rule.yaml 解析失败: repo={repo['repo_id']} path={rule_path} detail={exc}",
                    "repo_id": repo["repo_id"],
                    "rule_path": str(rule_path),
                },
                ensure_ascii=False,
            )
        )

    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise SystemExit(
            json.dumps(
                {
                    "error": f"rule.yaml 顶层必须是对象: repo={repo['repo_id']} path={rule_path}",
                    "repo_id": repo["repo_id"],
                    "rule_path": str(rule_path),
                },
                ensure_ascii=False,
            )
        )

    version = raw.get("version")
    if version != 1:
        raise SystemExit(
            json.dumps(
                {
                    "error": f"rule.yaml version 必须为 1: repo={repo['repo_id']} path={rule_path}",
                    "repo_id": repo["repo_id"],
                    "rule_path": str(rule_path),
                },
                ensure_ascii=False,
            )
        )

    prompt = raw.get("prompt") or {}
    constraints = raw.get("constraints") or {}
    review = raw.get("review") or {}
    if not isinstance(prompt, dict) or not isinstance(constraints, dict) or not isinstance(review, dict):
        raise SystemExit(
            json.dumps(
                {
                    "error": f"rule.yaml 顶层字段类型非法: repo={repo['repo_id']} path={rule_path}",
                    "repo_id": repo["repo_id"],
                    "rule_path": str(rule_path),
                },
                ensure_ascii=False,
            )
        )

    shared_context = prompt.get("shared_context") or []
    if not isinstance(shared_context, list):
        raise SystemExit(
            json.dumps(
                {
                    "error": f"prompt.shared_context 必须是数组: repo={repo['repo_id']} path={rule_path}",
                    "repo_id": repo["repo_id"],
                    "rule_path": str(rule_path),
                },
                ensure_ascii=False,
            )
        )
    shared_context = [str(item) for item in shared_context if str(item).strip()]

    skill_overrides = []
    skill_raw = prompt.get("skill_overrides") or {}
    if skill_name and isinstance(skill_raw, dict):
        block = skill_raw.get(skill_name) or {}
        if not isinstance(block, dict):
            raise SystemExit(
                json.dumps(
                    {
                        "error": f"prompt.skill_overrides.{skill_name} 必须是对象: repo={repo['repo_id']} path={rule_path}",
                        "repo_id": repo["repo_id"],
                        "rule_path": str(rule_path),
                    },
                    ensure_ascii=False,
                )
            )
        skill_overrides = [str(item) for item in (block.get("prepend") or []) if str(item).strip()]

    subagent_overrides = []
    subagent_raw = prompt.get("subagent_overrides") or {}
    if subagent_name and isinstance(subagent_raw, dict):
        block = subagent_raw.get(subagent_name) or {}
        if not isinstance(block, dict):
            raise SystemExit(
                json.dumps(
                    {
                        "error": f"prompt.subagent_overrides.{subagent_name} 必须是对象: repo={repo['repo_id']} path={rule_path}",
                        "repo_id": repo["repo_id"],
                        "rule_path": str(rule_path),
                    },
                    ensure_ascii=False,
                )
            )
        subagent_overrides = [str(item) for item in (block.get("prepend") or []) if str(item).strip()]

    protected_paths = constraints.get("protected_paths") or []
    required_reads = constraints.get("required_reads") or []
    forbidden_changes = constraints.get("forbidden_changes") or []
    test_policy = constraints.get("test_policy") or {}
    if not isinstance(protected_paths, list) or not isinstance(required_reads, list) or not isinstance(forbidden_changes, list):
        raise SystemExit(
            json.dumps(
                {
                    "error": f"constraints 字段类型非法: repo={repo['repo_id']} path={rule_path}",
                    "repo_id": repo["repo_id"],
                    "rule_path": str(rule_path),
                },
                ensure_ascii=False,
            )
        )
    if not isinstance(test_policy, dict):
        raise SystemExit(
            json.dumps(
                {
                    "error": f"constraints.test_policy 必须是对象: repo={repo['repo_id']} path={rule_path}",
                    "repo_id": repo["repo_id"],
                    "rule_path": str(rule_path),
                },
                ensure_ascii=False,
            )
        )

    required_read_files = []
    for rel in required_reads:
        rel = str(rel).strip()
        if not rel:
            continue
        abs_path = (repo_root / rel).resolve()
        try:
            abs_path.relative_to(repo_root)
        except ValueError:
            raise SystemExit(
                json.dumps(
                    {
                        "error": f"required_reads 不允许跨 repo: repo={repo['repo_id']} value={rel}",
                        "repo_id": repo["repo_id"],
                        "rule_path": str(rule_path),
                    },
                    ensure_ascii=False,
                )
            )
        required_read_files.append(
            {
                "repo_id": repo["repo_id"],
                "repo_root": str(repo_root),
                "relative_path": rel,
                "absolute_path": str(abs_path),
            }
        )

    normalized_forbidden = []
    for item in forbidden_changes:
        if not isinstance(item, dict):
            raise SystemExit(
                json.dumps(
                    {
                        "error": f"constraints.forbidden_changes 元素必须是对象: repo={repo['repo_id']} path={rule_path}",
                        "repo_id": repo["repo_id"],
                        "rule_path": str(rule_path),
                    },
                    ensure_ascii=False,
                )
            )
        rel_path = str(item.get("path") or "").strip()
        reason = str(item.get("reason") or "").strip()
        if not rel_path:
            raise SystemExit(
                json.dumps(
                    {
                        "error": f"constraints.forbidden_changes.path 不能为空: repo={repo['repo_id']} path={rule_path}",
                        "repo_id": repo["repo_id"],
                        "rule_path": str(rule_path),
                    },
                    ensure_ascii=False,
                )
            )
        normalized_forbidden.append(
            {
                "repo_id": repo["repo_id"],
                "path": rel_path,
                "reason": reason,
            }
        )

    review_required_checks = review.get("required_checks") or []
    review_required_evidence = review.get("required_evidence") or []
    severity_rules = review.get("severity_rules") or {}
    fail_conditions = review.get("fail_conditions") or []
    if not isinstance(review_required_checks, list) or not isinstance(review_required_evidence, list) or not isinstance(fail_conditions, list):
        raise SystemExit(
            json.dumps(
                {
                    "error": f"review 字段类型非法: repo={repo['repo_id']} path={rule_path}",
                    "repo_id": repo["repo_id"],
                    "rule_path": str(rule_path),
                },
                ensure_ascii=False,
            )
        )
    if not isinstance(severity_rules, dict):
        raise SystemExit(
            json.dumps(
                {
                    "error": f"review.severity_rules 必须是对象: repo={repo['repo_id']} path={rule_path}",
                    "repo_id": repo["repo_id"],
                    "rule_path": str(rule_path),
                },
                ensure_ascii=False,
            )
        )

    repo_entry["prompt"]["shared_context"] = shared_context
    repo_entry["prompt"]["skill_overrides"] = skill_overrides
    repo_entry["prompt"]["subagent_overrides"] = subagent_overrides
    repo_entry["constraints"]["required_reads"] = [str(item) for item in required_reads if str(item).strip()]
    repo_entry["constraints"]["protected_paths"] = [str(item) for item in protected_paths if str(item).strip()]
    repo_entry["constraints"]["forbidden_changes"] = normalized_forbidden
    repo_entry["constraints"]["test_policy"] = {
        "require_tests_for_code_change": bool(test_policy.get("require_tests_for_code_change")),
        "allow_testless_paths": [str(item) for item in (test_policy.get("allow_testless_paths") or []) if str(item).strip()],
    }
    repo_entry["review"]["required_checks"] = [str(item) for item in review_required_checks if str(item).strip()]
    repo_entry["review"]["required_evidence"] = [str(item) for item in review_required_evidence if str(item).strip()]
    repo_entry["review"]["severity_rules"] = {
        str(key): str(value).strip().lower()
        for key, value in severity_rules.items()
        if str(key).strip() and str(value).strip()
    }
    repo_entry["review"]["fail_conditions"] = [str(item) for item in fail_conditions if str(item).strip()]
    repo_entry["required_read_files"] = required_read_files

    bundle["merged"]["prompt_shared_context"].extend(shared_context)
    bundle["merged"]["prompt_skill_overrides"].extend(skill_overrides)
    bundle["merged"]["prompt_subagent_overrides"].extend(subagent_overrides)
    bundle["merged"]["protected_paths"].extend(
        {"repo_id": repo["repo_id"], "path": item}
        for item in repo_entry["constraints"]["protected_paths"]
    )
    bundle["merged"]["required_reads"].extend(required_read_files)
    bundle["merged"]["forbidden_changes"].extend(normalized_forbidden)
    bundle["merged"]["review_required_checks"].extend(repo_entry["review"]["required_checks"])
    bundle["merged"]["review_required_evidence"].extend(repo_entry["review"]["required_evidence"])
    bundle["merged"]["fail_conditions"].extend(repo_entry["review"]["fail_conditions"])
    if repo_entry["constraints"]["test_policy"]["require_tests_for_code_change"]:
        bundle["merged"]["test_policy"]["require_tests_for_code_change"] = True
    bundle["merged"]["test_policy"]["allow_testless_paths"].extend(
        {"repo_id": repo["repo_id"], "path": item}
        for item in repo_entry["constraints"]["test_policy"]["allow_testless_paths"]
    )
    for key, value in repo_entry["review"]["severity_rules"].items():
        existing = bundle["merged"]["severity_rules"].get(key)
        if existing is None or severity_rank(value) > severity_rank(existing):
            bundle["merged"]["severity_rules"][key] = value

    bundle["repos"].append(repo_entry)

bundle["merged"]["prompt_shared_context"] = unique_keep_order(bundle["merged"]["prompt_shared_context"])
bundle["merged"]["prompt_skill_overrides"] = unique_keep_order(bundle["merged"]["prompt_skill_overrides"])
bundle["merged"]["prompt_subagent_overrides"] = unique_keep_order(bundle["merged"]["prompt_subagent_overrides"])
bundle["merged"]["review_required_checks"] = unique_keep_order(bundle["merged"]["review_required_checks"])
bundle["merged"]["review_required_evidence"] = unique_keep_order(bundle["merged"]["review_required_evidence"])
bundle["merged"]["fail_conditions"] = unique_keep_order(bundle["merged"]["fail_conditions"])

print(json.dumps(bundle, ensure_ascii=False))
PY
}

render_rule_prompt_block() {
    local bundle_json="$1"
    ai_flow_rule_python "$bundle_json" <<'PY'
import json
import sys
from pathlib import Path

bundle = json.loads(sys.argv[1])
merged = bundle["merged"]
repos = bundle["repos"]
lines = []
has_content = False

if merged["prompt_shared_context"]:
    has_content = True
    lines.append("项目上下文：")
    for item in merged["prompt_shared_context"]:
        lines.append(f"- {item}")

phase_rules = []
phase_rules.extend(merged["prompt_skill_overrides"])
phase_rules.extend(merged["prompt_subagent_overrides"])
if phase_rules:
    has_content = True
    if lines:
        lines.append("")
    lines.append("本阶段附加规则：")
    for item in phase_rules:
        lines.append(f"- {item}")

constraint_lines = []
if merged["required_reads"]:
    constraint_lines.append("必须读取以下项目文件后再继续：")
    for item in merged["required_reads"]:
        constraint_lines.append(f"- [{item['repo_id']}] {item['relative_path']}")
if merged["protected_paths"]:
    constraint_lines.append("禁止改动以下受保护路径：")
    for item in merged["protected_paths"]:
        constraint_lines.append(f"- [{item['repo_id']}] {item['path']}")
if merged["forbidden_changes"]:
    constraint_lines.append("禁止改动以下文件：")
    for item in merged["forbidden_changes"]:
        reason = f" — {item['reason']}" if item.get("reason") else ""
        constraint_lines.append(f"- [{item['repo_id']}] {item['path']}{reason}")
if merged["test_policy"]["require_tests_for_code_change"]:
    constraint_lines.append("存在非豁免代码改动时，必须提供测试或等价自动化验证证据。")
if merged["test_policy"]["allow_testless_paths"]:
    constraint_lines.append("以下路径允许无测试证据：")
    for item in merged["test_policy"]["allow_testless_paths"]:
        constraint_lines.append(f"- [{item['repo_id']}] {item['path']}")

if constraint_lines:
    has_content = True
    if lines:
        lines.append("")
    lines.append("必须遵守的项目约束：")
    lines.extend(constraint_lines)

review_lines = []
if merged["review_required_checks"]:
    review_lines.append("本阶段审查必查项：")
    for item in merged["review_required_checks"]:
        review_lines.append(f"- {item}")
if merged["review_required_evidence"]:
    review_lines.append("本阶段必须体现的验证证据：")
    for item in merged["review_required_evidence"]:
        review_lines.append(f"- {item}")

if review_lines:
    has_content = True
    if lines:
        lines.append("")
    lines.append("本阶段审查关注点：")
    lines.extend(review_lines)

if not has_content:
    print("", end="")
    raise SystemExit(0)

print("## AI Flow 项目规则")
print("\n".join(lines))
PY
}

render_required_reads_block() {
    local bundle_json="$1"
    ai_flow_rule_python "$bundle_json" <<'PY'
import json
import sys
from pathlib import Path

bundle = json.loads(sys.argv[1])
entries = bundle["merged"]["required_reads"]
parts = []
for item in entries:
    path = Path(item["absolute_path"])
    if not path.is_file():
        raise SystemExit(
            json.dumps(
                {
                    "error": f"required_reads 文件不存在: repo={item['repo_id']} path={item['relative_path']}",
                    "repo_id": item["repo_id"],
                    "path": item["relative_path"],
                },
                ensure_ascii=False,
            )
        )
    content = path.read_text(encoding="utf-8")
    parts.append(f"### Required Read [{item['repo_id']}] {item['relative_path']}\n\n{content.rstrip()}")

if parts:
    print("\n\n".join(parts))
PY
}

match_rule_path() {
    local candidate="$1"
    local pattern="$2"
    ai_flow_rule_python "$candidate" "$pattern" <<'PY'
import fnmatch
import sys

candidate = sys.argv[1].strip().replace("\\", "/")
pattern = sys.argv[2].strip().replace("\\", "/")
print("1" if fnmatch.fnmatch(candidate, pattern) else "0")
PY
}

extract_rule_loader_error() {
    python3 - "${1:-}" <<'PY'
import json
import sys

raw = sys.argv[1].strip()
if not raw:
    print("rule 处理失败")
    raise SystemExit(0)
try:
    payload = json.loads(raw)
except Exception:
    print(raw)
    raise SystemExit(0)
print(payload.get("error") or "；".join(payload.get("errors") or []) or raw)
PY
}
