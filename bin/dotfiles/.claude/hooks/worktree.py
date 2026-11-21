#!/usr/bin/env python3
"""Unified Claude Code worktree lifecycle hook.

Dispatches WorktreeCreate and WorktreeRemove events from Claude Code.
- WorktreeCreate: Creates an isolated task worktree under
  ~/worktrees/<main-checkout-name>/<task-name> with a unique dedicated branch
  (claude/<slug>-<random suffix>) branching from the repository's base commit.
- WorktreeRemove: Verifies strict cleanliness (rejecting modified/untracked/ignored
  files and assume-unchanged / skip-worktree index flags), ensures creation record
  matches, and safely removes the worktree with non-force git worktree remove,
  preserving user data and the task branch.
"""

import json
import os
import re
import secrets
import subprocess
import sys
from typing import Any, Dict, List, Optional

RECORD_FILENAME = "claude-creation-record.json"


def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


def git(cwd: Optional[str], *args: str, check: bool = True) -> bytes:
    cmd = ["git"] + (["-C", cwd] if cwd else []) + list(args)
    res = subprocess.run(cmd, capture_output=True)
    if check and res.returncode != 0:
        err = res.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(err or f"git command failed: exit {res.returncode}")
    return res.stdout if res.returncode == 0 else b""


def parse_worktrees(cwd: str) -> List[Dict[str, str]]:
    raw = git(cwd, "worktree", "list", "--porcelain", "-z")
    records = []
    for block in raw.split(b"\0\0"):
        if not block:
            continue
        entry: Dict[str, str] = {}
        for item in block.split(b"\0"):
            if not item:
                continue
            k, sep, v = os.fsdecode(item).partition(" ")
            entry[k] = v if sep else "true"
        if entry:
            records.append(entry)
    return records


def resolve_base(main_dir: str) -> str:
    origin_head = git(main_dir, "rev-parse", "--verify", "-q", "refs/remotes/origin/HEAD^{commit}", check=False).decode().strip()
    if origin_head:
        return origin_head
    candidates = []
    for ref in ("refs/heads/main^{commit}", "refs/heads/master^{commit}"):
        sha = git(main_dir, "rev-parse", "--verify", "-q", ref, check=False).decode().strip()
        if sha:
            candidates.append(sha)
    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        raise RuntimeError("Ambiguous base: both refs/heads/main and refs/heads/master exist")
    raise RuntimeError("Cannot resolve base: neither refs/remotes/origin/HEAD nor unique main/master found")


def create_worktree(payload: Dict[str, Any]) -> None:
    name = payload.get("name")
    if not isinstance(name, str) or not name or name.strip() != name:
        raise ValueError(f"Task name must be a non-empty trimmed string: {name!r}")
    if any(c in name for c in "/\\\0") or name in (".", "..") or name.startswith("."):
        raise ValueError(f"Task name contains forbidden path characters: {name!r}")
    if re.fullmatch(r"pr-\d+", name):
        raise ValueError(f"Task name matches forbidden PR shape 'pr-<digits>': {name!r}")
    git(None, "check-ref-format", "--branch", name)

    cwd = payload.get("cwd") or os.getcwd()
    if not os.path.isdir(cwd):
        raise ValueError(f"Invocation cwd is not a valid directory: {cwd}")

    records = parse_worktrees(cwd)
    if not records or "bare" in records[0] or "worktree" not in records[0]:
        raise RuntimeError(f"Unable to resolve main checkout from {cwd} (bare repository or invalid gitdir)")
    main_dir = os.path.realpath(records[0]["worktree"])
    main_name = os.path.basename(main_dir.rstrip(os.sep))
    if not main_name:
        raise RuntimeError(f"Unable to derive checkout name from {main_dir}")

    base_sha = resolve_base(main_dir)

    slug = re.sub(r"[^a-zA-Z0-9._-]+", "-", name).strip("-") or "task"
    while True:
        branch = f"claude/{slug}-{secrets.token_hex(4)}"
        if not git(main_dir, "rev-parse", "--verify", "-q", f"refs/heads/{branch}", check=False):
            break

    wt_root = os.path.expanduser("~/worktrees")
    if os.path.islink(wt_root):
        raise ValueError(f"Worktrees root is a symlink: {wt_root}")
    os.makedirs(wt_root, exist_ok=True)
    if os.path.islink(wt_root) or not os.path.isdir(wt_root):
        raise ValueError(f"Worktrees root is not a regular directory: {wt_root}")

    parent = os.path.join(wt_root, main_name)
    if os.path.islink(parent):
        raise ValueError(f"Repository worktree parent is a symlink: {parent}")
    os.makedirs(parent, exist_ok=True)
    if os.path.islink(parent) or not os.path.isdir(parent):
        raise ValueError(f"Repository worktree parent is not a regular directory: {parent}")

    target = os.path.join(parent, name)
    if os.path.islink(target) or os.path.lexists(target):
        raise ValueError(f"Target path already exists: {target}")

    os.mkdir(target)

    try:
        git(main_dir, "worktree", "add", target, "-b", branch, base_sha)
    except Exception:
        try:
            os.rmdir(target)
        except OSError:
            pass
        raise

    canonical_target = os.path.realpath(target)
    wt_gitdir = git(canonical_target, "rev-parse", "--path-format=absolute", "--git-dir").decode().strip()
    rec = {
        "path": canonical_target,
        "branch": f"refs/heads/{branch}",
        "start_sha": base_sha,
    }
    tmp_rec = os.path.join(wt_gitdir, f"{RECORD_FILENAME}.tmp.{os.getpid()}")
    with open(tmp_rec, "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_rec, os.path.join(wt_gitdir, RECORD_FILENAME))

    eprint(f"Created worktree at {canonical_target} (branch {branch} from {base_sha[:8]})")
    print(canonical_target)


def remove_worktree(payload: Dict[str, Any]) -> None:
    req_path = payload.get("worktree_path")
    if not isinstance(req_path, str) or not req_path:
        raise ValueError("WorktreeRemove payload missing valid 'worktree_path'")
    if not os.path.isabs(req_path) or os.path.islink(req_path):
        raise ValueError(f"Requested worktree path is not an absolute canonical path: {req_path!r}")

    canonical_target = os.path.realpath(req_path)
    if req_path != canonical_target:
        raise ValueError(f"Requested raw path does not match canonical path: {req_path!r}")
    if not os.path.isdir(canonical_target):
        raise ValueError(f"Target is not a directory: {canonical_target}")

    records = parse_worktrees(canonical_target)
    if not records or "bare" in records[0] or "worktree" not in records[0]:
        raise RuntimeError("Invalid git worktree list or bare repository")

    main_dir = os.path.realpath(records[0]["worktree"])
    main_name = os.path.basename(main_dir.rstrip(os.sep))

    expected_root = os.path.realpath(os.path.expanduser("~/worktrees"))
    expected_parent = os.path.join(expected_root, main_name)
    if os.path.dirname(canonical_target) != expected_parent:
        raise ValueError(f"Worktree '{canonical_target}' is not under expected directory '{expected_parent}'")

    matching = next((r for r in records[1:] if r.get("worktree") == canonical_target), None)
    if not matching:
        raise RuntimeError(f"Worktree '{canonical_target}' is not a registered linked git worktree")
    if "locked" in matching:
        raise RuntimeError(f"Worktree is locked: {matching.get('locked') or matching.get('lock_reason')}")

    wt_gitdir = git(canonical_target, "rev-parse", "--path-format=absolute", "--git-dir").decode().strip()
    if os.path.basename(os.path.dirname(wt_gitdir)) != "worktrees":
        raise RuntimeError(f"Worktree admin directory '{wt_gitdir}' is not a linked worktree admin dir")
    if os.path.exists(os.path.join(wt_gitdir, "locked")):
        raise RuntimeError("Worktree is locked by admin lock file")

    rec_file = os.path.join(wt_gitdir, RECORD_FILENAME)
    if not os.path.isfile(rec_file):
        raise RuntimeError(
            f"Missing creation record in '{wt_gitdir}'. Clean manually created worktrees are protected from removal."
        )

    try:
        with open(rec_file, "r", encoding="utf-8") as f:
            rec = json.load(f)
        for field in ("path", "branch", "start_sha"):
            if not rec.get(field):
                raise ValueError(f"Missing field '{field}'")
    except Exception as exc:
        raise RuntimeError(f"Malformed creation record: {exc}")

    if rec["path"] != canonical_target:
        raise RuntimeError(
            f"Creation record path '{rec['path']}' does not match canonical path '{canonical_target}' (alias or moved checkout)"
        )

    expected_branch = rec["branch"]
    if matching.get("branch") != expected_branch:
        raise RuntimeError(f"Branch mismatch: registered '{matching.get('branch')}' != stored '{expected_branch}'")
    if matching.get("HEAD") != rec["start_sha"]:
        raise RuntimeError(f"Commit mismatch: registered HEAD '{matching.get('HEAD')}' != start SHA '{rec['start_sha']}'")

    cwd = payload.get("cwd")
    if cwd and os.path.isdir(cwd):
        cwd_common = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir", check=False).decode().strip()
        if cwd_common:
            wt_common = git(canonical_target, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip()
            if os.path.realpath(cwd_common) != os.path.realpath(wt_common):
                raise RuntimeError("Worktree belongs to a different repository than invocation cwd (foreign worktree)")

    ls_out = git(canonical_target, "ls-files", "-v", "-z")
    for token in ls_out.split(b"\0"):
        if token and (token[:1].islower() or token.startswith(b"S ")):
            flagged = os.fsdecode(token[2:])
            raise RuntimeError(f"Unverifiable tracked state (assume-unchanged or skip-worktree on '{flagged}')")

    status_out = git(canonical_target, "status", "--porcelain", "-uall", "--ignored", "--ignore-submodules=none", "-z")
    if status_out:
        raise RuntimeError("Worktree is dirty (staged, modified, untracked, or ignored content present)")

    sym_head = git(canonical_target, "symbolic-ref", "-q", "HEAD", check=False).decode().strip()
    if not sym_head:
        raise RuntimeError("HEAD is detached")
    if sym_head != expected_branch:
        raise RuntimeError(f"Branch switched: HEAD points to '{sym_head}', expected '{expected_branch}'")

    curr_sha = git(canonical_target, "rev-parse", "HEAD").decode().strip()
    if curr_sha != rec["start_sha"]:
        raise RuntimeError(f"HEAD commit '{curr_sha}' differs from start SHA '{rec['start_sha']}' (added commits)")

    git(main_dir, "worktree", "remove", matching["worktree"])
    eprint(f"Successfully removed worktree at {canonical_target} (branch '{expected_branch}' preserved)")


def main() -> None:
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            raise ValueError("Empty hook payload on stdin")
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("Hook payload must be a JSON object")
        event = payload.get("hook_event_name")
        if event == "WorktreeCreate":
            create_worktree(payload)
        elif event == "WorktreeRemove":
            remove_worktree(payload)
        else:
            raise ValueError(f"Unsupported or missing hook_event_name: {event!r}")
    except (ValueError, RuntimeError, OSError) as exc:
        eprint(f"Error: {exc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
