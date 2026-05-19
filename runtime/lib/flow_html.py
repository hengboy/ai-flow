#!/usr/bin/env python3
"""AI Flow HTML 渲染模块。

解析 Plan/Review Markdown 和 state JSON，生成自包含 HTML 文件。
仅使用 Python 标准库。
"""

from __future__ import annotations

import html
import json
import re
import subprocess
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


# ---- Markdown parser ----

@dataclass
class Block:
    kind: str  # h1/h2/h3/para/table/checklist/code/blockquote/prose
    content: str = ""
    cells: list[list[str]] = field(default_factory=list)  # for table
    checked: bool = False  # for checklist
    meta_key: str = ""  # for blockquote metadata lines
    meta_value: str = ""


class MarkdownParser:
    """逐行扫描 Markdown，识别已知结构；未识别区块 fallback 为 prose/pre。"""

    def __init__(self):
        self.blocks: list[Block] = []
        self._code_buf: list[str] = []
        self._code_lang = ""
        self._in_code = False
        self._para_buf: list[str] = []
        self._table_buf: list[list[str]] = []
        self._in_table = False
        self._blockquote_buf: list[str] = []
        self._in_blockquote = False

    def parse(self, text: str) -> list[Block]:
        self.blocks = []
        self._code_buf = []
        self._in_code = False
        self._para_buf = []
        self._table_buf = []
        self._in_table = False
        self._blockquote_buf = []
        self._in_blockquote = False

        for raw_line in text.split("\n"):
            line = raw_line.rstrip()

            # Fenced code block
            m_code = re.match(r"^```(\w*)", line)
            if m_code:
                if not self._in_code:
                    self._flush_para()
                    self._flush_table()
                    self._flush_blockquote()
                    self._in_code = True
                    self._code_lang = m_code.group(1)
                    self._code_buf = []
                else:
                    self._in_code = False
                    self.blocks.append(Block(kind="code", content="\n".join(self._code_buf)))
                    self._code_buf = []
                continue

            if self._in_code:
                self._code_buf.append(html.escape(line))
                continue

            # Heading
            m_h = re.match(r"^(#{1,3})\s+(.*)", line)
            if m_h:
                self._flush_para()
                self._flush_table()
                self._flush_blockquote()
                level = len(m_h.group(1))
                self.blocks.append(Block(kind=f"h{level}", content=m_h.group(2).strip()))
                continue

            # Table row
            if "|" in line and re.match(r"^\s*\|", line):
                self._flush_para()
                self._flush_blockquote()
                cells = [c.strip() for c in line.strip().split("|")[1:-1]]
                if all(c.replace("-", "").replace(":", "").strip() == "" for c in cells):
                    # separator line, skip
                    continue
                self._in_table = True
                self._table_buf.append(cells)
                continue
            else:
                self._flush_table()

            # Checklist
            m_check = re.match(r"^\s*- \[([ xX])\]\s+(.*)", line)
            if m_check:
                self._flush_para()
                self._flush_table()
                self._flush_blockquote()
                self.blocks.append(
                    Block(kind="checklist", content=m_check.group(2).strip(),
                          checked=m_check.group(1) in ("x", "X"))
                )
                continue

            # Blockquote metadata line: "> key：value" or "> key: value"
            m_bq = re.match(r"^>\s*(.+?)\s*[:：]\s*(.*)", line)
            if m_bq:
                self._flush_para()
                self._flush_table()
                key = m_bq.group(1).strip()
                val = m_bq.group(2).strip()
                self.blocks.append(Block(kind="blockquote", meta_key=key, meta_value=val))
                continue

            # Plain blockquote
            if line.startswith(">"):
                self._flush_para()
                self._flush_table()
                self._in_blockquote = True
                self._blockquote_buf.append(line[1:].strip())
                continue
            else:
                self._flush_blockquote()

            # Empty line
            if line.strip() == "":
                self._flush_para()
                continue

            # Fallback prose
            self._para_buf.append(line)

        self._flush_para()
        self._flush_table()
        self._flush_code()
        self._flush_blockquote()
        return self.blocks

    def _flush_para(self):
        if self._para_buf:
            text = "\n".join(self._para_buf)
            # Inline code
            text = re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(text))
            self._para_buf = []
            self.blocks.append(Block(kind="para", content=text))

    def _flush_table(self):
        if self._table_buf:
            self.blocks.append(Block(kind="table", cells=self._table_buf))
            self._table_buf = []
            self._in_table = False

    def _flush_code(self):
        if self._code_buf:
            self.blocks.append(Block(kind="code", content="\n".join(self._code_buf)))
            self._code_buf = []
            self._in_code = False

    def _flush_blockquote(self):
        if self._blockquote_buf:
            text = "\n".join(self._blockquote_buf)
            self._blockquote_buf = []
            self._in_blockquote = False
            self.blocks.append(Block(kind="prose", content=html.escape(text)))


# ---- Template engine ----

def _read_template(name: str, template_dir: Path) -> str:
    p = template_dir / f"{name}.html"
    if p.is_file():
        return p.read_text(encoding="utf-8")
    return f"<html><body>Template {name} not found</body></html>"


def _read_asset(name: str, template_dir: Path) -> str:
    p = template_dir / name
    return p.read_text(encoding="utf-8") if p.is_file() else ""


def _render_blocks(blocks: list[Block]) -> str:
    """将 blocks 渲染为 HTML 片段。"""
    parts = []
    in_checklist = False
    for b in blocks:
        if b.kind == "checklist":
            if not in_checklist:
                parts.append('<ul class="checklist">')
                in_checklist = True
            cls = "checked" if b.checked else "unchecked"
            parts.append(f'<li class="{cls}">{b.content}</li>')
        else:
            if in_checklist:
                parts.append("</ul>")
                in_checklist = False

            if b.kind.startswith("h"):
                level = b.kind[1:]
                parts.append(f"<h{level}>{b.content}</h{level}>")
            elif b.kind == "para":
                parts.append(f'<div class="prose"><p>{b.content}</p></div>')
            elif b.kind == "table":
                parts.append(_render_table(b.cells))
            elif b.kind == "code":
                parts.append(f"<pre><code>{b.content}</code></pre>")
            elif b.kind == "blockquote":
                parts.append(
                    f'<blockquote><span class="meta-k">{html.escape(b.meta_key)}</span>：'
                    f'<span class="meta-v">{html.escape(b.meta_value)}</span></blockquote>'
                )
            elif b.kind == "prose":
                parts.append(f'<div class="prose"><pre>{b.content}</pre></div>')
    if in_checklist:
        parts.append("</ul>")
    return "\n".join(parts)


def _render_table(cells: list[list[str]]) -> str:
    if not cells:
        return ""
    rows = []
    for i, row in enumerate(cells):
        tag = "th" if i == 0 else "td"
        cells_html = "".join(f"<{tag}>{html.escape(c)}</{tag}>" for c in row)
        rows.append(f"<tr>{cells_html}</tr>")
    return f'<table data-sortable><tbody>{"".join(rows)}</tbody></table>'


def _render_markdown_file(md_path: Path, template_name: str, template_dir: Path,
                          extra_vars: dict[str, str] | None = None) -> str:
    text = md_path.read_text(encoding="utf-8")
    parser = MarkdownParser()
    blocks = parser.parse(text)
    sections_html = _render_blocks(blocks)

    tmpl = _read_template(template_name, template_dir)
    css = _read_asset("common.css", template_dir)
    js = _read_asset("common.js", template_dir)

    vars_dict = {
        "CSS": css,
        "JS": js,
        "SECTIONS": sections_html,
    }
    if extra_vars:
        vars_dict.update(extra_vars)

    result = tmpl
    for k, v in vars_dict.items():
        result = result.replace(f"{{{{{k}}}}}", v)
    return result


# ---- Renderers ----

def _resolve_template_dir() -> Path:
    """尝试多个可能位置找到模板目录。"""
    candidates = [
        Path(__file__).resolve().parent.parent / "templates" / "html",
        Path.cwd() / "runtime" / "templates" / "html",
    ]
    for c in candidates:
        if c.is_dir():
            return c
    return candidates[0]


def render_plan(markdown_path: Path, output_path: Path) -> None:
    template_dir = _resolve_template_dir()
    extra: dict[str, str] = {
        "TITLE": markdown_path.stem,
        "SLUG": markdown_path.stem,
        "CREATED_AT": "",
        "STATUS": "",
        "SOURCE": "",
        "SOURCE_PATH": str(markdown_path),
        "REVIEW_RECORD": "",
    }
    # Try to extract metadata from first lines
    text = markdown_path.read_text(encoding="utf-8")
    for m in re.finditer(r"> (创建日期|创建时间|状态文件|需求来源)\s*[:：]\s*(.*)", text):
        key, val = m.group(1), m.group(2).strip()
        if key == "创建日期":
            extra["CREATED_AT"] = val
        elif key == "需求来源":
            extra["SOURCE"] = val
    # Extract title from first h1
    m_title = re.search(r"^# (.+)", text, re.MULTILINE)
    if m_title:
        extra["TITLE"] = m_title.group(1).strip()

    html_content = _render_markdown_file(markdown_path, "plan", template_dir, extra)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html_content, encoding="utf-8")


def render_review(markdown_path: Path, output_path: Path) -> None:
    template_dir = _resolve_template_dir()
    extra: dict[str, str] = {
        "TITLE": markdown_path.stem,
        "ENGINE": "",
        "ENGINE_INITIAL": "AI",
        "MODEL": "",
        "REVIEW_TIME": "",
        "RESULT": "",
        "SOURCE_PATH": str(markdown_path),
        "PLAN_PATH": "",
    }
    text = markdown_path.read_text(encoding="utf-8")
    for m in re.finditer(r"> (审核引擎|模型|审查时间|审查结论)\s*[:：]\s*(.*)", text):
        key, val = m.group(1), m.group(2).strip()
        if key == "审核引擎":
            extra["ENGINE"] = val
        elif key == "模型":
            extra["MODEL"] = val
        elif key == "审查时间":
            extra["REVIEW_TIME"] = val
        elif key == "审查结论":
            extra["RESULT"] = val
    m_title = re.search(r"^# (.+)", text, re.MULTILINE)
    if m_title:
        extra["TITLE"] = m_title.group(1).strip()

    html_content = _render_markdown_file(markdown_path, "review", template_dir, extra)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html_content, encoding="utf-8")


def render_status(project_dir: Path, output_path: Path) -> None:
    template_dir = _resolve_template_dir()
    state_dir = project_dir / ".ai-flow" / "state"
    if not state_dir.is_dir():
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text("<html><body>No state files</body></html>", encoding="utf-8")
        return

    statuses = {}
    total = 0
    done_count = 0
    in_progress_count = 0
    awaiting_count = 0

    rows = []
    for sf in sorted(state_dir.glob("*.json")):
        try:
            data = json.loads(sf.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        slug = data.get("slug", sf.stem)
        status = data.get("current_status", "unknown")
        plan_file = data.get("plan_file", "")
        total += 1
        if status == "DONE":
            done_count += 1
        elif status in ("IMPLEMENTING", "FIXING_REVIEW"):
            in_progress_count += 1
        elif status in ("AWAITING_REVIEW", "AWAITING_PLAN_REVIEW"):
            awaiting_count += 1

        # Derived next action
        derived = data.get("derived", {})
        if isinstance(derived, dict):
            next_events = derived.get("next_events", [])
        else:
            next_events = []
        next_str = ", ".join(next_events) if isinstance(next_events, list) else ""

        # Latest review
        last_review = ""
        if isinstance(derived, dict):
            lr = derived.get("last_review")
            if isinstance(lr, dict):
                last_review = lr.get("report_file", "")

        # HTML output link
        html_output = f".ai-flow/html/{sf.stem}.html"
        html_link = f'<a href="{html_output}">HTML</a>' if html_output else "—"

        plan_link = f'<a href="{html.escape(plan_file)}">{html.escape(Path(plan_file).name)}</a>' if plan_file else "—"
        review_link = f'<a href="{html.escape(last_review)}">{html.escape(Path(last_review).name)}</a>' if last_review else "—"

        badge_class = status.lower().replace("_", "_")
        rows.append(
            f"<tr>"
            f"<td>{html.escape(slug)}</td>"
            f'<td><span class="badge badge-{html.escape(badge_class)}">{html.escape(status)}</span></td>'
            f"<td>{plan_link}</td>"
            f"<td>{review_link}</td>"
            f"<td>{html.escape(next_str)}</td>"
            f"<td>{html_link}</td>"
            f"</tr>"
        )

    css = _read_asset("common.css", template_dir)
    js = _read_asset("common.js", template_dir)
    tmpl = _read_template("status", template_dir)

    vars_dict = {
        "CSS": css,
        "JS": js,
        "TOTAL": str(total),
        "DONE_COUNT": str(done_count),
        "IN_PROGRESS_COUNT": str(in_progress_count),
        "AWAITING_COUNT": str(awaiting_count),
        "ROWS": "\n".join(rows),
        "GENERATED_AT": datetime.now().strftime("%Y-%m-%d %H:%M"),
    }
    result = tmpl
    for k, v in vars_dict.items():
        result = result.replace(f"{{{{{k}}}}}", v)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(result, encoding="utf-8")


# ---- Path mapping ----

def map_source_to_html(source_path: str, output_dir: str) -> str:
    """源路径到 HTML 输出路径的镜像策略。"""
    src = Path(source_path)
    out = Path(output_dir)

    # Strip leading .ai-flow/ if present
    parts = src.parts
    if parts[0] == ".ai-flow" and len(parts) > 1:
        sub_parts = parts[1:]  # e.g. ("plans", "20260519-demo.md")
    else:
        # repo-root file
        sub_parts = parts

    # Replace .md with .html
    name = sub_parts[-1]
    if name.endswith(".md"):
        name = name[:-3] + ".html"
    sub_parts = sub_parts[:-1] + (name,)

    return str(out / Path(*sub_parts))


# ---- Git exclude ----

def ensure_git_exclude(project_dir: Path) -> None:
    """best-effort 追加 .ai-flow/html/ 到 .git/info/exclude，幂等。"""
    exclude_file = project_dir / ".git" / "info" / "exclude"
    line = ".ai-flow/html/"
    if exclude_file.is_file():
        content = exclude_file.read_text(encoding="utf-8")
        if line in content:
            return
    exclude_file.parent.mkdir(parents=True, exist_ok=True)
    with exclude_file.open("a", encoding="utf-8") as f:
        f.write(f"\n{line}\n")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="AI Flow HTML 渲染")
    sub = parser.add_subparsers(dest="cmd")

    p_plan = sub.add_parser("plan")
    p_plan.add_argument("--input", required=True)
    p_plan.add_argument("--output", required=True)

    p_review = sub.add_parser("review")
    p_review.add_argument("--input", required=True)
    p_review.add_argument("--output", required=True)

    p_status = sub.add_parser("status")
    p_status.add_argument("--project-dir", default=".")
    p_status.add_argument("--output", required=True)

    args = parser.parse_args()
    if args.cmd == "plan":
        render_plan(Path(args.input), Path(args.output))
    elif args.cmd == "review":
        render_review(Path(args.input), Path(args.output))
    elif args.cmd == "status":
        render_status(Path(args.project_dir), Path(args.output))
    else:
        parser.print_help()
