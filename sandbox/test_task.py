#!/usr/bin/env python3
"""Comprehensive unit and integration tests for task Sandbox lifecycle management.

Covers review-1 and review-2 findings:
- Finding 1: Streaming SHA256 verification and mode verification of tar archives,
             rejection of duplicate members, traversal ('..') and absolute paths,
             and anchored root .git exclusion (--exclude=./.git).
- Finding 2: Staged-vs-worktree preservation (staged.patch) and bare repo index reconstruction
             verification via GIT_INDEX_FILE, git read-tree, and git apply --cached;
             rejection of unmerged conflicts (git ls-files -u).
- Finding 3: Exact bundle ref and HEAD identity without commit peeling;
             annotated tags and blob tags supported; fetching HEAD into FETCH_HEAD.
- Finding 4: Preconditions and harness isolation: exclusive new destination (exist_ok=False),
             guest harness path validation (canonical, absolute, mutually disjoint from repo and staging),
             directory walk error propagation (onerror=raise), special file detection.
- Finding 5: Failure atomicity and diagnostic retention: guest staging retained on failure,
             failure receipt.json recorded with guest_stage, cleanup only on verified success.
- Finding 6: Full test suite covering all positive and negative execution paths.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from sandbox import task

ORIG_SUBPROCESS_RUN = subprocess.run


def create_test_git_repo(path: Path) -> str:
    """Initialize a real git repository with initial commit and return commit SHA."""
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-b", "trunk", str(path)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(path), "config", "user.name", "Tester"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "test@example.com"], check=True)
    (path / "README.md").write_text("# Test Repo\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(path), "add", "README.md"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(path), "commit", "-m", "Initial commit"], check=True, capture_output=True)
    res = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    )
    return res.stdout.strip()


class FakeSbxManager:
    """In-memory simulated sbx state dispatch for testing task.py."""

    def __init__(self, temp_dir: Path):
        self.temp_dir = temp_dir
        self.sandboxes: dict[str, dict] = {}
        self.exec_calls: list[list[str]] = []
        self.cp_calls: list[list[str]] = []
        self.ls_calls: list[list[str]] = []
        self.stop_calls: list[list[str]] = []
        self.rm_calls: list[list[str]] = []
        self.corrupt_bundle_transfer = False
        self.corrupt_staged_patch_transfer = False
        self.corrupt_worktree_transfer = False
        self.mutate_source_during_tar = False
        self.mutate_harness_during_tar = False
        self.mutate_during_transfer = False
        self.on_rm_callback: Any = None
        self.fail_git_fetch = False

    def dispatch(self, cmd: list[str], *args, **kwargs):
        if not cmd:
            return ORIG_SUBPROCESS_RUN(cmd, *args, **kwargs)

        if cmd[0] == "git" and "fetch" in cmd and getattr(self, "fail_git_fetch", False):
            res = subprocess.CompletedProcess(cmd, 128, stdout="", stderr="fatal: bundle fetch failed\n")
            if kwargs.get("check"):
                raise subprocess.CalledProcessError(res.returncode, cmd, output=res.stdout, stderr=res.stderr)
            return res

        if cmd[0] != "sbx":
            return ORIG_SUBPROCESS_RUN(cmd, *args, **kwargs)

        res = self._handle_sbx(cmd, *args, **kwargs)
        if kwargs.get("check") and res.returncode != 0:
            raise subprocess.CalledProcessError(res.returncode, cmd, output=res.stdout, stderr=res.stderr)
        return res

    def _handle_sbx(self, cmd: list[str], *args, **kwargs):
        subcommand = cmd[1]
        if subcommand == "ls":
            self.ls_calls.append(cmd)
            items = []
            for name, data in self.sandboxes.items():
                items.append({
                    "name": name,
                    "id": data["id"],
                    "status": data["status"],
                    "ports": data.get("ports", []),
                })
            return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(items), stderr="")

        elif subcommand == "create":
            name = None
            host_repo = None
            i = 2
            while i < len(cmd):
                if cmd[i] == "--name":
                    name = cmd[i + 1]
                    i += 2
                elif cmd[i] == "--kit":
                    host_repo = cmd[i + 3]
                    i += 4
                else:
                    i += 1

            if not name:
                raise ValueError("Missing --name in sbx create")
            if name in self.sandboxes:
                return subprocess.CompletedProcess(cmd, 1, stdout="", stderr=f"Sandbox {name} already exists\n")

            guest_fs = self.temp_dir / f"guest_{name}"
            guest_fs.mkdir(parents=True, exist_ok=True)
            (guest_fs / "tmp").mkdir(parents=True, exist_ok=True)

            guest_harness_task = guest_fs / f"home/agent/.local/state/agent-harness/{name}"
            guest_harness_task.mkdir(parents=True, exist_ok=True)
            guest_harness = guest_fs / "home/agent/.local/state/agent-harness"
            guest_harness.mkdir(parents=True, exist_ok=True)

            host_repo_path = Path(host_repo).resolve()
            guest_repo_path = guest_fs / host_repo_path.relative_to(host_repo_path.anchor)
            guest_repo_path.parent.mkdir(parents=True, exist_ok=True)
            ORIG_SUBPROCESS_RUN(["git", "clone", str(host_repo_path), str(guest_repo_path)], check=True, capture_output=True)
            ORIG_SUBPROCESS_RUN(["git", "-C", str(guest_repo_path), "config", "user.name", "Tester"], check=True)
            ORIG_SUBPROCESS_RUN(["git", "-C", str(guest_repo_path), "config", "user.email", "test@example.com"], check=True)

            self.sandboxes[name] = {
                "id": f"sbx-uuid-{name}-001",
                "status": "stopped",
                "guest_fs": guest_fs,
                "host_repo": host_repo_path,
                "guest_repo": guest_repo_path,
                "guest_repo_str": str(host_repo_path),
                "guest_harness": guest_harness_task,
                "guest_harness_str": f"/home/agent/.local/state/agent-harness/{name}",
            }
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        elif subcommand == "run":
            name = None
            for idx, arg in enumerate(cmd):
                if arg == "--name" and idx + 1 < len(cmd):
                    name = cmd[idx + 1]
            if not name or name not in self.sandboxes:
                return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="Sandbox not found\n")
            self.sandboxes[name]["status"] = "running"
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        elif subcommand == "stop":
            self.stop_calls.append(cmd)
            name = cmd[2]
            if name not in self.sandboxes:
                return subprocess.CompletedProcess(cmd, 1, stdout="", stderr=f"Sandbox {name} not found\n")
            self.sandboxes[name]["status"] = "stopped"
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        elif subcommand == "rm":
            self.rm_calls.append(cmd)
            args = [a for a in cmd[2:] if not a.startswith("-")]
            if not args:
                return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="Missing sandbox name\n")
            name = args[0]
            if name not in self.sandboxes:
                return subprocess.CompletedProcess(cmd, 1, stdout="", stderr=f"Sandbox {name} not found\n")
            del self.sandboxes[name]
            if getattr(self, "on_rm_callback", None):
                self.on_rm_callback(name)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        elif subcommand == "exec":
            self.exec_calls.append(cmd)
            name = cmd[2]
            inner_cmd = cmd[3:]
            if name not in self.sandboxes:
                return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="Sandbox not found\n")
            box = self.sandboxes[name]
            guest_fs = box["guest_fs"]
            guest_repo = box["guest_repo"]
            guest_repo_str = box["guest_repo_str"]
            guest_harness = box["guest_harness"]
            guest_harness_str = box["guest_harness_str"]

            def to_host_path(p: str) -> str:
                if p.startswith("--output="):
                    prefix, path_val = p.split("=", 1)
                    return prefix + "=" + to_host_path(path_val)
                if p == guest_repo_str or p.startswith(guest_repo_str + "/"):
                    rel = p[len(guest_repo_str):].lstrip("/")
                    return str(guest_repo / rel) if rel else str(guest_repo)
                if p.startswith("/tmp/"):
                    return str(guest_fs / p.lstrip("/"))
                if p.startswith("/"):
                    return str(guest_fs / p.lstrip("/"))
                return p

            def to_guest_stdout(text: str) -> str:
                text = text.replace(str(guest_repo), guest_repo_str)
                text = text.replace(str(guest_fs), "")
                return text

            if inner_cmd == ["pwd"]:
                return subprocess.CompletedProcess(cmd, 0, stdout="/home/agent\n", stderr="")

            elif inner_cmd[0] == "mktemp":
                if "-d" in inner_cmd:
                    p = tempfile.mkdtemp(prefix="preserve.", dir=guest_fs / "tmp")
                    rel = "/tmp/" + os.path.basename(p)
                    return subprocess.CompletedProcess(cmd, 0, stdout=rel + "\n", stderr="")
                else:
                    fd, p = tempfile.mkstemp(prefix="dep.", suffix=".bundle", dir=guest_fs / "tmp")
                    os.close(fd)
                    rel = "/tmp/" + os.path.basename(p)
                    return subprocess.CompletedProcess(cmd, 0, stdout=rel + "\n", stderr="")

            elif inner_cmd[0] == "git":
                real_cmd = [to_host_path(c) for c in inner_cmd]
                res = ORIG_SUBPROCESS_RUN(real_cmd, capture_output=True, text=True)
                stdout = to_guest_stdout(res.stdout) if res.stdout else ""
                stderr = to_guest_stdout(res.stderr) if res.stderr else ""
                return subprocess.CompletedProcess(cmd, res.returncode, stdout=stdout, stderr=stderr)

            elif inner_cmd[0] == "python3" and inner_cmd[1] == "-c":
                script = inner_cmd[2]
                cmd_args = [to_host_path(c) for c in inner_cmd[3:]]
                res = ORIG_SUBPROCESS_RUN(
                    [sys.executable, "-c", script] + cmd_args,
                    capture_output=True,
                    text=True,
                )
                return subprocess.CompletedProcess(cmd, res.returncode, stdout=res.stdout, stderr=res.stderr)

            elif inner_cmd[0] == "tar":
                real_cmd = [to_host_path(c) for c in inner_cmd]
                if self.mutate_source_during_tar and "worktree.tar.gz" in str(real_cmd):
                    (guest_repo / "sneaky_change.txt").write_text("concurrent edit\n")
                if self.mutate_harness_during_tar and "harness.tar.gz" in str(real_cmd):
                    (guest_harness / "sneaky_log.txt").write_text("concurrent harness log\n")
                res = ORIG_SUBPROCESS_RUN(real_cmd, capture_output=True, text=True)
                return subprocess.CompletedProcess(cmd, res.returncode, stdout=res.stdout, stderr=res.stderr)

            elif inner_cmd[0] == "sha256sum":
                real_file = Path(to_host_path(inner_cmd[1]))
                data = real_file.read_bytes()
                h = hashlib.sha256(data).hexdigest()
                return subprocess.CompletedProcess(cmd, 0, stdout=f"{h}  {inner_cmd[1]}\n", stderr="")

            elif inner_cmd[0] in ("mkdir", "rm"):
                real_cmd = [to_host_path(c) for c in inner_cmd]
                res = ORIG_SUBPROCESS_RUN(real_cmd, capture_output=True, text=True)
                return subprocess.CompletedProcess(cmd, res.returncode, stdout=res.stdout, stderr=res.stderr)

            elif inner_cmd[0] == "test" and inner_cmd[1] == "-d":
                real_dir = Path(to_host_path(inner_cmd[2]))
                code = 0 if real_dir.is_dir() else 1
                return subprocess.CompletedProcess(cmd, code, stdout="", stderr="")

            real_cmd = [to_host_path(c) for c in inner_cmd]
            res = ORIG_SUBPROCESS_RUN(real_cmd, capture_output=True, text=True)
            return subprocess.CompletedProcess(
                cmd,
                res.returncode,
                stdout=to_guest_stdout(res.stdout),
                stderr=to_guest_stdout(res.stderr),
            )

        elif subcommand == "cp":
            self.cp_calls.append(cmd)
            src, dst = cmd[2], cmd[3]
            if ":" in src:
                b_name, b_path = src.split(":", 1)
                guest_fs = self.sandboxes[b_name]["guest_fs"]
                guest_repo = self.sandboxes[b_name]["guest_repo"]
                guest_repo_str = self.sandboxes[b_name]["guest_repo_str"]
                guest_harness = self.sandboxes[b_name]["guest_harness"]
                guest_harness_str = self.sandboxes[b_name]["guest_harness_str"]
                if b_path.startswith("/tmp/"):
                    real_src = guest_fs / b_path.lstrip("/")
                elif b_path == guest_repo_str or b_path.startswith(guest_repo_str + "/"):
                    rel = b_path[len(guest_repo_str):].lstrip("/")
                    real_src = guest_repo / rel if rel else guest_repo
                elif b_path.startswith("/"):
                    real_src = guest_fs / b_path.lstrip("/")
                else:
                    real_src = guest_fs / b_path.lstrip("/")

                real_dst = Path(dst)
                real_dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(real_src, real_dst)
                if self.corrupt_bundle_transfer and real_dst.name == "repo.bundle":
                    real_dst.write_bytes(b"corrupt-bundle-data")
                elif self.corrupt_staged_patch_transfer and real_dst.name == "staged.patch":
                    real_dst.write_bytes(b"corrupt-staged-patch-data")
                elif self.corrupt_worktree_transfer and real_dst.name == "worktree.tar.gz":
                    real_dst.write_bytes(b"corrupt-tar-data")
                if self.mutate_during_transfer and real_dst.name == "worktree.tar.gz":
                    (guest_repo / "transfer_mutation.txt").write_text("mutated during transfer\n")
            elif ":" in dst:
                b_name, b_path = dst.split(":", 1)
                guest_fs = self.sandboxes[b_name]["guest_fs"]
                if b_path.startswith("/tmp/"):
                    real_dst = guest_fs / b_path.lstrip("/")
                else:
                    real_dst = guest_fs / b_path.lstrip("/")
                real_dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(Path(src), real_dst)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        raise NotImplementedError(f"MockSbx does not handle: {cmd}")


class TestValidationAndSchema(unittest.TestCase):
    """Test validation of names, IDs, branch names, host repos, and task record schema."""

    def test_validate_sandbox_name(self):
        valid = ["task-1", "dotfiles-sbx", "dev.box", "sandbox123"]
        for name in valid:
            self.assertEqual(task.validate_sandbox_name(name), name)

        invalid = ["-bad", ".bad", "bad-", "bad.", "bad_name", "a", "", "bad name", "a" * 65]
        for name in invalid:
            with self.assertRaises(ValueError):
                task.validate_sandbox_name(name)

    def test_validate_branch_name_and_forbidden_branches(self):
        forbidden = ["master", "main", "refs/heads/master", "refs/heads/main"]
        for b in forbidden:
            with self.assertRaises(ValueError):
                task.validate_branch_name(b)

        for bad in ["-start", "--option", "name\x00bad", "name\x1fbad"]:
            with self.assertRaises(ValueError):
                task.validate_branch_name(bad)

        valid = ["task/feature", "fix-123", "feature_test"]
        for b in valid:
            self.assertEqual(task.validate_branch_name(b), b)

    def test_validate_host_repo_rejects_worktrees_and_non_dirs(self):
        with tempfile.TemporaryDirectory() as td:
            repo_path = Path(td) / "normal_repo"
            create_test_git_repo(repo_path)
            self.assertEqual(task.validate_host_repo(repo_path), repo_path.resolve())

            wt_path = Path(td) / "fake_worktree"
            wt_path.mkdir()
            (wt_path / ".git").write_text("gitdir: /some/path\n")
            with self.assertRaises(ValueError) as cm:
                task.validate_host_repo(wt_path)
            self.assertIn("git worktree", str(cm.exception))

            non_repo = Path(td) / "empty_dir"
            non_repo.mkdir()
            with self.assertRaises(ValueError) as cm:
                task.validate_host_repo(non_repo)
            self.assertIn("missing a .git directory", str(cm.exception))

    def test_validate_record_and_destination_paths(self):
        with tempfile.TemporaryDirectory() as td:
            repo_path = Path(td) / "host_repo"
            create_test_git_repo(repo_path)

            inside_repo = repo_path / "preserved"
            with self.assertRaises(ValueError):
                task.validate_destination_path(inside_repo, host_repo=repo_path)
            with self.assertRaises(ValueError):
                task.validate_record_path(inside_repo, host_repo=repo_path)

            outside = Path(td) / "outside"
            self.assertEqual(task.validate_destination_path(outside, host_repo=repo_path), outside.resolve())
            self.assertEqual(task.validate_record_path(outside, host_repo=repo_path), outside.resolve())

    def test_validate_guest_harness_path_disjoint_and_canonical(self):
        guest_repo = "/home/agent/repo"
        valid_harness = "/home/agent/.local/state/agent-harness/task-01"
        self.assertEqual(task.validate_guest_harness_path(valid_harness, guest_repo), valid_harness)

        # Whole harness root is rejected
        with self.assertRaises(ValueError) as cm:
            task.validate_guest_harness_path("/home/agent/.local/state/agent-harness", guest_repo)
        self.assertIn("whole-harness root directory", str(cm.exception))

        with self.assertRaises(ValueError) as cm:
            task.validate_guest_harness_path("/home/agent/.local/state/agent-harness/", guest_repo)
        self.assertIn("whole-harness root directory", str(cm.exception))

        # Non-absolute
        with self.assertRaises(ValueError):
            task.validate_guest_harness_path("relative/path", guest_repo)

        # Traversal
        with self.assertRaises(ValueError):
            task.validate_guest_harness_path("/home/agent/../etc", guest_repo)

        # Harness inside repo
        with self.assertRaises(ValueError):
            task.validate_guest_harness_path("/home/agent/repo/harness", guest_repo)

        # Repo inside harness
        with self.assertRaises(ValueError):
            task.validate_guest_harness_path("/home/agent", "/home/agent/repo")

        # Disjoint from staging
        guest_stage = "/tmp/preserve.123"
        with self.assertRaises(ValueError):
            task.validate_guest_harness_path("/tmp/preserve.123/harness", guest_repo, guest_stage=guest_stage)

    def test_read_and_write_task_record_schema_and_permissions(self):
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            create_test_git_repo(repo)
            rec_file = Path(td) / "task.json"

            data = {
                "schema_version": 1,
                "task_id": "task-test",
                "sandbox_name": "sbx-test",
                "sandbox_id": "sbx-uuid-123",
                "host_repo": str(repo.resolve()),
                "base_commit": "a" * 40,
                "branch": "task/feature",
                "status": "ready",
            }
            task.write_task_record(rec_file, data, create_new=True)
            self.assertTrue(rec_file.exists())
            mode = rec_file.stat().st_mode & 0o777
            self.assertEqual(mode, 0o600)

            # Read back
            loaded = task.read_task_record(rec_file, require_sandbox_id=True)
            self.assertEqual(loaded["task_id"], "task-test")

            # Insecure permissions
            rec_file.chmod(0o666)
            with self.assertRaises(RuntimeError) as cm:
                task.read_task_record(rec_file)
            self.assertIn("unsafe permissions", str(cm.exception))


class TestBaseCommitResolutionBareRepo(unittest.TestCase):
    """Test base resolution in temporary bare repo, including HEAD-only and ancestor bundles."""

    def test_base_commit_resolution_head_only_and_ancestor_bundle(self):
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            c1 = create_test_git_repo(repo)

            (repo / "f2.txt").write_text("c2\n")
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-m", "c2"], check=True)
            c2 = subprocess.run(
                ["git", "-C", str(repo), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            bundle_file = Path(td) / "head_only.bundle"
            subprocess.run(
                ["git", "-C", str(repo), "bundle", "create", str(bundle_file), "HEAD"],
                check=True,
                capture_output=True,
            )

            # Resolving HEAD in bundle
            res_head = task.resolve_base_commit("HEAD", repo, bundle_path=bundle_file)
            self.assertEqual(res_head, c2)

            # Resolving ancestor SHA c1 in bundle
            res_c1 = task.resolve_base_commit(c1, repo, bundle_path=bundle_file)
            self.assertEqual(res_c1, c1)


class TestTaskLifecycle(unittest.TestCase):
    """Unit and integration tests for create, status, start, and preserve."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.host_repo = self.root / "host_repo"
        self.base_commit = create_test_git_repo(self.host_repo)

        self.workload = self.root / "workload"
        self.workload.mkdir()
        self.mixin = self.root / "mixin"
        self.mixin.mkdir()

        self.records_dir = self.root / "records"
        self.records_dir.mkdir()

        self.sbx_manager = FakeSbxManager(self.root / "sbx_env")
        self.patcher = patch("subprocess.run", side_effect=self.sbx_manager.dispatch)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.temp_dir.cleanup()

    def test_create_task_success(self):
        rec_path = self.records_dir / "task-success.json"
        rec = task.create_task(
            record_path=rec_path,
            task_id="task-01",
            sandbox_name="box-01",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/feature-01",
            workload_path=self.workload,
            mixin_path=self.mixin,
        )
        self.assertEqual(rec["task_id"], "task-01")
        self.assertEqual(rec["status"], "ready")
        self.assertEqual(rec["branch"], "task/feature-01")
        self.assertEqual(rec["base_commit"], self.base_commit)
        self.assertTrue(rec_path.exists())
        self.assertEqual(rec_path.stat().st_mode & 0o777, 0o600)

    def test_create_task_duplicate_record_refusal(self):
        rec_path = self.records_dir / "task-dup.json"
        rec_path.write_text("{}")
        rec_path.chmod(0o600)

        with self.assertRaises(FileExistsError):
            task.create_task(
                record_path=rec_path,
                task_id="task-dup",
                sandbox_name="box-dup",
                host_repo=self.host_repo,
                base_ref="trunk",
                branch="task/dup",
                workload_path=self.workload,
                mixin_path=self.mixin,
            )

    def test_create_task_existing_sandbox_name_refusal(self):
        rec_path = self.records_dir / "task-sbx-exist.json"
        self.sbx_manager.sandboxes["box-exist"] = {"id": "old-id", "status": "running"}

        with self.assertRaises(RuntimeError) as cm:
            task.create_task(
                record_path=rec_path,
                task_id="task-sbx-exist",
                sandbox_name="box-exist",
                host_repo=self.host_repo,
                base_ref="trunk",
                branch="task/exist",
                workload_path=self.workload,
                mixin_path=self.mixin,
            )
        self.assertIn("already exists in sbx ls", str(cm.exception))

    def test_create_task_existing_host_branch_refusal(self):
        subprocess.run(["git", "-C", str(self.host_repo), "branch", "task/collision"], check=True)
        rec_path = self.records_dir / "task-collision.json"

        with self.assertRaises(ValueError) as cm:
            task.create_task(
                record_path=rec_path,
                task_id="task-collision",
                sandbox_name="box-collision",
                host_repo=self.host_repo,
                base_ref="trunk",
                branch="task/collision",
                workload_path=self.workload,
                mixin_path=self.mixin,
            )
        self.assertIn("already exists in host repository", str(cm.exception))

    def test_create_task_with_dependency_bundle(self):
        other_repo = self.root / "other_repo"
        c_dep = create_test_git_repo(other_repo)
        bundle_file = self.root / "dep.bundle"
        subprocess.run(
            ["git", "-C", str(other_repo), "bundle", "create", str(bundle_file), "HEAD"],
            check=True,
            capture_output=True,
        )

        rec_path = self.records_dir / "task-dep.json"
        rec = task.create_task(
            record_path=rec_path,
            task_id="task-dep",
            sandbox_name="box-dep",
            host_repo=self.host_repo,
            base_ref=c_dep,
            branch="task/from-bundle",
            workload_path=self.workload,
            mixin_path=self.mixin,
            dependency_bundle=bundle_file,
        )
        self.assertEqual(rec["base_commit"], c_dep)
        self.assertEqual(rec["status"], "ready")

    def test_status_task_running_and_stopped_guards(self):
        rec_path = self.records_dir / "task-stat-guard.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-stat",
            sandbox_name="box-stat",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/stat-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
        )

        box = self.sbx_manager.sandboxes["box-stat"]
        box["status"] = "stopped"
        exec_count = len(self.sbx_manager.exec_calls)

        # Stopped VM: only ls is called, zero exec calls made
        st1 = task.status_task(rec_path)
        self.assertEqual(st1["vm_status"], "stopped")
        self.assertEqual(len(self.sbx_manager.exec_calls), exec_count)

        # Running VM: exec is called to query HEAD branch & commit
        box["status"] = "running"
        st2 = task.status_task(rec_path)
        self.assertEqual(st2["vm_status"], "running")
        self.assertTrue(len(self.sbx_manager.exec_calls) > exec_count)
        self.assertEqual(st2["guest_info"].get("branch"), "task/stat-branch")

    def test_status_task_sandbox_id_mismatch(self):
        rec_path = self.records_dir / "task-stat-mismatch.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-stat-mis",
            sandbox_name="box-stat-mis",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/mis-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
        )

        box = self.sbx_manager.sandboxes["box-stat-mis"]
        box["status"] = "running"
        box["id"] = "different-sbx-id"
        exec_count = len(self.sbx_manager.exec_calls)

        st = task.status_task(rec_path)
        self.assertFalse(st["id_match"])
        self.assertIn("sandbox_id_mismatch", st["mismatch"])
        # No exec calls made on identity mismatch
        self.assertEqual(len(self.sbx_manager.exec_calls), exec_count)

    def test_start_task_identity_verification_and_ancestry(self):
        rec_path = self.records_dir / "task-start-checks.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-start-chk",
            sandbox_name="box-start-chk",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/chk-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
        )

        # 1. Identity mismatch raises RuntimeError
        box = self.sbx_manager.sandboxes["box-start-chk"]
        real_id = box["id"]
        box["id"] = "wrong-id"
        with self.assertRaises(RuntimeError) as cm:
            task.start_task(rec_path)
        self.assertIn("Sandbox identity mismatch", str(cm.exception))
        box["id"] = real_id

        # 2. Non-ancestor HEAD raises RuntimeError
        guest_repo = box["guest_repo"]
        subprocess.run(["git", "-C", str(guest_repo), "config", "user.name", "Tester"], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "config", "user.email", "tester@example.com"], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "checkout", "--orphan", "orphan_branch"], check=True)
        (guest_repo / "orphan.txt").write_text("orphan\n")
        subprocess.run(["git", "-C", str(guest_repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "commit", "-m", "orphan commit"], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "checkout", "-B", "task/chk-branch"], check=True)

        with self.assertRaises(RuntimeError) as cm:
            task.start_task(rec_path)
        self.assertIn("not an ancestor of current HEAD", str(cm.exception))

    def test_start_task_dirty_checkout_retained(self):
        rec_path = self.records_dir / "task-start-dirty.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-start-dirty",
            sandbox_name="box-start-dirty",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/dirty-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
        )

        box = self.sbx_manager.sandboxes["box-start-dirty"]
        guest_repo = box["guest_repo"]
        (guest_repo / "dirty.txt").write_text("uncommitted work\n")

        res = task.start_task(rec_path)
        self.assertTrue(res["is_dirty"])
        self.assertTrue((guest_repo / "dirty.txt").exists())
        self.assertEqual((guest_repo / "dirty.txt").read_text(), "uncommitted work\n")

    def test_preserve_task_requires_quiesced_flag(self):
        rec_path = self.records_dir / "task-quiesced.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-q",
            sandbox_name="box-q",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/q-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-q",
        )
        dest = self.root / "preserved_q"

        with self.assertRaises(ValueError) as cm:
            task.preserve_task(rec_path, dest, quiesced=False)
        self.assertIn("--quiesced flag required", str(cm.exception))

    def test_preserve_task_refuses_existing_destination(self):
        rec_path = self.records_dir / "task-exist-dest.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-ed",
            sandbox_name="box-ed",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/ed-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-ed",
        )
        dest = self.root / "preserved_existing"
        dest.mkdir(parents=True, exist_ok=True)  # empty directory already exists

        with self.assertRaises(FileExistsError) as cm:
            task.preserve_task(rec_path, dest, quiesced=True)
        self.assertIn("already exists", str(cm.exception))

    def test_preserve_task_successful_end_to_end(self):
        rec_path = self.records_dir / "task-success-pres.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-sp",
            sandbox_name="box-sp",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/sp-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-sp",
        )

        box = self.sbx_manager.sandboxes["box-sp"]
        guest_repo = box["guest_repo"]
        (guest_repo / "work.txt").write_text("work done\n")
        guest_harness = box["guest_harness"]
        (guest_harness / "log.txt").write_text("harness log\n")

        dest = self.root / "preserved_sp"
        receipt = task.preserve_task(rec_path, dest, quiesced=True)

        self.assertTrue(receipt["verified"])
        self.assertEqual(receipt["status"], "verified")
        self.assertTrue((dest / "repo.bundle").exists())
        self.assertTrue((dest / "staged.patch").exists())
        self.assertTrue((dest / "worktree.tar.gz").exists())
        self.assertTrue((dest / "harness.tar.gz").exists())
        self.assertTrue((dest / "manifest_before.json").exists())
        self.assertTrue((dest / "manifest_after.json").exists())
        self.assertTrue((dest / "receipt.json").exists())
        self.assertEqual((dest / "receipt.json").stat().st_mode & 0o777, 0o600)

        # Updated record has preserved status
        rec = task.read_task_record(rec_path)
        self.assertEqual(rec["status"], "preserved")
        self.assertEqual(len(rec["preservations"]), 1)
        self.assertTrue(rec["preservations"][0]["verified"])

    def test_preserve_task_staged_vs_worktree_divergence(self):
        rec_path = self.records_dir / "task-staged-div.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-staged-div",
            sandbox_name="box-staged-div",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/staged-div-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-staged-div",
        )

        box = self.sbx_manager.sandboxes["box-staged-div"]
        guest_repo = box["guest_repo"]
        # Commit version A
        (guest_repo / "three_way.txt").write_text("HEAD content (A)\n")
        subprocess.run(["git", "-C", str(guest_repo), "add", "three_way.txt"], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "commit", "-m", "commit A"], check=True)

        # Stage version B
        (guest_repo / "three_way.txt").write_text("Index content (B)\n")
        subprocess.run(["git", "-C", str(guest_repo), "add", "three_way.txt"], check=True)

        # Put version C in working tree
        (guest_repo / "three_way.txt").write_text("Worktree content (C)\n")

        # Also add a new staged file
        (guest_repo / "new_staged.txt").write_text("new staged\n")
        subprocess.run(["git", "-C", str(guest_repo), "add", "new_staged.txt"], check=True)

        dest = self.root / "preserved_staged_div"
        receipt = task.preserve_task(rec_path, dest, quiesced=True)

        self.assertTrue(receipt["verified"])
        self.assertTrue((dest / "staged.patch").stat().st_size > 0)
        self.assertEqual(receipt["staged_patch"]["index_entries_count"], 3)  # README, three_way, new_staged

    def test_preserve_task_raw_refs_and_bundle_head_branch(self):
        rec_path = self.records_dir / "task-raw-refs.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-raw-refs",
            sandbox_name="box-raw-refs",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/raw-refs-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-raw-refs",
        )

        box = self.sbx_manager.sandboxes["box-raw-refs"]
        guest_repo = box["guest_repo"]

        # 1. Annotated tag
        subprocess.run(["git", "-C", str(guest_repo), "tag", "-a", "-m", "annotated tag", "v1.0-annotated"], check=True)

        # 2. Tag pointing directly to a blob (non-commit tag)
        res_hash = subprocess.run(
            ["git", "-C", str(guest_repo), "hash-object", "-w", "README.md"],
            capture_output=True,
            text=True,
            check=True,
        )
        blob_sha = res_hash.stdout.strip()
        subprocess.run(["git", "-C", str(guest_repo), "tag", "blob-tag", blob_sha], check=True)

        # 3. Branch named BUNDLE_HEAD
        subprocess.run(["git", "-C", str(guest_repo), "branch", "BUNDLE_HEAD"], check=True)

        dest = self.root / "preserved_raw_refs"
        receipt = task.preserve_task(rec_path, dest, quiesced=True)

        self.assertTrue(receipt["verified"])
        self.assertIn("refs/tags/v1.0-annotated", receipt["bundle"]["refs"])
        self.assertIn("refs/tags/blob-tag", receipt["bundle"]["refs"])
        self.assertIn("refs/heads/BUNDLE_HEAD", receipt["bundle"]["refs"])

    def test_preserve_task_tar_integrity_same_size_corruption(self):
        # Direct verification of verify_tar_against_manifest with same-size corrupted content
        with tempfile.TemporaryDirectory() as td:
            tar_file = Path(td) / "test.tar.gz"
            good_bytes = b"original content 1234"
            corrupt_bytes = b"corrupted content!!!!"
            self.assertEqual(len(good_bytes), len(corrupt_bytes))

            sha_good = hashlib.sha256(good_bytes).hexdigest()

            # Create tar with corrupt_bytes
            with tarfile.open(tar_file, "w:gz") as tar:
                ti = tarfile.TarInfo("test.txt")
                ti.size = len(corrupt_bytes)
                ti.mode = 0o644
                ti.type = tarfile.REGTYPE
                import io
                tar.addfile(ti, io.BytesIO(corrupt_bytes))

            manifest = {
                "test.txt": {
                    "type": "file",
                    "mode": "0o644",
                    "size": len(good_bytes),
                    "sha256": sha_good,
                    "link_target": None,
                }
            }

            with self.assertRaises(ValueError) as cm:
                task.verify_tar_against_manifest(tar_file, manifest)
            self.assertIn("SHA256 mismatch", str(cm.exception))

    def test_preserve_task_tar_path_traversal_and_duplicates(self):
        import io
        with tempfile.TemporaryDirectory() as td:
            # 1. Absolute path
            tar_abs = Path(td) / "abs.tar.gz"
            with tarfile.open(tar_abs, "w:gz") as tar:
                ti = tarfile.TarInfo("/etc/passwd")
                ti.size = 0
                tar.addfile(ti, io.BytesIO())
            with self.assertRaises(ValueError) as cm:
                task.verify_tar_against_manifest(tar_abs, {})
            self.assertIn("forbidden absolute path", str(cm.exception))

            # 2. Directory traversal
            tar_trav = Path(td) / "trav.tar.gz"
            with tarfile.open(tar_trav, "w:gz") as tar:
                ti = tarfile.TarInfo("../escape.txt")
                ti.size = 0
                tar.addfile(ti, io.BytesIO())
            with self.assertRaises(ValueError) as cm:
                task.verify_tar_against_manifest(tar_trav, {})
            self.assertIn("directory traversal component", str(cm.exception))

            # 3. Duplicate member
            tar_dup = Path(td) / "dup.tar.gz"
            with tarfile.open(tar_dup, "w:gz") as tar:
                ti1 = tarfile.TarInfo("file.txt")
                ti1.size = 0
                tar.addfile(ti1, io.BytesIO())
                ti2 = tarfile.TarInfo("file.txt")
                ti2.size = 0
                tar.addfile(ti2, io.BytesIO())
            with self.assertRaises(ValueError) as cm:
                task.verify_tar_against_manifest(tar_dup, {"file.txt": {"type": "file", "mode": "0o644", "size": 0, "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "link_target": None}})
            self.assertIn("duplicate member", str(cm.exception))

    def test_preserve_task_detects_concurrent_mutation(self):
        rec_path = self.records_dir / "task-h-mut.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-hmut",
            sandbox_name="box-hmut",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/hmut-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-hmut",
        )
        self.sbx_manager.mutate_harness_during_tar = True

        dest = self.root / "preserved_hmut"
        with self.assertRaises(RuntimeError) as cm:
            task.preserve_task(rec_path, dest, quiesced=True)
        self.assertIn("Snapshot state changed during preservation", str(cm.exception))

    def test_preserve_task_rejects_special_file(self):
        rec_path = self.records_dir / "task-special-file.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-spec",
            sandbox_name="box-spec",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/spec-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-spec",
        )
        guest_repo = self.sbx_manager.sandboxes["box-spec"]["guest_repo"]
        fifo_path = guest_repo / "test.fifo"
        os.mkfifo(fifo_path)

        dest = self.root / "preserved_spec"
        with self.assertRaises(RuntimeError) as cm:
            task.preserve_task(rec_path, dest, quiesced=True)
        self.assertIn("Unsupported special file", str(cm.exception))

    def test_preserve_task_rejects_unmerged_conflicts(self):
        rec_path = self.records_dir / "task-unmerged.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-unmerged",
            sandbox_name="box-unmerged",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/unmerged-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-unmerged",
        )
        guest_repo = self.sbx_manager.sandboxes["box-unmerged"]["guest_repo"]

        # Simulate merge conflict
        subprocess.run(["git", "-C", str(guest_repo), "branch", "branch-a"], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "branch", "branch-b"], check=True)
        (guest_repo / "conflict.txt").write_text("line a\n")
        subprocess.run(["git", "-C", str(guest_repo), "add", "conflict.txt"], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "commit", "-m", "commit a"], check=True)

        subprocess.run(["git", "-C", str(guest_repo), "checkout", "branch-b"], check=True)
        (guest_repo / "conflict.txt").write_text("line b\n")
        subprocess.run(["git", "-C", str(guest_repo), "add", "conflict.txt"], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "commit", "-m", "commit b"], check=True)

        subprocess.run(["git", "-C", str(guest_repo), "merge", "task/unmerged-branch"], capture_output=True)

        dest = self.root / "preserved_unmerged"
        with self.assertRaises(RuntimeError) as cm:
            task.preserve_task(rec_path, dest, quiesced=True)
        self.assertIn("unmerged index entries", str(cm.exception))

    def test_preserve_task_failure_retention_and_diagnostics(self):
        rec_path = self.records_dir / "task-fail-retain.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-fr",
            sandbox_name="box-fr",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/fr-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-fr",
        )

        self.sbx_manager.corrupt_bundle_transfer = True
        dest = self.root / "preserved_failed"

        with self.assertRaises(RuntimeError):
            task.preserve_task(rec_path, dest, quiesced=True)

        # Receipt written on failure
        self.assertTrue((dest / "receipt.json").exists())
        fail_receipt = json.loads((dest / "receipt.json").read_text())
        self.assertFalse(fail_receipt["verified"])
        self.assertEqual(fail_receipt["status"], "failed")
        self.assertIn("guest_stage", fail_receipt)
        guest_stage = fail_receipt["guest_stage"]

        # Guest staging directory was NOT deleted
        box = self.sbx_manager.sandboxes["box-fr"]
        guest_fs = box["guest_fs"]
        guest_stage_host = guest_fs / guest_stage.lstrip("/")
        self.assertTrue(guest_stage_host.exists())

        # Task record updated with failure
        rec = task.read_task_record(rec_path)
        self.assertEqual(len(rec["preservations"]), 1)
        self.assertFalse(rec["preservations"][0]["verified"])

    def test_preserve_task_detects_concurrent_mutation_during_transfer(self):
        rec_path = self.records_dir / "task-t-mut.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-tmut",
            sandbox_name="box-tmut",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/tmut-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-tmut",
        )

        box = self.sbx_manager.sandboxes["box-tmut"]
        guest_repo = box["guest_repo"]
        (guest_repo / "work.txt").write_text("initial work\n")
        guest_harness = box["guest_harness"]
        (guest_harness / "log.txt").write_text("initial harness log\n")

        # Enable mutation during sbx cp of archives
        self.sbx_manager.mutate_during_transfer = True

        dest = self.root / "preserved_tmut"
        with self.assertRaises(RuntimeError) as cm:
            task.preserve_task(rec_path, dest, quiesced=True)

        # Precise failing stage: post-transfer snapshot comparison
        self.assertIn("Snapshot state changed during preservation", str(cm.exception))
        self.assertIn("concurrent modification during transfer or verification", str(cm.exception))

        # Failed-transfer evidence and diagnostics survive in dest
        self.assertTrue((dest / "receipt.json").exists())
        fail_receipt = json.loads((dest / "receipt.json").read_text())
        self.assertFalse(fail_receipt["verified"])
        self.assertEqual(fail_receipt["status"], "failed")
        self.assertIn("guest_stage", fail_receipt)
        self.assertIn("verification_scope", fail_receipt)
        self.assertEqual(
            fail_receipt["verification_scope"],
            "Verification covers this point in time; retirement always requires a fresh check and explicit authorization.",
        )

        # Transferred archives survived in dest
        self.assertTrue((dest / "repo.bundle").exists())
        self.assertTrue((dest / "staged.patch").exists())
        self.assertTrue((dest / "worktree.tar.gz").exists())
        self.assertTrue((dest / "harness.tar.gz").exists())

        # Diagnostic manifests before and after survive in dest and show difference
        self.assertTrue((dest / "manifest_before.json").exists())
        self.assertTrue((dest / "manifest_after.json").exists())
        mb = json.loads((dest / "manifest_before.json").read_text())
        ma = json.loads((dest / "manifest_after.json").read_text())
        self.assertNotIn("transfer_mutation.txt", mb["worktree"])
        self.assertIn("transfer_mutation.txt", ma["worktree"])

        # Source work and guest staging survive
        guest_fs = box["guest_fs"]
        guest_stage_host = guest_fs / fail_receipt["guest_stage"].lstrip("/")
        self.assertTrue(guest_stage_host.exists())
        self.assertTrue((guest_repo / "work.txt").exists())
        self.assertTrue((guest_repo / "transfer_mutation.txt").exists())

    def test_lossless_index_parsing_and_exact_fidelity(self):
        # 1. Unit test demonstrating old whitespace lossy splitting collapses repeated-space names
        sha_a = "1111111111111111111111111111111111111111"
        sha_b = "2222222222222222222222222222222222222222"
        # Old parser with standard whitespace split
        lossy_raw_line1 = f"100644 {sha_a} 0\tspace name.txt\n"
        lossy_raw_line2 = f"100644 {sha_b} 0\tspace  name.txt\n"
        old_lossy_dict = {}
        for line in (lossy_raw_line1 + lossy_raw_line2).splitlines():
            parts = line.strip().split()
            if len(parts) >= 4:
                old_lossy_dict[" ".join(parts[3:])] = {"mode": parts[0], "sha": parts[1], "stage": parts[2]}
        # Old parser collapsed the two paths into one!
        self.assertEqual(len(old_lossy_dict), 1)
        self.assertIn("space name.txt", old_lossy_dict)
        self.assertNotIn("space  name.txt", old_lossy_dict)

        # New lossless parser using NUL delimiter and splitting metadata at first TAB only
        nul_records = (
            b"100644 " + sha_a.encode() + b" 0\tspace name.txt\0"
            b"100644 " + sha_b.encode() + b" 0\tspace  name.txt\0"
            b"100644 " + sha_a.encode() + b" 0\ttab\tname.txt\0"
            b"100644 " + sha_a.encode() + b" 0\tnewline\nname.txt\0"
            b"100644 " + sha_a.encode() + b" 0\tnonascii_\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e.txt\0"
        )
        lossless_dict = task.parse_ls_files_stage_z(nul_records)
        self.assertEqual(len(lossless_dict), 5)
        self.assertIn("space name.txt", lossless_dict)
        self.assertIn("space  name.txt", lossless_dict)
        self.assertEqual(lossless_dict["space name.txt"]["sha"], sha_a)
        self.assertEqual(lossless_dict["space  name.txt"]["sha"], sha_b)
        self.assertIn("tab\tname.txt", lossless_dict)
        self.assertIn("newline\nname.txt", lossless_dict)
        self.assertIn("nonascii_日本語.txt", lossless_dict)

        # 2. End-to-end integration test with real Git
        rec_path = self.records_dir / "task-special-paths.json"
        task.create_task(
            record_path=rec_path,
            task_id="task-spec-paths",
            sandbox_name="box-spec-paths",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/spec-paths-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path="/home/agent/.local/state/agent-harness/box-spec-paths",
        )

        box = self.sbx_manager.sandboxes["box-spec-paths"]
        guest_repo = box["guest_repo"]

        # Commit initial file to be deleted, and initial file to diverge (HEAD=A)
        (guest_repo / "to_delete.txt").write_text("delete me\n")
        (guest_repo / "three_way.txt").write_text("version A in HEAD\n")
        subprocess.run(["git", "-C", str(guest_repo), "add", "to_delete.txt", "three_way.txt"], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "commit", "-m", "commit base"], check=True)

        # Staged deletion
        subprocess.run(["git", "-C", str(guest_repo), "rm", "to_delete.txt"], check=True)

        # Distinct repeated-space names, tabs, newlines, non-ASCII
        (guest_repo / "space name.txt").write_text("space 1\n")
        (guest_repo / "space  name.txt").write_text("space 2\n")
        (guest_repo / "tab\tname.txt").write_text("tab\n")
        (guest_repo / "newline\nname.txt").write_text("newline\n")
        (guest_repo / "nonascii_日本語.txt").write_text("nihongo\n")

        # Staged binary file
        bin_data = bytes(range(256))
        (guest_repo / "binary.bin").write_bytes(bin_data)

        # Stage version B for divergent file
        (guest_repo / "three_way.txt").write_text("version B in index\n")

        # Add all to index
        subprocess.run(
            ["git", "-C", str(guest_repo), "add", "space name.txt", "space  name.txt", "tab\tname.txt", "newline\nname.txt", "nonascii_日本語.txt", "binary.bin", "three_way.txt"],
            check=True,
        )

        # Put version C in working tree
        (guest_repo / "three_way.txt").write_text("version C in worktree\n")

        guest_harness = box["guest_harness"]
        (guest_harness / "run.log").write_text("step executed\n")

        dest = self.root / "preserved_special_paths"
        receipt = task.preserve_task(rec_path, dest, quiesced=True)

        self.assertTrue(receipt["verified"])
        self.assertEqual(receipt["status"], "verified")
        self.assertEqual(
            receipt["verification_scope"],
            "Verification covers this point in time; retirement always requires a fresh check and explicit authorization.",
        )

        mb = json.loads((dest / "manifest_before.json").read_text())
        idx_stage = mb["index_stage"]

        # Both repeated space entries exist distinctly
        self.assertIn("space name.txt", idx_stage)
        self.assertIn("space  name.txt", idx_stage)
        self.assertIn("tab\tname.txt", idx_stage)
        self.assertIn("newline\nname.txt", idx_stage)
        self.assertIn("nonascii_日本語.txt", idx_stage)
        self.assertIn("binary.bin", idx_stage)
        self.assertIn("three_way.txt", idx_stage)
        self.assertNotIn("to_delete.txt", idx_stage)

        # Worktree archive contains version C of three_way.txt and matches manifest
        self.assertEqual(mb["worktree"]["three_way.txt"]["sha256"], hashlib.sha256(b"version C in worktree\n").hexdigest())

    def test_harness_selection_explicit_validation_and_rejection(self):
        # 1. Absent harness selection fails before destination creation
        rec_path_absent = self.records_dir / "task-absent-harness.json"
        task.create_task(
            record_path=rec_path_absent,
            task_id="task-absent",
            sandbox_name="box-absent",
            host_repo=self.host_repo,
            base_ref="trunk",
            branch="task/absent-branch",
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path=None,  # No harness in record
        )
        dest_absent = self.root / "dest_should_not_exist_absent"
        with self.assertRaises(ValueError) as cm:
            task.preserve_task(rec_path_absent, dest_absent, quiesced=True)  # No harness argument
        self.assertIn("Explicit task harness path is required", str(cm.exception))
        self.assertFalse(dest_absent.exists(), "Destination directory must not be created when harness selection is absent")

        # 2. Whole harness root selection fails before destination creation
        dest_whole = self.root / "dest_should_not_exist_whole"
        with self.assertRaises(ValueError) as cm:
            task.preserve_task(rec_path_absent, dest_whole, quiesced=True, harness_path="/home/agent/.local/state/agent-harness")
        self.assertIn("whole-harness root directory", str(cm.exception))
        self.assertFalse(dest_whole.exists(), "Destination directory must not be created when whole harness root is selected")

        # 3. Nonexistent guest harness path fails before destination creation
        dest_nonexist = self.root / "dest_should_not_exist_nonexist"
        with self.assertRaises(RuntimeError) as cm:
            task.preserve_task(rec_path_absent, dest_nonexist, quiesced=True, harness_path="/home/agent/.local/state/agent-harness/does_not_exist")
        self.assertIn("does not exist", str(cm.exception))
        self.assertFalse(dest_nonexist.exists(), "Destination directory must not be created when guest harness path does not exist")

        # 4. Guest harness symlink alias to guest repo fails before destination creation
        box_absent = self.sbx_manager.sandboxes["box-absent"]
        guest_fs = box_absent["guest_fs"]
        guest_repo = box_absent["guest_repo"]
        symlink_to_repo = guest_fs / "home/agent/symlink_repo"
        os.symlink(guest_repo, symlink_to_repo)

        dest_symlink = self.root / "dest_should_not_exist_symlink"
        with self.assertRaises(ValueError) as cm:
            task.preserve_task(rec_path_absent, dest_symlink, quiesced=True, harness_path="/home/agent/symlink_repo")
        self.assertIn("overlap", str(cm.exception))
        self.assertFalse(dest_symlink.exists(), "Destination directory must not be created when harness symlinks to repo")

        # 5. Guest harness symlink inside guest repo fails before destination creation
        inner_dir = guest_repo / "sub_harness"
        inner_dir.mkdir(parents=True, exist_ok=True)
        symlink_to_inner = guest_fs / "home/agent/symlink_inner"
        os.symlink(inner_dir, symlink_to_inner)

        dest_inner = self.root / "dest_should_not_exist_inner"
        with self.assertRaises(ValueError) as cm:
            task.preserve_task(rec_path_absent, dest_inner, quiesced=True, harness_path="/home/agent/symlink_inner")
        self.assertIn("must be mutually disjoint", str(cm.exception))
        self.assertFalse(dest_inner.exists(), "Destination directory must not be created when harness symlinks inside repo")


class TestCli(unittest.TestCase):
    """Test CLI commands flow from /tmp with PYTHONPATH."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.host_repo = self.root / "cli_repo"
        create_test_git_repo(self.host_repo)
        self.workload = self.root / "workload"
        self.workload.mkdir()
        self.mixin = self.root / "mixin"
        self.mixin.mkdir()
        self.records_dir = self.root / "records"
        self.records_dir.mkdir()

        self.sbx_manager = FakeSbxManager(self.root / "sbx_env")
        self.patcher = patch("subprocess.run", side_effect=self.sbx_manager.dispatch)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.temp_dir.cleanup()

    def test_cli_flow(self):
        rec_file = str(self.records_dir / "cli_task.json")
        dest_dir = str(self.root / "cli_dest")

        ret = task.main([
            "create",
            "--record", rec_file,
            "--task-id", "cli-01",
            "--name", "cli-box",
            "--repo", str(self.host_repo),
            "--base", "trunk",
            "--branch", "task/cli-branch",
            "--workload", str(self.workload),
            "--mixin", str(self.mixin),
            "--harness-path", "/home/agent/.local/state/agent-harness/cli-box",
        ])
        self.assertEqual(ret, 0)

        ret = task.main(["status", "--record", rec_file, "--json"])
        self.assertEqual(ret, 0)

        ret = task.main(["start", "--record", rec_file])
        self.assertEqual(ret, 0)

        ret = task.main(["preserve", "--record", rec_file, "--dest", dest_dir, "--quiesced"])
        self.assertEqual(ret, 0)
        self.assertTrue((Path(dest_dir) / "receipt.json").exists())


class TestTaskRetirement(unittest.TestCase):
    """Test suite for task.py retire command, preflights, worktree cleanup, and idempotency."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.host_repo = self.root / "host_repo"
        self.base_sha = create_test_git_repo(self.host_repo)
        self.workload = self.root / "workload"
        self.workload.mkdir()
        self.mixin = self.root / "mixin"
        self.mixin.mkdir()
        self.records_dir = self.root / "records"
        self.records_dir.mkdir()
        self.manifests_dir = self.root / "manifests"
        self.manifests_dir.mkdir()

        self.sbx_manager = FakeSbxManager(self.root / "sbx_env")
        self.patcher = patch("subprocess.run", side_effect=self.sbx_manager.dispatch)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.temp_dir.cleanup()

    def _setup_completed_task(
        self,
        task_id: str = "task-01",
        name: str = "box-01",
        branch: str = "task/feature-01",
        sub_branch: str = "sub/feature-01",
        with_worktree: bool = True,
        host_has_sub_branch: bool = True,
    ) -> tuple[Path, Path, Path | None, str]:
        rec_path = self.records_dir / f"{task_id}.json"
        harness_path = f"/home/agent/.local/state/agent-harness/{name}"
        task.create_task(
            record_path=rec_path,
            task_id=task_id,
            sandbox_name=name,
            host_repo=self.host_repo,
            base_ref="trunk",
            branch=branch,
            workload_path=self.workload,
            mixin_path=self.mixin,
            guest_harness_path=harness_path,
        )

        box = self.sbx_manager.sandboxes[name]
        guest_repo = box["guest_repo"]
        guest_harness = box["guest_harness"]
        (guest_harness / "run.log").write_text("harness output\n")

        # Make commit in guest
        (guest_repo / "feature.txt").write_text("feature content\n")
        subprocess.run(["git", "-C", str(guest_repo), "add", "feature.txt"], check=True)
        subprocess.run(["git", "-C", str(guest_repo), "commit", "-m", f"feat: {task_id}"], check=True)
        rev_head = subprocess.check_output(["git", "-C", str(guest_repo), "rev-parse", "HEAD"], text=True).strip()
        rev_tree = subprocess.check_output(["git", "-C", str(guest_repo), "rev-parse", "HEAD^{tree}"], text=True).strip()

        # Create sub_branch in guest so it gets included in preservation bundle
        subprocess.run(["git", "-C", str(guest_repo), "branch", sub_branch, rev_head], check=True)

        pres_dir = self.root / f"preserved_{task_id}"
        task.preserve_task(rec_path, pres_dir, quiesced=True, harness_path=harness_path)

        if host_has_sub_branch:
            subprocess.run(["git", "-C", str(self.host_repo), "checkout", "-b", sub_branch, self.base_sha], check=True, capture_output=True)
            (self.host_repo / "feature.txt").write_text("feature content\n")
            subprocess.run(["git", "-C", str(self.host_repo), "add", "feature.txt"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(self.host_repo), "commit", "-m", f"feat: {task_id} squashed"], check=True, capture_output=True)
            sub_sha = subprocess.check_output(["git", "-C", str(self.host_repo), "rev-parse", "HEAD"], text=True).strip()
            sub_tree = subprocess.check_output(["git", "-C", str(self.host_repo), "rev-parse", "HEAD^{tree}"], text=True).strip()
            subprocess.run(["git", "-C", str(self.host_repo), "checkout", "trunk"], check=True, capture_output=True)
        else:
            sub_sha = rev_head
            sub_tree = rev_tree

        manifest_path = self.manifests_dir / f"manifest_{task_id}.json"
        manifest_data = {
            "schema_version": 1,
            "record_type": "submission_manifest",
            "task_id": task_id,
            "repo": str(self.host_repo.resolve()),
            "status": "accepted",
            "base_commit": self.base_sha,
            "reviewed_head": rev_head,
            "reviewed_tree": rev_tree,
            "submission_branch": sub_branch,
            "submitted_sha": sub_sha,
            "submitted_tree": sub_tree,
            "commit_message": f"feat: {task_id} squashed\n",
            "dependencies": [],
            "designer_accepted": True,
            "verification_evidence": "All tests passed cleanly.",
            "accepted_at": "2026-11-10T12:00:00Z",
        }
        manifest_path.write_text(json.dumps(manifest_data, indent=2), encoding="utf-8")
        os.chmod(manifest_path, 0o600)

        wt_dir = None
        if with_worktree:
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(self.host_repo),
                    "fetch",
                    str(pres_dir / "repo.bundle"),
                    f"{rev_head}:{branch}",
                ],
                check=True,
                capture_output=True,
            )
            wt_dir = self.root / f"wt_{task_id}"
            subprocess.run(["git", "-C", str(self.host_repo), "worktree", "add", str(wt_dir), branch], check=True, capture_output=True)
            task.register_worktree(rec_path, wt_dir)

        return rec_path, manifest_path, wt_dir, sub_sha

    def test_retire_success_sandbox_and_worktree(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-ok",
            name="box-retire-ok",
            branch="task/retire-ok",
            sub_branch="sub/retire-ok",
            with_worktree=True,
        )
        self.assertIn("box-retire-ok", self.sbx_manager.sandboxes)
        self.assertTrue(wt_dir.exists())

        res = task.retire_task(rec_path, manifest_path)

        self.assertEqual(res["status"], "retired")
        self.assertEqual(res["task_id"], "retire-ok")
        self.assertEqual(res["worktree_removed"], str(wt_dir.resolve()))
        self.assertEqual(res["branch_preserved"], "sub/retire-ok")

        # Sandbox stopped and removed
        self.assertNotIn("box-retire-ok", self.sbx_manager.sandboxes)
        self.assertTrue(any(c[1] == "stop" and "box-retire-ok" in c for c in self.sbx_manager.stop_calls))
        self.assertTrue(any(c[1] == "rm" and "--force" in c and "box-retire-ok" in c for c in self.sbx_manager.rm_calls))
        self.assertFalse(any("--all" in c for c in self.sbx_manager.rm_calls))

        # Worktree removed
        wt_list = task.get_worktrees(self.host_repo)
        self.assertFalse(any(Path(w["worktree"]).resolve() == wt_dir.resolve() for w in wt_list))

        # Branches are preserved
        res_b1 = subprocess.run(["git", "-C", str(self.host_repo), "rev-parse", "refs/heads/task/retire-ok"], capture_output=True, text=True)
        self.assertEqual(res_b1.returncode, 0)
        res_b2 = subprocess.run(["git", "-C", str(self.host_repo), "rev-parse", "refs/heads/sub/retire-ok"], capture_output=True, text=True)
        self.assertEqual(res_b2.returncode, 0)

        # Task record updated to retired
        rec = task.read_task_record(rec_path, require_sandbox_id=False)
        self.assertEqual(rec["status"], "retired")
        self.assertEqual(rec["retirement"]["phase"], "completed")

        # Status command reflects retired state cleanly
        stat_res = task.status_task(rec_path)
        self.assertEqual(stat_res["task_lifecycle"], "retired")
        self.assertEqual(stat_res["vm_status"], "missing")
        self.assertIsNone(stat_res["mismatch"])

    def test_retire_success_no_worktree(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-no-wt",
            name="box-retire-no-wt",
            branch="task/retire-no-wt",
            sub_branch="sub/retire-no-wt",
            with_worktree=False,
        )
        self.assertIsNone(wt_dir)

        res = task.retire_task(rec_path, manifest_path)
        self.assertEqual(res["status"], "retired")
        self.assertIsNone(res["worktree_removed"])
        self.assertNotIn("box-retire-no-wt", self.sbx_manager.sandboxes)

    def test_retire_ensures_durable_host_branch_from_bundle(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-fetch-br",
            name="box-fetch-br",
            branch="task/fetch-br",
            sub_branch="sub/fetch-br",
            with_worktree=False,
            host_has_sub_branch=False,
        )
        # Ensure sub/fetch-br does NOT exist on host repository before retirement
        res_pre = subprocess.run(["git", "-C", str(self.host_repo), "rev-parse", "--verify", "-q", "refs/heads/sub/fetch-br"], capture_output=True)
        self.assertNotEqual(res_pre.returncode, 0)

        res = task.retire_task(rec_path, manifest_path)
        self.assertEqual(res["status"], "retired")

        # Now sub/fetch-br MUST exist on host repository and point to sub_sha
        res_post = subprocess.run(["git", "-C", str(self.host_repo), "rev-parse", "--verify", "refs/heads/sub/fetch-br"], capture_output=True, text=True)
        self.assertEqual(res_post.returncode, 0)
        self.assertEqual(res_post.stdout.strip().lower(), sub_sha.lower())

    def test_retire_rejects_divergent_host_branch(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-div",
            name="box-div",
            branch="task/div-br",
            sub_branch="sub/div-br",
            with_worktree=False,
            host_has_sub_branch=True,
        )
        # Point sub/div-br on host to a divergent commit
        (self.host_repo / "divergent.txt").write_text("divergent content\n")
        subprocess.run(["git", "-C", str(self.host_repo), "add", "divergent.txt"], check=True)
        subprocess.run(["git", "-C", str(self.host_repo), "commit", "-m", "divergent commit"], check=True)
        div_sha = subprocess.check_output(["git", "-C", str(self.host_repo), "rev-parse", "HEAD"], text=True).strip()
        subprocess.run(["git", "-C", str(self.host_repo), "update-ref", "refs/heads/sub/div-br", div_sha], check=True)

        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path, manifest_path)
        self.assertIn("diverges from expected SHA", str(cm.exception))

        # Sandbox must NOT be deleted
        self.assertIn("box-div", self.sbx_manager.sandboxes)
        self.assertEqual(len(self.sbx_manager.rm_calls), 0)

    def test_retire_rejects_stale_preservation_when_guest_mutated(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-stale",
            name="box-stale",
            branch="task/stale-br",
            sub_branch="sub/stale-br",
            with_worktree=False,
        )
        # Mutate guest after preservation
        box = self.sbx_manager.sandboxes["box-stale"]
        guest_repo = box["guest_repo"]
        (guest_repo / "unpreserved.txt").write_text("unpreserved data\n")

        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path, manifest_path)
        self.assertIn("Guest state has changed since preservation export", str(cm.exception))

        # Sandbox must NOT be deleted
        self.assertIn("box-stale", self.sbx_manager.sandboxes)
        self.assertEqual(len(self.sbx_manager.rm_calls), 0)

    def test_retire_rejects_sandbox_id_mismatch(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-mis",
            name="box-mis",
            branch="task/mis-br",
            sub_branch="sub/mis-br",
            with_worktree=False,
        )
        # Change ID in sandbox manager
        self.sbx_manager.sandboxes["box-mis"]["id"] = "different-unauthorized-id"

        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path, manifest_path)
        self.assertIn("Sandbox identity mismatch", str(cm.exception))
        self.assertEqual(len(self.sbx_manager.rm_calls), 0)

    def test_retire_rejects_missing_or_unaccepted_manifest(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-man-chk",
            name="box-man-chk",
            branch="task/man-br",
            sub_branch="sub/man-br",
            with_worktree=False,
        )
        non_manifest = self.manifests_dir / "nonexistent.json"
        with self.assertRaises(FileNotFoundError):
            task.retire_task(rec_path, non_manifest)

        # Unaccepted status
        unacc_path = self.manifests_dir / "unaccepted.json"
        data = json.loads(manifest_path.read_text())
        data["status"] = "prepared"
        unacc_path.write_text(json.dumps(data))
        os.chmod(unacc_path, 0o600)
        with self.assertRaises(ValueError) as cm:
            task.retire_task(rec_path, unacc_path)
        self.assertIn("expected 'accepted'", str(cm.exception))

        # Task ID mismatch
        mismatch_path = self.manifests_dir / "mismatch.json"
        data["status"] = "accepted"
        data["task_id"] = "wrong-task-id"
        mismatch_path.write_text(json.dumps(data))
        os.chmod(mismatch_path, 0o600)
        with self.assertRaises(ValueError) as cm:
            task.retire_task(rec_path, mismatch_path)
        self.assertIn("does not match record task_id", str(cm.exception))

    def test_retire_rejects_corrupted_preservation_checksum(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-corrupt",
            name="box-corrupt",
            branch="task/corrupt-br",
            sub_branch="sub/corrupt-br",
            with_worktree=False,
        )
        pres_dir = self.root / "preserved_retire-corrupt"
        # Tamper with bundle file
        bundle_file = pres_dir / "repo.bundle"
        bundle_file.write_bytes(bundle_file.read_bytes() + b"\ncorrupt")

        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path, manifest_path)
        self.assertIn("checksum mismatch", str(cm.exception))
        self.assertIn("box-corrupt", self.sbx_manager.sandboxes)

    def test_retire_dirty_worktree_rejections(self):
        # 1. Unstaged tracked changes
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-wt-dirty1",
            name="box-wt-dirty1",
            branch="task/wt-dirty1",
            sub_branch="sub/wt-dirty1",
            with_worktree=True,
        )
        (wt_dir / "README.md").write_text("unstaged modification\n")
        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path, manifest_path)
        self.assertIn("unstaged tracked changes", str(cm.exception))
        self.assertIn("box-wt-dirty1", self.sbx_manager.sandboxes)
        self.assertEqual(len(self.sbx_manager.rm_calls), 0)

        # 2. Staged uncommitted changes
        rec_path2, manifest_path2, wt_dir2, sub_sha2 = self._setup_completed_task(
            task_id="retire-wt-dirty2",
            name="box-wt-dirty2",
            branch="task/wt-dirty2",
            sub_branch="sub/wt-dirty2",
            with_worktree=True,
        )
        (wt_dir2 / "staged.txt").write_text("staged content\n")
        subprocess.run(["git", "-C", str(wt_dir2), "add", "staged.txt"], check=True)
        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path2, manifest_path2)
        self.assertIn("staged uncommitted changes", str(cm.exception))
        self.assertIn("box-wt-dirty2", self.sbx_manager.sandboxes)

        # 3. Untracked files
        rec_path3, manifest_path3, wt_dir3, sub_sha3 = self._setup_completed_task(
            task_id="retire-wt-dirty3",
            name="box-wt-dirty3",
            branch="task/wt-dirty3",
            sub_branch="sub/wt-dirty3",
            with_worktree=True,
        )
        (wt_dir3 / "untracked.txt").write_text("untracked\n")
        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path3, manifest_path3)
        self.assertIn("untracked files", str(cm.exception))
        self.assertIn("box-wt-dirty3", self.sbx_manager.sandboxes)

        # 4. Ignored files
        rec_path4, manifest_path4, wt_dir4, sub_sha4 = self._setup_completed_task(
            task_id="retire-wt-dirty4",
            name="box-wt-dirty4",
            branch="task/wt-dirty4",
            sub_branch="sub/wt-dirty4",
            with_worktree=True,
        )
        (self.host_repo / ".git" / "info").mkdir(parents=True, exist_ok=True)
        (self.host_repo / ".git" / "info" / "exclude").write_text("*.log\n")
        (wt_dir4 / "test.log").write_text("ignored log data\n")
        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path4, manifest_path4)
        self.assertIn("ignored files", str(cm.exception))
        self.assertIn("box-wt-dirty4", self.sbx_manager.sandboxes)

    def test_retire_rejects_main_worktree_and_cwd(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-main-wt",
            name="box-main-wt",
            branch="task/main-wt",
            sub_branch="sub/main-wt",
            with_worktree=False,
        )
        # Attempt to retire main repo checkout as worktree
        with self.assertRaises(ValueError) as cm:
            task.retire_task(rec_path, manifest_path, worktree_path=self.host_repo)
        self.assertIn("main repository checkout", str(cm.exception))

        # Attempt to retire current working directory
        with self.assertRaises(ValueError) as cm:
            task.retire_task(rec_path, manifest_path, worktree_path=Path.cwd())
        self.assertIn("inside target worktree", str(cm.exception))

    def test_retire_journal_resumption_and_idempotency(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-resume",
            name="box-resume",
            branch="task/resume",
            sub_branch="sub/resume",
            with_worktree=True,
        )
        # Simulate partial failure: sandbox was stopped and removed, record has phase sandbox_removed
        del self.sbx_manager.sandboxes["box-resume"]
        rec = task.read_task_record(rec_path, require_sandbox_id=False)
        rec["retirement"] = {
            "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "phase": "sandbox_removed",
            "manifest_path": str(manifest_path.resolve()),
            "submitted_sha": sub_sha,
            "submission_branch": "sub/resume",
            "host_worktree": str(wt_dir.resolve()),
            "phases": [{"phase": "sandbox_removed", "timestamp": "...", "status": "completed"}],
        }
        task.write_task_record(rec_path, rec)

        # Retry retirement: skips missing sandbox and completes worktree removal
        res = task.retire_task(rec_path, manifest_path)
        self.assertEqual(res["status"], "retired")
        self.assertEqual(res["worktree_removed"], str(wt_dir.resolve()))

        # Check worktree is gone
        wt_list = task.get_worktrees(self.host_repo)
        self.assertFalse(any(Path(w["worktree"]).resolve() == wt_dir.resolve() for w in wt_list))

        # Re-running on already retired task is idempotent
        res_idem = task.retire_task(rec_path, manifest_path)
        self.assertEqual(res_idem["status"], "retired")
        self.assertTrue(res_idem.get("already_retired"))

    def test_backward_compatibility_read_record(self):
        # Record with no host_worktree or retirement fields
        old_record = {
            "schema_version": 1,
            "task_id": "legacy-task",
            "sandbox_name": "legacy-box",
            "sandbox_id": "legacy-id",
            "host_repo": str(self.host_repo),
            "base_ref": "trunk",
            "base_commit": self.base_sha,
            "branch": "task/legacy",
            "status": "ready",
            "guest_harness_path": None,
        }
        rec_path = self.records_dir / "legacy.json"
        task.write_task_record(rec_path, old_record)

        loaded = task.read_task_record(rec_path, require_sandbox_id=False)
        self.assertEqual(loaded["task_id"], "legacy-task")
        self.assertIsNone(loaded.get("host_worktree"))
        self.assertIsNone(loaded.get("retirement"))

        # Retired record
        old_record["status"] = "retired"
        task.write_task_record(rec_path, old_record)
        loaded_retired = task.read_task_record(rec_path, require_sandbox_id=False)
        self.assertEqual(loaded_retired["status"], "retired")

    def test_cli_retire_and_register_worktree(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-cli",
            name="box-retire-cli",
            branch="task/retire-cli",
            sub_branch="sub/retire-cli",
            with_worktree=False,
        )
        # Create worktree manually
        manifest = json.loads(manifest_path.read_text())
        rev_head = manifest["reviewed_head"]
        pres_dir = self.root / "preserved_retire-cli"
        subprocess.run(
            [
                "git",
                "-C",
                str(self.host_repo),
                "fetch",
                str(pres_dir / "repo.bundle"),
                f"{rev_head}:task/retire-cli",
            ],
            check=True,
            capture_output=True,
        )
        wt_dir = self.root / "wt_cli"
        subprocess.run(["git", "-C", str(self.host_repo), "worktree", "add", str(wt_dir), "task/retire-cli"], check=True, capture_output=True)

        ret_reg = task.main(["register-worktree", "--record", str(rec_path), "--worktree", str(wt_dir)])
        self.assertEqual(ret_reg, 0)
        rec = task.read_task_record(rec_path, require_sandbox_id=False)
        self.assertEqual(rec["host_worktree"], str(wt_dir.resolve()))

        ret_retire = task.main(["retire", "--record", str(rec_path), "--manifest", str(manifest_path)])
        self.assertEqual(ret_retire, 0)
        self.assertNotIn("box-retire-cli", self.sbx_manager.sandboxes)
        wt_list = task.get_worktrees(self.host_repo)
        self.assertFalse(any(Path(w["worktree"]).resolve() == wt_dir.resolve() for w in wt_list))

    def test_retire_stops_before_removal_on_branch_fetch_failure(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-fetch-fail",
            name="box-fetch-fail",
            branch="task/fetch-fail",
            sub_branch="sub/fetch-fail",
            with_worktree=False,
            host_has_sub_branch=False,
        )
        # Ensure sub_branch does not exist on host
        subprocess.run(["git", "-C", str(self.host_repo), "branch", "-D", "sub/fetch-fail"], capture_output=True)
        # Simulate fetch failure
        self.sbx_manager.fail_git_fetch = True

        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path, manifest_path)
        self.assertIn("could not be made durable", str(cm.exception))

        # Sandbox must NOT have been stopped or removed
        self.assertIn("box-fetch-fail", self.sbx_manager.sandboxes)
        self.assertEqual(len(self.sbx_manager.stop_calls), 0)
        self.assertEqual(len(self.sbx_manager.rm_calls), 0)

        # Task record must not be retired
        rec_post = task.read_task_record(rec_path, require_sandbox_id=False)
        self.assertNotEqual(rec_post.get("status"), "retired")

    def test_retire_rejects_worktree_mismatch_with_registered(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-wt-mismatch",
            name="box-wt-mismatch",
            branch="task/wt-mismatch",
            sub_branch="sub/wt-mismatch",
            with_worktree=True,
        )
        mismatch_wt = self.root / "other_unregistered_worktree"
        mismatch_wt.mkdir(parents=True, exist_ok=True)

        with self.assertRaises(ValueError) as cm:
            task.retire_task(rec_path, manifest_path, worktree_path=mismatch_wt)
        self.assertIn("does not match registered host worktree", str(cm.exception))

        # Neither worktree nor sandbox should be removed
        self.assertTrue(wt_dir.exists())
        self.assertIn("box-wt-mismatch", self.sbx_manager.sandboxes)
        self.assertEqual(len(self.sbx_manager.rm_calls), 0)
        rec_post = task.read_task_record(rec_path, require_sandbox_id=False)
        self.assertNotEqual(rec_post.get("status"), "retired")

    def test_retire_worktree_recheck_mutation_between_phases(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-wt-race",
            name="box-wt-race",
            branch="task/wt-race",
            sub_branch="sub/wt-race",
            with_worktree=True,
        )

        def on_rm(name):
            # Simulate concurrent mutation staged in worktree between sandbox rm and worktree rm
            mutation = wt_dir / "concurrent_staged.txt"
            mutation.write_text("concurrent staged data\n")
            subprocess.run(["git", "-C", str(wt_dir), "add", "concurrent_staged.txt"], check=True)

        self.sbx_manager.on_rm_callback = on_rm

        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path, manifest_path)
        self.assertIn("has staged uncommitted changes", str(cm.exception))

        # Sandbox was stopped and removed
        self.assertNotIn("box-wt-race", self.sbx_manager.sandboxes)
        self.assertTrue(any(c[1] == "rm" and "--force" in c and "box-wt-race" in c for c in self.sbx_manager.rm_calls))

        # But worktree removal was aborted immediately upon cleanliness recheck
        self.assertTrue(wt_dir.exists())
        self.assertTrue((wt_dir / "concurrent_staged.txt").exists())
        wt_list = task.get_worktrees(self.host_repo)
        self.assertTrue(any(Path(w["worktree"]).resolve() == wt_dir.resolve() for w in wt_list))

        # Journal shows sandbox_removed, but not worktree_removed or completed
        rec = task.read_task_record(rec_path, require_sandbox_id=False)
        self.assertEqual(rec["retirement"]["phase"], "sandbox_removed")
        self.assertNotEqual(rec["status"], "retired")

    def test_retire_rejects_initially_stopped_sandbox(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-init-stopped",
            name="box-init-stopped",
            branch="task/init-stopped",
            sub_branch="sub/init-stopped",
            with_worktree=False,
        )
        # Sandbox is observed stopped before any recorded retirement phase
        self.sbx_manager.sandboxes["box-init-stopped"]["status"] = "stopped"

        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path, manifest_path)
        self.assertIn("is stopped", str(cm.exception))
        self.assertIn("task.py start", str(cm.exception))

        # No stop or rm calls must have been dispatched
        self.assertEqual(len(self.sbx_manager.stop_calls), 0)
        self.assertEqual(len(self.sbx_manager.rm_calls), 0)

        # Sandbox must NOT be deleted
        self.assertIn("box-init-stopped", self.sbx_manager.sandboxes)
        rec = task.read_task_record(rec_path, require_sandbox_id=False)
        self.assertNotEqual(rec.get("status"), "retired")

    def test_retire_does_not_create_wrong_branch_on_stale_bundle_ref(self):
        rec_path, manifest_path, wt_dir, sub_sha = self._setup_completed_task(
            task_id="retire-stale-ref",
            name="box-stale-ref",
            branch="task/stale-ref",
            sub_branch="sub/stale-ref",
            with_worktree=False,
            host_has_sub_branch=False,
        )
        # Ensure sub/stale-ref does not exist on host
        res = subprocess.run(
            ["git", "-C", str(self.host_repo), "rev-parse", "--verify", "-q", "refs/heads/sub/stale-ref"],
            capture_output=True,
        )
        self.assertNotEqual(res.returncode, 0)

        # Modify manifest with a non-existent target commit SHA
        # The preservation bundle still has a named ref 'refs/heads/sub/stale-ref' pointing to rev_head
        m_data = json.loads(manifest_path.read_text())
        m_data["submitted_sha"] = "0" * 40
        manifest_path.write_text(json.dumps(m_data, indent=2))

        with self.assertRaises(RuntimeError) as cm:
            task.retire_task(rec_path, manifest_path)
        self.assertIn("could not be made durable", str(cm.exception))

        # Crucial check: verify that host repository does NOT have refs/heads/sub/stale-ref created
        res_post = subprocess.run(
            ["git", "-C", str(self.host_repo), "rev-parse", "--verify", "-q", "refs/heads/sub/stale-ref"],
            capture_output=True,
        )
        self.assertNotEqual(res_post.returncode, 0, "Wrong branch ref must not be created on host from stale bundle ref")


if __name__ == "__main__":
    unittest.main()
