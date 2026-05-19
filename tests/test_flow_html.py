"""flow_html.py 单元测试。"""

import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "runtime", "lib"))

from flow_html import MarkdownParser, map_source_to_html, ensure_git_exclude


# --- MarkdownParser ---

def _parse(text):
    p = MarkdownParser()
    return p.parse(text)


def test_parse_h1():
    blocks = _parse("# Hello World")
    assert len(blocks) == 1
    assert blocks[0].kind == "h1"
    assert blocks[0].content == "Hello World"


def test_parse_h2():
    blocks = _parse("## Section Title")
    assert len(blocks) == 1
    assert blocks[0].kind == "h2"


def test_parse_h3():
    blocks = _parse("### Sub Section")
    assert len(blocks) == 1
    assert blocks[0].kind == "h3"


def test_parse_para():
    blocks = _parse("This is a paragraph.\nWith continuation.")
    assert len(blocks) == 1
    assert blocks[0].kind == "para"
    assert "This is a paragraph" in blocks[0].content


def test_parse_table():
    blocks = _parse("| Header1 | Header2 |\n| --- | --- |\n| a | b |")
    assert any(b.kind == "table" for b in blocks)
    table_block = [b for b in blocks if b.kind == "table"][0]
    assert len(table_block.cells) == 2  # header + 1 data row


def test_parse_checklist():
    blocks = _parse("- [x] Done task\n- [ ] Pending task")
    checked_blocks = [b for b in blocks if b.kind == "checklist"]
    assert len(checked_blocks) == 2
    assert checked_blocks[0].checked is True
    assert checked_blocks[1].checked is False


def test_parse_code_block():
    blocks = _parse("```python\nprint('hello')\n```")
    code_blocks = [b for b in blocks if b.kind == "code"]
    assert len(code_blocks) == 1
    # 代码块内容被 HTML 转义
    assert "print" in code_blocks[0].content
    assert "hello" in code_blocks[0].content


def test_parse_blockquote_meta():
    blocks = _parse("> 创建日期：2026-05-19")
    bq = [b for b in blocks if b.kind == "blockquote"]
    assert len(bq) == 1
    assert bq[0].meta_key == "创建日期"
    assert bq[0].meta_value == "2026-05-19"


def test_parse_unknown_fallback_prose():
    # 未知结构应 fallback 为 prose
    blocks = _parse("some random text that is not a heading or table")
    assert any(b.kind == "para" for b in blocks)


# --- map_source_to_html ---

def test_path_mapping_plans():
    result = map_source_to_html(".ai-flow/plans/20260519-demo.md", ".ai-flow/html")
    assert result == ".ai-flow/html/plans/20260519-demo.html"


def test_path_mapping_reports():
    result = map_source_to_html(".ai-flow/reports/20260519-review.md", ".ai-flow/html")
    assert result == ".ai-flow/html/reports/20260519-review.html"


def test_path_mapping_repo_root():
    result = map_source_to_html("README.md", ".ai-flow/html")
    assert result == ".ai-flow/html/README.html"


def test_path_mapping_nested():
    result = map_source_to_html("reports/standalone/xxx.md", ".ai-flow/html")
    assert result == ".ai-flow/html/reports/standalone/xxx.html"


# --- ensure_git_exclude ---

def test_git_exclude_idempotent():
    with tempfile.TemporaryDirectory() as tmp:
        project_dir = Path(tmp)
        git_info = project_dir / ".git" / "info"
        git_info.mkdir(parents=True)
        exclude_file = git_info / "exclude"
        exclude_file.write_text("# existing comment\n")

        ensure_git_exclude(project_dir)
        content1 = exclude_file.read_text()
        assert ".ai-flow/html/" in content1

        ensure_git_exclude(project_dir)
        content2 = exclude_file.read_text()
        # Only one occurrence
        assert content2.count(".ai-flow/html/") == 1
