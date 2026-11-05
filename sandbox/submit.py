#!/usr/bin/env python3
"""Reviewed task submissions and multi-task assembly tool.

Provides explicit, repeatable prepare, accept, and assemble stages for
managing reviewed task submissions and safe linear multi-task assembly.
All state is tracked via validated JSON records stored outside repositories.
"""

from __future__ import annotations

import argparse
import datetime
import fcntl
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
TASK_ID_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")
GIT_HASH_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
FORBIDDEN_BRANCHES = {"master", "main", "refs/heads/master", "refs/heads/main"}


def iso_now() -> str:
    """Return current UTC timestamp in ISO-8601 format."""
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def validate_task_id(task_id: Any) -> str:
    """Validate task ID format and type."""
    if not isinstance(task_id, str):
        raise ValueError(f"Task ID must be a string, got {type(task_id).__name__}.")
    cleaned = task_id.strip()
    if not cleaned or not TASK_ID_PATTERN.match(cleaned):
        raise ValueError(
            f"Invalid task ID '{task_id}'. Must be 1-128 characters matching "
            "[a-zA-Z0-9][a-zA-Z0-9._-]* without path separators or shell characters."
        )
    return cleaned


def validate_git_sha(sha: Any, name: str = "SHA") -> str:
    """Validate exact 40-character hexadecimal commit SHA (no symbolic refs)."""
    if not isinstance(sha, str):
        raise ValueError(f"{name} must be a string, got {type(sha).__name__}.")
    cleaned = sha.strip()
    if not cleaned or not GIT_HASH_PATTERN.match(cleaned):
        raise ValueError(
            f"Invalid {name} '{sha}'. Expected an exact 40-character hexadecimal SHA, not a symbolic ref."
        )
    return cleaned.lower()


def validate_branch_name(branch: Any, git_bin: str = "git") -> str:
    """Validate branch name using git check-ref-format and rejecting master/main."""
    if not isinstance(branch, str):
        raise ValueError(f"Branch name must be a string, got {type(branch).__name__}.")
    cleaned = branch.strip()
    if not cleaned:
        raise ValueError("Branch name cannot be empty.")
    if cleaned.startswith("-"):
        raise ValueError(f"Branch name cannot start with a dash: '{cleaned}'")
    if any(ord(c) < 32 or ord(c) == 127 for c in cleaned):
        raise ValueError(f"Branch name contains control characters: '{cleaned}'")

    norm = cleaned.lower().removeprefix("refs/heads/")
    if norm in {"master", "main"}:
        raise ValueError(
            f"Branch name cannot be '{cleaned}'. master and main branches are forbidden."
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


def validate_repo_path(repo_path: Any) -> Path:
    """Validate git repository checkout directory."""
    if not isinstance(repo_path, (str, Path)):
        raise ValueError(f"Repository path must be a string or Path, got {type(repo_path).__name__}.")
    path = Path(repo_path).resolve()
    if not path.is_dir():
        raise ValueError(f"Repository directory does not exist or is not a directory: {path}")
    git_entry = path / ".git"
    if not git_entry.exists():
        raise ValueError(f"Repository at {path} is missing a .git directory.")
    if git_entry.is_file():
        try:
            content = git_entry.read_text(encoding="utf-8").strip()
            if not content.startswith("gitdir:"):
                raise ValueError(f"Repository at {path} has invalid .git file content.")
        except OSError as e:
            raise ValueError(f"Cannot read .git file at {path}: {e}") from e
    elif not git_entry.is_dir():
        raise ValueError(f"Repository at {path} has non-directory .git entry.")

    res = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0 or res.stdout.strip() != "true":
        raise ValueError(f"Directory {path} is not inside a git work tree.")

    return path


def validate_record_path_outside_repo(record_path: Any, repo: Path | None = None) -> Path:
    """Validate that record path is outside repository."""
    if not isinstance(record_path, (str, Path)):
        raise ValueError(f"Record path must be a string or Path, got {type(record_path).__name__}.")
    resolved = Path(record_path).resolve()
    if repo is not None:
        r_resolved = Path(repo).resolve()
        if resolved == r_resolved or r_resolved in resolved.parents:
            raise ValueError(
                f"Record path {resolved} must be outside repository {r_resolved}."
            )
    return resolved


def validate_dependencies(
    dependencies: Any,
    current_task_id: str | None = None,
) -> list[dict[str, str]]:
    """Validate dependency list for schema, types, exact SHAs, uniqueness, and non-self."""
    if dependencies is None:
        return []
    if not isinstance(dependencies, list):
        raise ValueError(f"Dependencies must be a list, got {type(dependencies).__name__}.")

    validated: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    seen_shas: set[str] = set()

    for i, dep in enumerate(dependencies):
        if not isinstance(dep, dict):
            raise ValueError(f"Dependency at index {i} must be a dict, got {type(dep).__name__}.")

        if "task_id" not in dep or "accepted_sha" not in dep:
            raise ValueError(
                f"Dependency at index {i} must contain 'task_id' and 'accepted_sha' keys: {dep}"
            )

        tid = validate_task_id(dep["task_id"])
        if current_task_id is not None and tid == current_task_id:
            raise ValueError(f"Self-dependency is forbidden: task '{current_task_id}' cannot depend on itself.")

        if tid in seen_ids:
            raise ValueError(f"Duplicate dependency task ID '{tid}' in dependencies list.")
        seen_ids.add(tid)

        sha = validate_git_sha(dep["accepted_sha"], f"dependency '{tid}' accepted SHA")
        if sha in seen_shas:
            raise ValueError(f"Duplicate dependency accepted SHA '{sha}' in dependencies list.")
        seen_shas.add(sha)

        validated.append({"task_id": tid, "accepted_sha": sha})

    return validated


def parse_dependency(dep_str: str) -> dict[str, str]:
    """Parse a single dependency in TASK_ID:SHA or TASK_ID=SHA format."""
    cleaned = dep_str.strip()
    if ":" in cleaned:
        tid, sha = cleaned.split(":", 1)
    elif "=" in cleaned:
        tid, sha = cleaned.split("=", 1)
    else:
        raise ValueError(
            f"Invalid dependency format '{dep_str}'. Expected 'TASK_ID:SHA' or 'TASK_ID=SHA'."
        )
    return {
        "task_id": validate_task_id(tid.strip()),
        "accepted_sha": validate_git_sha(sha.strip(), "dependency accepted SHA"),
    }


def load_dependency_from_manifest(manifest_path: Path | str) -> dict[str, str]:
    """Load dependency from an existing accepted submission manifest."""
    m_path = Path(manifest_path)
    data = read_json_record(m_path)
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"Manifest at {m_path} has invalid schema_version: {data.get('schema_version')}")
    if data.get("record_type") != "submission_manifest" or data.get("status") != "accepted":
        raise ValueError(f"Manifest at {m_path} is not an accepted submission manifest.")
    task_id = validate_task_id(data.get("task_id"))
    submitted_sha = validate_git_sha(data.get("submitted_sha"), "submitted SHA")
    return {"task_id": task_id, "accepted_sha": submitted_sha}


class RecordLock:
    """Advisory flock on companion lock file."""

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
                f"Another operation is in progress for record '{self.lock_path.name}'"
            ) from e
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            finally:
                os.close(self._fd)
                self._fd = None


def write_json_record(record_path: Path, data: dict[str, Any], create_new: bool = False) -> None:
    """Atomically write JSON record with 0600 permissions, companion lock, and overwrite guard."""
    record_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    with RecordLock(record_path):
        if create_new and record_path.exists():
            raise FileExistsError(f"Record file already exists at {record_path}; refusing overwrite.")

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


def read_json_record(record_path: Path) -> dict[str, Any]:
    """Read and validate JSON record with strict file checks."""
    if not record_path.exists():
        raise FileNotFoundError(f"Record file not found: {record_path}")
    if record_path.is_symlink():
        raise RuntimeError(f"Record file {record_path} must not be a symlink")
    st = record_path.lstat()
    if not stat.S_ISREG(st.st_mode):
        raise RuntimeError(f"Record file {record_path} must be a regular file")
    mode = st.st_mode & 0o777
    if mode not in (0o600, 0o400):
        raise RuntimeError(
            f"Record file {record_path} has unsafe permissions ({oct(mode)}), expected 0600 or 0400"
        )
    try:
        data = json.loads(record_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse JSON record at {record_path}: {e}") from e

    if not isinstance(data, dict):
        raise ValueError(f"Record at {record_path} must be a JSON object")

    return data


def run_git(
    cmd: list[str],
    cwd: Path | str,
    git_bin: str = "git",
    check: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run git command in directory without shell evaluation."""
    full_cmd = [git_bin, "-C", str(cwd)] + cmd
    res = subprocess.run(
        full_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and res.returncode != 0:
        raise RuntimeError(
            f"Git command failed (exit {res.returncode}): {' '.join(full_cmd)}\n"
            f"Stdout: {res.stdout.strip()}\n"
            f"Stderr: {res.stderr.strip()}"
        )
    return res


def check_ref_absent(repo: Path, ref_name: str, desc: str, git_bin: str = "git") -> None:
    """Verify ref does not exist, distinguishing absent ref (exit 1) from read errors."""
    res = run_git(["rev-parse", "--verify", "-q", ref_name], cwd=repo, git_bin=git_bin)
    if res.returncode == 0:
        raise ValueError(f"{desc} '{ref_name}' already exists in {repo}.")
    if res.returncode != 1:
        raise RuntimeError(
            f"Unexpected error checking ref '{ref_name}' (exit {res.returncode}): {res.stderr.strip()}"
        )


def check_no_ignored_collisions(repo: Path, target_commits: list[str], git_bin: str = "git") -> None:
    """Preflight check: refuse if existing ignored local files would collide with files tracked in target_commits."""
    res_ign = run_git(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], cwd=repo, check=True, git_bin=git_bin)
    ignored_paths = set(filter(None, res_ign.stdout.split("\0")))
    if not ignored_paths:
        return

    colliding: set[str] = set()
    for commit in target_commits:
        res_tree = run_git(["ls-tree", "-r", "--name-only", "-z", commit], cwd=repo, check=True, git_bin=git_bin)
        tracked = set(filter(None, res_tree.stdout.split("\0")))
        intersection = ignored_paths & tracked
        if intersection:
            colliding.update(intersection)

        for ign in ignored_paths:
            parts = ign.split("/")
            for i in range(1, len(parts)):
                if "/".join(parts[:i]) in tracked:
                    colliding.add(ign)

        for trk in tracked:
            parts = trk.split("/")
            for i in range(1, len(parts)):
                prefix = "/".join(parts[:i])
                if prefix in ignored_paths:
                    colliding.add(prefix)

    if colliding:
        raise RuntimeError(
            f"Operation aborted to prevent data loss: existing ignored file(s) would be overwritten or deleted: "
            f"{sorted(colliding)}"
        )


def verify_git_object_commit(
    repo: Path,
    sha: str,
    name: str = "commit",
    git_bin: str = "git",
) -> dict[str, Any]:
    """Verify that sha exists as a commit object and return its parents, tree, and message."""
    clean_sha = validate_git_sha(sha, name)
    res = run_git(["rev-parse", "--verify", "-q", f"{clean_sha}^{{commit}}"], cwd=repo, git_bin=git_bin)
    if res.returncode != 0:
        raise ValueError(f"{name} '{sha}' does not exist as a commit object in {repo}.")

    p_res = run_git(["rev-parse", f"{clean_sha}^@"], cwd=repo, check=True, git_bin=git_bin)
    parents = [p.strip() for p in p_res.stdout.splitlines() if p.strip()]

    t_res = run_git(["rev-parse", f"{clean_sha}^{{tree}}"], cwd=repo, check=True, git_bin=git_bin)
    tree = validate_git_sha(t_res.stdout.strip(), f"{name} tree")

    m_res = run_git(["log", "-1", "--format=%B", clean_sha], cwd=repo, check=True, git_bin=git_bin)
    msg = m_res.stdout
    if not msg.strip():
        raise ValueError(f"{name} '{sha}' has an empty commit message.")

    return {"sha": clean_sha, "tree": tree, "parents": parents, "message": msg}


def verify_git_ancestry(
    repo: Path,
    ancestor_sha: str,
    descendant_sha: str,
    desc: str = "Ancestry check",
    git_bin: str = "git",
) -> None:
    """Verify ancestor_sha is an ancestor of descendant_sha, failing closed on errors."""
    anc = validate_git_sha(ancestor_sha, "ancestor SHA")
    desc_sha = validate_git_sha(descendant_sha, "descendant SHA")
    res = run_git(["merge-base", "--is-ancestor", anc, desc_sha], cwd=repo, git_bin=git_bin)
    if res.returncode not in (0, 1):
        raise RuntimeError(f"git merge-base failed (exit {res.returncode}): {res.stderr.strip()}")
    if res.returncode != 0:
        raise ValueError(f"{desc}: commit '{anc}' is not an ancestor of '{desc_sha}'.")


def verify_nonempty_delta(
    repo: Path,
    base_sha: str,
    head_sha: str,
    desc: str = "Delta check",
    git_bin: str = "git",
) -> None:
    """Verify delta between base_sha and head_sha is nonempty, failing closed on errors."""
    b_sha = validate_git_sha(base_sha, "base commit SHA")
    h_sha = validate_git_sha(head_sha, "head commit SHA")

    b_tree = run_git(["rev-parse", f"{b_sha}^{{tree}}"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
    h_tree = run_git(["rev-parse", f"{h_sha}^{{tree}}"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
    if b_tree == h_tree:
        raise ValueError(f"{desc}: tree of '{h_sha}' is identical to base '{b_sha}' (empty delta).")

    res = run_git(["diff", "--quiet", b_sha, h_sha], cwd=repo, git_bin=git_bin)
    if res.returncode not in (0, 1):
        raise RuntimeError(f"git diff failed (exit {res.returncode}): {res.stderr.strip()}")
    if res.returncode == 0:
        raise ValueError(f"{desc}: diff between '{b_sha}' and '{h_sha}' is empty.")


def check_clean_worktree(repo: Path, git_bin: str = "git") -> None:
    """Verify repository has a valid HEAD and no unstaged tracked, staged, or untracked changes."""
    run_git(["update-index", "-q", "--refresh"], cwd=repo, check=True, git_bin=git_bin)

    diff_files = run_git(["diff-files", "--quiet"], cwd=repo, git_bin=git_bin)
    if diff_files.returncode not in (0, 1):
        raise RuntimeError(f"git diff-files failed (exit {diff_files.returncode}): {diff_files.stderr.strip()}")
    if diff_files.returncode == 1:
        names = run_git(["diff-files", "--name-status"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
        raise RuntimeError(f"Repository at {repo} has unstaged tracked changes:\n{names}")

    # HEAD must exist and be valid for every supported operation; fail closed on read errors!
    head_check = run_git(["rev-parse", "--verify", "-q", "HEAD"], cwd=repo, git_bin=git_bin)
    if head_check.returncode != 0:
        raise RuntimeError(
            f"Failed to verify HEAD in repository {repo} (exit {head_check.returncode}): {head_check.stderr.strip()}"
        )

    diff_cached = run_git(["diff-index", "--cached", "--quiet", "HEAD", "--"], cwd=repo, git_bin=git_bin)
    if diff_cached.returncode not in (0, 1):
        raise RuntimeError(
            f"git diff-index --cached failed (exit {diff_cached.returncode}): {diff_cached.stderr.strip()}"
        )
    if diff_cached.returncode == 1:
        names = run_git(
            ["diff-index", "--cached", "--name-status", "HEAD", "--"],
            cwd=repo,
            check=True,
            git_bin=git_bin,
        ).stdout.strip()
        raise RuntimeError(f"Repository at {repo} has staged uncommitted changes:\n{names}")

    untracked = run_git(["ls-files", "--others", "--exclude-standard"], cwd=repo, check=True, git_bin=git_bin)
    if untracked.stdout.strip():
        names = untracked.stdout.strip()
        raise RuntimeError(f"Repository at {repo} has untracked files:\n{names}")


def get_current_branch(repo: Path, git_bin: str = "git") -> str:
    """Return currently checked out branch name, rejecting detached HEAD and default branches."""
    res = run_git(["symbolic-ref", "-q", "--short", "HEAD"], cwd=repo, git_bin=git_bin)
    if res.returncode != 0:
        raise RuntimeError(
            f"Current HEAD in {repo} is detached; an explicit implementation branch is required."
        )
    branch = res.stdout.strip()
    if not branch:
        raise RuntimeError(f"Could not determine current branch in {repo}.")
    norm = branch.lower().removeprefix("refs/heads/")
    if norm in {"master", "main"}:
        raise RuntimeError(f"Cannot operate directly on default branch '{branch}' (master/main).")
    return branch


def validate_candidate_record(
    cand: dict[str, Any],
    repo: Path,
    git_bin: str = "git",
) -> dict[str, Any]:
    """Validate candidate record schema, types, and actual Git-object bindings in repository."""
    if not isinstance(cand, dict):
        raise ValueError("Candidate record must be a JSON object.")
    if cand.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"Candidate record has invalid schema_version: {cand.get('schema_version')}")
    if cand.get("record_type") != "candidate":
        raise ValueError(f"Candidate record has invalid record_type: '{cand.get('record_type')}'")
    if cand.get("status") != "prepared":
        raise ValueError(f"Candidate record has status '{cand.get('status')}', expected 'prepared'.")

    tid = validate_task_id(cand.get("task_id"))
    base_sha = validate_git_sha(cand.get("base_commit"), "candidate base_commit")
    reviewed_sha = validate_git_sha(cand.get("reviewed_head"), "candidate reviewed_head")
    reviewed_tree = validate_git_sha(cand.get("reviewed_tree"), "candidate reviewed_tree")
    sub_branch = validate_branch_name(cand.get("submission_branch"), git_bin=git_bin)
    impl_branch = validate_branch_name(cand.get("implementation_branch"), git_bin=git_bin)
    deps = validate_dependencies(cand.get("dependencies", []), current_task_id=tid)

    # Verify Git object bindings in repo
    verify_git_object_commit(repo, base_sha, "candidate base_commit", git_bin=git_bin)
    r_obj = verify_git_object_commit(repo, reviewed_sha, "candidate reviewed_head", git_bin=git_bin)
    if r_obj["tree"] != reviewed_tree:
        raise ValueError(
            f"Candidate reviewed_tree '{reviewed_tree}' does not match actual tree '{r_obj['tree']}' of reviewed_head '{reviewed_sha}'."
        )

    verify_git_ancestry(repo, base_sha, reviewed_sha, "Candidate base ancestry", git_bin=git_bin)
    verify_nonempty_delta(repo, base_sha, reviewed_sha, "Candidate nonempty delta", git_bin=git_bin)

    # Verify each dependency commit exists and is present in base_commit's ancestry
    for dep in deps:
        dep_sha = dep["accepted_sha"]
        verify_git_object_commit(repo, dep_sha, f"dependency '{dep['task_id']}' commit", git_bin=git_bin)
        verify_git_ancestry(
            repo,
            dep_sha,
            base_sha,
            f"Dependency '{dep['task_id']}' in task base ancestry",
            git_bin=git_bin,
        )

    return cand


def validate_submission_manifest(
    m: dict[str, Any],
    repo: Path,
    git_bin: str = "git",
) -> dict[str, Any]:
    """Validate submission manifest schema, types, evidence, and actual Git-object bindings."""
    if not isinstance(m, dict):
        raise ValueError("Submission manifest must be a JSON object.")
    if m.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"Submission manifest has invalid schema_version: {m.get('schema_version')}")
    if m.get("record_type") != "submission_manifest":
        raise ValueError(f"Submission manifest has invalid record_type: '{m.get('record_type')}'")
    if m.get("status") != "accepted":
        raise ValueError(f"Submission manifest has status '{m.get('status')}', expected 'accepted'.")

    tid = validate_task_id(m.get("task_id"))
    base_sha = validate_git_sha(m.get("base_commit"), "manifest base_commit")
    reviewed_sha = validate_git_sha(m.get("reviewed_head"), "manifest reviewed_head")
    reviewed_tree = validate_git_sha(m.get("reviewed_tree"), "manifest reviewed_tree")
    submitted_sha = validate_git_sha(m.get("submitted_sha"), "manifest submitted_sha")
    submitted_tree = validate_git_sha(m.get("submitted_tree"), "manifest submitted_tree")
    sub_branch = validate_branch_name(m.get("submission_branch"), git_bin=git_bin)

    if m.get("designer_accepted") is not True:
        raise ValueError(f"Submission manifest for task '{tid}' does not have designer_accepted set to true.")

    evidence = m.get("verification_evidence")
    if not isinstance(evidence, str) or not evidence.strip():
        raise ValueError(f"Submission manifest for task '{tid}' has missing or empty verification_evidence.")

    commit_msg = m.get("commit_message")
    if not isinstance(commit_msg, str) or not commit_msg.strip():
        raise ValueError(f"Submission manifest for task '{tid}' has missing or empty commit_message.")

    deps = validate_dependencies(m.get("dependencies", []), current_task_id=tid)

    # Git object bindings in repo
    verify_git_object_commit(repo, base_sha, "manifest base_commit", git_bin=git_bin)
    r_obj = verify_git_object_commit(repo, reviewed_sha, "manifest reviewed_head", git_bin=git_bin)
    if r_obj["tree"] != reviewed_tree:
        raise ValueError(
            f"Manifest reviewed_tree '{reviewed_tree}' does not match actual tree '{r_obj['tree']}' of reviewed_head '{reviewed_sha}'."
        )
    verify_git_ancestry(repo, base_sha, reviewed_sha, "Manifest reviewed_head ancestry", git_bin=git_bin)
    verify_nonempty_delta(repo, base_sha, reviewed_sha, "Manifest reviewed_head nonempty delta", git_bin=git_bin)

    s_obj = verify_git_object_commit(repo, submitted_sha, "manifest submitted_sha", git_bin=git_bin)
    if s_obj["tree"] != submitted_tree:
        raise ValueError(
            f"Manifest submitted_tree '{submitted_tree}' does not match actual tree '{s_obj['tree']}' of submitted_sha '{submitted_sha}'."
        )
    if submitted_tree != reviewed_tree:
        raise ValueError(
            f"Manifest submitted_tree '{submitted_tree}' does not match reviewed_tree '{reviewed_tree}'."
        )
    if len(s_obj["parents"]) != 1 or s_obj["parents"][0] != base_sha:
        raise ValueError(
            f"Manifest submitted_sha '{submitted_sha}' parents {s_obj['parents']} do not match base_commit '{base_sha}'."
        )
    if s_obj["message"].strip() != commit_msg.strip():
        raise ValueError(
            f"Manifest commit_message does not match actual commit message of submitted_sha '{submitted_sha}'."
        )

    # Verify submitted commit produces nonempty delta against base
    verify_nonempty_delta(repo, base_sha, submitted_sha, "Manifest submitted_sha nonempty delta", git_bin=git_bin)

    # Dependencies binding and ancestry
    for dep in deps:
        dep_sha = dep["accepted_sha"]
        verify_git_object_commit(repo, dep_sha, f"dependency '{dep['task_id']}' commit", git_bin=git_bin)
        verify_git_ancestry(
            repo,
            dep_sha,
            base_sha,
            f"Dependency '{dep['task_id']}' in task base ancestry",
            git_bin=git_bin,
        )

    return m


def cmd_prepare(
    repo_path: Path | str,
    task_id: str,
    base_ref: str,
    reviewed_ref: str,
    submission_branch: str,
    output_path: Path | str,
    implementation_branch: str,
    dependencies: list[dict[str, str]] | None = None,
    git_bin: str = "git",
) -> dict[str, Any]:
    """Prepare a submission branch from a reviewed implementation commit.

    1. Validates clean tree, explicit implementation branch, exact SHAs matching reviewed commit,
       base ancestor, nonempty diff, and absent target branch.
    2. Preflights existing ignored files to guarantee no data loss across branch switch and squash.
    3. Validates dependencies and their presence in base ancestry.
    4. Reserves output candidate record path before mutating Git state.
    5. Creates submission branch at base commit and squash-merges reviewed SHA without committing.
    6. Verifies resulting branch, HEAD, and that staged write-tree equals reviewed tree.
    7. On failure, preserves staged/conflicted work and records incomplete status without rollback.
    """
    repo = validate_repo_path(repo_path)
    tid = validate_task_id(task_id)

    # Exact immutable SHAs required; no symbolic refs
    base_sha = validate_git_sha(base_ref, "base commit SHA")
    reviewed_sha = validate_git_sha(reviewed_ref, "reviewed implementation SHA")

    # Explicit implementation branch required
    if not implementation_branch:
        raise ValueError("Explicit implementation branch is required.")
    exp_branch = validate_branch_name(implementation_branch, git_bin=git_bin)

    sub_branch = validate_branch_name(submission_branch, git_bin=git_bin)
    out_path = validate_record_path_outside_repo(output_path, repo)

    if out_path.exists():
        raise FileExistsError(
            f"Output candidate record path '{out_path}' already exists; refusing overwrite."
        )

    # Clean tree validation
    check_clean_worktree(repo, git_bin=git_bin)

    # Current branch validation
    cur_branch = get_current_branch(repo, git_bin=git_bin)
    if cur_branch != exp_branch:
        raise ValueError(
            f"Current branch '{cur_branch}' does not match implementation branch "
            f"'{exp_branch}' recorded by caller."
        )

    # Verify commits exist in repo
    verify_git_object_commit(repo, base_sha, "base commit SHA", git_bin=git_bin)
    r_obj = verify_git_object_commit(repo, reviewed_sha, "reviewed implementation SHA", git_bin=git_bin)
    reviewed_tree = r_obj["tree"]

    # Current HEAD must equal reviewed SHA
    head_sha = run_git(["rev-parse", "HEAD"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
    if head_sha != reviewed_sha:
        raise ValueError(
            f"Current HEAD commit '{head_sha}' does not match reviewed implementation SHA '{reviewed_sha}'."
        )

    # Base must be ancestor of reviewed SHA
    verify_git_ancestry(repo, base_sha, reviewed_sha, "Base commit check", git_bin=git_bin)

    # Nonempty diff between base and reviewed SHA
    verify_nonempty_delta(repo, base_sha, reviewed_sha, "Diff check", git_bin=git_bin)

    # Preflight existing ignored files: protect against silent data loss across switch/squash
    check_no_ignored_collisions(repo, [base_sha, reviewed_sha], git_bin=git_bin)

    # Target submission branch must not already exist (distinguishing absent from query error)
    check_ref_absent(repo, f"refs/heads/{sub_branch}", f"Target submission branch '{sub_branch}'", git_bin=git_bin)

    # Validate dependencies schema, uniqueness, non-self, and base ancestry
    deps = validate_dependencies(dependencies, current_task_id=tid)
    for dep in deps:
        dep_sha = dep["accepted_sha"]
        verify_git_object_commit(repo, dep_sha, f"dependency '{dep['task_id']}' commit", git_bin=git_bin)
        verify_git_ancestry(
            repo,
            dep_sha,
            base_sha,
            f"Dependency '{dep['task_id']}' in task base ancestry",
            git_bin=git_bin,
        )

    # Reserve candidate record before Git mutations
    candidate_record: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "record_type": "candidate",
        "task_id": tid,
        "repo": str(repo),
        "status": "incomplete",
        "base_commit": base_sha,
        "reviewed_head": reviewed_sha,
        "reviewed_tree": reviewed_tree,
        "implementation_branch": cur_branch,
        "submission_branch": sub_branch,
        "dependencies": deps,
        "created_at": iso_now(),
        "stage": "preparing",
        "error": None,
    }
    write_json_record(out_path, candidate_record, create_new=True)

    try:
        # Mutate Git: checkout submission branch at base with --no-overwrite-ignore
        co_res = run_git(["checkout", "--no-overwrite-ignore", "-b", sub_branch, base_sha], cwd=repo, git_bin=git_bin)
        if co_res.returncode != 0:
            err_msg = f"Failed to checkout submission branch '{sub_branch}' at '{base_sha}': {co_res.stderr.strip()}"
            candidate_record["error"] = err_msg
            candidate_record["stage"] = "checkout_failed"
            write_json_record(out_path, candidate_record)
            raise RuntimeError(err_msg)

        # Verify actual branch and HEAD after checkout
        act_branch = get_current_branch(repo, git_bin=git_bin)
        if act_branch != sub_branch:
            err_msg = f"Checkout created branch '{act_branch}', expected '{sub_branch}'."
            candidate_record["error"] = err_msg
            candidate_record["stage"] = "branch_mismatch"
            write_json_record(out_path, candidate_record)
            raise RuntimeError(err_msg)

        act_head = run_git(["rev-parse", "HEAD"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
        if act_head != base_sha:
            err_msg = f"Checkout produced HEAD '{act_head}', expected '{base_sha}'."
            candidate_record["error"] = err_msg
            candidate_record["stage"] = "head_mismatch"
            write_json_record(out_path, candidate_record)
            raise RuntimeError(err_msg)

        # Mutate Git: squash merge reviewed SHA with --no-overwrite-ignore
        merge_res = run_git(["merge", "--no-overwrite-ignore", "--squash", reviewed_sha], cwd=repo, git_bin=git_bin)
        if merge_res.returncode != 0:
            err_msg = f"git merge --squash {reviewed_sha} failed (exit {merge_res.returncode}): {merge_res.stderr.strip()}"
            candidate_record["error"] = err_msg
            candidate_record["stage"] = "merge_squash_failed"
            write_json_record(out_path, candidate_record)
            # Preserve staged/conflicted work in checkout; do not reset!
            raise RuntimeError(err_msg)

        # Verify actual branch and HEAD after squash merge
        act_branch = get_current_branch(repo, git_bin=git_bin)
        if act_branch != sub_branch:
            err_msg = f"Branch after squash merge is '{act_branch}', expected '{sub_branch}'."
            candidate_record["error"] = err_msg
            candidate_record["stage"] = "branch_mismatch"
            write_json_record(out_path, candidate_record)
            raise RuntimeError(err_msg)

        act_head = run_git(["rev-parse", "HEAD"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
        if act_head != base_sha:
            err_msg = f"HEAD after squash merge is '{act_head}', expected '{base_sha}'."
            candidate_record["error"] = err_msg
            candidate_record["stage"] = "head_mismatch"
            write_json_record(out_path, candidate_record)
            raise RuntimeError(err_msg)

        # Verify staged tree equals reviewed tree
        write_tree_res = run_git(["write-tree"], cwd=repo, check=True, git_bin=git_bin)
        staged_tree = validate_git_sha(write_tree_res.stdout.strip(), "staged tree")
        if staged_tree != reviewed_tree:
            err_msg = (
                f"Staged tree '{staged_tree}' after squash merge does not match reviewed tree '{reviewed_tree}'."
            )
            candidate_record["error"] = err_msg
            candidate_record["stage"] = "staged_tree_mismatch"
            write_json_record(out_path, candidate_record)
            raise RuntimeError(err_msg)

        # Successful preparation: mark prepared
        candidate_record["status"] = "prepared"
        candidate_record["stage"] = "prepared"
        candidate_record["error"] = None
        write_json_record(out_path, candidate_record)

    except Exception as e:
        if candidate_record.get("status") != "prepared":
            candidate_record["status"] = "incomplete"
            if not candidate_record.get("error"):
                candidate_record["error"] = str(e)
            write_json_record(out_path, candidate_record)
        raise

    return candidate_record


def cmd_accept(
    candidate_path: Path | str,
    output_path: Path | str,
    designer_accepted: bool,
    verification_evidence: str,
    repo_path: Path | str | None = None,
    dependencies: list[dict[str, str]] | None = None,
    git_bin: str = "git",
) -> dict[str, Any]:
    """Validate designer commit and produce accepted submission manifest.

    Verifies candidate record and its actual Git-object bindings, same repo/branch,
    clean worktree, exactly one non-merge commit whose parent is base, and final
    tree equals reviewed implementation tree. Refuses overwrite of existing accepted record.
    """
    c_path = Path(candidate_path)
    cand_raw = read_json_record(c_path)

    if not designer_accepted:
        raise ValueError("Explicit designer acceptance indicator (--accepted) is required to accept a submission.")
    if not isinstance(verification_evidence, str) or not verification_evidence.strip():
        raise ValueError("Verification evidence reference (--verification-evidence) cannot be empty.")

    cand_repo = Path(cand_raw["repo"])
    if repo_path is not None:
        user_repo = validate_repo_path(repo_path)
        if user_repo != cand_repo.resolve():
            raise ValueError(
                f"Specified repository '{user_repo}' does not match candidate record repo '{cand_repo}'."
            )
    repo = validate_repo_path(cand_repo)

    # Validate candidate record schema, types, and actual Git-object bindings in repo
    cand = validate_candidate_record(cand_raw, repo, git_bin=git_bin)

    out_path = validate_record_path_outside_repo(output_path, repo)
    if out_path.exists():
        raise FileExistsError(
            f"Output submission manifest '{out_path}' already exists; refusing overwrite."
        )

    # Verify clean worktree (fails closed if HEAD cannot be verified)
    check_clean_worktree(repo, git_bin=git_bin)

    # Verify current branch is submission branch
    cur_branch = get_current_branch(repo, git_bin=git_bin)
    if cur_branch != cand["submission_branch"]:
        raise ValueError(
            f"Current branch '{cur_branch}' does not match candidate submission branch '{cand['submission_branch']}'."
        )

    # Verify HEAD commit
    head_sha = run_git(["rev-parse", "HEAD"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
    s_obj = verify_git_object_commit(repo, head_sha, "HEAD commit", git_bin=git_bin)

    if len(s_obj["parents"]) == 0:
        raise ValueError(
            f"HEAD commit '{head_sha}' is a root commit without parents; expected parent '{cand['base_commit']}'."
        )
    if len(s_obj["parents"]) > 1:
        raise ValueError(f"HEAD commit '{head_sha}' is a merge commit with multiple parents: {s_obj['parents']}.")
    if s_obj["parents"][0] != cand["base_commit"]:
        raise ValueError(
            f"HEAD commit's parent '{s_obj['parents'][0]}' does not match candidate base commit '{cand['base_commit']}'."
        )

    count_res = run_git(
        ["rev-list", "--count", f"{cand['base_commit']}..HEAD"],
        cwd=repo,
        check=True,
        git_bin=git_bin,
    )
    if count_res.stdout.strip() != "1":
        raise ValueError(
            f"Expected exactly 1 commit between base '{cand['base_commit']}' and HEAD, found '{count_res.stdout.strip()}'."
        )

    # Verify tree equals reviewed implementation tree
    head_tree = s_obj["tree"]
    if head_tree != cand["reviewed_tree"]:
        raise ValueError(
            f"Submitted commit tree '{head_tree}' does not match reviewed implementation tree '{cand['reviewed_tree']}'."
        )

    # Verify submitted commit produces nonempty delta against base
    verify_nonempty_delta(repo, cand["base_commit"], head_sha, "Submitted commit nonempty delta", git_bin=git_bin)

    # Resolve and validate dependencies
    raw_deps = dependencies if dependencies is not None else cand.get("dependencies", [])
    deps = validate_dependencies(raw_deps, current_task_id=cand["task_id"])
    for dep in deps:
        dep_sha = dep["accepted_sha"]
        verify_git_object_commit(repo, dep_sha, f"dependency '{dep['task_id']}' commit", git_bin=git_bin)
        verify_git_ancestry(
            repo,
            dep_sha,
            cand["base_commit"],
            f"Dependency '{dep['task_id']}' in task base ancestry",
            git_bin=git_bin,
        )

    commit_msg = s_obj["message"]

    manifest: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "record_type": "submission_manifest",
        "task_id": cand["task_id"],
        "repo": str(repo),
        "status": "accepted",
        "base_commit": cand["base_commit"],
        "reviewed_head": cand["reviewed_head"],
        "reviewed_tree": cand["reviewed_tree"],
        "submission_branch": cand["submission_branch"],
        "submitted_sha": head_sha,
        "submitted_tree": head_tree,
        "commit_message": commit_msg,
        "dependencies": deps,
        "designer_accepted": True,
        "verification_evidence": verification_evidence.strip(),
        "accepted_at": iso_now(),
    }
    write_json_record(out_path, manifest, create_new=True)

    return manifest


def cmd_assemble(
    repo_path: Path | str,
    base_ref: str,
    pr_branch: str,
    manifest_paths: list[Path | str],
    output_path: Path | str,
    git_bin: str = "git",
) -> dict[str, Any]:
    """Assemble multiple accepted task submissions onto a new PR branch.

    Validates dependency chains, prevents hidden history, safe fast-forwards
    matching parent SHAs, cherry-picks independent commits, stops immediately
    on conflicts preserving inspectable state, and writes an assembly record.
    """
    repo = validate_repo_path(repo_path)
    branch_name = validate_branch_name(pr_branch, git_bin=git_bin)
    out_path = validate_record_path_outside_repo(output_path, repo)

    if out_path.exists():
        raise FileExistsError(
            f"Output assembly record '{out_path}' already exists; refusing overwrite."
        )

    if not manifest_paths:
        raise ValueError("At least one submission manifest path is required for assembly.")

    # Clean worktree validation in integration clone
    check_clean_worktree(repo, git_bin=git_bin)

    # Base SHA validation in repo
    base_sha = validate_git_sha(base_ref, "explicit assembly base SHA")
    verify_git_object_commit(repo, base_sha, "explicit assembly base", git_bin=git_bin)

    # Read and validate manifests with full schema and Git bindings
    manifests: list[dict[str, Any]] = []
    seen_task_ids: set[str] = set()
    seen_submitted_shas: set[str] = set()

    for p in manifest_paths:
        m_path = Path(p)
        m_raw = read_json_record(m_path)
        m = validate_submission_manifest(m_raw, repo, git_bin=git_bin)

        tid = m["task_id"]
        if tid in seen_task_ids:
            raise ValueError(f"Duplicate task ID '{tid}' found in input manifests.")
        seen_task_ids.add(tid)

        ssha = m["submitted_sha"]
        if ssha in seen_submitted_shas:
            raise ValueError(f"Duplicate submitted SHA '{ssha}' found in input manifests.")
        seen_submitted_shas.add(ssha)

        manifests.append(m)

    # Preflight existing ignored files against all target commits
    all_target_commits = [base_sha] + [m["submitted_sha"] for m in manifests]
    check_no_ignored_collisions(repo, all_target_commits, git_bin=git_bin)

    # PR branch must not already exist (distinguishing absent from query error)
    check_ref_absent(repo, f"refs/heads/{branch_name}", f"Target PR branch '{branch_name}'", git_bin=git_bin)

    # Validate dependency chains and base consistency
    processed_tasks: dict[str, str] = {}  # task_id -> submitted_sha
    for m in manifests:
        tid = m["task_id"]
        t_base = m["base_commit"]
        t_deps = m.get("dependencies", [])

        dep_shas = set()
        for dep in t_deps:
            dep_id = dep["task_id"]
            dep_sha = dep["accepted_sha"]
            if dep_id not in processed_tasks:
                raise ValueError(
                    f"Task '{tid}' depends on '{dep_id}', but '{dep_id}' does not precede it in manifest order."
                )
            if processed_tasks[dep_id] != dep_sha:
                raise ValueError(
                    f"Task '{tid}' declared dependency on '{dep_id}' at SHA '{dep_sha}', "
                    f"but '{dep_id}' submitted SHA is '{processed_tasks[dep_id]}'."
                )
            # Verify dependency is an ancestor of task base commit
            verify_git_ancestry(
                repo,
                dep_sha,
                t_base,
                f"Dependency '{dep_id}' in base ancestry of '{tid}'",
                git_bin=git_bin,
            )
            dep_shas.add(dep_sha)

        valid_bases = {base_sha} | dep_shas
        if t_base not in valid_bases:
            raise ValueError(
                f"Task '{tid}' has base_commit '{t_base}' which is neither the assembly base '{base_sha}' "
                f"nor any declared dependency accepted SHA ({sorted(dep_shas)})."
            )

        processed_tasks[tid] = m["submitted_sha"]

    # Reserve assembly record before Git mutations
    assembly_record: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "record_type": "assembly_record",
        "repo": str(repo),
        "status": "incomplete",
        "base_commit": base_sha,
        "pr_branch": branch_name,
        "manifests": [str(Path(p).resolve()) for p in manifest_paths],
        "assembled_commits": [],
        "sha_mapping": {},
        "created_at": iso_now(),
        "stage": "assembling",
        "error": None,
    }
    write_json_record(out_path, assembly_record, create_new=True)

    try:
        # Create PR branch at base with --no-overwrite-ignore
        co_res = run_git(["checkout", "--no-overwrite-ignore", "-b", branch_name, base_sha], cwd=repo, git_bin=git_bin)
        if co_res.returncode != 0:
            err_msg = f"Failed to checkout new PR branch '{branch_name}' at base '{base_sha}': {co_res.stderr.strip()}"
            assembly_record["error"] = err_msg
            assembly_record["stage"] = "checkout_failed"
            write_json_record(out_path, assembly_record)
            raise RuntimeError(err_msg)

        # Verify actual branch and HEAD after checkout
        act_branch = get_current_branch(repo, git_bin=git_bin)
        if act_branch != branch_name:
            err_msg = f"Checkout created branch '{act_branch}', expected '{branch_name}'."
            assembly_record["error"] = err_msg
            assembly_record["stage"] = "branch_mismatch"
            write_json_record(out_path, assembly_record)
            raise RuntimeError(err_msg)

        act_head = run_git(["rev-parse", "HEAD"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
        if act_head != base_sha:
            err_msg = f"Checkout produced HEAD '{act_head}', expected '{base_sha}'."
            assembly_record["error"] = err_msg
            assembly_record["stage"] = "head_mismatch"
            write_json_record(out_path, assembly_record)
            raise RuntimeError(err_msg)

        current_head = base_sha

        # Apply task commits in order
        for m in manifests:
            tid = m["task_id"]
            sub_sha = m["submitted_sha"]
            sub_parent = m["base_commit"]
            sub_tree = m["submitted_tree"]

            # Current tree before applying
            cur_tree = run_git(["rev-parse", "HEAD^{tree}"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()

            # Reject empty tasks on BOTH fast-forward and cherry-pick paths!
            if cur_tree == sub_tree:
                err_msg = (
                    f"Task '{tid}' application is empty or duplicate "
                    "(current tree already equals submitted tree before application)."
                )
                assembly_record["error"] = err_msg
                assembly_record["stage"] = "empty_duplicate_rejected"
                assembly_record["failed_task_id"] = tid
                write_json_record(out_path, assembly_record)
                raise RuntimeError(err_msg)

            parent_tree = run_git(["rev-parse", f"{sub_parent}^{{tree}}"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
            if sub_tree == parent_tree:
                err_msg = f"Task '{tid}' is an empty submission (submitted tree equals parent tree)."
                assembly_record["error"] = err_msg
                assembly_record["stage"] = "empty_submission_rejected"
                assembly_record["failed_task_id"] = tid
                write_json_record(out_path, assembly_record)
                raise RuntimeError(err_msg)

            if current_head == sub_parent:
                # Safe fast-forward
                ff_res = run_git(["merge", "--ff-only", sub_sha], cwd=repo, git_bin=git_bin)
                if ff_res.returncode != 0:
                    err_msg = f"Fast-forward merge failed for task '{tid}' ({sub_sha}): {ff_res.stderr.strip()}"
                    assembly_record["error"] = err_msg
                    assembly_record["stage"] = "fast_forward_failed"
                    assembly_record["failed_task_id"] = tid
                    write_json_record(out_path, assembly_record)
                    raise RuntimeError(err_msg)
                method = "fast-forward"
            else:
                # Cherry-pick
                cp_res = run_git(["cherry-pick", sub_sha], cwd=repo, git_bin=git_bin)
                if cp_res.returncode != 0:
                    st_out = run_git(["status", "--porcelain"], cwd=repo, git_bin=git_bin).stdout.strip()
                    err_msg = (
                        f"Cherry-pick conflict applying task '{tid}' ({sub_sha}):\n"
                        f"{cp_res.stderr.strip()}\n{st_out}"
                    )
                    assembly_record["error"] = err_msg
                    assembly_record["stage"] = "conflict"
                    assembly_record["failed_task_id"] = tid
                    assembly_record["failed_submitted_sha"] = sub_sha
                    write_json_record(out_path, assembly_record)
                    # Stop immediately, leave conflict and diagnostic record, never auto-abort/reset
                    raise RuntimeError(err_msg)
                method = "cherry-pick"

            # Check actual branch and HEAD after EVERY apply (detecting no-op ff or unexpected ref state)
            act_branch = get_current_branch(repo, git_bin=git_bin)
            if act_branch != branch_name:
                err_msg = f"Current branch '{act_branch}' does not match PR branch '{branch_name}' after applying task '{tid}'."
                assembly_record["error"] = err_msg
                assembly_record["stage"] = "branch_mismatch"
                assembly_record["failed_task_id"] = tid
                write_json_record(out_path, assembly_record)
                raise RuntimeError(err_msg)

            actual_head = run_git(["rev-parse", "HEAD"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
            if method == "fast-forward":
                if actual_head != sub_sha:
                    err_msg = (
                        f"Fast-forward merge of task '{tid}' failed to advance HEAD to '{sub_sha}' "
                        f"(actual HEAD: '{actual_head}')."
                    )
                    assembly_record["error"] = err_msg
                    assembly_record["stage"] = "head_not_advanced"
                    assembly_record["failed_task_id"] = tid
                    write_json_record(out_path, assembly_record)
                    raise RuntimeError(err_msg)
            else:
                if actual_head == current_head:
                    err_msg = f"Cherry-pick of task '{tid}' failed to advance HEAD from '{current_head}'."
                    assembly_record["error"] = err_msg
                    assembly_record["stage"] = "head_not_advanced"
                    assembly_record["failed_task_id"] = tid
                    write_json_record(out_path, assembly_record)
                    raise RuntimeError(err_msg)

            assembled_sha = actual_head

            # Post-application verification on assembled commit:
            res_obj = verify_git_object_commit(repo, assembled_sha, f"assembled commit for task '{tid}'", git_bin=git_bin)
            if len(res_obj["parents"]) != 1 or res_obj["parents"][0] != current_head:
                err_msg = (
                    f"Assembled commit '{assembled_sha}' parent {res_obj['parents']} "
                    f"does not match previous HEAD '{current_head}'."
                )
                assembly_record["error"] = err_msg
                assembly_record["stage"] = "parent_mismatch"
                assembly_record["failed_task_id"] = tid
                write_json_record(out_path, assembly_record)
                raise RuntimeError(err_msg)

            if res_obj["message"].strip() != m["commit_message"].strip():
                err_msg = (
                    f"Assembled commit message for task '{tid}' does not match manifest commit message."
                )
                assembly_record["error"] = err_msg
                assembly_record["stage"] = "message_mismatch"
                assembly_record["failed_task_id"] = tid
                write_json_record(out_path, assembly_record)
                raise RuntimeError(err_msg)

            new_tree = res_obj["tree"]
            if new_tree == cur_tree:
                err_msg = f"Task '{tid}' application produced an empty commit (tree unchanged)."
                assembly_record["error"] = err_msg
                assembly_record["stage"] = "empty_application"
                assembly_record["failed_task_id"] = tid
                write_json_record(out_path, assembly_record)
                raise RuntimeError(err_msg)

            # Verify clean state after commit
            check_clean_worktree(repo, git_bin=git_bin)

            current_head = assembled_sha
            assembly_record["assembled_commits"].append({
                "task_id": tid,
                "submitted_sha": sub_sha,
                "assembled_sha": assembled_sha,
                "method": method,
            })
            assembly_record["sha_mapping"][sub_sha] = assembled_sha

        # Before marking prepared, verify recorded state matches actual Git branch, HEAD, and clean state
        final_branch = get_current_branch(repo, git_bin=git_bin)
        if final_branch != branch_name:
            err_msg = f"Final branch '{final_branch}' does not match expected PR branch '{branch_name}'."
            assembly_record["error"] = err_msg
            assembly_record["stage"] = "branch_mismatch"
            write_json_record(out_path, assembly_record)
            raise RuntimeError(err_msg)

        final_head = run_git(["rev-parse", "HEAD"], cwd=repo, check=True, git_bin=git_bin).stdout.strip()
        if final_head != current_head:
            err_msg = f"Final HEAD '{final_head}' does not match recorded last commit '{current_head}'."
            assembly_record["error"] = err_msg
            assembly_record["stage"] = "head_mismatch"
            write_json_record(out_path, assembly_record)
            raise RuntimeError(err_msg)

        check_clean_worktree(repo, git_bin=git_bin)

        # Successful assembly is only prepared, not independently verified or publishable
        assembly_record["status"] = "prepared"
        assembly_record["stage"] = "prepared"
        assembly_record["error"] = None
        assembly_record["assembled_at"] = iso_now()
        write_json_record(out_path, assembly_record)

    except Exception as e:
        if assembly_record.get("status") != "prepared":
            assembly_record["status"] = "incomplete"
            if not assembly_record.get("error"):
                assembly_record["error"] = str(e)
            write_json_record(out_path, assembly_record)
        raise

    return assembly_record


def build_parser() -> argparse.ArgumentParser:
    """Build command-line parser with prepare, accept, and assemble subcommands."""
    parser = argparse.ArgumentParser(
        prog="submit.py",
        description="Reviewed task submissions and multi-task assembly helper.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # prepare
    p_prep = subparsers.add_parser("prepare", help="Prepare a submission branch from reviewed implementation commit.")
    p_prep.add_argument("--repo", default=".", help="Path to repository checkout (default: current directory)")
    p_prep.add_argument("--task-id", required=True, help="Explicit task ID")
    p_prep.add_argument("--base", "--base-sha", required=True, help="Base commit SHA (exact 40-char hex)")
    p_prep.add_argument(
        "--reviewed-sha", "--reviewed-head", "--head",
        required=True,
        help="Reviewed implementation commit SHA (exact 40-char hex)",
    )
    p_prep.add_argument("--submission-branch", "--branch", required=True, help="New submission branch name")
    p_prep.add_argument("--output", "--record", "--candidate-record", required=True, help="Path for candidate record outside repo")
    p_prep.add_argument("--implementation-branch", required=True, help="Explicit implementation branch name to verify")
    p_prep.add_argument("--dependency", action="append", default=[], help="Dependency in TASK_ID:SHA format (repeatable)")
    p_prep.add_argument("--dependency-manifest", action="append", default=[], help="Path to dependency submission manifest (repeatable)")
    p_prep.add_argument("--git-bin", default=os.environ.get("GIT_BIN", "git"), help="Path to git binary")

    # accept
    p_acc = subparsers.add_parser("accept", help="Validate designer commit and record accepted submission manifest.")
    p_acc.add_argument("--candidate", "--candidate-record", "--record", required=True, help="Path to candidate record")
    p_acc.add_argument("--output", "--manifest", "--submission-manifest", required=True, help="Path for output submission manifest")
    p_acc.add_argument("--accepted", "--designer-accepted", action="store_true", help="Explicit designer acceptance indicator")
    p_acc.add_argument("--verification-evidence", "--evidence", required=True, help="Reference or description of verification evidence")
    p_acc.add_argument("--repo", help="Optional repository path (defaults to repo in candidate record)")
    p_acc.add_argument("--dependency", action="append", default=[], help="Dependency in TASK_ID:SHA format (repeatable)")
    p_acc.add_argument("--dependency-manifest", action="append", default=[], help="Path to dependency submission manifest (repeatable)")
    p_acc.add_argument("--git-bin", default=os.environ.get("GIT_BIN", "git"), help="Path to git binary")

    # assemble
    p_ass = subparsers.add_parser("assemble", help="Assemble multiple task submissions onto a new PR branch.")
    p_ass.add_argument("--repo", required=True, help="Path to clean integration clone")
    p_ass.add_argument("--base", "--base-sha", required=True, help="Explicit base commit SHA (exact 40-char hex)")
    p_ass.add_argument("--branch", "--pr-branch", required=True, help="New PR branch name")
    p_ass.add_argument("--manifests", nargs="*", default=[], help="Ordered manifest paths")
    p_ass.add_argument("--manifest", action="append", default=[], help="Manifest path (repeatable)")
    p_ass.add_argument("--output", "--record", "--assembly-record", required=True, help="Path for output assembly record")
    p_ass.add_argument("--git-bin", default=os.environ.get("GIT_BIN", "git"), help="Path to git binary")

    return parser


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "prepare":
            deps = [parse_dependency(d) for d in args.dependency]
            for dm in args.dependency_manifest:
                deps.append(load_dependency_from_manifest(dm))

            rec = cmd_prepare(
                repo_path=args.repo,
                task_id=args.task_id,
                base_ref=args.base,
                reviewed_ref=args.reviewed_sha,
                submission_branch=args.submission_branch,
                output_path=args.output,
                implementation_branch=args.implementation_branch,
                dependencies=deps,
                git_bin=args.git_bin,
            )
            print(f"Prepared submission candidate: task={rec['task_id']} branch={rec['submission_branch']}")
            return 0

        elif args.command == "accept":
            deps = [parse_dependency(d) for d in args.dependency] if args.dependency else None
            if args.dependency_manifest:
                if deps is None:
                    deps = []
                for dm in args.dependency_manifest:
                    deps.append(load_dependency_from_manifest(dm))

            rec = cmd_accept(
                candidate_path=args.candidate,
                output_path=args.output,
                designer_accepted=args.accepted,
                verification_evidence=args.verification_evidence,
                repo_path=args.repo,
                dependencies=deps,
                git_bin=args.git_bin,
            )
            print(f"Accepted submission: task={rec['task_id']} sha={rec['submitted_sha']}")
            return 0

        elif args.command == "assemble":
            all_manifests = list(args.manifests) + list(args.manifest)
            if not all_manifests:
                raise ValueError("At least one submission manifest is required for assembly (--manifests or --manifest).")

            rec = cmd_assemble(
                repo_path=args.repo,
                base_ref=args.base,
                pr_branch=args.branch,
                manifest_paths=all_manifests,
                output_path=args.output,
                git_bin=args.git_bin,
            )
            print(f"Prepared assembled PR branch: {rec['pr_branch']} ({len(rec['assembled_commits'])} commits)")
            return 0

        else:
            parser.print_help(sys.stderr)
            return 2

    except Exception as e:
        sys.stderr.write(f"error: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
