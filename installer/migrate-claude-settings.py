#!/usr/bin/env python3
"""One-time safe migration utility for Claude Code settings.

Merges WorktreeCreate and WorktreeRemove hook definitions from the tracked
dotfiles template into an existing ~/.claude/settings.json copy-once file.
"""

import argparse
from datetime import datetime, timezone
import difflib
import json
import os
import stat
import sys
import tempfile
from typing import Any, Tuple


def show_diff(existing_val: Any, template_val: Any) -> None:
    s_exist = (json.dumps(existing_val, indent=2) + "\n").splitlines(keepends=True)
    s_tmpl = (json.dumps(template_val, indent=2) + "\n").splitlines(keepends=True)
    diff = list(difflib.unified_diff(s_exist, s_tmpl, fromfile="existing", tofile="template"))
    if diff:
        sys.stderr.write("".join(diff))


def write_sibling(dir_path: str, prefix: str, suffix: str, data: bytes, mode: int) -> Tuple[int, str]:
    fd, path = tempfile.mkstemp(dir=dir_path, prefix=prefix, suffix=suffix)
    try:
        os.fchmod(fd, stat.S_IMODE(mode))
        with open(fd, "wb", closefd=False) as f:
            f.write(data)
            f.flush()
            os.fsync(fd)
    except Exception:
        os.close(fd)
        if os.path.exists(path):
            os.unlink(path)
        raise
    return fd, path


def migrate(settings_path: str, template_path: str, dry_run: bool = False) -> int:
    if not os.path.isfile(template_path):
        raise RuntimeError(f"Tracked template file not found: {template_path}")
    with open(template_path, "r", encoding="utf-8") as f:
        tmpl_data = json.load(f)

    tmpl_hooks = tmpl_data.get("hooks", {})
    tmpl_create = tmpl_hooks.get("WorktreeCreate")
    tmpl_remove = tmpl_hooks.get("WorktreeRemove")
    if tmpl_create is None or tmpl_remove is None:
        raise RuntimeError(f"Tracked template ({template_path}) is missing worktree hooks")

    target = os.path.abspath(os.path.expanduser(settings_path))
    if os.path.islink(target):
        raise ValueError(f"Target settings file '{target}' is a symlink (symlink replacement prohibited)")
    if not os.path.isfile(target):
        raise ValueError(f"Target settings file does not exist or is not regular: {target}")

    orig_stat = os.stat(target)
    with open(target, "rb") as f:
        orig_bytes = f.read()

    data = json.loads(orig_bytes.decode("utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"Settings root is not a JSON object: {target}")

    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(f"Settings 'hooks' is not a JSON object: {target}")

    has_create = "WorktreeCreate" in hooks
    has_remove = "WorktreeRemove" in hooks
    if has_create or has_remove:
        conflict = False
        for name, tmpl_val in (("WorktreeCreate", tmpl_create), ("WorktreeRemove", tmpl_remove)):
            if name in hooks:
                if hooks[name] == tmpl_val:
                    print(f"Notice: '{name}' hook already exists and matches template value.")
                else:
                    conflict = True
                    sys.stderr.write(f"Conflict: '{name}' hook already exists with differing configuration:\n")
                    show_diff(hooks[name], tmpl_val)
        print("No changes made to target settings file.")
        return 1 if conflict else 0

    hooks["WorktreeCreate"] = tmpl_create
    hooks["WorktreeRemove"] = tmpl_remove

    if dry_run:
        print(f"Dry run: WorktreeCreate and WorktreeRemove would be merged into {target}.")
        return 0

    target_dir = os.path.dirname(target)
    new_bytes = (json.dumps(data, indent=2) + "\n").encode("utf-8")

    fd_stage, stage_path = write_sibling(target_dir, ".settings.json.tmp.", "", new_bytes, orig_stat.st_mode)
    os.close(fd_stage)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    backup_path = None
    try:
        fd_bak, backup_path = write_sibling(
            target_dir, f"settings.json.pre-worktrees.{timestamp}.", ".bak", orig_bytes, orig_stat.st_mode
        )
        os.close(fd_bak)
    except Exception:
        if os.path.exists(stage_path):
            os.unlink(stage_path)
        raise

    try:
        if os.path.islink(target):
            raise RuntimeError(f"Target settings file became a symlink: {target}")
        cur = os.stat(target)
        if (
            cur.st_ino != orig_stat.st_ino
            or cur.st_dev != orig_stat.st_dev
            or cur.st_size != orig_stat.st_size
            or cur.st_mtime_ns != orig_stat.st_mtime_ns
        ):
            raise RuntimeError(f"Target settings file was modified during staging: {target}")
        with open(target, "rb") as f:
            if f.read() != orig_bytes:
                raise RuntimeError(f"Target settings content changed during staging: {target}")
        os.replace(stage_path, target)
    except Exception:
        if os.path.exists(stage_path):
            os.unlink(stage_path)
        raise

    print(f"Successfully migrated Claude settings: {target}")
    print(f"Original settings backed up to: {backup_path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Migrate Claude Code settings to include worktree hooks.")
    parser.add_argument(
        "--settings-file",
        "-s",
        default=os.path.expanduser("~/.claude/settings.json"),
        help="Path to Claude settings file (default: ~/.claude/settings.json)",
    )
    parser.add_argument(
        "--template-file",
        "-t",
        default=None,
        help="Path to tracked dotfiles template settings.json",
    )
    parser.add_argument(
        "--dry-run",
        "-n",
        action="store_true",
        help="Inspect migration without writing changes or creating backup",
    )
    args = parser.parse_args()

    template = args.template_file
    if not template:
        repo_root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
        template = os.path.join(repo_root, "bin", "dotfiles", ".claude", "settings.json")

    try:
        return migrate(args.settings_file, template, dry_run=args.dry_run)
    except (ValueError, RuntimeError, OSError) as exc:
        sys.stderr.write(f"Error: {exc}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
