import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from pathlib import Path

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
    elif cmd == "trim-marker":
        FlowUtils.trim_to_marker(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
