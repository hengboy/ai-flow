#!/bin/bash
# flow-workspace.sh — workspace manifest discovery and validation
# Subcommands: detect-root, validate-manifest, list-repos, repo-git-root

set -euo pipefail

python3 - "$@" <<'PY'
import argparse
import json
import os
import re
import sys
from pathlib import Path


WORKSPACE_FILE_NAME = "workspace.json"
AI_FLOW_DIR_NAME = ".ai-flow"
SLUG_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class WorkspaceError(Exception):
    pass


def find_nearest_workspace_file(start: Path) -> Path | None:
    """Walk upward from start looking for .ai-flow/workspace.json."""
    current = start.resolve()
    while True:
        candidate = current / AI_FLOW_DIR_NAME / WORKSPACE_FILE_NAME
        if candidate.is_file():
            return candidate
        parent = current.parent
        if parent == current:
            return None
        current = parent


def load_workspace_manifest(workspace_file: Path) -> dict:
    """Load and return the workspace manifest JSON."""
    if not workspace_file.is_file():
        raise WorkspaceError(f"workspace manifest not found: {workspace_file}")
    try:
        with workspace_file.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as exc:
        raise WorkspaceError(f"workspace manifest JSON 损坏: {workspace_file}") from exc
    return data


def validate_manifest(manifest: dict, workspace_file: Path) -> list[dict]:
    """Validate manifest structure and return normalized repo list.

    Returns list of dicts with keys: id, path, git_root.
    """
    ws_root = workspace_file.parent.parent  # parent of .ai-flow

    if not isinstance(manifest, dict):
        raise WorkspaceError("workspace manifest 根节点必须是 JSON 对象")
    if manifest.get("schema_version") != 1:
        raise WorkspaceError("workspace manifest schema_version 必须是 1")

    name = manifest.get("name")
    if not isinstance(name, str) or not name.strip():
        raise WorkspaceError("workspace manifest name 不能为空")

    repos = manifest.get("repos")
    if not isinstance(repos, list) or not repos:
        raise WorkspaceError("workspace manifest repos 必须是非空数组")

    seen_ids: set[str] = set()
    validated: list[dict] = []
    for idx, repo in enumerate(repos):
        if not isinstance(repo, dict):
            raise WorkspaceError(f"repos[{idx}] 必须是对象")

        repo_id = repo.get("id")
        if not isinstance(repo_id, str):
            raise WorkspaceError(f"repos[{idx}].id 必须是字符串")
        if not SLUG_ID_RE.match(repo_id):
            raise WorkspaceError(f"repos[{idx}].id 必须是 lowercase kebab-case: {repo_id!r}")
        if repo_id in seen_ids:
            raise WorkspaceError(f"repos[{idx}].id 重复: {repo_id!r}")
        seen_ids.add(repo_id)

        repo_path = repo.get("path")
        if not isinstance(repo_path, str) or not repo_path.strip():
            raise WorkspaceError(f"repos[{idx}].path 不能为空")

        # Normalize: workspace-root-relative
        abs_path = (ws_root / repo_path).resolve()
        rel_from_ws = abs_path.relative_to(ws_root).as_posix()

        # Verify it's a valid git repo
        import subprocess
        try:
            result = subprocess.run(
                ["git", "-C", str(abs_path), "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode != 0:
                raise WorkspaceError(
                    f"repos[{idx}].path={rel_from_ws!r} 不是有效的 Git 仓库: {result.stderr.strip()}"
                )
            git_root = result.stdout.strip()
        except FileNotFoundError:
            raise WorkspaceError("git 命令不可用，无法验证 workspace repos")

        validated.append({
            "id": repo_id,
            "path": rel_from_ws,
            "git_root": Path(git_root).relative_to(ws_root).as_posix(),
        })

    return validated


def cmd_detect_root(args):
    """Print the nearest workspace root directory."""
    start = Path.cwd().resolve()
    ws_file = find_nearest_workspace_file(start)
    if ws_file is None:
        print("no-workspace", file=sys.stderr)
        sys.exit(1)
    ws_root = ws_file.parent.parent
    print(ws_root)


def cmd_validate_manifest(args):
    """Validate a workspace manifest and print normalized repo list."""
    if args.workspace_file:
        ws_file = Path(args.workspace_file).resolve()
    else:
        ws_file = find_nearest_workspace_file(Path.cwd().resolve())
        if ws_file is None:
            print("错误: 找不到 .ai-flow/workspace.json", file=sys.stderr)
            sys.exit(1)

    manifest = load_workspace_manifest(ws_file)
    repos = validate_manifest(manifest, ws_file)
    print(json.dumps({"workspace_root": ws_file.parent.parent.as_posix(), "repos": repos}, ensure_ascii=False, indent=2))


def cmd_list_repos(args):
    """Print repo ids from workspace manifest, one per line."""
    if args.workspace_file:
        ws_file = Path(args.workspace_file).resolve()
    else:
        ws_file = find_nearest_workspace_file(Path.cwd().resolve())
        if ws_file is None:
            print("no-workspace", file=sys.stderr)
            sys.exit(1)

    manifest = load_workspace_manifest(ws_file)
    repos = validate_manifest(manifest, ws_file)
    for repo in repos:
        print(repo["id"])


def cmd_repo_git_root(args):
    """Print the git root path for a specific repo id."""
    if args.workspace_file:
        ws_file = Path(args.workspace_file).resolve()
    else:
        ws_file = find_nearest_workspace_file(Path.cwd().resolve())
        if ws_file is None:
            print("no-workspace", file=sys.stderr)
            sys.exit(1)

    manifest = load_workspace_manifest(ws_file)
    repos = validate_manifest(manifest, ws_file)
    ws_root = ws_file.parent.parent

    target = args.repo_id
    for repo in repos:
        if repo["id"] == target:
            print(repo["git_root"])
            return

    print(f"错误: 找不到 repo '{target}'", file=sys.stderr)
    sys.exit(1)


def build_parser():
    parser = argparse.ArgumentParser(prog="flow-workspace.sh")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("detect-root").set_defaults(func=cmd_detect_root)

    validate = subparsers.add_parser("validate-manifest")
    validate.add_argument("--workspace-file")
    validate.set_defaults(func=cmd_validate_manifest)

    list_r = subparsers.add_parser("list-repos")
    list_r.add_argument("--workspace-file")
    list_r.set_defaults(func=cmd_list_repos)

    repo_root = subparsers.add_parser("repo-git-root")
    repo_root.add_argument("--workspace-file")
    repo_root.add_argument("repo_id")
    repo_root.set_defaults(func=cmd_repo_git_root)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except WorkspaceError as exc:
        print(f"错误: {exc}", file=sys.stderr)
        sys.exit(1)
PY
