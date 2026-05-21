import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional

class FlowUtils:
    @staticmethod
    def get_json_field(file_path, field_path):
        """获取 JSON 文件中的特定字段，支持点号分隔路径"""
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            
            value = data
            for part in field_path.split('.'):
                if value is None:
                    return None
                if isinstance(value, dict):
                    value = value.get(part)
                elif isinstance(value, list) and part.isdigit():
                    idx = int(part)
                    value = value[idx] if 0 <= idx < len(value) else None
                else:
                    return None
            return value
        except Exception:
            return None

    @staticmethod
    def parse_plan_steps(plan_file):
        """解析 plan 中的实施步骤。

        兼容标准 plan 模板的 `### ...` 步骤块，并尽量识别旧 plan 的
        2.x 层级步骤块；但只要缺少标准 Step 子字段，就会标记为无效。
        """
        try:
            text = Path(plan_file).read_text(encoding='utf-8')
        except Exception as exc:
            return {"ok": False, "error": f"无法读取 plan 文件: {exc}", "steps": []}

        lines = text.splitlines()
        in_steps = False
        current = None
        steps = []

        def flush():
            nonlocal current
            if current is not None:
                steps.append(current)
                current = None

        def new_step(title):
            return {
                "title": title,
                "step_id": "",
                "goal": "",
                "file_boundary": [],
                "review_focus": "",
                "actions_all": [],
                "actions_pending": [],
                "actions_done": [],
                "acceptance_all": [],
                "acceptance_pending": [],
                "acceptance_done": [],
                "close_condition": "",
                "blockers": "",
                "raw": [],
                "valid": True,
                "errors": [],
                "_mode": None,
                "_in_file_boundary": False,
                "_in_actions": False,
                "_in_acceptance": False,
            }

        for line in lines:
            if line.startswith("## 4.") or line.startswith("## 5.") or line.startswith("## 6.") or line.startswith("## 7.") or line.startswith("## 8."):
                if in_steps:
                    flush()
                    break
            if line.startswith("## 3. 实施步骤"):
                in_steps = True
                continue
            if not in_steps:
                continue

            if line.startswith("### "):
                title = line.replace("### ", "", 1).strip()
                if title:
                    flush()
                    current = new_step(title)
                    current["raw"].append(line)
                    # 标准模板之外的 2.x 章节仍允许进入解析，但后续会被严格校验
                    if re.match(r"^\d+\.\d+(?:\.\d+)?\s+", title):
                        current["_mode"] = "legacy"
                    else:
                        current["_mode"] = "standard"
                    continue

            if current is None:
                continue

            current["raw"].append(line)
            stripped = line.strip()
            if line.startswith("**Step ID**："):
                current["step_id"] = line.replace("**Step ID**：", "", 1).strip().strip("`")
            elif line.startswith("**目标**："):
                current["goal"] = line.replace("**目标**：", "", 1).strip()
            elif line.startswith("**文件边界**："):
                current["_in_file_boundary"] = True
                current["_in_actions"] = False
                current["_in_acceptance"] = False
            elif line.startswith("**本轮 review 预期关注面**："):
                current["review_focus"] = line.replace("**本轮 review 预期关注面**：", "", 1).strip()
                current["_in_file_boundary"] = False
            elif line.startswith("**执行动作**："):
                current["_in_actions"] = True
                current["_in_file_boundary"] = False
                current["_in_acceptance"] = False
            elif line.startswith("**本步验收**："):
                current["_in_acceptance"] = True
                current["_in_actions"] = False
                current["_in_file_boundary"] = False
            elif line.startswith("**本步关闭条件**："):
                current["close_condition"] = line.replace("**本步关闭条件**：", "", 1).strip()
                current["_in_acceptance"] = False
            elif line.startswith("**阻塞条件**："):
                current["blockers"] = line.replace("**阻塞条件**：", "", 1).strip()
                current["_in_acceptance"] = False
            else:
                if current["_in_file_boundary"] and stripped.startswith(("- Create:", "- Modify:", "- Test:")):
                    current["file_boundary"].append(stripped)
                elif current["_in_actions"] and stripped.startswith(("- [ ]", "- [x]", "- [X]")):
                    current["actions_all"].append(stripped)
                    if stripped.startswith(("- [x]", "- [X]")):
                        current["actions_done"].append(stripped)
                    else:
                        current["actions_pending"].append(stripped)
                elif current["_in_acceptance"] and stripped.startswith(("- [ ]", "- [x]", "- [X]")):
                    current["acceptance_all"].append(stripped)
                    if stripped.startswith(("- [x]", "- [X]")):
                        current["acceptance_done"].append(stripped)
                    else:
                        current["acceptance_pending"].append(stripped)

        flush()

        for step in steps:
            errors = []
            if not step["step_id"]:
                errors.append("缺少 Step ID")
            if not step["goal"]:
                errors.append("缺少目标")
            if not step["file_boundary"]:
                errors.append("缺少文件边界")
            if not step["review_focus"]:
                errors.append("缺少本轮 review 预期关注面")
            if not step["actions_all"]:
                errors.append("缺少执行动作")
            if not step["acceptance_all"]:
                errors.append("缺少本步验收")
            if not step["close_condition"]:
                errors.append("缺少本步关闭条件")
            if not step["blockers"]:
                errors.append("缺少阻塞条件")
            step["valid"] = not errors
            step["errors"] = errors
            for key in ("_mode", "_in_file_boundary", "_in_actions", "_in_acceptance"):
                step.pop(key, None)

        ok = bool(steps) and all(step["valid"] for step in steps)
        return {
            "ok": ok,
            "error": "" if ok else "plan 实施步骤结构不符合标准模板",
            "steps": steps,
        }

    @staticmethod
    def parse_markdown_table(file_path, section_name):
        """提取 Markdown 文件特定章节下的表格数据"""
        try:
            text = Path(file_path).read_text(encoding='utf-8')
            lines = text.splitlines()
            in_section = False
            table_lines = []
            
            for line in lines:
                if line.startswith('##') or line.startswith('###'):
                    if section_name in line:
                        in_section = True
                        table_lines = []
                        continue
                    if in_section:
                        break
                if in_section and line.strip().startswith('|'):
                    table_lines.append(line.strip())
            
            if len(table_lines) < 3: # 至少需要表头、分隔行和一行数据
                return []
            
            rows = []
            # 跳过表头和分隔行
            for raw in table_lines[2:]:
                cells = [cell.strip() for cell in raw.strip('|').split('|')]
                if any(cells):
                    rows.append(cells)
            return rows
        except Exception:
            return []

    @staticmethod
    def detect_tech_stack(project_dir):
        """探测项目技术栈"""
        project_path = Path(project_dir)
        frameworks = []
        
        pkg_json = project_path / "package.json"
        if pkg_json.is_file():
            content = pkg_json.read_text(encoding='utf-8')
            if '"next"' in content: frameworks.append("Next.js")
            if '"react"' in content: frameworks.append("React")
            if '"vue"' in content: frameworks.append("Vue")
            if '"tailwindcss"' in content: frameworks.append("TailwindCSS")
        
        if (project_path / "src-tauri").is_dir(): frameworks.append("Tauri(Rust)")
        if (project_path / "pom.xml").is_file(): frameworks.append("Java/Spring Boot")
        if (project_path / "go.mod").is_file(): frameworks.append("Go")
        if (project_path / "requirements.txt").is_file() or (project_path / "pyproject.toml").is_file():
            frameworks.append("Python")
        if (project_path / "Cargo.toml").is_file() and not (project_path / "src-tauri").is_dir():
            frameworks.append("Rust")
            
        return ", ".join(frameworks) if frameworks else "Unknown"

    @staticmethod
    def collect_repo_args(state_file, project_dir):
        """从状态文件中收集多仓参数"""
        try:
            with open(state_file, 'r', encoding='utf-8') as f:
                state = json.load(f)
            owner = Path(project_dir).resolve()
            scope = state.get("execution_scope") or {}
            repos = scope.get("repos") or []
            results = []
            for repo in repos:
                repo_id = str(repo.get("id") or "").strip()
                repo_path = str(repo.get("path") or "").strip()
                if not repo_id or not repo_path:
                    continue
                repo_root = (owner / repo_path).resolve()
                results.append(f"{repo_id}::{repo_root}")
            return results
        except Exception:
            return []

    @staticmethod
    def validate_plan_paths(bundle_json_str, plan_file):
        """校验计划文件中的路径是否命中保护规则"""
        try:
            bundle = json.loads(bundle_json_str)
            plan_path = Path(plan_file).resolve()
            plan_text = plan_path.read_text(encoding="utf-8")
            
            repos = bundle.get("repos", []) or []
            repo_ids = {str(item.get("repo_id") or "").strip() for item in repos}
            
            # 使用 parse_markdown_table 提取表格
            # 逻辑稍微有点不同，这里是针对特定章节
            rows = FlowUtils.parse_markdown_table(plan_file, "文件边界总览")
            
            import fnmatch
            errors = []
            for row in rows:
                if len(row) < 2: continue
                path = row[0].strip().replace("`", "")
                repo_id = row[1].strip() or "owner"
                if repo_id not in repo_ids:
                    repo_id = "owner"
                if not path:
                    continue
                
                merged = bundle.get("merged", {})
                for item in merged.get("protected_paths", []):
                    pattern = str(item.get("path") or "").strip()
                    if item.get("repo_id") == repo_id and pattern and fnmatch.fnmatch(path, pattern.replace("\\", "/")):
                        errors.append(f"命中 protected_paths，计划声明的执行边界不可修改: [{repo_id}] {path} -> {pattern}")
                
                for item in merged.get("forbidden_changes", []):
                    pattern = str(item.get("path") or "").strip()
                    if item.get("repo_id") == repo_id and pattern and fnmatch.fnmatch(path, pattern.replace("\\", "/")):
                        reason = str(item.get("reason") or "").strip()
                        suffix = f"：{reason}" if reason else ""
                        errors.append(f"命中 forbidden_changes，计划声明的执行边界不可修改: [{repo_id}] {path} -> {pattern}{suffix}")
            return errors
        except Exception as e:
            return [f"验证过程出错: {str(e)}"]

    @staticmethod
    def validate_plan_structure(plan_file):
        """验证 plan 的实施步骤是否符合标准模板。"""
        result = FlowUtils.parse_plan_steps(plan_file)
        if result["ok"]:
            return []
        errors = [result.get("error") or "plan 实施步骤结构不合法"]
        for step in result.get("steps") or []:
            if step.get("errors"):
                label = step.get("step_id") or step.get("title") or "unknown step"
                errors.append(f"{label}: {'; '.join(step['errors'])}")
        return errors

    @staticmethod
    def validate_plan_completion(plan_file):
        """验证 plan 是否已完成所有执行动作。"""
        result = FlowUtils.parse_plan_steps(plan_file)
        if not result["ok"]:
            return [result.get("error") or "plan 实施步骤结构不合法"]
        errors = []
        for step in result.get("steps") or []:
            label = step.get("step_id") or step.get("title") or "unknown step"
            if step.get("actions_pending"):
                errors.append(f"{label}: 仍有未完成执行动作")
            if step.get("acceptance_pending"):
                errors.append(f"{label}: 仍有未完成验收项")
        return errors

    @staticmethod
    def validate_plan_coverage(plan_file, report_file, review_mode="regular"):
        """验证审查报告的计划覆盖度是否与 plan 的步骤集合一致。"""
        try:
            Path(plan_file).read_text(encoding="utf-8")
        except Exception as exc:
            return [f"无法读取 plan 文件: {exc}"]

        try:
            report_text = Path(report_file).read_text(encoding="utf-8")
        except Exception as exc:
            return [f"无法读取审查报告: {exc}"]

        plan_result = FlowUtils.parse_plan_steps(plan_file)
        if not plan_result["ok"]:
            return [plan_result.get("error") or "plan 实施步骤结构不合法"]

        normalized_mode = (review_mode or "").strip().lower()
        if normalized_mode in {"", "auto"}:
            mode_match = re.search(r"(?m)^> 审查模式：([^\n]+)$", report_text)
            if mode_match:
                normalized_mode = mode_match.group(1).strip().lower()
        if normalized_mode not in {"regular", "incremental", "recheck"}:
            normalized_mode = "regular"

        errors = []
        plan_step_ids = []
        seen_plan_ids = set()
        for step in plan_result.get("steps") or []:
            step_id = str(step.get("step_id") or "").strip()
            if not step_id:
                errors.append("plan 实施步骤缺少 Step ID")
                continue
            if step_id in seen_plan_ids:
                errors.append(f"plan 实施步骤 Step ID 重复: {step_id}")
                continue
            seen_plan_ids.add(step_id)
            plan_step_ids.append(step_id)

        section_match = re.search(
            r"(?ms)^## 2\. 计划覆盖度检查(?:[（(][^)\n）]+[)）])?\s*\n"
            r"(.*?)(?=^(?:##|###) 2\.1 |^## 3\. |\Z)",
            report_text,
        )
        if not section_match:
            return ["报告缺少 ## 2. 计划覆盖度检查"]

        rows = []
        for line in section_match.group(1).splitlines():
            stripped = line.strip()
            if not stripped.startswith("|"):
                continue
            cells = [part.strip() for part in stripped.split("|")[1:-1]]
            if len(cells) < 3:
                continue
            raw_step = cells[0].strip("`").strip()
            if not raw_step or raw_step in {"实施步骤", "Step ID", "Step ID（必须一一对应）"}:
                continue
            if set(raw_step) == {"-"}:
                continue
            step_id = re.split(r"[（(]", raw_step, maxsplit=1)[0].strip().strip("`")
            if not step_id:
                errors.append("计划覆盖度检查存在空步骤标识")
                continue
            rows.append({
                "step_id": step_id,
                "status": cells[1].replace("**", "").strip(),
                "raw_label": raw_step,
            })

        if not rows:
            errors.append("计划覆盖度检查缺少有效表格内容")
            return errors

        seen_report_ids = set()
        duplicate_report_ids = []
        incomplete_rows = []
        allowed_statuses = {"已实现", "未实现", "部分实现"}
        for row in rows:
            step_id = row["step_id"]
            if step_id in seen_report_ids:
                duplicate_report_ids.append(step_id)
            else:
                seen_report_ids.add(step_id)
            if row["status"] not in allowed_statuses:
                errors.append(
                    f"计划覆盖度检查状态非法: {step_id} -> {row['status'] or '空'}"
                )
            if row["status"] in {"未实现", "部分实现"}:
                incomplete_rows.append(f"{step_id} -> {row['status']}")

        if duplicate_report_ids:
            errors.append("计划覆盖度检查存在重复步骤: " + ", ".join(sorted(set(duplicate_report_ids))))

        plan_step_set = set(plan_step_ids)
        report_step_set = seen_report_ids

        if normalized_mode == "incremental":
            missing = [step_id for step_id in seen_report_ids if step_id not in plan_step_set]
            if missing:
                errors.append("计划覆盖度检查包含 plan 未定义步骤: " + ", ".join(sorted(missing)))
            if not report_step_set:
                errors.append("计划覆盖度检查缺少任何步骤覆盖")
        else:
            missing = [step_id for step_id in plan_step_ids if step_id not in report_step_set]
            extra = [step_id for step_id in report_step_set if step_id not in plan_step_set]
            if missing:
                errors.append("计划覆盖度检查缺少以下 plan 步骤: " + ", ".join(missing))
            if extra:
                errors.append("计划覆盖度检查包含 plan 未定义步骤: " + ", ".join(sorted(extra)))

        if incomplete_rows:
            errors.append("计划覆盖度检查存在未完成项: " + ", ".join(incomplete_rows))

        return errors

    @staticmethod
    def render_template(template_path, env_vars):
        """通用模板渲染逻辑"""
        try:
            text = Path(template_path).read_text(encoding="utf-8")
            for key, value in env_vars.items():
                text = text.replace(key, value)
            return text
        except Exception:
            return ""

    @staticmethod
    def trim_to_marker(file_path, marker, fallback_slug=""):
        """将文件截断到特定标记处"""
        try:
            path = Path(file_path)
            text = path.read_text(encoding="utf-8")
            lines = text.splitlines()
            for index, line in enumerate(lines):
                if line.startswith(marker):
                    trimmed = "\n".join(lines[index:])
                    if text.endswith("\n"): trimmed += "\n"
                    path.write_text(trimmed, encoding="utf-8")
                    return True
            
            # Fallback
            for fallback in ["## 1. 需求概述", "## 1\\. 需求概述", "## 需求概述"]:
                for index, line in enumerate(lines):
                    if fallback in line:
                        start = index
                        for j in range(index, -1, -1):
                            if lines[j].startswith("# "):
                                start = j
                                break
                        if start == index:
                            title = f"# 实施计划：{fallback_slug}" if fallback_slug else "# 实施计划"
                            lines.insert(index, title)
                            start = index
                        trimmed = "\n".join(lines[start:])
                        if text.endswith("\n"): trimmed += "\n"
                        path.write_text(trimmed, encoding="utf-8")
                        return True
            return False
        except Exception:
            return False

def _parse_iso_datetime(iso_str: str) -> datetime:
    """解析 ISO 8601 时间字符串，兼容 Python < 3.11。

    Python 3.11 之前 datetime.fromisoformat() 不支持带时区偏移的字符串
    （如 '2026-05-20T08:00:00+08:00'）。此函数先尝试 fromisoformat()，
    失败后手动剥离时区偏移并构造 tzinfo。
    """
    try:
        return datetime.fromisoformat(iso_str)
    except (ValueError, AttributeError):
        pass
    s = iso_str.strip()
    tz_offset = None
    m = re.search(r'([+-])(\d{2}):?(\d{2})$', s)
    if m:
        sign = 1 if m.group(1) == '+' else -1
        hours = int(m.group(2))
        minutes = int(m.group(3))
        tz_offset = timezone(timedelta(hours=sign * hours, minutes=sign * minutes))
        s = s[:m.start()]
    elif s.endswith('Z') or s.endswith('z'):
        tz_offset = timezone.utc
        s = s[:-1]
    dt = datetime.fromisoformat(s)
    if tz_offset is not None:
        dt = dt.replace(tzinfo=tz_offset)
    return dt


@dataclass
class FlowNode:
    state: str
    label: str
    x: int = 0
    y: int = 0
    is_current: bool = False
    is_failed: bool = False
    duration_ms: int = 0
    diagnosis: str = ""


@dataclass
class FlowEdge:
    from_state: str
    to_state: str
    event: str = ""
    label: str = ""
    is_traversed: bool = False


FLOW_NODES = {
    "AWAITING_PLAN_REVIEW": FlowNode("AWAITING_PLAN_REVIEW", "待计划审核"),
    "PLAN_REVIEW_FAILED": FlowNode("PLAN_REVIEW_FAILED", "计划审核失败", is_failed=True),
    "PLANNED": FlowNode("PLANNED", "计划已审核"),
    "IMPLEMENTING": FlowNode("IMPLEMENTING", "开发中"),
    "AWAITING_REVIEW": FlowNode("AWAITING_REVIEW", "待审查"),
    "REVIEW_FAILED": FlowNode("REVIEW_FAILED", "审查失败", is_failed=True),
    "FIXING_REVIEW": FlowNode("FIXING_REVIEW", "修复中"),
    "DONE": FlowNode("DONE", "完成"),
}

FLOW_EDGES = [
    FlowEdge("AWAITING_PLAN_REVIEW", "PLANNED", "plan_review_passed", "审核通过"),
    FlowEdge("AWAITING_PLAN_REVIEW", "PLAN_REVIEW_FAILED", "plan_review_failed", "审核失败"),
    FlowEdge("PLAN_REVIEW_FAILED", "AWAITING_PLAN_REVIEW", "plan_reopened", "重新提交"),
    FlowEdge("PLANNED", "IMPLEMENTING", "execute_started", "开始执行"),
    FlowEdge("PLANNED", "AWAITING_PLAN_REVIEW", "plan_reopened", "需求变更"),
    FlowEdge("IMPLEMENTING", "AWAITING_REVIEW", "implementation_completed", "完成编码"),
    FlowEdge("IMPLEMENTING", "AWAITING_PLAN_REVIEW", "plan_reopened", "需求变更"),
    FlowEdge("AWAITING_REVIEW", "DONE", "review_passed", "审查通过"),
    FlowEdge("AWAITING_REVIEW", "REVIEW_FAILED", "review_failed", "审查失败"),
    FlowEdge("AWAITING_REVIEW", "IMPLEMENTING", "implementation_reopened", "重新实现"),
    FlowEdge("REVIEW_FAILED", "FIXING_REVIEW", "fix_started", "开始修复"),
    FlowEdge("REVIEW_FAILED", "IMPLEMENTING", "implementation_reopened", "重新实现"),
    FlowEdge("FIXING_REVIEW", "AWAITING_REVIEW", "fix_completed", "修复完成"),
    FlowEdge("FIXING_REVIEW", "IMPLEMENTING", "implementation_reopened", "重新实现"),
    FlowEdge("DONE", "DONE", "recheck_passed", "再审查通过"),
    FlowEdge("DONE", "REVIEW_FAILED", "recheck_failed", "再审查失败"),
    FlowEdge("DONE", "IMPLEMENTING", "implementation_reopened", "重新实现"),
]


def _format_duration_short(ms: int) -> str:
    if ms < 1000:
        return f"{ms}ms"
    elif ms < 60000:
        return f"{ms / 1000:.0f}s"
    elif ms < 3600000:
        return f"{ms / 60000:.0f}min"
    else:
        return f"{ms / 3600000:.1f}h"


def build_flow_graph(
    transitions: list,
    current_status: str,
    stage_durations: Optional[dict] = None,
    diagnosis: Optional[str] = None,
) -> tuple:
    import copy
    nodes = {k: copy.deepcopy(v) for k, v in FLOW_NODES.items()}
    edges = [copy.deepcopy(e) for e in FLOW_EDGES]

    traversed_pairs = set()
    for t in transitions:
        frm = t.get("from")
        to = t.get("to")
        if frm and to:
            traversed_pairs.add((frm, to))

    for edge in edges:
        if (edge.from_state, edge.to_state) in traversed_pairs:
            edge.is_traversed = True

    if current_status in nodes:
        nodes[current_status].is_current = True

    if stage_durations:
        # calculate_stage_durations 返回的 key 是阶段名（plan_review/coding/review），
        # 需要映射到对应的状态节点。
        stage_to_states = {
            "plan_review": ["AWAITING_PLAN_REVIEW", "PLAN_REVIEW_FAILED"],
            "coding": ["PLANNED", "IMPLEMENTING"],
            "review": ["AWAITING_REVIEW", "REVIEW_FAILED", "FIXING_REVIEW", "DONE"],
        }
        for stage_name, duration in stage_durations.items():
            target_states = stage_to_states.get(stage_name, [])
            for state_key in target_states:
                if state_key in nodes:
                    nodes[state_key].duration_ms = duration

    if diagnosis and current_status in nodes:
        nodes[current_status].diagnosis = diagnosis

    return list(nodes.values()), edges


def render_ascii_flow(nodes: list, edges: list) -> str:
    current = [n for n in nodes if n.is_current][0] if any(n.is_current for n in nodes) else None
    traversed_pairs = {(e.from_state, e.to_state) for e in edges if e.is_traversed}

    main_path_states = [
        "AWAITING_PLAN_REVIEW",
        "PLANNED",
        "IMPLEMENTING",
        "AWAITING_REVIEW",
        "DONE",
    ]
    failed_branches = {
        "PLAN_REVIEW_FAILED": ("AWAITING_PLAN_REVIEW", "below"),
        "REVIEW_FAILED": ("AWAITING_REVIEW", "below"),
    }

    lines = []
    main_nodes_in_path = [s for s in main_path_states if s in {n.state for n in nodes}]

    node_map = {n.state: n for n in nodes}

    parts = []
    for i, state_key in enumerate(main_nodes_in_path):
        node = node_map[state_key]
        label = node.label
        if node.is_current:
            marker = ">>>"
        elif i > 0 and (main_nodes_in_path[i - 1], state_key) in traversed_pairs:
            marker = "-->"
        else:
            marker = "- ->"

        dur_str = f" ({_format_duration_short(node.duration_ms)})" if node.duration_ms > 0 else ""
        parts.append(f"{marker} [{label}]{dur_str}")

    lines.append("  " + "".join(parts))

    for fail_state, (parent_state, position) in failed_branches.items():
        if fail_state not in node_map:
            continue
        fail_node = node_map[fail_state]
        parent_idx = main_nodes_in_path.index(parent_state) if parent_state in main_nodes_in_path else -1
        if parent_idx < 0:
            continue

        prefix_width = 0
        for j in range(parent_idx + 1):
            prev_state = main_nodes_in_path[j]
            prev_node = node_map[prev_state]
            prefix_width += len(prev_node.label) + 4
            if j > 0:
                prev_key = main_nodes_in_path[j - 1]
                if (prev_key, prev_state) in traversed_pairs:
                    prefix_width += 3
                else:
                    prefix_width += 4

        dur_str = f" ({_format_duration_short(fail_node.duration_ms)})" if fail_node.duration_ms > 0 else ""
        fail_label = f"[{fail_node.label}]{dur_str}"
        lines.append("  " + " " * prefix_width + "|")
        lines.append("  " + " " * prefix_width + "V")
        lines.append("  " + " " * prefix_width + fail_label)

    return "\n".join(lines)


def render_svg_flow(nodes: list, edges: list) -> str:
    node_map = {n.state: n for n in nodes}

    layout = {
        "AWAITING_PLAN_REVIEW": (20, 60),
        "PLAN_REVIEW_FAILED": (20, 180),
        "PLANNED": (200, 60),
        "IMPLEMENTING": (380, 60),
        "AWAITING_REVIEW": (560, 60),
        "REVIEW_FAILED": (560, 180),
        "FIXING_REVIEW": (740, 180),
        "DONE": (740, 60),
    }

    node_width = 120
    node_height = 40
    svg_width = 900
    svg_height = 260

    parts = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{svg_width}" height="{svg_height}" viewBox="0 0 {svg_width} {svg_height}">'
    )
    parts.append(
        "<style>"
        ".node { fill: #f0f0f0; stroke: #333; stroke-width: 1.5; rx: 6; }"
        ".node-current { fill: #dbeafe; stroke: #2563eb; stroke-width: 2; }"
        ".node-failed { fill: #fee2e2; stroke: #dc2626; stroke-width: 2; }"
        ".node-label { font: 12px sans-serif; text-anchor: middle; dominant-baseline: central; fill: #111; }"
        ".edge-traversed { stroke: #333; stroke-width: 2; fill: none; }"
        ".edge-pending { stroke: #999; stroke-width: 1.5; stroke-dasharray: 5,5; fill: none; }"
        ".duration-label { font: 10px sans-serif; fill: #666; text-anchor: middle; }"
        "</style>"
    )

    for edge in edges:
        if edge.from_state not in layout or edge.to_state not in layout:
            continue
        x1, y1 = layout[edge.from_state]
        x2, y2 = layout[edge.to_state]
        x1 += node_width / 2
        y1 += node_height
        x2 += node_width / 2

        cls = "edge-traversed" if edge.is_traversed else "edge-pending"
        mid_y = (y1 + y2) / 2
        path_d = f"M {x1} {y1} Q {x1} {mid_y} {(x1 + x2) / 2} {mid_y} T {x2} {y2}"
        parts.append(f'<path class="{cls}" d="{path_d}"/>')

    for state_key, (x, y) in layout.items():
        if state_key not in node_map:
            continue
        node = node_map[state_key]
        cls = "node"
        if node.is_current:
            cls = "node-current"
        elif node.is_failed:
            cls = "node-failed"

        parts.append(
            f'<rect class="{cls}" x="{x}" y="{y}" width="{node_width}" height="{node_height}"/>'
        )
        parts.append(
            f'<text class="node-label" x="{x + node_width / 2}" y="{y + node_height / 2}">{node.label}</text>'
        )

        if node.duration_ms > 0:
            parts.append(
                f'<text class="duration-label" x="{x + node_width / 2}" y="{y + node_height + 14}">{_format_duration_short(node.duration_ms)}</text>'
            )

    parts.append("</svg>")
    return "\n".join(parts)


@dataclass
class StageDuration:
    stage_name: str
    start_event: str
    end_event: str
    duration_ms: int
    notes: str = ""
    failed_count: int = 0


def calculate_stage_durations(transitions: list) -> list:
    """从 transitions 数组中提取各阶段耗时。

    返回 list[StageDuration]，覆盖 plan_review、coding、review 三个阶段。
    """
    if not transitions:
        return []

    def find_event(event_name, start_idx=0):
        for i in range(start_idx, len(transitions)):
            if transitions[i].get("event") == event_name:
                return i
        return None

    def find_status_to(status, from_event=None, start_idx=0):
        for i in range(start_idx, len(transitions)):
            if transitions[i].get("to") == status:
                return i
        return None

    def calc_ms(idx_start, idx_end):
        try:
            if idx_start is None or idx_end is None:
                return 0
            t1 = _parse_iso_datetime(transitions[idx_start]["at"])
            t2 = _parse_iso_datetime(transitions[idx_end]["at"])
            delta = int((t2 - t1).total_seconds() * 1000)
            return max(0, delta)
        except (ValueError, TypeError, IndexError, KeyError):
            return 0

    def format_duration(ms):
        if ms < 1000:
            return f"{ms}ms"
        elif ms < 60000:
            return f"{ms / 1000:.1f}s"
        elif ms < 3600000:
            return f"{ms / 60000:.1f}min"
        else:
            return f"{ms / 3600000:.1f}h"

    result = []

    # plan_review 阶段：从 plan_created 到第一次到达 PLANNED
    plan_start = find_event("plan_created")
    plan_end = find_status_to("PLANNED")
    if plan_start is not None and plan_end is not None and plan_end > plan_start:
        failed = sum(1 for t in transitions[plan_start:plan_end + 1]
                     if t.get("event") == "plan_review_failed")
        notes = f"含 {failed} 次审核失败" if failed else "无"
        result.append(StageDuration(
            stage_name="plan_review",
            start_event="plan_created",
            end_event="plan_review_passed",
            duration_ms=calc_ms(plan_start, plan_end),
            notes=notes,
            failed_count=failed,
        ))

    # coding 阶段：从 execute_started 到 implementation_completed
    code_start = find_event("execute_started")
    code_end = find_event("implementation_completed")
    if code_start is not None and code_end is not None and code_end > code_start:
        result.append(StageDuration(
            stage_name="coding",
            start_event="execute_started",
            end_event="implementation_completed",
            duration_ms=calc_ms(code_start, code_end),
            notes="无",
        ))

    # review 阶段：从第一个 review 相关事件到最后一个
    review_events = {"review_passed", "review_failed", "recheck_passed", "recheck_failed",
                     "fix_started", "fix_completed"}
    review_indices = [i for i, t in enumerate(transitions)
                      if t.get("event") in review_events]
    if len(review_indices) >= 2:
        review_start = review_indices[0]
        review_end = review_indices[-1]
        fix_count = sum(1 for t in transitions[review_start:review_end + 1]
                        if t.get("event") == "fix_completed")
        # 统计 review 轮次（review_passed/review_failed/recheck_passed/recheck_failed）
        round_events = [t for i, t in enumerate(transitions)
                        if i in review_indices and t.get("event") in
                        ("review_passed", "review_failed", "recheck_passed", "recheck_failed")]
        round_count = len(round_events)
        passed = any(t.get("event") in ("review_passed", "recheck_passed")
                     for t in round_events)
        notes = f"{round_count} 轮审查，{fix_count} 次修复"
        if passed:
            notes += "，最终通过"
        else:
            notes += "，最终未通过"
        result.append(StageDuration(
            stage_name="review",
            start_event=transitions[review_start].get("event", ""),
            end_event=transitions[review_end].get("event", ""),
            duration_ms=calc_ms(review_start, review_end),
            notes=notes,
            failed_count=sum(1 for t in round_events if "failed" in t.get("event", "")),
        ))
    elif len(review_indices) == 1:
        # 只有单个 review 事件（如直接进入 review_passed）
        idx = review_indices[0]
        result.append(StageDuration(
            stage_name="review",
            start_event=transitions[idx].get("event", ""),
            end_event=transitions[idx].get("event", ""),
            duration_ms=0,
            notes="单事件，无耗时",
        ))

    return result


def calculate_review_round_durations(transitions: list) -> list:
    """计算每轮 review 的独立耗时。

    返回 list[dict]，每项包含 round、event、result、duration_ms。
    """
    if not transitions:
        return []

    review_events = {"review_passed", "review_failed", "recheck_passed", "recheck_failed"}
    review_transitions = [(i, t) for i, t in enumerate(transitions)
                          if t.get("event") in review_events]
    if len(review_transitions) < 2:
        return []

    rounds = []
    prev_idx, prev_t = review_transitions[0]
    for round_num, (curr_idx, curr_t) in enumerate(review_transitions[1:], start=1):
        try:
            t1 = _parse_iso_datetime(prev_t["at"])
            t2 = _parse_iso_datetime(curr_t["at"])
            delta = max(0, int((t2 - t1).total_seconds() * 1000))
        except (ValueError, TypeError, KeyError):
            delta = 0

        event_name = curr_t.get("event", "")
        result = "passed" if event_name.endswith("passed") else "failed"
        rounds.append({
            "round": round_num,
            "event": event_name,
            "result": result,
            "duration_ms": delta,
        })
        prev_idx, prev_t = curr_idx, curr_t

    return rounds


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(1)
        
    cmd = sys.argv[1]
    if cmd == "get-json-field":
        res = FlowUtils.get_json_field(sys.argv[2], sys.argv[3])
        if res is not None:
            print(json.dumps(res, ensure_ascii=False) if isinstance(res, (dict, list)) else res)
    elif cmd == "parse-table":
        res = FlowUtils.parse_markdown_table(sys.argv[2], sys.argv[3])
        for row in res:
            print("|".join(row))
    elif cmd == "detect-stack":
        print(FlowUtils.detect_tech_stack(sys.argv[2]))
    elif cmd == "collect-repos":
        res = FlowUtils.collect_repo_args(sys.argv[2], sys.argv[3])
        for line in res:
            print(line)
    elif cmd == "validate-plan-paths":
        res = FlowUtils.validate_plan_paths(sys.argv[2], sys.argv[3])
        for err in res:
            print(err)
    elif cmd == "validate-plan-structure":
        res = FlowUtils.validate_plan_structure(sys.argv[2])
        for err in res:
            print(err)
    elif cmd == "validate-plan-completion":
        res = FlowUtils.validate_plan_completion(sys.argv[2])
        for err in res:
            print(err)
    elif cmd == "validate-plan-coverage":
        review_mode = sys.argv[4] if len(sys.argv) > 4 else "regular"
        res = FlowUtils.validate_plan_coverage(sys.argv[2], sys.argv[3], review_mode)
        for err in res:
            print(err)
    elif cmd == "trim-marker":
        FlowUtils.trim_to_marker(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
