#!/usr/bin/env python3
"""Task Sandbox Lifecycle Management Tool.

Provides explicit, repeatable create, status, start, and preserve subcommands
for managing isolated task Sandboxes. State is tracked via JSON task records
stored at caller-provided paths outside the repository.
"""

from __future__ import annotations

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import Any

DEFAULT_CPUS = 2
DEFAULT_MEMORY = "4g"
DEFAULT_TIMEOUT = 60
LONG_TIMEOUT = 300

NAME_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9.-]{1,63}$")
TASK_ID_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")
GIT_HASH_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
FORBIDDEN_BRANCHES = {"master", "main", "refs/heads/master", "refs/heads/main"}
VALID_LIFECYCLES = {"provisioning", "ready", "running", "preserved", "failed", "retired"}


def validate_sandbox_name(name: str) -> str:
    """Validate sandbox name against length, character, and format constraints."""
    if (
        not name
        or not NAME_PATTERN.match(name)
        or name.startswith("-")
        or name.startswith(".")
        or name.endswith("-")
        or name.endswith(".")
        or "_" in name
    ):
        raise ValueError(
            f"Invalid sandbox name '{name}'. Must be 2-64 characters matching "
            "[a-zA-Z0-9][a-zA-Z0-9.-]* (no underscores, cannot start or end with '-' or '.')"
        )
    return name


def validate_task_id(task_id: str) -> str:
    """Validate explicit task ID format."""
    if not task_id or not TASK_ID_PATTERN.match(task_id):
        raise ValueError(
            f"Invalid task ID '{task_id}'. Must be 1-128 characters matching "
            "[a-zA-Z0-9][a-zA-Z0-9._-]* without path separators or shell characters."
        )
    return task_id


def validate_branch_name(branch: str, git_bin: str = "git") -> str:
    """Validate implementation branch name using git check-ref-format and rejecting master/main."""
    cleaned = branch.strip()
    if not cleaned:
        raise ValueError("Implementation branch name cannot be empty.")
    if cleaned.startswith("-"):
        raise ValueError(f"Branch name cannot start with a dash: '{cleaned}'")
    if any(ord(c) < 32 or ord(c) == 127 for c in cleaned):
        raise ValueError(f"Branch name contains control characters: '{cleaned}'")

    norm = cleaned.lower().removeprefix("refs/heads/")
    if norm in {"master", "main"}:
        raise ValueError(
            f"Implementation branch cannot be '{cleaned}'. master/main branches are forbidden."
        )

    res = subprocess.run(
        [git_bin, "check-ref-format", "--branch", cleaned],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        err = res.stderr.strip() or f"ref name format error: {cleaned}"
        raise ValueError(f"Invalid branch name '{cleaned}': {err}")

    return cleaned


def validate_host_repo(repo_path: Path) -> Path:
    """Validate normal host repository checkout (rejecting linked worktrees)."""
    resolved = repo_path.resolve()
    if not resolved.is_dir():
        raise ValueError(f"Host repository directory does not exist or is not a directory: {resolved}")
    git_entry = resolved / ".git"
    if not git_entry.exists():
        raise ValueError(f"Host repository at {resolved} is missing a .git directory.")
    if git_entry.is_file():
        raise ValueError(
            f"Host repository at {resolved} has a .git file (git worktree). "
            "sbx clone requires a normal .git directory, not a linked worktree source."
        )
    if not git_entry.is_dir():
        raise ValueError(f"Host repository at {resolved} has non-directory .git entry.")
    return resolved


def validate_record_path(record_path: Path, host_repo: Path | None = None) -> Path:
    """Validate that task record path is outside host repository."""
    resolved = record_path.resolve()
    if host_repo is not None:
        hr_resolved = host_repo.resolve()
        if resolved == hr_resolved or hr_resolved in resolved.parents:
            raise ValueError(
                f"Task record path {resolved} must be outside host repository {hr_resolved}."
            )
    return resolved


def validate_destination_path(dest_path: Path, host_repo: Path) -> Path:
    """Validate preservation destination path outside source repository."""
    resolved = dest_path.resolve()
    hr_resolved = host_repo.resolve()
    if resolved == hr_resolved or hr_resolved in resolved.parents:
        raise ValueError(
            f"Destination path {resolved} must be outside host repository {hr_resolved}."
        )
    return resolved


def validate_guest_harness_path(
    guest_harness_path: str,
    guest_repo: str,
    guest_stage: str | None = None,
) -> str:
    """Validate that guest harness path is absolute, canonical, task-scoped, and mutually disjoint from repo and staging."""
    if not guest_harness_path:
        raise ValueError("Guest harness path cannot be empty.")
    if not os.path.isabs(guest_harness_path):
        raise ValueError(f"Guest harness path must be an absolute path: '{guest_harness_path}'")

    norm = os.path.normpath(guest_harness_path)
    if guest_harness_path != "/" and guest_harness_path.rstrip("/") != norm:
        raise ValueError(f"Guest harness path is not canonical: '{guest_harness_path}'")

    parts = norm.split("/")
    if any(p == ".." for p in parts):
        raise ValueError(f"Guest harness path contains invalid traversal components: '{guest_harness_path}'")

    if norm in ("/home/agent/.local/state/agent-harness", "/home/agent/.local/state/agent-harness/"):
        raise ValueError(
            f"Guest harness path '{guest_harness_path}' cannot be the whole-harness root directory; "
            "an explicit task-scoped harness path is required."
        )

    repo_norm = os.path.normpath(guest_repo)
    if norm == repo_norm:
        raise ValueError(
            f"Guest harness path '{norm}' and guest repo '{repo_norm}' must be mutually disjoint."
        )
    try:
        common_repo = os.path.commonpath([norm, repo_norm])
    except ValueError:
        common_repo = None

    if common_repo in (norm, repo_norm):
        raise ValueError(
            f"Guest harness path '{norm}' and guest repo '{repo_norm}' must be mutually disjoint."
        )

    if guest_stage:
        stage_norm = os.path.normpath(guest_stage)
        if norm == stage_norm:
            raise ValueError(
                f"Guest harness path '{norm}' and guest staging '{stage_norm}' must be mutually disjoint."
            )
        try:
            common_stage = os.path.commonpath([norm, stage_norm])
        except ValueError:
            common_stage = None

        if common_stage in (norm, stage_norm):
            raise ValueError(
                f"Guest harness path '{norm}' and guest staging '{stage_norm}' must be mutually disjoint."
            )

    return norm


def check_real_guest_harness(
    sandbox_name: str,
    guest_harness: str,
    guest_repo: str,
    guest_stage: str | None = None,
    sbx_bin: str = "sbx",
) -> str:
    """Validate guest harness existence, directory status, and realpath disjointness in guest."""
    check_script = (
        "import os, sys, json\n"
        "harness_arg = sys.argv[1]\n"
        "repo_arg = sys.argv[2]\n"
        "stage_arg = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None\n"
        "if not os.path.exists(harness_arg):\n"
        "    print(json.dumps({'error': f'Guest harness path does not exist: {harness_arg}', 'type': 'not_found'}))\n"
        "    sys.exit(0)\n"
        "if not os.path.isdir(harness_arg):\n"
        "    print(json.dumps({'error': f'Guest harness path is not a directory: {harness_arg}', 'type': 'not_dir'}))\n"
        "    sys.exit(0)\n"
        "real_h = os.path.realpath(harness_arg)\n"
        "real_r = os.path.realpath(repo_arg)\n"
        "if real_h == real_r:\n"
        "    print(json.dumps({'error': f'Guest harness real path \\'{real_h}\\' and guest repo real path \\'{real_r}\\' overlap.', 'type': 'overlap'}))\n"
        "    sys.exit(0)\n"
        "try:\n"
        "    c_r = os.path.commonpath([real_h, real_r])\n"
        "except ValueError:\n"
        "    c_r = None\n"
        "if c_r in (real_h, real_r):\n"
        "    print(json.dumps({'error': f'Guest harness real path \\'{real_h}\\' and guest repo real path \\'{real_r}\\' must be mutually disjoint.', 'type': 'overlap'}))\n"
        "    sys.exit(0)\n"
        "if stage_arg:\n"
        "    real_s = os.path.realpath(stage_arg)\n"
        "    if real_h == real_s:\n"
        "        print(json.dumps({'error': f'Guest harness real path \\'{real_h}\\' and guest stage real path \\'{real_s}\\' overlap.', 'type': 'overlap'}))\n"
        "        sys.exit(0)\n"
        "    try:\n"
        "        c_s = os.path.commonpath([real_h, real_s])\n"
        "    except ValueError:\n"
        "        c_s = None\n"
        "    if c_s in (real_h, real_s):\n"
        "        print(json.dumps({'error': f'Guest harness real path \\'{real_h}\\' and guest stage real path \\'{real_s}\\' must be mutually disjoint.', 'type': 'overlap'}))\n"
        "        sys.exit(0)\n"
        "print(json.dumps({'ok': True, 'real_harness': real_h}))\n"
    )
    cmd = [
        sbx_bin,
        "exec",
        sandbox_name,
        "python3",
        "-c",
        check_script,
        guest_harness,
        guest_repo,
    ]
    if guest_stage:
        cmd.append(guest_stage)
    res = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if res.returncode != 0:
        raise RuntimeError(f"Failed to validate guest harness path in sandbox: {res.stderr}")
    try:
        out = json.loads(res.stdout.strip())
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse harness check response: {res.stdout}") from e
    if "error" in out:
        if out.get("type") in ("not_found", "not_dir"):
            raise RuntimeError(out["error"])
        raise ValueError(out["error"])
    return out["real_harness"]


def parse_ls_files_stage_z(raw_output: bytes | str) -> dict[str, dict[str, str]]:
    """Losslessly parse git ls-files -z --stage output splitting metadata from path at first TAB."""
    if isinstance(raw_output, str):
        raw_bytes = raw_output.encode("utf-8", errors="surrogateescape")
    else:
        raw_bytes = raw_output

    index_stage: dict[str, dict[str, str]] = {}
    for entry in raw_bytes.split(b"\0"):
        if not entry:
            continue
        if b"\t" not in entry:
            raise ValueError(f"Invalid ls-files --stage record (missing TAB): {entry!r}")
        meta, path_bytes = entry.split(b"\t", 1)
        meta_parts = meta.split(b" ")
        if len(meta_parts) != 3:
            raise ValueError(f"Invalid ls-files --stage metadata (expected 3 parts): {meta!r}")
        mode = meta_parts[0].decode("ascii")
        sha = meta_parts[1].decode("ascii")
        stage = meta_parts[2].decode("ascii")
        path_str = path_bytes.decode("utf-8", errors="surrogateescape")
        index_stage[path_str] = {"mode": mode, "sha": sha, "stage": stage}
    return index_stage


class TaskRecordLock:
    """Advisory flock on a task record companion lock file."""

    def __init__(self, record_path: Path):
        self.lock_path = record_path.parent / f"{record_path.name}.lock"
        self._fd: int | None = None

    def __enter__(self):
        self.lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        flags = os.O_CREAT | os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self._fd = os.open(self.lock_path, flags, 0o600)
        try:
            fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError) as e:
            os.close(self._fd)
            self._fd = None
            raise RuntimeError(
                f"Another task operation is currently in progress for record '{self.lock_path.name}'"
            ) from e
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            finally:
                os.close(self._fd)
                self._fd = None


def read_task_record(record_path: Path, require_sandbox_id: bool = False) -> dict[str, Any]:
    """Read and validate a task record JSON file with strict permissions and schema checks."""
    if not record_path.exists():
        raise FileNotFoundError(f"Task record file not found: {record_path}")
    if record_path.is_symlink():
        raise RuntimeError(f"Task record file {record_path} must not be a symlink")
    st = record_path.lstat()
    if not stat.S_ISREG(st.st_mode):
        raise RuntimeError(f"Task record file {record_path} must be a regular file")
    mode = st.st_mode & 0o777
    if mode not in (0o600, 0o400):
        raise RuntimeError(
            f"Task record file {record_path} has unsafe permissions ({oct(mode)}), expected 0600"
        )
    try:
        data = json.loads(record_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse task record JSON at {record_path}: {e}") from e

    if not isinstance(data, dict):
        raise ValueError(f"Task record at {record_path} must be a JSON object")

    schema_version = data.get("schema_version")
    if not isinstance(schema_version, int) or schema_version < 1:
        raise ValueError(f"Task record has invalid schema_version: {schema_version}")

    task_id = data.get("task_id")
    if not isinstance(task_id, str):
        raise ValueError("Task record task_id must be a string")
    validate_task_id(task_id)

    sandbox_name = data.get("sandbox_name")
    if not isinstance(sandbox_name, str):
        raise ValueError("Task record sandbox_name must be a string")
    validate_sandbox_name(sandbox_name)

    sandbox_id = data.get("sandbox_id")
    if require_sandbox_id:
        if not isinstance(sandbox_id, str) or not sandbox_id.strip():
            raise RuntimeError(f"Task record has missing or empty sandbox_id: {sandbox_id}")
    elif sandbox_id is not None and not isinstance(sandbox_id, str):
        raise ValueError("Task record sandbox_id must be a string or null")

    host_repo = data.get("host_repo")
    if not isinstance(host_repo, str):
        raise ValueError("Task record host_repo must be a string")
    validate_host_repo(Path(host_repo))

    base_commit = data.get("base_commit")
    if not isinstance(base_commit, str) or not GIT_HASH_PATTERN.match(base_commit):
        raise ValueError(f"Task record base_commit is not a valid 40-char SHA: {base_commit}")

    branch = data.get("branch")
    if not isinstance(branch, str):
        raise ValueError("Task record branch must be a string")
    validate_branch_name(branch)

    status = data.get("status")
    if not isinstance(status, str) or status not in VALID_LIFECYCLES:
        raise ValueError(f"Task record status '{status}' not in valid lifecycles: {VALID_LIFECYCLES}")

    guest_harness_path = data.get("guest_harness_path")
    if guest_harness_path is not None and not isinstance(guest_harness_path, str):
        raise ValueError("Task record guest_harness_path must be a string or null")

    host_worktree = data.get("host_worktree")
    if host_worktree is not None and not isinstance(host_worktree, str):
        raise ValueError("Task record host_worktree must be a string or null")

    retirement = data.get("retirement")
    if retirement is not None and not isinstance(retirement, dict):
        raise ValueError("Task record retirement must be a dict or null")

    return data


def write_task_record(record_path: Path, data: dict[str, Any], create_new: bool = False) -> None:
    """Atomically write task record JSON with 0600 permissions."""
    record_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if create_new and record_path.exists():
        raise FileExistsError(f"Task record file already exists at {record_path}")

    with tempfile.NamedTemporaryFile(
        "w",
        dir=record_path.parent,
        encoding="utf-8",
        delete=False,
        prefix=f".{record_path.name}.tmp",
    ) as tf:
        json.dump(data, tf, indent=2)
        tf.write("\n")
        tf.flush()
        os.fsync(tf.fileno())
        tmp_name = tf.name

    try:
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, record_path)
    finally:
        if os.path.exists(tmp_name):
            try:
                os.unlink(tmp_name)
            except OSError:
                pass


def resolve_base_commit(
    base_ref: str,
    host_repo: Path,
    bundle_path: Path | None = None,
    git_bin: str = "git",
) -> str:
    """Resolve base ref/SHA to exact 40-character commit in host repo or dependency bundle."""
    ref_clean = base_ref.strip()

    if bundle_path is not None and bundle_path.is_file():
        with tempfile.TemporaryDirectory() as tmp_bare:
            bare_repo = Path(tmp_bare)
            subprocess.run([git_bin, "init", "--bare", str(bare_repo)], check=True, capture_output=True)

            res_fetch = subprocess.run(
                [
                    git_bin,
                    "-C",
                    str(bare_repo),
                    "fetch",
                    str(bundle_path),
                    "HEAD:refs/bundle/HEAD",
                    "+refs/*:refs/bundle/*",
                ],
                capture_output=True,
                text=True,
            )
            if res_fetch.returncode != 0:
                raise ValueError(f"Failed to fetch refs from bundle {bundle_path}: {res_fetch.stderr}")

            if GIT_HASH_PATTERN.match(ref_clean):
                res_cat = subprocess.run(
                    [git_bin, "-C", str(bare_repo), "cat-file", "-e", f"{ref_clean}^{{commit}}"],
                    capture_output=True,
                )
                if res_cat.returncode == 0:
                    return ref_clean.lower()
                raise ValueError(f"Base commit SHA '{ref_clean}' does not exist in bundle {bundle_path}")

            candidates = [
                f"refs/bundle/{ref_clean}",
                f"refs/bundle/heads/{ref_clean}",
                f"refs/bundle/tags/{ref_clean}",
            ]
            if ref_clean == "HEAD":
                candidates = ["refs/bundle/HEAD"]

            matched_shas: set[str] = set()
            for cand in candidates:
                res_cand = subprocess.run(
                    [git_bin, "-C", str(bare_repo), "rev-parse", "--verify", "--quiet", f"{cand}^{{commit}}"],
                    capture_output=True,
                    text=True,
                )
                if res_cand.returncode == 0 and res_cand.stdout.strip():
                    matched_shas.add(res_cand.stdout.strip().lower())

            if len(matched_shas) == 1:
                return next(iter(matched_shas))
            elif len(matched_shas) > 1:
                raise ValueError(f"Ambiguous ref '{ref_clean}' in bundle {bundle_path}: matches multiple commits")

            raise ValueError(f"Could not resolve base ref '{ref_clean}' in bundle {bundle_path}")

    if GIT_HASH_PATTERN.match(ref_clean):
        res = subprocess.run(
            [git_bin, "-C", str(host_repo), "cat-file", "-e", f"{ref_clean}^{{commit}}"],
            capture_output=True,
            timeout=DEFAULT_TIMEOUT,
        )
        if res.returncode == 0:
            return ref_clean.lower()
        raise ValueError(f"Base commit SHA '{ref_clean}' does not exist in host repository {host_repo}")

    res = subprocess.run(
        [git_bin, "-C", str(host_repo), "rev-parse", "--verify", f"{ref_clean}^{{commit}}"],
        capture_output=True,
        text=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if res.returncode == 0:
        sha = res.stdout.strip().lower()
        if GIT_HASH_PATTERN.match(sha):
            return sha

    raise ValueError(f"Could not resolve base ref '{ref_clean}' to an exact commit in host repo {host_repo}")


def get_sandbox_info(name: str, sbx_bin: str = "sbx") -> dict[str, Any] | None:
    """Query sandbox metadata via read-only 'sbx ls --json'."""
    try:
        res = subprocess.run(
            [sbx_bin, "ls", "--json"],
            capture_output=True,
            text=True,
            check=True,
            timeout=DEFAULT_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Command '{sbx_bin} ls --json' timed out after {DEFAULT_TIMEOUT}s.")
    try:
        data = json.loads(res.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse '{sbx_bin} ls --json' output: {e}") from e

    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict) and item.get("name") == name:
                return item
    return None


GUEST_SNAPSHOT_SCRIPT = """
import os, sys, json, stat, hashlib, subprocess

repo_path = sys.argv[1]
harness_path = sys.argv[2]

unmerged = subprocess.check_output(["git", "-C", repo_path, "ls-files", "-u"], text=True).strip()
if unmerged:
    raise ValueError(f"Repository has unmerged index entries (merge conflicts in progress):\\n{unmerged}")

head_sha = subprocess.check_output(["git", "-C", repo_path, "rev-parse", "HEAD"], text=True).strip()
try:
    head_ref = subprocess.check_output(["git", "-C", repo_path, "rev-parse", "--symbolic-full-name", "HEAD"], text=True).strip()
except Exception:
    head_ref = "HEAD"

refs_raw = subprocess.check_output(["git", "-C", repo_path, "for-each-ref", "--format=%(objectname) %(refname)"], text=True)
refs = {}
for line in refs_raw.splitlines():
    if line.strip():
        sha, rname = line.strip().split(maxsplit=1)
        refs[rname] = sha

index_stage_raw = subprocess.check_output(["git", "-C", repo_path, "ls-files", "-z", "--stage"])
index_stage = {}
for entry in index_stage_raw.split(bytes([0])):
    if not entry:
        continue
    meta, path_bytes = entry.split(bytes([9]), 1)
    parts = meta.split(b" ")
    mode = parts[0].decode("ascii")
    sha = parts[1].decode("ascii")
    stage = parts[2].decode("ascii")
    path_str = path_bytes.decode("utf-8", errors="surrogateescape")
    index_stage[path_str] = {"mode": mode, "sha": sha, "stage": stage}

def handle_walk_error(err):
    raise err

def scan_dir(root_dir, is_git=False):
    manifest = {}
    root_resolved = os.path.realpath(root_dir)
    for dirpath, dirnames, filenames in os.walk(root_dir, onerror=handle_walk_error, followlinks=False):
        if is_git and os.path.realpath(dirpath) == root_resolved:
            dirnames[:] = [d for d in dirnames if d != ".git"]

        for name in sorted(dirnames + filenames):
            if is_git and os.path.realpath(dirpath) == root_resolved and name == ".git":
                continue
            full_path = os.path.join(dirpath, name)
            rel_path = os.path.relpath(full_path, root_dir)
            st = os.lstat(full_path)
            mode = st.st_mode
            if stat.S_ISDIR(mode):
                ftype = "dir"
                sha = None
                target = None
                size = 0
            elif stat.S_ISLNK(mode):
                ftype = "symlink"
                sha = None
                target = os.readlink(full_path)
                size = st.st_size
            elif stat.S_ISREG(mode):
                ftype = "file"
                h = hashlib.sha256()
                with open(full_path, "rb") as f:
                    while chunk := f.read(65536):
                        h.update(chunk)
                sha = h.hexdigest()
                target = None
                size = st.st_size
            else:
                raise ValueError(f"Unsupported special file: {rel_path} (mode {oct(mode)})")
            manifest[rel_path] = {
                "type": ftype,
                "mode": oct(mode & 0o777),
                "size": size,
                "sha256": sha,
                "link_target": target,
            }
    return manifest

wt_manifest = scan_dir(repo_path, is_git=True)
harness_manifest = scan_dir(harness_path, is_git=False)

output = {
    "head": {"commit": head_sha, "ref": head_ref},
    "refs": refs,
    "index_stage": index_stage,
    "worktree": wt_manifest,
    "harness": harness_manifest,
}
print(json.dumps(output))
"""


def get_guest_snapshot(
    sandbox_name: str,
    guest_repo: str,
    guest_harness: str,
    sbx_bin: str = "sbx",
) -> dict[str, Any]:
    """Capture full guest snapshot (HEAD, refs, index_stage, worktree manifest, harness manifest)."""
    res = subprocess.run(
        [
            sbx_bin,
            "exec",
            sandbox_name,
            "python3",
            "-c",
            GUEST_SNAPSHOT_SCRIPT,
            guest_repo,
            guest_harness,
        ],
        capture_output=True,
        text=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if res.returncode != 0:
        raise RuntimeError(f"Guest snapshot generation failed: {res.stderr}")
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse guest snapshot JSON: {e}") from e


def verify_tar_against_manifest(tar_path: Path, manifest: dict[str, dict[str, Any]]) -> None:
    """Verify tar archive contents against captured manifest without extracting untrusted files."""
    found_members: set[str] = set()
    seen_raw_names: set[str] = set()
    with tarfile.open(tar_path, "r:*") as tar:
        for member in tar.getmembers():
            if member.name in seen_raw_names:
                raise ValueError(f"Archive {tar_path.name} contains duplicate member '{member.name}'")
            seen_raw_names.add(member.name)

            if member.name.startswith("/") or member.name.startswith("\\"):
                raise ValueError(f"Archive {tar_path.name} contains forbidden absolute path '{member.name}'")

            norm_name = member.name.removeprefix("./").strip("/")
            if not norm_name or norm_name == ".":
                continue

            parts = norm_name.split("/")
            if any(p == ".." for p in parts):
                raise ValueError(f"Archive {tar_path.name} contains directory traversal component in '{norm_name}'")

            if norm_name not in manifest:
                raise ValueError(f"Archive {tar_path.name} contains unexpected member '{norm_name}' not in manifest")

            expected = manifest[norm_name]
            found_members.add(norm_name)

            expected_mode_int = int(expected["mode"], 8)
            actual_mode_int = member.mode & 0o777
            if actual_mode_int != expected_mode_int:
                raise ValueError(
                    f"Archive member '{norm_name}' mode mismatch: {oct(actual_mode_int)} != {oct(expected_mode_int)}"
                )

            if member.isreg():
                if expected["type"] != "file":
                    raise ValueError(f"Archive member '{norm_name}' is file, expected {expected['type']}")
                if member.size != expected["size"]:
                    raise ValueError(
                        f"Archive member '{norm_name}' size mismatch: {member.size} != {expected['size']}"
                    )
                f = tar.extractfile(member)
                if f is None:
                    raise ValueError(f"Failed to read file member '{norm_name}' from archive {tar_path.name}")
                h = hashlib.sha256()
                while chunk := f.read(65536):
                    h.update(chunk)
                actual_sha = h.hexdigest()
                if actual_sha != expected["sha256"]:
                    raise ValueError(
                        f"Archive member '{norm_name}' SHA256 mismatch: {actual_sha} != {expected['sha256']}"
                    )
            elif member.isdir():
                if expected["type"] != "dir":
                    raise ValueError(f"Archive member '{norm_name}' is dir, expected {expected['type']}")
            elif member.issym():
                if expected["type"] != "symlink":
                    raise ValueError(f"Archive member '{norm_name}' is symlink, expected {expected['type']}")
                if member.linkname != expected["link_target"]:
                    raise ValueError(
                        f"Archive member '{norm_name}' symlink target mismatch: {member.linkname} != {expected['link_target']}"
                    )
            else:
                raise ValueError(f"Archive member '{norm_name}' has unsupported archive type")

    missing = set(manifest.keys()) - found_members
    if missing:
        sample = sorted(list(missing))[:5]
        raise ValueError(f"Archive {tar_path.name} is missing {len(missing)} members from manifest (e.g. {sample})")


def create_task(
    record_path: Path,
    task_id: str,
    sandbox_name: str,
    host_repo: Path,
    base_ref: str,
    branch: str,
    workload_path: Path,
    mixin_path: Path,
    dependency_bundle: Path | None = None,
    dependency_task_ids: list[str] | None = None,
    guest_harness_path: str | None = None,
    cpus: int = DEFAULT_CPUS,
    memory: str = DEFAULT_MEMORY,
    sbx_bin: str = "sbx",
    git_bin: str = "git",
) -> dict[str, Any]:
    """Create a task sandbox and initialize task record."""
    val_task_id = validate_task_id(task_id)
    val_name = validate_sandbox_name(sandbox_name)
    val_host_repo = validate_host_repo(host_repo)
    val_record_path = validate_record_path(record_path, val_host_repo)
    val_branch = validate_branch_name(branch, git_bin=git_bin)

    res_workload = workload_path.resolve()
    if not res_workload.is_dir():
        raise ValueError(f"Workload kit path does not exist or is not a directory: {res_workload}")
    res_mixin = mixin_path.resolve()
    if not res_mixin.is_dir():
        raise ValueError(f"Mixin kit path does not exist or is not a directory: {res_mixin}")

    val_bundle: Path | None = None
    if dependency_bundle is not None:
        val_bundle = dependency_bundle.resolve()
        if not val_bundle.is_file():
            raise ValueError(f"Dependency bundle file does not exist: {val_bundle}")

    with TaskRecordLock(val_record_path):
        if val_record_path.exists():
            raise FileExistsError(f"Task record file already exists at {val_record_path}")

        existing_sbx = get_sandbox_info(val_name, sbx_bin=sbx_bin)
        if existing_sbx is not None:
            raise RuntimeError(
                f"Sandbox '{val_name}' already exists in sbx ls. Refusing to adopt existing VM."
            )

        res_host_branch = subprocess.run(
            [git_bin, "-C", str(val_host_repo), "rev-parse", "--verify", "--quiet", f"refs/heads/{val_branch}"],
            capture_output=True,
            text=True,
        )
        if res_host_branch.returncode == 0:
            raise ValueError(
                f"Branch '{val_branch}' already exists in host repository. Refusing collision."
            )

        base_commit = resolve_base_commit(
            base_ref,
            val_host_repo,
            bundle_path=val_bundle,
            git_bin=git_bin,
        )

        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        record: dict[str, Any] = {
            "schema_version": 1,
            "task_id": val_task_id,
            "sandbox_name": val_name,
            "sandbox_id": None,
            "host_repo": str(val_host_repo),
            "base_ref": base_ref,
            "base_commit": base_commit,
            "branch": val_branch,
            "workload_path": str(res_workload),
            "mixin_path": str(res_mixin),
            "cpus": cpus,
            "memory": memory,
            "dependency_bundle": str(val_bundle) if val_bundle else None,
            "dependency_task_ids": dependency_task_ids or [],
            "guest_cwd": None,
            "guest_repo_path": None,
            "guest_harness_path": guest_harness_path,
            "host_worktree": None,
            "status": "provisioning",
            "created_at": now,
            "updated_at": now,
            "preservations": [],
            "retirement": None,
            "last_error": None,
        }
        write_task_record(val_record_path, record, create_new=True)

        try:
            cmd_create = [
                sbx_bin,
                "create",
                "--name",
                val_name,
                "--cpus",
                str(cpus),
                "--memory",
                str(memory),
                "--skills",
                "off",
                "--clone",
                "--kit",
                str(res_mixin),
                str(res_workload),
                str(val_host_repo),
            ]
            subprocess.run(cmd_create, capture_output=True, text=True, check=True, timeout=LONG_TIMEOUT)

            cmd_run = [sbx_bin, "run", "-d", "--name", val_name]
            subprocess.run(cmd_run, capture_output=True, text=True, check=True, timeout=DEFAULT_TIMEOUT)

            info = get_sandbox_info(val_name, sbx_bin=sbx_bin)
            if not info:
                raise RuntimeError(f"Sandbox '{val_name}' not found in sbx ls after start.")
            observed_id = info.get("id") or info.get("sandbox_id")
            if not observed_id:
                raise RuntimeError(f"Sandbox '{val_name}' has no observed ID in sbx ls metadata.")
            record["sandbox_id"] = observed_id

            res_pwd = subprocess.run(
                [sbx_bin, "exec", val_name, "pwd"],
                capture_output=True,
                text=True,
                check=True,
                timeout=DEFAULT_TIMEOUT,
            )
            guest_cwd = res_pwd.stdout.strip()
            record["guest_cwd"] = guest_cwd

            res_git_host = subprocess.run(
                [sbx_bin, "exec", val_name, "git", "-C", str(val_host_repo), "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                timeout=DEFAULT_TIMEOUT,
            )
            if res_git_host.returncode == 0 and res_git_host.stdout.strip():
                guest_repo_path = res_git_host.stdout.strip()
            else:
                res_git_cwd = subprocess.run(
                    [sbx_bin, "exec", val_name, "git", "-C", guest_cwd, "rev-parse", "--show-toplevel"],
                    capture_output=True,
                    text=True,
                    timeout=DEFAULT_TIMEOUT,
                )
                if res_git_cwd.returncode == 0 and res_git_cwd.stdout.strip():
                    guest_repo_path = res_git_cwd.stdout.strip()
                else:
                    raise RuntimeError("Failed to discover git clone repository checkout in guest sandbox.")
            record["guest_repo_path"] = guest_repo_path

            if guest_harness_path is not None:
                validate_guest_harness_path(guest_harness_path, guest_repo_path)

            if val_bundle is not None:
                res_mktemp = subprocess.run(
                    [sbx_bin, "exec", val_name, "mktemp", "/tmp/dep.XXXXXX.bundle"],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=DEFAULT_TIMEOUT,
                )
                guest_bundle_tmp = res_mktemp.stdout.strip()

                subprocess.run(
                    [sbx_bin, "cp", str(val_bundle), f"{val_name}:{guest_bundle_tmp}"],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=LONG_TIMEOUT,
                )

                subprocess.run(
                    [
                        sbx_bin,
                        "exec",
                        val_name,
                        "git",
                        "-C",
                        guest_repo_path,
                        "fetch",
                        guest_bundle_tmp,
                        base_commit,
                    ],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=LONG_TIMEOUT,
                )

                res_cat = subprocess.run(
                    [
                        sbx_bin,
                        "exec",
                        val_name,
                        "git",
                        "-C",
                        guest_repo_path,
                        "cat-file",
                        "-e",
                        f"{base_commit}^{{commit}}",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=DEFAULT_TIMEOUT,
                )
                if res_cat.returncode != 0:
                    raise RuntimeError(f"Base commit {base_commit} was not found in guest clone after bundle fetch.")

                subprocess.run([sbx_bin, "exec", val_name, "rm", "-f", guest_bundle_tmp], capture_output=True, timeout=DEFAULT_TIMEOUT)

            res_ref_check = subprocess.run(
                [
                    sbx_bin,
                    "exec",
                    val_name,
                    "git",
                    "-C",
                    guest_repo_path,
                    "show-ref",
                    "--verify",
                    f"refs/heads/{val_branch}",
                ],
                capture_output=True,
                text=True,
            )
            if res_ref_check.returncode == 0:
                raise ValueError(
                    f"Branch '{val_branch}' already exists in guest repository. Refusing to overwrite existing ref."
                )

            subprocess.run(
                [
                    sbx_bin,
                    "exec",
                    val_name,
                    "git",
                    "-C",
                    guest_repo_path,
                    "checkout",
                    "-b",
                    val_branch,
                    base_commit,
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=DEFAULT_TIMEOUT,
            )

            res_head = subprocess.run(
                [sbx_bin, "exec", val_name, "git", "-C", guest_repo_path, "rev-parse", "HEAD"],
                capture_output=True,
                text=True,
                check=True,
                timeout=DEFAULT_TIMEOUT,
            )
            head_sha = res_head.stdout.strip().lower()
            if head_sha != base_commit.lower():
                raise RuntimeError(f"HEAD commit in guest {head_sha} does not match base {base_commit}")

            res_br = subprocess.run(
                [sbx_bin, "exec", val_name, "git", "-C", guest_repo_path, "rev-parse", "--abbrev-ref", "HEAD"],
                capture_output=True,
                text=True,
                check=True,
                timeout=DEFAULT_TIMEOUT,
            )
            head_branch = res_br.stdout.strip()
            if head_branch != val_branch:
                raise RuntimeError(f"HEAD branch in guest {head_branch} does not match {val_branch}")

            record["status"] = "ready"
            record["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            write_task_record(val_record_path, record)
            return record

        except Exception as e:
            record["status"] = "failed"
            record["last_error"] = str(e)
            record["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            write_task_record(val_record_path, record)
            raise


def status_task(
    record_path: Path,
    sbx_bin: str = "sbx",
    git_bin: str = "git",
) -> dict[str, Any]:
    """Query task and sandbox status without executing commands on stopped or mismatched VMs."""
    record = read_task_record(record_path, require_sandbox_id=False)
    sandbox_name = record["sandbox_name"]
    expected_id = record.get("sandbox_id")

    info = get_sandbox_info(sandbox_name, sbx_bin=sbx_bin)
    observed_id: str | None = None
    vm_status: str
    mismatch_reasons: list[str] = []

    if info is None:
        vm_status = "missing"
        if record.get("status") != "retired":
            mismatch_reasons.append("sandbox_not_found_in_sbx_ls")
    else:
        observed_id = info.get("id") or info.get("sandbox_id")
        vm_status = str(info.get("status", "unknown")).lower()
        if expected_id and observed_id != expected_id:
            mismatch_reasons.append(
                f"sandbox_id_mismatch (recorded={expected_id}, observed={observed_id})"
            )

    is_unknown = vm_status not in ("running", "stopped", "created", "exited", "missing")
    id_match = (expected_id == observed_id) if (expected_id and observed_id) else False

    guest_info: dict[str, Any] = {}
    if vm_status == "running" and id_match:
        guest_repo = record.get("guest_repo_path")
        if guest_repo:
            res_b = subprocess.run(
                [sbx_bin, "exec", sandbox_name, "git", "-C", guest_repo, "rev-parse", "--abbrev-ref", "HEAD"],
                capture_output=True,
                text=True,
                timeout=DEFAULT_TIMEOUT,
            )
            if res_b.returncode == 0:
                guest_info["branch"] = res_b.stdout.strip()
            res_c = subprocess.run(
                [sbx_bin, "exec", sandbox_name, "git", "-C", guest_repo, "rev-parse", "HEAD"],
                capture_output=True,
                text=True,
                timeout=DEFAULT_TIMEOUT,
            )
            if res_c.returncode == 0:
                guest_info["head_commit"] = res_c.stdout.strip()

    return {
        "task_id": record["task_id"],
        "sandbox_name": sandbox_name,
        "record_path": str(record_path.resolve()),
        "task_lifecycle": record.get("status"),
        "vm_status": vm_status,
        "recorded_sandbox_id": expected_id,
        "observed_sandbox_id": observed_id,
        "id_match": id_match,
        "mismatch": "; ".join(mismatch_reasons) if mismatch_reasons else None,
        "is_unknown": is_unknown,
        "branch": record.get("branch"),
        "base_commit": record.get("base_commit"),
        "guest_repo_path": record.get("guest_repo_path"),
        "guest_info": guest_info,
        "preservations_count": len(record.get("preservations", [])),
    }


def start_task(
    record_path: Path,
    sbx_bin: str = "sbx",
    git_bin: str = "git",
) -> dict[str, Any]:
    """Explicitly resume recorded existing sandbox, verifying identity and base ancestry."""
    with TaskRecordLock(record_path):
        record = read_task_record(record_path, require_sandbox_id=True)
        if record.get("status") == "retired":
            raise RuntimeError("Task has been retired; cannot resume a retired task.")
        sandbox_name = record["sandbox_name"]
        expected_id = record["sandbox_id"]

        info = get_sandbox_info(sandbox_name, sbx_bin=sbx_bin)
        if info is None:
            raise RuntimeError(f"Sandbox '{sandbox_name}' not found in sbx ls. Cannot resume.")

        observed_id = info.get("id") or info.get("sandbox_id")
        if observed_id != expected_id:
            raise RuntimeError(
                f"Sandbox identity mismatch: expected {expected_id}, observed {observed_id}. "
                "Refusing to start."
            )

        observed_status = str(info.get("status", "")).lower()
        if observed_status != "running":
            cmd_run = [sbx_bin, "run", "-d", "--name", sandbox_name]
            subprocess.run(cmd_run, capture_output=True, text=True, check=True, timeout=DEFAULT_TIMEOUT)

        guest_repo = record.get("guest_repo_path")
        if not guest_repo:
            raise RuntimeError("Task record is missing guest_repo_path.")

        res_top = subprocess.run(
            [sbx_bin, "exec", sandbox_name, "git", "-C", guest_repo, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=DEFAULT_TIMEOUT,
        )
        if res_top.returncode != 0:
            raise RuntimeError(
                f"Guest repository path '{guest_repo}' is not a valid git repository inside sandbox."
            )
        if res_top.stdout.strip() != guest_repo:
            raise RuntimeError(
                f"Guest top-level mismatch: expected '{guest_repo}', observed '{res_top.stdout.strip()}'."
            )

        res_br = subprocess.run(
            [sbx_bin, "exec", sandbox_name, "git", "-C", guest_repo, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=DEFAULT_TIMEOUT,
        )
        if res_br.returncode != 0:
            raise RuntimeError("Failed to query HEAD branch in guest repository.")
        current_branch = res_br.stdout.strip()
        if current_branch != record["branch"]:
            raise RuntimeError(
                f"Repository branch mismatch: expected branch '{record['branch']}', found '{current_branch}'. "
                "Refusing to reset or checkout; dirty work preserved."
            )

        base_commit = record["base_commit"]
        res_ancestor = subprocess.run(
            [
                sbx_bin,
                "exec",
                sandbox_name,
                "git",
                "-C",
                guest_repo,
                "merge-base",
                "--is-ancestor",
                base_commit,
                "HEAD",
            ],
            capture_output=True,
            timeout=DEFAULT_TIMEOUT,
        )
        if res_ancestor.returncode != 0:
            raise RuntimeError(f"Base commit '{base_commit}' is not an ancestor of current HEAD in guest repository.")

        res_dirty = subprocess.run(
            [sbx_bin, "exec", sandbox_name, "git", "-C", guest_repo, "status", "--porcelain=v1"],
            capture_output=True,
            text=True,
            timeout=DEFAULT_TIMEOUT,
        )
        if res_dirty.returncode != 0:
            raise RuntimeError(f"Failed to query git status in guest repository: {res_dirty.stderr}")
        is_dirty = bool(res_dirty.stdout.strip())

        record["status"] = "running"
        record["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        write_task_record(record_path, record)
        return {"record": record, "is_dirty": is_dirty}


def preserve_task(
    record_path: Path,
    dest_path: Path,
    quiesced: bool = False,
    harness_path: str | None = None,
    sbx_bin: str = "sbx",
    git_bin: str = "git",
) -> dict[str, Any]:
    """Capture full Git refs bundle, working files, and harness state to host destination."""
    if not quiesced:
        raise ValueError(
            "Preservation requires explicit confirmation that agents and processes are stopped (--quiesced flag required)."
        )

    with TaskRecordLock(record_path):
        record = read_task_record(record_path, require_sandbox_id=True)
        if record.get("status") == "retired":
            raise RuntimeError("Task has been retired; cannot resume a retired task.")
        sandbox_name = record["sandbox_name"]
        expected_id = record["sandbox_id"]
        host_repo = Path(record["host_repo"])
        guest_repo = record.get("guest_repo_path")
        if not guest_repo:
            raise RuntimeError("Task record is missing guest_repo_path.")

        info = get_sandbox_info(sandbox_name, sbx_bin=sbx_bin)
        if info is None or str(info.get("status", "")).lower() != "running":
            st_str = info.get("status") if info else "not_found"
            raise RuntimeError(
                f"Sandbox '{sandbox_name}' is not running (status: {st_str}). "
                "Preserve requires a running sandbox."
            )

        observed_id = info.get("id") or info.get("sandbox_id")
        if observed_id != expected_id:
            raise RuntimeError(
                f"Sandbox identity mismatch: expected {expected_id}, observed {observed_id}."
            )

        guest_harness_raw = harness_path or record.get("guest_harness_path")
        if not guest_harness_raw or not str(guest_harness_raw).strip():
            raise ValueError(
                "Explicit task harness path is required in task record or preserve argument (selection is absent)."
            )
        guest_harness = validate_guest_harness_path(guest_harness_raw, guest_repo)
        check_real_guest_harness(sandbox_name, guest_harness, guest_repo, sbx_bin=sbx_bin)

        dest = validate_destination_path(dest_path, host_repo)
        if dest.exists():
            raise FileExistsError(f"Preservation destination directory already exists: {dest}")
        dest.mkdir(mode=0o700, parents=True, exist_ok=False)

        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        res_mktemp = subprocess.run(
            [sbx_bin, "exec", sandbox_name, "mktemp", "-d", "/tmp/preserve.XXXXXX"],
            capture_output=True,
            text=True,
            check=True,
            timeout=DEFAULT_TIMEOUT,
        )
        guest_stage = res_mktemp.stdout.strip()
        validate_guest_harness_path(guest_harness, guest_repo, guest_stage)
        check_real_guest_harness(sandbox_name, guest_harness, guest_repo, guest_stage=guest_stage, sbx_bin=sbx_bin)

        snap_before: dict[str, Any] | None = None
        snap_after: dict[str, Any] | None = None
        try:
            snap_before = get_guest_snapshot(sandbox_name, guest_repo, guest_harness, sbx_bin=sbx_bin)

            guest_bundle = f"{guest_stage}/repo.bundle"
            subprocess.run(
                [
                    sbx_bin,
                    "exec",
                    sandbox_name,
                    "git",
                    "-C",
                    guest_repo,
                    "bundle",
                    "create",
                    guest_bundle,
                    "--all",
                    "HEAD",
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=LONG_TIMEOUT,
            )

            guest_staged_patch = f"{guest_stage}/staged.patch"
            subprocess.run(
                [
                    sbx_bin,
                    "exec",
                    sandbox_name,
                    "git",
                    "-C",
                    guest_repo,
                    "diff",
                    "--cached",
                    "--binary",
                    "--full-index",
                    f"--output={guest_staged_patch}",
                    "HEAD",
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=LONG_TIMEOUT,
            )

            guest_worktree = f"{guest_stage}/worktree.tar.gz"
            tar_wt_cmd = [
                sbx_bin,
                "exec",
                sandbox_name,
                "tar",
                "--exclude=./.git",
                "-czf",
                guest_worktree,
                "-C",
                guest_repo,
                ".",
            ]
            res_tar_wt = subprocess.run(tar_wt_cmd, capture_output=True, text=True, timeout=LONG_TIMEOUT)
            if res_tar_wt.returncode != 0:
                raise RuntimeError(
                    f"Failed to archive guest working directory: exit {res_tar_wt.returncode}, {res_tar_wt.stderr}"
                )

            guest_harness_tar = f"{guest_stage}/harness.tar.gz"
            tar_h_cmd = [
                sbx_bin,
                "exec",
                sandbox_name,
                "tar",
                "-czf",
                guest_harness_tar,
                "-C",
                guest_harness,
                ".",
            ]
            res_tar_h = subprocess.run(tar_h_cmd, capture_output=True, text=True, timeout=LONG_TIMEOUT)
            if res_tar_h.returncode != 0:
                raise RuntimeError(
                    f"Failed to archive guest harness directory: exit {res_tar_h.returncode}, {res_tar_h.stderr}"
                )

            snap_after = get_guest_snapshot(sandbox_name, guest_repo, guest_harness, sbx_bin=sbx_bin)
            if snap_before != snap_after:
                raise RuntimeError(
                    "Snapshot state changed during preservation (concurrent modification during archive generation). "
                    "Refusing verified receipt."
                )

            res_b_sha = subprocess.run(
                [sbx_bin, "exec", sandbox_name, "sha256sum", guest_bundle],
                capture_output=True,
                text=True,
                check=True,
                timeout=DEFAULT_TIMEOUT,
            )
            guest_bundle_sha = res_b_sha.stdout.strip().split()[0]

            res_p_sha = subprocess.run(
                [sbx_bin, "exec", sandbox_name, "sha256sum", guest_staged_patch],
                capture_output=True,
                text=True,
                check=True,
                timeout=DEFAULT_TIMEOUT,
            )
            guest_staged_sha = res_p_sha.stdout.strip().split()[0]

            res_w_sha = subprocess.run(
                [sbx_bin, "exec", sandbox_name, "sha256sum", guest_worktree],
                capture_output=True,
                text=True,
                check=True,
                timeout=DEFAULT_TIMEOUT,
            )
            guest_worktree_sha = res_w_sha.stdout.strip().split()[0]

            res_h_sha = subprocess.run(
                [sbx_bin, "exec", sandbox_name, "sha256sum", guest_harness_tar],
                capture_output=True,
                text=True,
                check=True,
                timeout=DEFAULT_TIMEOUT,
            )
            guest_harness_sha = res_h_sha.stdout.strip().split()[0]

            host_bundle = dest / "repo.bundle"
            host_staged_patch = dest / "staged.patch"
            host_worktree = dest / "worktree.tar.gz"
            host_harness = dest / "harness.tar.gz"

            subprocess.run(
                [sbx_bin, "cp", f"{sandbox_name}:{guest_bundle}", str(host_bundle)],
                capture_output=True,
                text=True,
                check=True,
                timeout=LONG_TIMEOUT,
            )
            subprocess.run(
                [sbx_bin, "cp", f"{sandbox_name}:{guest_staged_patch}", str(host_staged_patch)],
                capture_output=True,
                text=True,
                check=True,
                timeout=LONG_TIMEOUT,
            )
            subprocess.run(
                [sbx_bin, "cp", f"{sandbox_name}:{guest_worktree}", str(host_worktree)],
                capture_output=True,
                text=True,
                check=True,
                timeout=LONG_TIMEOUT,
            )
            subprocess.run(
                [sbx_bin, "cp", f"{sandbox_name}:{guest_harness_tar}", str(host_harness)],
                capture_output=True,
                text=True,
                check=True,
                timeout=LONG_TIMEOUT,
            )

            with open(host_bundle, "rb") as f:
                host_bundle_sha = hashlib.sha256(f.read()).hexdigest()
            if host_bundle_sha != guest_bundle_sha:
                raise RuntimeError(
                    f"Bundle SHA256 mismatch: guest={guest_bundle_sha}, host={host_bundle_sha}"
                )

            with open(host_staged_patch, "rb") as f:
                host_staged_sha = hashlib.sha256(f.read()).hexdigest()
            if host_staged_sha != guest_staged_sha:
                raise RuntimeError(
                    f"Staged patch SHA256 mismatch: guest={guest_staged_sha}, host={host_staged_sha}"
                )

            with open(host_worktree, "rb") as f:
                host_worktree_sha = hashlib.sha256(f.read()).hexdigest()
            if host_worktree_sha != guest_worktree_sha:
                raise RuntimeError(
                    f"Worktree archive SHA256 mismatch: guest={guest_worktree_sha}, host={host_worktree_sha}"
                )

            with open(host_harness, "rb") as f:
                host_harness_sha = hashlib.sha256(f.read()).hexdigest()
            if host_harness_sha != guest_harness_sha:
                raise RuntimeError(
                    f"Harness archive SHA256 mismatch: guest={guest_harness_sha}, host={host_harness_sha}"
                )

            with tempfile.TemporaryDirectory() as tmp_bare:
                bare_path = Path(tmp_bare)
                subprocess.run([git_bin, "init", "--bare", str(bare_path)], check=True, capture_output=True)

                res_v = subprocess.run(
                    [git_bin, "-C", str(bare_path), "bundle", "verify", str(host_bundle)],
                    capture_output=True,
                    text=True,
                )
                if res_v.returncode != 0:
                    raise RuntimeError(f"Host 'git bundle verify' failed on {host_bundle}: {res_v.stderr}")

                res_fetch = subprocess.run(
                    [
                        git_bin,
                        "-C",
                        str(bare_path),
                        "fetch",
                        str(host_bundle),
                        "+refs/*:refs/*",
                    ],
                    capture_output=True,
                    text=True,
                )
                if res_fetch.returncode != 0:
                    raise RuntimeError(f"Failed to fetch refs from bundle into bare mirror: {res_fetch.stderr}")

                res_fetch_head = subprocess.run(
                    [
                        git_bin,
                        "-C",
                        str(bare_path),
                        "fetch",
                        str(host_bundle),
                        "HEAD",
                    ],
                    capture_output=True,
                    text=True,
                )
                if res_fetch_head.returncode != 0:
                    raise RuntimeError(f"Failed to fetch HEAD from bundle into bare mirror: {res_fetch_head.stderr}")

                res_fsck = subprocess.run(
                    [git_bin, "-C", str(bare_path), "fsck", "--full", "--strict"],
                    capture_output=True,
                    text=True,
                )
                if res_fsck.returncode != 0:
                    raise RuntimeError(f"Bundle fsck failed: {res_fsck.stderr}")

                for refname, sha in snap_before["refs"].items():
                    res_r = subprocess.run(
                        [git_bin, "-C", str(bare_path), "rev-parse", "--verify", f"{refname}"],
                        capture_output=True,
                        text=True,
                    )
                    if res_r.returncode != 0 or res_r.stdout.strip().lower() != sha.lower():
                        raise RuntimeError(
                            f"Restored ref '{refname}' mismatch: expected {sha}, got {res_r.stdout.strip()}"
                        )

                res_head_test = subprocess.run(
                    [git_bin, "-C", str(bare_path), "rev-parse", "--verify", "FETCH_HEAD"],
                    capture_output=True,
                    text=True,
                )
                if (
                    res_head_test.returncode != 0
                    or res_head_test.stdout.strip().lower() != snap_before["head"]["commit"].lower()
                ):
                    raise RuntimeError(
                        f"Restored HEAD mismatch: expected {snap_before['head']['commit']}, got {res_head_test.stdout.strip()}"
                    )

                custom_env = os.environ.copy()
                custom_env["GIT_INDEX_FILE"] = str(bare_path / "test_index")
                subprocess.run(
                    [git_bin, "-C", str(bare_path), "read-tree", "FETCH_HEAD"],
                    env=custom_env,
                    check=True,
                    capture_output=True,
                )
                if host_staged_patch.stat().st_size > 0:
                    res_apply = subprocess.run(
                        [git_bin, "-C", str(bare_path), "apply", "--cached", str(host_staged_patch)],
                        env=custom_env,
                        capture_output=True,
                        text=True,
                    )
                    if res_apply.returncode != 0:
                        raise RuntimeError(f"Failed to apply staged patch to bare index: {res_apply.stderr}")

                res_bare_ls = subprocess.run(
                    [git_bin, "-C", str(bare_path), "ls-files", "-z", "--stage"],
                    env=custom_env,
                    capture_output=True,
                    check=True,
                )
                bare_index_stage = parse_ls_files_stage_z(res_bare_ls.stdout)
                if bare_index_stage != snap_before.get("index_stage", {}):
                    raise RuntimeError("Reconstructed bare index stage does not match captured guest index stage")

            verify_tar_against_manifest(host_worktree, snap_before["worktree"])
            verify_tar_against_manifest(host_harness, snap_before["harness"])

            snap_after = get_guest_snapshot(sandbox_name, guest_repo, guest_harness, sbx_bin=sbx_bin)
            if snap_before != snap_after:
                raise RuntimeError(
                    "Snapshot state changed during preservation (concurrent modification during transfer or verification). "
                    "Refusing verified receipt."
                )

            (dest / "manifest_before.json").write_text(json.dumps(snap_before, indent=2) + "\n", encoding="utf-8")
            (dest / "manifest_after.json").write_text(json.dumps(snap_after, indent=2) + "\n", encoding="utf-8")
            os.chmod(dest / "manifest_before.json", 0o600)
            os.chmod(dest / "manifest_after.json", 0o600)

            receipt: dict[str, Any] = {
                "schema_version": 1,
                "task_id": record["task_id"],
                "sandbox_name": sandbox_name,
                "sandbox_id": expected_id,
                "timestamp": timestamp,
                "verified": True,
                "destination": str(dest),
                "verification_scope": (
                    "Verification covers this point in time; retirement always requires a fresh check and explicit authorization."
                ),
                "bundle": {
                    "filename": "repo.bundle",
                    "sha256": host_bundle_sha,
                    "refs_count": len(snap_before["refs"]),
                    "refs": snap_before["refs"],
                    "head": snap_before["head"],
                },
                "staged_patch": {
                    "filename": "staged.patch",
                    "sha256": host_staged_sha,
                    "size": host_staged_patch.stat().st_size,
                    "index_entries_count": len(snap_before["index_stage"]),
                },
                "worktree": {
                    "filename": "worktree.tar.gz",
                    "sha256": host_worktree_sha,
                    "members_count": len(snap_before["worktree"]),
                },
                "harness": {
                    "filename": "harness.tar.gz",
                    "sha256": host_harness_sha,
                    "members_count": len(snap_before["harness"]),
                },
                "status": "verified",
            }
            receipt_file = dest / "receipt.json"
            receipt_file.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
            os.chmod(receipt_file, 0o600)

            record.setdefault("preservations", []).append(
                {
                    "timestamp": timestamp,
                    "verified": True,
                    "destination": str(dest),
                    "bundle_sha256": host_bundle_sha,
                    "staged_patch_sha256": host_staged_sha,
                    "worktree_sha256": host_worktree_sha,
                    "harness_sha256": host_harness_sha,
                    "status": "verified",
                    "verification_scope": (
                        "Verification covers this point in time; retirement always requires a fresh check and explicit authorization."
                    ),
                }
            )
            record["status"] = "preserved"
            record["updated_at"] = timestamp
            write_task_record(record_path, record)

            subprocess.run([sbx_bin, "exec", sandbox_name, "rm", "-rf", guest_stage], capture_output=True, timeout=DEFAULT_TIMEOUT)

            return receipt

        except Exception as err:
            if snap_after is None:
                try:
                    snap_after = get_guest_snapshot(sandbox_name, guest_repo, guest_harness, sbx_bin=sbx_bin)
                except Exception:
                    pass

            fail_receipt = {
                "schema_version": 1,
                "task_id": record.get("task_id"),
                "sandbox_name": sandbox_name,
                "sandbox_id": expected_id,
                "timestamp": timestamp,
                "verified": False,
                "guest_stage": guest_stage,
                "error": str(err),
                "destination": str(dest),
                "verification_scope": (
                    "Verification covers this point in time; retirement always requires a fresh check and explicit authorization."
                ),
                "status": "failed",
            }
            try:
                receipt_file = dest / "receipt.json"
                receipt_file.write_text(json.dumps(fail_receipt, indent=2) + "\n", encoding="utf-8")
                os.chmod(receipt_file, 0o600)
                if snap_before is not None:
                    (dest / "manifest_before.json").write_text(json.dumps(snap_before, indent=2) + "\n", encoding="utf-8")
                    os.chmod(dest / "manifest_before.json", 0o600)
                if snap_after is not None:
                    (dest / "manifest_after.json").write_text(json.dumps(snap_after, indent=2) + "\n", encoding="utf-8")
                    os.chmod(dest / "manifest_after.json", 0o600)
            except OSError:
                pass

            record.setdefault("preservations", []).append(
                {
                    "timestamp": timestamp,
                    "verified": False,
                    "guest_stage": guest_stage,
                    "error": str(err),
                    "destination": str(dest),
                    "verification_scope": (
                        "Verification covers this point in time; retirement always requires a fresh check and explicit authorization."
                    ),
                    "status": "failed",
                }
            )
            record["updated_at"] = timestamp
            write_task_record(record_path, record)

            raise


def parse_worktree_list_porcelain(raw_output: str) -> list[dict[str, Any]]:
    """Parse output of 'git worktree list --porcelain'."""
    worktrees: list[dict[str, Any]] = []
    current: dict[str, Any] = {}
    is_first = True

    for line in raw_output.splitlines():
        line = line.strip()
        if not line:
            if current:
                current["is_main"] = is_first
                worktrees.append(current)
                current = {}
                is_first = False
            continue

        if line.startswith("worktree "):
            if current:
                current["is_main"] = is_first
                worktrees.append(current)
                current = {}
                is_first = False
            current["worktree"] = line.removeprefix("worktree ").strip()
        elif line.startswith("HEAD "):
            current["HEAD"] = line.removeprefix("HEAD ").strip()
        elif line.startswith("branch "):
            current["branch"] = line.removeprefix("branch ").strip()
        elif line == "detached":
            current["detached"] = True
        elif line == "bare":
            current["bare"] = True

    if current:
        current["is_main"] = is_first
        worktrees.append(current)

    return worktrees


def get_worktrees(host_repo: Path, git_bin: str = "git") -> list[dict[str, Any]]:
    """List worktrees from host repo via 'git worktree list --porcelain'."""
    res = subprocess.run(
        [git_bin, "-C", str(host_repo), "worktree", "list", "--porcelain"],
        capture_output=True,
        text=True,
        check=True,
        timeout=DEFAULT_TIMEOUT,
    )
    return parse_worktree_list_porcelain(res.stdout)


def verify_worktree_clean(worktree_path: Path, git_bin: str = "git") -> None:
    """Verify worktree has no unstaged, staged, untracked, or ignored changes."""
    subprocess.run(
        [git_bin, "-C", str(worktree_path), "update-index", "-q", "--refresh"],
        capture_output=True,
        check=True,
        timeout=DEFAULT_TIMEOUT,
    )

    diff_files = subprocess.run(
        [git_bin, "-C", str(worktree_path), "diff-files", "--quiet"],
        capture_output=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if diff_files.returncode != 0:
        names = subprocess.run(
            [git_bin, "-C", str(worktree_path), "diff-files", "--name-status"],
            capture_output=True,
            text=True,
            timeout=DEFAULT_TIMEOUT,
        ).stdout.strip()
        raise RuntimeError(f"Worktree at {worktree_path} has unstaged tracked changes:\n{names}")

    diff_cached = subprocess.run(
        [git_bin, "-C", str(worktree_path), "diff-index", "--cached", "--quiet", "HEAD", "--"],
        capture_output=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if diff_cached.returncode != 0:
        names = subprocess.run(
            [git_bin, "-C", str(worktree_path), "diff-index", "--cached", "--name-status", "HEAD", "--"],
            capture_output=True,
            text=True,
            timeout=DEFAULT_TIMEOUT,
        ).stdout.strip()
        raise RuntimeError(f"Worktree at {worktree_path} has staged uncommitted changes:\n{names}")

    untracked = subprocess.run(
        [git_bin, "-C", str(worktree_path), "ls-files", "--others", "--exclude-standard"],
        capture_output=True,
        text=True,
        check=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if untracked.stdout.strip():
        raise RuntimeError(f"Worktree at {worktree_path} has untracked files:\n{untracked.stdout.strip()}")

    ignored = subprocess.run(
        [git_bin, "-C", str(worktree_path), "ls-files", "--others", "--ignored", "--exclude-standard"],
        capture_output=True,
        text=True,
        check=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if ignored.stdout.strip():
        raise RuntimeError(f"Worktree at {worktree_path} has ignored files:\n{ignored.stdout.strip()}")


def ensure_durable_host_branch(
    host_repo: Path,
    branch_name: str,
    target_sha: str,
    bundle_path: Path | None = None,
    git_bin: str = "git",
) -> None:
    """Ensure host repository has branch_name pointing to target_sha without overwriting divergent branch."""
    res_verify = subprocess.run(
        [git_bin, "-C", str(host_repo), "rev-parse", "--verify", "-q", f"refs/heads/{branch_name}"],
        capture_output=True,
        text=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if res_verify.returncode == 0:
        current_sha = res_verify.stdout.strip().lower()
        if current_sha != target_sha.lower():
            raise RuntimeError(
                f"Host branch '{branch_name}' already exists at {current_sha}, which diverges from "
                f"expected SHA {target_sha}. Refusing to overwrite existing divergent branch."
            )
        return

    # Branch does not exist on host. Check if commit object is in host_repo.
    res_cat = subprocess.run(
        [git_bin, "-C", str(host_repo), "cat-file", "-e", f"{target_sha}^{{commit}}"],
        capture_output=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if res_cat.returncode == 0:
        subprocess.run(
            [git_bin, "-C", str(host_repo), "branch", branch_name, target_sha],
            check=True,
            capture_output=True,
            timeout=DEFAULT_TIMEOUT,
        )
        res_check = subprocess.run(
            [git_bin, "-C", str(host_repo), "rev-parse", "--verify", "-q", f"refs/heads/{branch_name}"],
            capture_output=True,
            text=True,
            timeout=DEFAULT_TIMEOUT,
        )
        if res_check.returncode == 0 and res_check.stdout.strip().lower() == target_sha.lower():
            return
        raise RuntimeError(
            f"Created host branch '{branch_name}' could not be verified at {target_sha}."
        )

    # Commit not in host repo. Fetch exact expected target commit directly into host branch ref.
    # Do not fetch named refspecs to prevent creating wrong branches from stale bundle refs.
    if bundle_path and bundle_path.is_file():
        res_fetch = subprocess.run(
            [
                git_bin,
                "-C",
                str(host_repo),
                "fetch",
                str(bundle_path),
                f"{target_sha}:refs/heads/{branch_name}",
            ],
            capture_output=True,
            text=True,
            timeout=LONG_TIMEOUT,
        )
        if res_fetch.returncode == 0:
            res_check = subprocess.run(
                [git_bin, "-C", str(host_repo), "rev-parse", "--verify", "-q", f"refs/heads/{branch_name}"],
                capture_output=True,
                text=True,
                timeout=DEFAULT_TIMEOUT,
            )
            if res_check.returncode == 0 and res_check.stdout.strip().lower() == target_sha.lower():
                return
            raise RuntimeError(
                f"Fetched branch '{branch_name}' could not be verified at expected SHA {target_sha}."
            )

    raise RuntimeError(
        f"Required commit '{target_sha}' for branch '{branch_name}' could not be made durable on host repository. "
        "A bundle alone is not the same as retaining the branch. Retirement refused."
    )


def verify_accepted_manifest(
    manifest_path: Path,
    record: dict[str, Any],
    git_bin: str = "git",
) -> dict[str, Any]:
    """Read and validate accepted submission manifest matching task record."""
    if not manifest_path.exists():
        raise FileNotFoundError(f"Submission manifest file not found: {manifest_path}")
    if manifest_path.is_symlink():
        raise RuntimeError(f"Submission manifest file {manifest_path} must not be a symlink")
    st = manifest_path.lstat()
    if not stat.S_ISREG(st.st_mode):
        raise RuntimeError(f"Submission manifest file {manifest_path} must be a regular file")
    mode = st.st_mode & 0o777
    if mode not in (0o600, 0o400):
        raise RuntimeError(
            f"Submission manifest file {manifest_path} has unsafe permissions ({oct(mode)}), expected 0600 or 0400"
        )
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse submission manifest JSON at {manifest_path}: {e}") from e

    if not isinstance(data, dict):
        raise ValueError(f"Submission manifest at {manifest_path} must be a JSON object")

    if data.get("schema_version") != 1:
        raise ValueError(f"Submission manifest has invalid schema_version: {data.get('schema_version')}")
    if data.get("record_type") != "submission_manifest":
        raise ValueError(f"Submission manifest has invalid record_type: '{data.get('record_type')}'")
    if data.get("status") != "accepted":
        raise ValueError(f"Submission manifest status is '{data.get('status')}', expected 'accepted'")
    if data.get("designer_accepted") is not True:
        raise ValueError("Submission manifest designer_accepted must be true")

    if data.get("task_id") != record["task_id"]:
        raise ValueError(
            f"Manifest task_id '{data.get('task_id')}' does not match record task_id '{record['task_id']}'"
        )

    if str(data.get("base_commit", "")).lower() != str(record["base_commit"]).lower():
        raise ValueError(
            f"Manifest base_commit '{data.get('base_commit')}' does not match record base_commit '{record['base_commit']}'"
        )

    manifest_repo = Path(data.get("repo", "")).resolve()
    record_repo = Path(record["host_repo"]).resolve()
    if manifest_repo != record_repo:
        raise ValueError(
            f"Manifest repository '{manifest_repo}' does not match record host_repo '{record_repo}'"
        )

    submitted_sha = data.get("submitted_sha")
    submitted_tree = data.get("submitted_tree")
    reviewed_head = data.get("reviewed_head")
    reviewed_tree = data.get("reviewed_tree")
    sub_branch = data.get("submission_branch")

    if not submitted_sha or not GIT_HASH_PATTERN.match(submitted_sha):
        raise ValueError(f"Manifest submitted_sha '{submitted_sha}' is not a valid 40-char SHA")
    if not submitted_tree or not GIT_HASH_PATTERN.match(submitted_tree):
        raise ValueError(f"Manifest submitted_tree '{submitted_tree}' is not a valid 40-char SHA")
    if not reviewed_head or not GIT_HASH_PATTERN.match(reviewed_head):
        raise ValueError(f"Manifest reviewed_head '{reviewed_head}' is not a valid 40-char SHA")
    if not reviewed_tree or not GIT_HASH_PATTERN.match(reviewed_tree):
        raise ValueError(f"Manifest reviewed_tree '{reviewed_tree}' is not a valid 40-char SHA")

    if submitted_tree.lower() != reviewed_tree.lower():
        raise ValueError(
            f"Manifest submitted_tree '{submitted_tree}' does not match reviewed_tree '{reviewed_tree}'"
        )

    validate_branch_name(sub_branch, git_bin=git_bin)

    return data


def verify_preservation_export(
    record: dict[str, Any],
    host_repo: Path,
    git_bin: str = "git",
) -> tuple[dict[str, Any], Path]:
    """Verify task preservation receipt and actual artifact checksums outside repository."""
    preservations = record.get("preservations", [])
    verified_entries = [p for p in preservations if p.get("verified") is True]
    if not verified_entries:
        raise ValueError("No verified preservation export found in task record. Retirement requires verified preservation.")

    latest_pres = verified_entries[-1]
    dest_str = latest_pres.get("destination")
    if not dest_str:
        raise ValueError("Preservation entry has missing destination path")
    dest = Path(dest_str).resolve()
    if not dest.is_dir():
        raise RuntimeError(f"Preservation destination directory does not exist: {dest}")

    receipt_file = dest / "receipt.json"
    if not receipt_file.is_file():
        raise RuntimeError(f"Preservation receipt file does not exist: {receipt_file}")
    if receipt_file.is_symlink():
        raise RuntimeError(f"Preservation receipt file {receipt_file} must not be a symlink")
    st = receipt_file.lstat()
    mode = st.st_mode & 0o777
    if mode not in (0o600, 0o400):
        raise RuntimeError(f"Preservation receipt has unsafe permissions ({oct(mode)}), expected 0600 or 0400")

    try:
        receipt = json.loads(receipt_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse preservation receipt JSON: {e}") from e

    if not isinstance(receipt, dict):
        raise ValueError("Preservation receipt must be a JSON object")

    if receipt.get("verified") is not True or receipt.get("status") != "verified":
        raise ValueError("Preservation receipt is not verified")
    if receipt.get("task_id") != record["task_id"]:
        raise ValueError(f"Receipt task_id '{receipt.get('task_id')}' != record task_id '{record['task_id']}'")
    if receipt.get("sandbox_name") != record["sandbox_name"]:
        raise ValueError(f"Receipt sandbox_name '{receipt.get('sandbox_name')}' != record sandbox_name '{record['sandbox_name']}'")
    if receipt.get("sandbox_id") != record["sandbox_id"]:
        raise ValueError(f"Receipt sandbox_id '{receipt.get('sandbox_id')}' != record sandbox_id '{record['sandbox_id']}'")

    artifacts = [
        ("bundle", receipt.get("bundle", {}).get("filename", "repo.bundle"), latest_pres.get("bundle_sha256")),
        ("staged_patch", receipt.get("staged_patch", {}).get("filename", "staged.patch"), latest_pres.get("staged_patch_sha256")),
        ("worktree", receipt.get("worktree", {}).get("filename", "worktree.tar.gz"), latest_pres.get("worktree_sha256")),
        ("harness", receipt.get("harness", {}).get("filename", "harness.tar.gz"), latest_pres.get("harness_sha256")),
    ]

    for key, filename, record_sha in artifacts:
        art_file = dest / filename
        if not art_file.is_file():
            raise RuntimeError(f"Preservation artifact '{filename}' not found at {art_file}")
        h = hashlib.sha256()
        with open(art_file, "rb") as f:
            while chunk := f.read(65536):
                h.update(chunk)
        actual_sha = h.hexdigest()
        receipt_sha = receipt.get(key, {}).get("sha256")
        if actual_sha != receipt_sha:
            raise RuntimeError(
                f"Preservation artifact '{filename}' checksum mismatch with receipt: actual={actual_sha}, receipt={receipt_sha}"
            )
        if record_sha and actual_sha != record_sha:
            raise RuntimeError(
                f"Preservation artifact '{filename}' checksum mismatch with task record: actual={actual_sha}, record={record_sha}"
            )

    bundle_path = dest / receipt.get("bundle", {}).get("filename", "repo.bundle")
    res_bv = subprocess.run(
        [git_bin, "-C", str(host_repo), "bundle", "verify", str(bundle_path)],
        capture_output=True,
        text=True,
        timeout=DEFAULT_TIMEOUT,
    )
    if res_bv.returncode != 0:
        raise RuntimeError(f"Preservation bundle verification failed: {res_bv.stderr}")

    return receipt, dest


def check_fresh_guest_state(
    sandbox_name: str,
    guest_repo: str,
    guest_harness: str | None,
    dest: Path,
    sbx_bin: str = "sbx",
) -> None:
    """Check fresh guest state against preserved snapshot; fail if modified."""
    manifest_after_path = dest / "manifest_after.json"
    if not manifest_after_path.is_file():
        manifest_after_path = dest / "manifest_before.json"
    if not manifest_after_path.is_file():
        raise RuntimeError("Preservation manifest JSON not found in destination.")

    preserved_manifest = json.loads(manifest_after_path.read_text(encoding="utf-8"))
    current_snapshot = get_guest_snapshot(sandbox_name, guest_repo, guest_harness or "", sbx_bin=sbx_bin)

    if current_snapshot != preserved_manifest:
        raise RuntimeError(
            "Guest state has changed since preservation export (modifications detected). "
            "Retirement refused because preservation export is stale."
        )


def register_worktree(
    record_path: Path,
    worktree_path: Path,
    git_bin: str = "git",
) -> dict[str, Any]:
    """Register and validate a host worktree path in an existing task record."""
    with TaskRecordLock(record_path):
        record = read_task_record(record_path, require_sandbox_id=False)
        wt = Path(worktree_path).resolve()
        host_repo = Path(record["host_repo"]).resolve()
        if wt == host_repo:
            raise ValueError(f"Worktree path '{wt}' is the main repository checkout.")
        wt_list = get_worktrees(host_repo, git_bin=git_bin)
        matching = [w for w in wt_list if Path(w["worktree"]).resolve() == wt]
        if not matching:
            raise ValueError(f"Worktree path '{wt}' not found in 'git worktree list --porcelain' for {host_repo}")
        if matching[0].get("is_main"):
            raise ValueError(f"Worktree path '{wt}' is the main worktree.")
        record["host_worktree"] = str(wt)
        record["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        write_task_record(record_path, record)
        return record


def retire_task(
    record_path: Path,
    manifest_path: Path,
    worktree_path: Path | None = None,
    harness_path: str | None = None,
    sbx_bin: str = "sbx",
    git_bin: str = "git",
) -> dict[str, Any]:
    """Retire a completed task's exact sandbox and optional registered host worktree.

    Verifies accepted submission manifest, matching preservation export, fresh guest state,
    and durable host branch before destruction. Preflights all destructive targets before
    first removal and journals retirement phases for safe resumption.
    """
    with TaskRecordLock(record_path):
        record = read_task_record(record_path, require_sandbox_id=True)
        host_repo = Path(record["host_repo"]).resolve()
        sandbox_name = record["sandbox_name"]
        expected_id = record["sandbox_id"]

        retirement_info = record.get("retirement") or {}
        if record.get("status") == "retired" and retirement_info.get("phase") == "completed":
            return {
                "task_id": record["task_id"],
                "sandbox_name": sandbox_name,
                "sandbox_id": expected_id,
                "status": "retired",
                "worktree_removed": retirement_info.get("host_worktree"),
                "branch_preserved": retirement_info.get("submission_branch"),
                "submitted_sha": retirement_info.get("submitted_sha"),
                "retirement": retirement_info,
                "already_retired": True,
            }

        registered_wt = record.get("host_worktree") or retirement_info.get("host_worktree")
        registered_wt_path = Path(registered_wt).resolve() if registered_wt else None

        if worktree_path is not None:
            explicit_wt = worktree_path.resolve()
            if registered_wt_path is not None and explicit_wt != registered_wt_path:
                raise ValueError(
                    f"Specified worktree path '{explicit_wt}' does not match registered host worktree '{registered_wt_path}' "
                    f"for task '{record['task_id']}'. Cannot override a previously registered worktree during retirement."
                )
            wt_to_remove = explicit_wt
        else:
            wt_to_remove = registered_wt_path

        try:
            # ---------------- PREFLIGHT PHASE ----------------
            # 1. Validate submission manifest
            manifest = verify_accepted_manifest(manifest_path, record, git_bin=git_bin)
            submitted_sha = manifest["submitted_sha"]
            submitted_tree = manifest["submitted_tree"]
            sub_branch = manifest["submission_branch"]

            # 2. Validate preservation export and artifact checksums
            receipt, pres_dest = verify_preservation_export(record, host_repo, git_bin=git_bin)
            bundle_file = pres_dest / receipt.get("bundle", {}).get("filename", "repo.bundle")

            # 3. Ensure durable host branch/ref at accepted SHA before any destruction
            ensure_durable_host_branch(
                host_repo,
                sub_branch,
                submitted_sha,
                bundle_path=bundle_file,
                git_bin=git_bin,
            )

            # Verify submitted_sha commit tree matches manifest submitted_tree
            res_tree = subprocess.run(
                [git_bin, "-C", str(host_repo), "rev-parse", f"{submitted_sha}^{{tree}}"],
                capture_output=True,
                text=True,
                check=True,
                timeout=DEFAULT_TIMEOUT,
            )
            actual_tree = res_tree.stdout.strip().lower()
            if actual_tree != submitted_tree.lower():
                raise ValueError(
                    f"Submitted commit tree '{actual_tree}' does not match manifest tree '{submitted_tree}'"
                )

            # Ensure task implementation branch is also durable on host at reviewed_head
            task_branch = record.get("branch")
            if task_branch and task_branch != sub_branch:
                expected_task_sha = manifest.get("reviewed_head")
                if not expected_task_sha:
                    raise RuntimeError("Accepted manifest is missing reviewed_head required to preserve task branch.")
                ensure_durable_host_branch(
                    host_repo,
                    task_branch,
                    expected_task_sha,
                    bundle_path=bundle_file,
                    git_bin=git_bin,
                )

            # 4. Preflight registered host worktree (if any)
            if wt_to_remove is not None and retirement_info.get("phase") != "worktree_removed":
                if wt_to_remove == host_repo:
                    raise ValueError(f"Worktree path '{wt_to_remove}' is the main repository checkout. Cannot remove main checkout.")

                cwd = Path.cwd().resolve()
                if cwd == wt_to_remove or wt_to_remove in cwd.parents:
                    raise ValueError(f"Current working directory '{cwd}' is inside target worktree '{wt_to_remove}'. Cannot remove active worktree.")

                wt_list = get_worktrees(host_repo, git_bin=git_bin)
                matching_wt = [w for w in wt_list if Path(w["worktree"]).resolve() == wt_to_remove]
                if not matching_wt:
                    raise ValueError(f"Registered worktree '{wt_to_remove}' not found in 'git worktree list --porcelain' for {host_repo}.")
                wt_entry = matching_wt[0]
                if wt_entry.get("is_main"):
                    raise ValueError(f"Worktree '{wt_to_remove}' is the main checkout.")

                res_c = subprocess.run(
                    [git_bin, "-C", str(wt_to_remove), "rev-parse", "--git-common-dir"],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=DEFAULT_TIMEOUT,
                )
                comm_dir = Path(res_c.stdout.strip())
                if not comm_dir.is_absolute():
                    comm_dir = (wt_to_remove / comm_dir).resolve()
                else:
                    comm_dir = comm_dir.resolve()
                if comm_dir != (host_repo / ".git").resolve():
                    raise ValueError(f"Worktree '{wt_to_remove}' git-common-dir '{comm_dir}' does not match '{host_repo / '.git'}'.")

                if wt_entry.get("detached"):
                    raise ValueError(f"Worktree '{wt_to_remove}' has detached HEAD, expected branch '{record['branch']}'.")
                wt_branch = (wt_entry.get("branch") or "").removeprefix("refs/heads/")
                if wt_branch not in (record.get("branch"), sub_branch):
                    raise ValueError(f"Worktree '{wt_to_remove}' branch '{wt_branch}' does not match expected task branch '{record['branch']}'.")

                verify_worktree_clean(wt_to_remove, git_bin=git_bin)

            # 5. Preflight sandbox identity and fresh guest state
            current_phase = retirement_info.get("phase")
            info = get_sandbox_info(sandbox_name, sbx_bin=sbx_bin)
            if info is None:
                if current_phase in ("sandbox_removed", "worktree_removed", "completed"):
                    pass
                elif current_phase == "sandbox_stopped":
                    record["retirement"]["phase"] = "sandbox_removed"
                    write_task_record(record_path, record)
                else:
                    raise RuntimeError(f"Sandbox '{sandbox_name}' not found in sbx ls. Cannot retire missing sandbox.")
            else:
                observed_id = info.get("id") or info.get("sandbox_id")
                if observed_id != expected_id:
                    raise RuntimeError(
                        f"Sandbox identity mismatch: recorded={expected_id}, observed={observed_id}. "
                        "Never adopt or delete a same-name different-ID sandbox."
                    )

                observed_status = str(info.get("status", "")).lower()
                if observed_status == "running":
                    guest_repo = record.get("guest_repo_path")
                    if not guest_repo:
                        raise RuntimeError("Task record is missing guest_repo_path.")
                    guest_harness_raw = harness_path or record.get("guest_harness_path")
                    check_fresh_guest_state(sandbox_name, guest_repo, guest_harness_raw, pres_dest, sbx_bin=sbx_bin)
                elif current_phase in ("sandbox_stopped", "sandbox_removed", "worktree_removed", "completed"):
                    # Supported retry after a journaled stop from a previous retirement preflight
                    if observed_status not in ("stopped", "exited", "created"):
                        raise RuntimeError(
                            f"Sandbox '{sandbox_name}' in unexpected status '{observed_status}' during retirement resumption."
                        )
                else:
                    raise RuntimeError(
                        f"Sandbox '{sandbox_name}' is stopped (status: '{observed_status}'). "
                        "Retirement requires a fresh guest snapshot check against a running sandbox to verify no "
                        "modifications occurred after preservation. Please resume the sandbox with "
                        f"'python3 sandbox/task.py start --record {record_path}', preserve again, and retry retirement."
                    )

            # Preflight passed. Journal preflight phase.
            now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
            if wt_to_remove is not None:
                record["host_worktree"] = str(wt_to_remove)
            if not record.get("retirement"):
                record["retirement"] = {
                    "started_at": now_iso,
                    "phase": "preflight_passed",
                    "manifest_path": str(manifest_path.resolve()),
                    "submitted_sha": submitted_sha,
                    "submission_branch": sub_branch,
                    "host_worktree": str(wt_to_remove) if wt_to_remove else None,
                    "phases": [],
                }
            record["retirement"]["phases"].append({
                "phase": "preflight_passed",
                "timestamp": now_iso,
                "status": "completed",
            })
            write_task_record(record_path, record)

            # ---------------- EXECUTION PHASE ----------------
            # 1. Quiesce / stop sandbox (if running)
            info = get_sandbox_info(sandbox_name, sbx_bin=sbx_bin)
            if info is not None:
                observed_status = str(info.get("status", "")).lower()
                if observed_status == "running":
                    subprocess.run([sbx_bin, "stop", sandbox_name], check=True, timeout=DEFAULT_TIMEOUT)
                    info_after = get_sandbox_info(sandbox_name, sbx_bin=sbx_bin)
                    if info_after is not None:
                        id_after = info_after.get("id") or info_after.get("sandbox_id")
                        if id_after != expected_id:
                            raise RuntimeError(f"Sandbox identity changed after stop: {id_after} != {expected_id}")
                        st_after = str(info_after.get("status", "")).lower()
                        if st_after not in ("stopped", "exited", "created"):
                            raise RuntimeError(f"Sandbox failed to quiesce: observed status '{st_after}'")

            record["retirement"]["phase"] = "sandbox_stopped"
            record["retirement"]["phases"].append({
                "phase": "sandbox_stopped",
                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "status": "completed",
            })
            write_task_record(record_path, record)

            # 2. Remove sandbox
            info = get_sandbox_info(sandbox_name, sbx_bin=sbx_bin)
            if info is not None:
                observed_id = info.get("id") or info.get("sandbox_id")
                if observed_id != expected_id:
                    raise RuntimeError(f"Sandbox identity mismatch before rm: {observed_id} != {expected_id}")
                observed_status = str(info.get("status", "")).lower()
                if observed_status not in ("stopped", "exited", "created"):
                    raise RuntimeError(
                        f"Refusing to remove sandbox '{sandbox_name}': expected stopped status, observed '{observed_status}'"
                    )
                # Targeted local removal with --force to bypass interactive confirmation noninteractively.
                # Safe because sandbox ID matches task record, container was confirmed stopped, and removal targets only sandbox_name (never --all).
                subprocess.run([sbx_bin, "rm", "--force", sandbox_name], check=True, timeout=DEFAULT_TIMEOUT)
                info_after_rm = get_sandbox_info(sandbox_name, sbx_bin=sbx_bin)
                if info_after_rm is not None:
                    raise RuntimeError(f"Sandbox '{sandbox_name}' still exists in sbx ls after 'sbx rm'.")

            record["retirement"]["phase"] = "sandbox_removed"
            record["retirement"]["phases"].append({
                "phase": "sandbox_removed",
                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "status": "completed",
            })
            write_task_record(record_path, record)

            # 3. Remove host worktree (if registered)
            if wt_to_remove is not None:
                wt_list = get_worktrees(host_repo, git_bin=git_bin)
                matching_wt = [w for w in wt_list if Path(w["worktree"]).resolve() == wt_to_remove]
                if matching_wt:
                    wt_entry = matching_wt[0]
                    if wt_to_remove == host_repo or wt_entry.get("is_main"):
                        raise ValueError(f"Worktree '{wt_to_remove}' is the main checkout.")
                    cwd = Path.cwd().resolve()
                    if cwd == wt_to_remove or wt_to_remove in cwd.parents:
                        raise ValueError(f"Current working directory '{cwd}' is inside target worktree '{wt_to_remove}'.")

                    # Recheck worktree branch and cleanliness immediately before removal,
                    # including ignored files, to guard against mutations introduced between phases.
                    wt_branch = (wt_entry.get("branch") or "").removeprefix("refs/heads/")
                    if wt_branch not in (record.get("branch"), sub_branch):
                        raise ValueError(
                            f"Worktree '{wt_to_remove}' branch '{wt_branch}' does not match expected task branch '{record['branch']}'."
                        )
                    verify_worktree_clean(wt_to_remove, git_bin=git_bin)

                    subprocess.run(
                        [git_bin, "-C", str(host_repo), "worktree", "remove", str(wt_to_remove)],
                        check=True,
                        timeout=DEFAULT_TIMEOUT,
                    )
                    wt_list_after = get_worktrees(host_repo, git_bin=git_bin)
                    if any(Path(w["worktree"]).resolve() == wt_to_remove for w in wt_list_after):
                        raise RuntimeError(f"Worktree '{wt_to_remove}' still present after 'git worktree remove'.")

                record["retirement"]["phase"] = "worktree_removed"
                record["retirement"]["phases"].append({
                    "phase": "worktree_removed",
                    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "status": "completed",
                })
                write_task_record(record_path, record)

            # 4. Mark retired and completed
            now_done = datetime.datetime.now(datetime.timezone.utc).isoformat()
            record["status"] = "retired"
            record["updated_at"] = now_done
            record["retirement"]["phase"] = "completed"
            record["retirement"]["completed_at"] = now_done
            record["retirement"]["phases"].append({
                "phase": "completed",
                "timestamp": now_done,
                "status": "completed",
            })
            record["last_error"] = None
            write_task_record(record_path, record)

            return {
                "task_id": record["task_id"],
                "sandbox_name": sandbox_name,
                "sandbox_id": expected_id,
                "status": "retired",
                "worktree_removed": str(wt_to_remove) if wt_to_remove else None,
                "branch_preserved": sub_branch,
                "submitted_sha": submitted_sha,
                "retirement": record["retirement"],
            }

        except Exception as err:
            if "retirement" in record and isinstance(record["retirement"], dict):
                record["retirement"]["error"] = str(err)
            record["last_error"] = str(err)
            record["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            try:
                write_task_record(record_path, record)
            except Exception:
                pass
            raise


def build_parser() -> argparse.ArgumentParser:
    """Build command line argument parser."""
    parser = argparse.ArgumentParser(
        prog="task.py",
        description="Task Sandbox Lifecycle Management CLI.",
    )
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # create
    p_create = subparsers.add_parser("create", help="Create a task sandbox.")
    p_create.add_argument("--record", required=True, help="Path to JSON task record file")
    p_create.add_argument("--task-id", required=True, help="Explicit task ID")
    p_create.add_argument("--name", required=True, help="Sandbox name")
    p_create.add_argument("--repo", required=True, help="Host git repository path")
    p_create.add_argument("--base", required=True, help="Base commit ref or SHA")
    p_create.add_argument("--branch", required=True, help="Implementation branch (rejects master/main)")
    p_create.add_argument("--workload", required=True, help="Workload kit path")
    p_create.add_argument("--mixin", required=True, help="Mixin kit path")
    p_create.add_argument("--bundle", help="Optional dependency bundle path")
    p_create.add_argument(
        "--depends-on",
        action="append",
        default=[],
        dest="depends_on",
        help="Dependency task ID",
    )
    p_create.add_argument(
        "--harness-path",
        default=None,
        help="Explicit guest task harness state directory path",
    )
    p_create.add_argument("--cpus", type=int, default=DEFAULT_CPUS, help="CPUs sizing")
    p_create.add_argument("--memory", default=DEFAULT_MEMORY, help="Memory sizing")
    p_create.add_argument("--sbx-bin", default=os.environ.get("SBX_BIN", "sbx"), help="Path to sbx binary")
    p_create.add_argument("--git-bin", default=os.environ.get("GIT_BIN", "git"), help="Path to git binary")

    # status
    p_status = subparsers.add_parser("status", help="Query task sandbox status.")
    p_status.add_argument("--record", required=True, help="Path to JSON task record file")
    p_status.add_argument("--json", action="store_true", help="Output status as JSON")
    p_status.add_argument("--sbx-bin", default=os.environ.get("SBX_BIN", "sbx"), help="Path to sbx binary")
    p_status.add_argument("--git-bin", default=os.environ.get("GIT_BIN", "git"), help="Path to git binary")

    # start
    p_start = subparsers.add_parser("start", help="Resume an existing recorded sandbox.")
    p_start.add_argument("--record", required=True, help="Path to JSON task record file")
    p_start.add_argument("--sbx-bin", default=os.environ.get("SBX_BIN", "sbx"), help="Path to sbx binary")
    p_start.add_argument("--git-bin", default=os.environ.get("GIT_BIN", "git"), help="Path to git binary")

    # preserve
    p_preserve = subparsers.add_parser("preserve", help="Preserve running sandbox work and harness state.")
    p_preserve.add_argument("--record", required=True, help="Path to JSON task record file")
    p_preserve.add_argument("--dest", required=True, help="Host destination directory")
    p_preserve.add_argument(
        "--quiesced",
        action="store_true",
        help="Assert that all agent and development processes are stopped",
    )
    p_preserve.add_argument(
        "--harness-path",
        default=None,
        help="Explicit guest task harness directory path",
    )
    p_preserve.add_argument("--sbx-bin", default=os.environ.get("SBX_BIN", "sbx"), help="Path to sbx binary")
    p_preserve.add_argument("--git-bin", default=os.environ.get("GIT_BIN", "git"), help="Path to git binary")

    # register-worktree
    p_reg = subparsers.add_parser("register-worktree", help="Register a host worktree path in a task record.")
    p_reg.add_argument("--record", required=True, help="Path to JSON task record file")
    p_reg.add_argument("--worktree", required=True, help="Host worktree path")
    p_reg.add_argument("--git-bin", default=os.environ.get("GIT_BIN", "git"), help="Path to git binary")

    # retire
    p_retire = subparsers.add_parser("retire", help="Retire completed task sandbox and optional registered worktree.")
    p_retire.add_argument("--record", required=True, help="Path to JSON task record file")
    p_retire.add_argument("--manifest", required=True, help="Path to accepted submission manifest JSON file")
    p_retire.add_argument("--worktree", default=None, help="Optional host worktree path to retire")
    p_retire.add_argument("--harness-path", default=None, help="Explicit guest task harness directory path")
    p_retire.add_argument("--sbx-bin", default=os.environ.get("SBX_BIN", "sbx"), help="Path to sbx binary")
    p_retire.add_argument("--git-bin", default=os.environ.get("GIT_BIN", "git"), help="Path to git binary")

    return parser


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        record_path = Path(args.record)

        if args.subcommand == "create":
            record = create_task(
                record_path=record_path,
                task_id=args.task_id,
                sandbox_name=args.name,
                host_repo=Path(args.repo),
                base_ref=args.base,
                branch=args.branch,
                workload_path=Path(args.workload),
                mixin_path=Path(args.mixin),
                dependency_bundle=Path(args.bundle) if args.bundle else None,
                dependency_task_ids=args.depends_on,
                guest_harness_path=args.harness_path,
                cpus=args.cpus,
                memory=args.memory,
                sbx_bin=args.sbx_bin,
                git_bin=args.git_bin,
            )
            print(f"Task sandbox created: {record['sandbox_name']} (task: {record['task_id']}, status: {record['status']})")
            return 0

        elif args.subcommand == "status":
            stat_res = status_task(record_path, sbx_bin=args.sbx_bin, git_bin=args.git_bin)
            if args.json:
                print(json.dumps(stat_res, indent=2))
            else:
                print(f"Task ID:          {stat_res['task_id']}")
                print(f"Sandbox Name:     {stat_res['sandbox_name']}")
                print(f"Lifecycle State:  {stat_res['task_lifecycle']}")
                print(f"VM Status:        {stat_res['vm_status']}")
                print(f"Recorded ID:      {stat_res['recorded_sandbox_id']}")
                print(f"Observed ID:      {stat_res['observed_sandbox_id']}")
                print(f"ID Match:         {stat_res['id_match']}")
                if stat_res.get("mismatch"):
                    print(f"Mismatch:         {stat_res['mismatch']}")
                if stat_res.get("is_unknown"):
                    print("Warning:          Observed VM status is unknown.")
                print(f"Branch:           {stat_res['branch']}")
                print(f"Base Commit:      {stat_res['base_commit']}")
                if stat_res.get("guest_info"):
                    print(f"Guest Info:       {stat_res['guest_info']}")
            return 0

        elif args.subcommand == "start":
            res = start_task(record_path, sbx_bin=args.sbx_bin, git_bin=args.git_bin)
            print(f"Task sandbox resumed: {res['record']['sandbox_name']} (dirty work: {res['is_dirty']})")
            return 0

        elif args.subcommand == "preserve":
            dest_path = Path(args.dest)
            receipt = preserve_task(
                record_path,
                dest_path,
                quiesced=args.quiesced,
                harness_path=args.harness_path,
                sbx_bin=args.sbx_bin,
                git_bin=args.git_bin,
            )
            print(f"Preservation verified: destination={receipt['destination']} bundle_sha={receipt['bundle']['sha256']}")
            return 0

        elif args.subcommand == "register-worktree":
            rec = register_worktree(record_path, Path(args.worktree), git_bin=args.git_bin)
            print(f"Registered worktree for task {rec['task_id']}: {rec['host_worktree']}")
            return 0

        elif args.subcommand == "retire":
            res = retire_task(
                record_path=record_path,
                manifest_path=Path(args.manifest),
                worktree_path=Path(args.worktree) if args.worktree else None,
                harness_path=args.harness_path,
                sbx_bin=args.sbx_bin,
                git_bin=args.git_bin,
            )
            print(
                f"Task environment retired: {res['sandbox_name']} "
                f"(task: {res['task_id']}, worktree: {res['worktree_removed'] or 'none'}, "
                f"branch: {res['branch_preserved']})"
            )
            return 0

        else:
            parser.print_help(sys.stderr)
            return 1

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
