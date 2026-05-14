import json
import os
import re
import sys
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
