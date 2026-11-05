#!/usr/bin/env python3
"""Integration tests for sandbox/submit.py.

Exercises prepare, accept, and assemble stages using real temporary Git fixtures.
Covers:
- multiple checkpoint commits -> single submission with equal tree
- zero diff
- wrong head / base / branch
- dirty / index / untracked files
- bad records and schema validation
- output overwrite refusal
- extra commit / merge rejected
- preserve trailers and commit attribution
- two independent tasks common base
- dependent task based on accepted submission SHA
- missing and reordered dependencies
- undeclared base
- duplicate task / commit
- conflict and empty application keeping inspectable state with incomplete record
- review rework 1 regressions:
  - accept verifies actual reviewed Git-object binding, ancestry, and tree
  - assemble verifies reviewed Git-object binding, acceptance flag, evidence, and message
  - assemble rejects empty tasks on fast-forward path
  - dependencies must be unique, non-self, exact, and present in base ancestry (rejects multi-tip prerequisites)
  - git reads fail closed on nonzero exits (e.g. git diff exit 128)
  - prepare requires exact SHAs (rejects symbolic refs) and explicit implementation branch
  - prepare verifies staged write-tree equals reviewed tree
  - post-mutation exceptions persist incomplete diagnostics without rollback
- CLI invocation
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from sandbox.submit import (
    check_no_ignored_collisions,
    check_ref_absent,
    cmd_accept,
    cmd_assemble,
    cmd_prepare,
    main,
    read_json_record,
    write_json_record,
)


class TestSubmit(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmpdir.name)
        self.records_dir = self.root / "records"
        self.records_dir.mkdir(mode=0o700, parents=True, exist_ok=True)

    def tearDown(self):
        self.tmpdir.cleanup()

    def _init_repo(self, path: Path) -> str:
        """Create a clean git repository with initial commit on trunk."""
        path.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "-b", "trunk", str(path)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(path), "config", "user.name", "Aoi Kondo"], check=True)
        subprocess.run(["git", "-C", str(path), "config", "user.email", "aoi.kondo@admidori.net"], check=True)
        subprocess.run(["git", "-C", str(path), "config", "commit.gpgsign", "false"], check=True)
        readme = path / "README.md"
        readme.write_text("# Test Repo\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(path), "add", "README.md"], check=True)
        subprocess.run(["git", "-C", str(path), "commit", "-m", "chore: initial commit"], check=True)
        res = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
        return res.stdout.strip()

    def _clone_repo(self, src: Path, dest: Path) -> None:
        """Clone repository and configure user identity for commits/cherry-picks."""
        subprocess.run(["git", "clone", str(src), str(dest)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(dest), "config", "user.name", "Aoi Kondo"], check=True)
        subprocess.run(["git", "-C", str(dest), "config", "user.email", "aoi.kondo@admidori.net"], check=True)
        subprocess.run(["git", "-C", str(dest), "config", "commit.gpgsign", "false"], check=True)

    def _commit_files(self, repo: Path, files: dict[str, str], message: str) -> str:
        """Write files, stage, and commit with message."""
        for rel_path, content in files.items():
            f_path = repo / rel_path
            f_path.parent.mkdir(parents=True, exist_ok=True)
            f_path.write_text(content, encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", rel_path], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-m", message], check=True)
        res = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
        return res.stdout.strip()

    def test_multiple_checkpoints_to_single_submission_equal_tree(self):
        """Multiple checkpoint commits squashed into single submission with identical tree."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        # Create task branch with 3 linear checkpoint commits
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/my-task", base_sha], check=True)
        c1 = self._commit_files(repo, {"foo.txt": "foo 1\n"}, "feat: checkpoint 1")
        c2 = self._commit_files(repo, {"foo.txt": "foo 2\n", "bar.txt": "bar\n"}, "feat: checkpoint 2")
        reviewed_sha = self._commit_files(
            repo,
            {"foo.txt": "foo final\n", "bar.txt": "bar\n", "baz.txt": "baz\n"},
            "feat: checkpoint 3 (final)",
        )

        cand_path = self.records_dir / "candidate_01.json"
        res_cand = cmd_prepare(
            repo_path=repo,
            task_id="task-01",
            base_ref=base_sha,
            reviewed_ref=reviewed_sha,
            submission_branch="sub/task-01",
            output_path=cand_path,
            implementation_branch="task/my-task",
        )

        self.assertEqual(res_cand["status"], "prepared")
        self.assertEqual(res_cand["task_id"], "task-01")
        self.assertEqual(res_cand["base_commit"], base_sha)
        self.assertEqual(res_cand["reviewed_head"], reviewed_sha)

        # Verify candidate record file on disk
        cand_on_disk = read_json_record(cand_path)
        self.assertEqual(cand_on_disk["status"], "prepared")
        self.assertEqual(cand_on_disk["reviewed_tree"], res_cand["reviewed_tree"])

        # Check repo state: checked out on sub/task-01 at base_sha, changes staged in index
        current_branch = subprocess.run(
            ["git", "-C", str(repo), "symbolic-ref", "--short", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertEqual(current_branch, "sub/task-01")

        current_head = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertEqual(current_head, base_sha)

        # Designer manually commits the squash-staged submission
        designer_msg = (
            "feat(foo): add foo, bar, and baz\n\n"
            "Combine all three components into single reviewed submission.\n\n"
            "Co-authored-by: Designer (Opus) <noreply@anthropic.com>\n"
            "Co-authored-by: Antigravity (Gemini 3.8 Flash) <noreply@google.com>"
        )
        subprocess.run(["git", "-C", str(repo), "commit", "-m", designer_msg], check=True)
        submitted_sha = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        # Call accept
        manifest_path = self.records_dir / "manifest_01.json"
        res_manifest = cmd_accept(
            candidate_path=cand_path,
            output_path=manifest_path,
            designer_accepted=True,
            verification_evidence="All 42 tests passed; clean diff verified against reviewed implementation.",
        )

        self.assertEqual(res_manifest["status"], "accepted")
        self.assertEqual(res_manifest["task_id"], "task-01")
        self.assertEqual(res_manifest["submitted_sha"], submitted_sha)
        self.assertEqual(res_manifest["base_commit"], base_sha)
        self.assertEqual(res_manifest["submitted_tree"], res_cand["reviewed_tree"])

        # Verify manifest file permissions (0600)
        st = manifest_path.lstat()
        self.assertEqual(st.st_mode & 0o777, 0o600)

    def test_zero_diff_rejected(self):
        """Preparation is rejected when diff between base and reviewed SHA is empty."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        # Implementation branch with zero diff (pointing directly to base)
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/zero-diff", base_sha], check=True)

        cand_path = self.records_dir / "candidate_zero.json"
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-zero",
                base_ref=base_sha,
                reviewed_ref=base_sha,
                submission_branch="sub/task-zero",
                output_path=cand_path,
                implementation_branch="task/zero-diff",
            )
        self.assertIn("Diff check", str(ctx.exception))
        self.assertFalse(cand_path.exists())

    def test_wrong_head_rejected(self):
        """Preparation is rejected when current HEAD does not match reviewed SHA."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/wrong-head", base_sha], check=True)
        c1 = self._commit_files(repo, {"a.txt": "a\n"}, "feat: c1")
        c2 = self._commit_files(repo, {"b.txt": "b\n"}, "feat: c2")

        cand_path = self.records_dir / "candidate_wrong_head.json"
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-wh",
                base_ref=base_sha,
                reviewed_ref=c1,  # reviewed c1, but HEAD is c2
                submission_branch="sub/task-wh",
                output_path=cand_path,
                implementation_branch="task/wrong-head",
            )
        self.assertIn("does not match reviewed implementation SHA", str(ctx.exception))
        self.assertFalse(cand_path.exists())

    def test_wrong_base_rejected(self):
        """Preparation is rejected when base is not an ancestor of reviewed SHA."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "branch-a", base_sha], check=True)
        ca = self._commit_files(repo, {"a.txt": "a\n"}, "feat: branch a")

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "branch-b", base_sha], check=True)
        cb = self._commit_files(repo, {"b.txt": "b\n"}, "feat: branch b")

        # Now try to prepare branch-b with base=ca (ca is not ancestor of cb)
        cand_path = self.records_dir / "candidate_wb.json"
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-wb",
                base_ref=ca,
                reviewed_ref=cb,
                submission_branch="sub/task-wb",
                output_path=cand_path,
                implementation_branch="branch-b",
            )
        self.assertIn("is not an ancestor", str(ctx.exception))
        self.assertFalse(cand_path.exists())

    def test_wrong_branch_rejected(self):
        """Preparation is rejected on wrong branch or default branch."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/actual-branch", base_sha], check=True)
        c1 = self._commit_files(repo, {"foo.txt": "foo\n"}, "feat: foo")

        cand_path = self.records_dir / "candidate_wbr.json"
        # Caller claims implementation branch is task/expected-branch
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-wbr",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/task-wbr",
                output_path=cand_path,
                implementation_branch="task/expected-branch",
            )
        self.assertIn("does not match implementation branch", str(ctx.exception))

        # Checkout forbidden main branch and try to prepare
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "main", c1], check=True)
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-default",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/task-default",
                output_path=cand_path,
                implementation_branch="main",
            )
        self.assertIn("master and main branches are forbidden", str(ctx.exception))

    def test_dirty_files_rejected(self):
        """Dirty tracked, staged, or untracked files are rejected in prepare and accept."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/dirty", base_sha], check=True)
        c1 = self._commit_files(repo, {"foo.txt": "foo\n"}, "feat: foo")

        cand_path = self.records_dir / "candidate_dirty.json"

        # 1. Untracked file
        untracked = repo / "untracked.tmp"
        untracked.write_text("untracked\n", encoding="utf-8")
        with self.assertRaises(RuntimeError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-dirty",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/task-dirty",
                output_path=cand_path,
                implementation_branch="task/dirty",
            )
        self.assertIn("untracked files", str(ctx.exception))
        untracked.unlink()

        # 2. Unstaged tracked modification
        (repo / "foo.txt").write_text("modified without staging\n", encoding="utf-8")
        with self.assertRaises(RuntimeError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-dirty",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/task-dirty",
                output_path=cand_path,
                implementation_branch="task/dirty",
            )
        self.assertIn("unstaged tracked changes", str(ctx.exception))
        # Revert
        subprocess.run(["git", "-C", str(repo), "checkout", "--", "foo.txt"], check=True)

        # 3. Staged uncommitted change
        (repo / "foo.txt").write_text("staged change\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repo), "add", "foo.txt"], check=True)
        with self.assertRaises(RuntimeError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-dirty",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/task-dirty",
                output_path=cand_path,
                implementation_branch="task/dirty",
            )
        self.assertIn("staged uncommitted changes", str(ctx.exception))
        subprocess.run(["git", "-C", str(repo), "reset", "--hard", "HEAD"], check=True)

    def test_bad_records_rejected(self):
        """Malformed, corrupted, or invalid records are rejected."""
        bad_path = self.records_dir / "bad.json"

        # Missing file
        with self.assertRaises(FileNotFoundError):
            read_json_record(self.records_dir / "nonexistent.json")

        # Corrupt JSON
        bad_path.write_text("{ incomplete json ...", encoding="utf-8")
        os.chmod(bad_path, 0o600)
        with self.assertRaises(RuntimeError):
            read_json_record(bad_path)

        # Unsafe permissions (e.g. 0666)
        bad_path.write_text(json.dumps({"schema_version": 1}), encoding="utf-8")
        os.chmod(bad_path, 0o666)
        with self.assertRaises(RuntimeError) as ctx:
            read_json_record(bad_path)
        self.assertIn("unsafe permissions", str(ctx.exception))

        # Accept called with incomplete candidate record
        repo = self.root / "repo_bad_rec"
        self._init_repo(repo)
        os.chmod(bad_path, 0o600)
        write_json_record(
            bad_path,
            {
                "schema_version": 1,
                "record_type": "candidate",
                "task_id": "t1",
                "status": "incomplete",
                "repo": str(repo),
            },
        )
        with self.assertRaises(ValueError) as ctx:
            cmd_accept(
                candidate_path=bad_path,
                output_path=self.records_dir / "m_out.json",
                designer_accepted=True,
                verification_evidence="evidence",
            )
        self.assertIn("expected 'prepared'", str(ctx.exception))

    def test_output_overwrite_refusal(self):
        """Output records refuse to overwrite existing files."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/ow", base_sha], check=True)
        c1 = self._commit_files(repo, {"a.txt": "a\n"}, "feat: a")

        existing_cand = self.records_dir / "cand_existing.json"
        existing_cand.write_text("{}", encoding="utf-8")
        os.chmod(existing_cand, 0o600)

        with self.assertRaises(FileExistsError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-ow",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/task-ow",
                output_path=existing_cand,
                implementation_branch="task/ow",
            )
        self.assertIn("already exists", str(ctx.exception))

    def test_extra_commit_and_merge_rejected_in_accept(self):
        """Accept rejects merge commits, extra commits, and tree alterations."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/extra", base_sha], check=True)
        c1 = self._commit_files(repo, {"a.txt": "a\n"}, "feat: a")

        cand_path = self.records_dir / "cand_extra.json"
        cmd_prepare(
            repo_path=repo,
            task_id="task-extra",
            base_ref=base_sha,
            reviewed_ref=c1,
            submission_branch="sub/task-extra",
            output_path=cand_path,
            implementation_branch="task/extra",
        )

        # 1. Designer makes 2 commits instead of 1
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "commit 1"], check=True)
        self._commit_files(repo, {"b.txt": "b\n"}, "commit 2")

        manifest_path = self.records_dir / "m_extra.json"
        with self.assertRaises(ValueError) as ctx:
            cmd_accept(
                candidate_path=cand_path,
                output_path=manifest_path,
                designer_accepted=True,
                verification_evidence="tests passed",
            )
        self.assertIn("does not match candidate base commit", str(ctx.exception))

        # Reset to base_sha and squash again to test tree alteration
        subprocess.run(["git", "-C", str(repo), "reset", "--hard", base_sha], check=True)
        subprocess.run(["git", "-C", str(repo), "merge", "--squash", c1], check=True)
        # Designer modifies a file before committing (unexplained change to tree)
        (repo / "a.txt").write_text("a altered\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repo), "add", "a.txt"], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: altered commit"], check=True)

        with self.assertRaises(ValueError) as ctx:
            cmd_accept(
                candidate_path=cand_path,
                output_path=manifest_path,
                designer_accepted=True,
                verification_evidence="tests passed",
            )
        self.assertIn("does not match reviewed implementation tree", str(ctx.exception))

        # Missing explicit designer acceptance indicator
        with self.assertRaises(ValueError) as ctx:
            cmd_accept(
                candidate_path=cand_path,
                output_path=manifest_path,
                designer_accepted=False,
                verification_evidence="evidence",
            )
        self.assertIn("designer acceptance indicator", str(ctx.exception))

    def test_preserve_trailers_and_commit_attribution(self):
        """Attribution and trailers are fully preserved across assemble."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        # Task 1
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/trailers", base_sha], check=True)
        c1 = self._commit_files(repo, {"lib.py": "x = 1\n"}, "feat: init lib")

        cand1 = self.records_dir / "cand_tr.json"
        cmd_prepare(
            repo_path=repo,
            task_id="task-tr",
            base_ref=base_sha,
            reviewed_ref=c1,
            submission_branch="sub/task-tr",
            output_path=cand1,
            implementation_branch="task/trailers",
        )

        full_message = (
            "feat(lib): add calculation routine\n\n"
            "This implements the core library with strict error bounds.\n\n"
            "Co-authored-by: Codex (gpt-6-sol) <noreply@openai.com>\n"
            "Co-authored-by: Antigravity (Gemini 3.8 Flash) <noreply@google.com>"
        )
        subprocess.run(["git", "-C", str(repo), "commit", "-m", full_message], check=True)

        man1 = self.records_dir / "man_tr.json"
        cmd_accept(
            candidate_path=cand1,
            output_path=man1,
            designer_accepted=True,
            verification_evidence="Full test suite passed",
        )

        # Assemble onto PR branch
        int_repo = self.root / "int_repo"
        self._clone_repo(repo, int_repo)

        ass_path = self.records_dir / "ass_tr.json"
        cmd_assemble(
            repo_path=int_repo,
            base_ref=base_sha,
            pr_branch="pr/with-trailers",
            manifest_paths=[man1],
            output_path=ass_path,
        )

        assembled_msg = subprocess.run(
            ["git", "-C", str(int_repo), "log", "-1", "--format=%B", "pr/with-trailers"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertEqual(assembled_msg, full_message)

    def test_two_independent_tasks_common_base(self):
        """Two independent tasks starting from common base assemble cleanly via fast-forward + cherry-pick."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        # Task 1
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/ind-1", base_sha], check=True)
        c1 = self._commit_files(repo, {"file1.txt": "file1 content\n"}, "feat: task 1")
        cand1 = self.records_dir / "cand_ind1.json"
        cmd_prepare(repo, "task-1", base_sha, c1, "sub/task-1", cand1, implementation_branch="task/ind-1")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: task 1 submitted"], check=True)
        man1 = self.records_dir / "man_ind1.json"
        m1 = cmd_accept(cand1, man1, designer_accepted=True, verification_evidence="evidence 1")

        # Task 2 (same base)
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/ind-2", base_sha], check=True)
        c2 = self._commit_files(repo, {"file2.txt": "file2 content\n"}, "feat: task 2")
        cand2 = self.records_dir / "cand_ind2.json"
        cmd_prepare(repo, "task-2", base_sha, c2, "sub/task-2", cand2, implementation_branch="task/ind-2")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: task 2 submitted"], check=True)
        man2 = self.records_dir / "man_ind2.json"
        m2 = cmd_accept(cand2, man2, designer_accepted=True, verification_evidence="evidence 2")

        # Integration clone
        int_repo = self.root / "int_repo_ind"
        self._clone_repo(repo, int_repo)

        ass_path = self.records_dir / "ass_ind.json"
        res_ass = cmd_assemble(
            repo_path=int_repo,
            base_ref=base_sha,
            pr_branch="pr/independent-tasks",
            manifest_paths=[man1, man2],
            output_path=ass_path,
        )

        self.assertEqual(res_ass["status"], "prepared")
        self.assertEqual(len(res_ass["assembled_commits"]), 2)
        self.assertEqual(res_ass["assembled_commits"][0]["method"], "fast-forward")
        self.assertEqual(res_ass["assembled_commits"][1]["method"], "cherry-pick")

        # Verify both files exist in the assembled PR branch
        subprocess.run(["git", "-C", str(int_repo), "checkout", "pr/independent-tasks"], check=True)
        self.assertTrue((int_repo / "file1.txt").exists())
        self.assertTrue((int_repo / "file2.txt").exists())

    def test_dependent_task_based_on_accepted_submission_sha(self):
        """Dependent task based on earlier accepted submission SHA fast-forwards cleanly."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        # Task 1
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/dep-1", base_sha], check=True)
        c1 = self._commit_files(repo, {"core.txt": "core v1\n"}, "feat(core): checkpoint")
        cand1 = self.records_dir / "cand_d1.json"
        cmd_prepare(repo, "task-1", base_sha, c1, "sub/task-1", cand1, implementation_branch="task/dep-1")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat(core): accept core"], check=True)
        man1 = self.records_dir / "man_d1.json"
        m1 = cmd_accept(cand1, man1, designer_accepted=True, verification_evidence="core verified")
        s1 = m1["submitted_sha"]

        # Task 2 builds directly on accepted S1
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/dep-2", s1], check=True)
        c2 = self._commit_files(repo, {"extension.txt": "ext v1\n"}, "feat(ext): checkpoint")
        cand2 = self.records_dir / "cand_d2.json"
        cmd_prepare(
            repo_path=repo,
            task_id="task-2",
            base_ref=s1,
            reviewed_ref=c2,
            submission_branch="sub/task-2",
            output_path=cand2,
            implementation_branch="task/dep-2",
            dependencies=[{"task_id": "task-1", "accepted_sha": s1}],
        )
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat(ext): accept ext"], check=True)
        man2 = self.records_dir / "man_d2.json"
        m2 = cmd_accept(
            candidate_path=cand2,
            output_path=man2,
            designer_accepted=True,
            verification_evidence="ext verified",
        )
        s2 = m2["submitted_sha"]

        # Integration clone
        int_repo = self.root / "int_repo_dep"
        self._clone_repo(repo, int_repo)

        ass_path = self.records_dir / "ass_dep.json"
        res_ass = cmd_assemble(
            repo_path=int_repo,
            base_ref=base_sha,
            pr_branch="pr/pipeline",
            manifest_paths=[man1, man2],
            output_path=ass_path,
        )

        self.assertEqual(res_ass["status"], "prepared")
        self.assertEqual(res_ass["assembled_commits"][0]["method"], "fast-forward")
        self.assertEqual(res_ass["assembled_commits"][1]["method"], "fast-forward")
        self.assertEqual(res_ass["assembled_commits"][0]["assembled_sha"], s1)
        self.assertEqual(res_ass["assembled_commits"][1]["assembled_sha"], s2)

    def test_missing_and_reordered_dependencies_rejected(self):
        """Assembly rejects missing dependencies, reordered manifests, and SHA mismatches."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        # Task 1
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/ord-1", base_sha], check=True)
        c1 = self._commit_files(repo, {"a.txt": "a\n"}, "feat: a")
        cand1 = self.records_dir / "cand_o1.json"
        cmd_prepare(repo, "task-1", base_sha, c1, "sub/task-1", cand1, implementation_branch="task/ord-1")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: a submitted"], check=True)
        man1 = self.records_dir / "man_o1.json"
        m1 = cmd_accept(cand1, man1, designer_accepted=True, verification_evidence="evidence 1")
        s1 = m1["submitted_sha"]

        # Task 2 depends on Task 1
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/ord-2", s1], check=True)
        c2 = self._commit_files(repo, {"b.txt": "b\n"}, "feat: b")
        cand2 = self.records_dir / "cand_o2.json"
        cmd_prepare(
            repo, "task-2", s1, c2, "sub/task-2", cand2,
            implementation_branch="task/ord-2",
            dependencies=[{"task_id": "task-1", "accepted_sha": s1}],
        )
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: b submitted"], check=True)
        man2 = self.records_dir / "man_o2.json"
        m2 = cmd_accept(cand2, man2, designer_accepted=True, verification_evidence="evidence 2")

        int_repo = self.root / "int_repo_ord"
        self._clone_repo(repo, int_repo)

        # 1. Reordered: manifests=[man2, man1]
        with self.assertRaises(ValueError) as ctx:
            cmd_assemble(
                repo_path=int_repo,
                base_ref=base_sha,
                pr_branch="pr/reordered",
                manifest_paths=[man2, man1],
                output_path=self.records_dir / "ass_reorder.json",
            )
        self.assertIn("does not precede it in manifest order", str(ctx.exception))

        # 2. Missing dependency: manifests=[man2]
        with self.assertRaises(ValueError) as ctx:
            cmd_assemble(
                repo_path=int_repo,
                base_ref=base_sha,
                pr_branch="pr/missing",
                manifest_paths=[man2],
                output_path=self.records_dir / "ass_missing.json",
            )
        self.assertIn("does not precede it in manifest order", str(ctx.exception))

    def test_undeclared_base_rejected(self):
        """Tasks with bases not matching assembly base or declared dependencies are rejected."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        # Task 1
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/u-1", base_sha], check=True)
        c1 = self._commit_files(repo, {"a.txt": "a\n"}, "feat: a")
        cand1 = self.records_dir / "cand_u1.json"
        cmd_prepare(repo, "task-1", base_sha, c1, "sub/task-1", cand1, implementation_branch="task/u-1")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: a submitted"], check=True)
        man1 = self.records_dir / "man_u1.json"
        m1 = cmd_accept(cand1, man1, designer_accepted=True, verification_evidence="ev")
        s1 = m1["submitted_sha"]

        # Task 2 is built on s1, but DOES NOT declare task-1 in dependencies
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/u-2", s1], check=True)
        c2 = self._commit_files(repo, {"b.txt": "b\n"}, "feat: b")
        cand2 = self.records_dir / "cand_u2.json"
        cmd_prepare(repo, "task-2", s1, c2, "sub/task-2", cand2, implementation_branch="task/u-2", dependencies=[])
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: b submitted"], check=True)
        man2 = self.records_dir / "man_u2.json"
        m2 = cmd_accept(cand2, man2, designer_accepted=True, verification_evidence="ev")

        int_repo = self.root / "int_repo_undec"
        self._clone_repo(repo, int_repo)

        with self.assertRaises(ValueError) as ctx:
            cmd_assemble(
                repo_path=int_repo,
                base_ref=base_sha,
                pr_branch="pr/undec",
                manifest_paths=[man1, man2],
                output_path=self.records_dir / "ass_undec.json",
            )
        self.assertIn("which is neither the assembly base", str(ctx.exception))

    def test_duplicate_task_and_commit_rejected(self):
        """Duplicate task IDs and duplicate submitted SHAs are rejected during assembly."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/dup", base_sha], check=True)
        c1 = self._commit_files(repo, {"a.txt": "a\n"}, "feat: a")
        cand1 = self.records_dir / "cand_dup.json"
        cmd_prepare(repo, "task-dup", base_sha, c1, "sub/task-dup", cand1, implementation_branch="task/dup")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: a submitted"], check=True)
        man1 = self.records_dir / "man_dup.json"
        cmd_accept(cand1, man1, designer_accepted=True, verification_evidence="ev")

        int_repo = self.root / "int_repo_dup"
        self._clone_repo(repo, int_repo)

        # Duplicate manifest in input list
        with self.assertRaises(ValueError) as ctx:
            cmd_assemble(
                repo_path=int_repo,
                base_ref=base_sha,
                pr_branch="pr/dup",
                manifest_paths=[man1, man1],
                output_path=self.records_dir / "ass_dup.json",
            )
        self.assertIn("Duplicate task ID", str(ctx.exception))

    def test_conflict_leaves_inspectable_state_and_incomplete_record(self):
        """Cherry-pick conflict stops immediately, preserves unmerged work, and records incomplete state."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        # Common file in base
        base_sha = self._commit_files(repo, {"conflict.txt": "base line\n"}, "chore: add common file")

        # Task 1 modifies conflict.txt
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/c-1", base_sha], check=True)
        c1 = self._commit_files(repo, {"conflict.txt": "task 1 line\n"}, "feat: task 1 edit")
        cand1 = self.records_dir / "cand_c1.json"
        cmd_prepare(repo, "task-1", base_sha, c1, "sub/task-1", cand1, implementation_branch="task/c-1")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: task 1 squash"], check=True)
        man1 = self.records_dir / "man_c1.json"
        cmd_accept(cand1, man1, designer_accepted=True, verification_evidence="ev1")

        # Task 2 also modifies conflict.txt differently from base_sha
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/c-2", base_sha], check=True)
        c2 = self._commit_files(repo, {"conflict.txt": "task 2 conflicting line\n"}, "feat: task 2 edit")
        cand2 = self.records_dir / "cand_c2.json"
        cmd_prepare(repo, "task-2", base_sha, c2, "sub/task-2", cand2, implementation_branch="task/c-2")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: task 2 squash"], check=True)
        man2 = self.records_dir / "man_c2.json"
        cmd_accept(cand2, man2, designer_accepted=True, verification_evidence="ev2")

        int_repo = self.root / "int_repo_conflict"
        self._clone_repo(repo, int_repo)

        ass_path = self.records_dir / "ass_conflict.json"
        with self.assertRaises(RuntimeError) as ctx:
            cmd_assemble(
                repo_path=int_repo,
                base_ref=base_sha,
                pr_branch="pr/conflicted",
                manifest_paths=[man1, man2],
                output_path=ass_path,
            )
        self.assertIn("Cherry-pick conflict", str(ctx.exception))

        # Assembly record exists with incomplete status and conflict stage
        self.assertTrue(ass_path.exists())
        ass_rec = read_json_record(ass_path)
        self.assertEqual(ass_rec["status"], "incomplete")
        self.assertEqual(ass_rec["stage"], "conflict")
        self.assertEqual(ass_rec["failed_task_id"], "task-2")
        self.assertIn("Cherry-pick conflict", ass_rec["error"])

        # Integration repo is left in conflicted state (UU conflict.txt); not aborted/reset
        st_out = subprocess.run(
            ["git", "-C", str(int_repo), "status", "--porcelain"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("UU conflict.txt", st_out)

    def test_empty_application_rejected_and_incomplete_record(self):
        """Applying a task that produces an empty diff/commit is rejected and recorded incomplete."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        # Task 1 adds same_file.txt
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/e-1", base_sha], check=True)
        c1 = self._commit_files(repo, {"same.txt": "identical content\n"}, "feat: task 1 same")
        cand1 = self.records_dir / "cand_e1.json"
        cmd_prepare(repo, "task-1", base_sha, c1, "sub/task-1", cand1, implementation_branch="task/e-1")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: task 1 same submitted"], check=True)
        man1 = self.records_dir / "man_e1.json"
        cmd_accept(cand1, man1, designer_accepted=True, verification_evidence="ev1")

        # Task 2 adds identical same_file.txt from base_sha
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/e-2", base_sha], check=True)
        c2 = self._commit_files(repo, {"same.txt": "identical content\n"}, "feat: task 2 same")
        cand2 = self.records_dir / "cand_e2.json"
        cmd_prepare(repo, "task-2", base_sha, c2, "sub/task-2", cand2, implementation_branch="task/e-2")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: task 2 same submitted"], check=True)
        man2 = self.records_dir / "man_e2.json"
        cmd_accept(cand2, man2, designer_accepted=True, verification_evidence="ev2")

        int_repo = self.root / "int_repo_empty"
        self._clone_repo(repo, int_repo)

        ass_path = self.records_dir / "ass_empty.json"
        with self.assertRaises(RuntimeError) as ctx:
            cmd_assemble(
                repo_path=int_repo,
                base_ref=base_sha,
                pr_branch="pr/empty-diff",
                manifest_paths=[man1, man2],
                output_path=ass_path,
            )
        self.assertIn("empty or duplicate", str(ctx.exception))

        self.assertTrue(ass_path.exists())
        ass_rec = read_json_record(ass_path)
        self.assertEqual(ass_rec["status"], "incomplete")
        self.assertEqual(ass_rec["stage"], "empty_duplicate_rejected")

    def test_record_outside_repo_enforced(self):
        """Attempting to place candidate or manifest records inside repository is denied."""
        repo = self.root / "repo"
        base_sha = self._init_repo(repo)

        inside_cand = repo / "candidate.json"
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-ins",
                base_ref=base_sha,
                reviewed_ref=base_sha,
                submission_branch="sub/ins",
                output_path=inside_cand,
                implementation_branch="trunk",
            )
        self.assertIn("must be outside repository", str(ctx.exception))

    def test_candidate_incomplete_record_preserved_on_squash_failure(self):
        """Failure during Git mutation preserves incomplete record with error stage."""
        repo = self.root / "repo_squash_fail"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/sq-fail", base_sha], check=True)
        c1 = self._commit_files(repo, {"foo.txt": "foo\n"}, "feat: foo")

        cand_path = self.records_dir / "cand_sq_fail.json"

        # Create a mock git script that fails specifically on 'merge'
        mock_git = self.root / "mock_git.sh"
        mock_git.write_text(
            '#!/bin/sh\n'
            'for arg in "$@"; do\n'
            '  if [ "$arg" = "merge" ]; then\n'
            '    echo "fatal: simulated merge conflict/failure" >&2\n'
            '    exit 1\n'
            '  fi\n'
            'done\n'
            'exec /usr/bin/git "$@"\n',
            encoding="utf-8",
        )
        mock_git.chmod(0o755)

        with self.assertRaises(RuntimeError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-sq-fail",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/sq-fail",
                output_path=cand_path,
                implementation_branch="task/sq-fail",
                git_bin=str(mock_git),
            )
        self.assertIn("simulated merge conflict/failure", str(ctx.exception))

        # Output record must be preserved with incomplete status and merge_squash_failed stage
        self.assertTrue(cand_path.exists())
        rec = read_json_record(cand_path)
        self.assertEqual(rec["status"], "incomplete")
        self.assertEqual(rec["stage"], "merge_squash_failed")
        self.assertIn("simulated merge conflict/failure", rec["error"])

        # Current branch is sub/sq-fail, preserving state without auto-reset
        current_branch = subprocess.run(
            ["git", "-C", str(repo), "symbolic-ref", "--short", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertEqual(current_branch, "sub/sq-fail")

    # --- Review 1 Targeted Regressions ---

    def test_accept_verifies_reviewed_head_git_binding_and_tree(self):
        """Accept verifies actual Git commit object, tree, and ancestry of candidate reviewed_head."""
        repo = self.root / "repo_rev_binding"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/bind", base_sha], check=True)
        c1 = self._commit_files(repo, {"bind.txt": "content\n"}, "feat: bind commit")

        cand_path = self.records_dir / "cand_bind.json"
        cmd_prepare(repo, "task-bind", base_sha, c1, "sub/task-bind", cand_path, implementation_branch="task/bind")

        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: bind squashed"], check=True)

        # 1. Tamper reviewed_head to 40 'f' characters
        cand_data = read_json_record(cand_path)
        cand_data["reviewed_head"] = "f" * 40
        write_json_record(cand_path, cand_data)

        man_path = self.records_dir / "man_bind.json"
        with self.assertRaises(ValueError) as ctx:
            cmd_accept(cand_path, man_path, designer_accepted=True, verification_evidence="evidence")
        self.assertIn("does not exist as a commit object", str(ctx.exception))

        # 2. Tamper reviewed_tree to different SHA
        cand_data["reviewed_head"] = c1
        cand_data["reviewed_tree"] = "e" * 40
        write_json_record(cand_path, cand_data)

        with self.assertRaises(ValueError) as ctx:
            cmd_accept(cand_path, man_path, designer_accepted=True, verification_evidence="evidence")
        self.assertIn("does not match actual tree", str(ctx.exception))

    def test_assemble_verifies_reviewed_binding_acceptance_and_evidence(self):
        """Assemble verifies manifest reviewed_head binding, designer_accepted flag, and non-empty evidence."""
        repo = self.root / "repo_ass_binding"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/asm", base_sha], check=True)
        c1 = self._commit_files(repo, {"asm.txt": "content\n"}, "feat: asm commit")

        cand_path = self.records_dir / "cand_asm.json"
        cmd_prepare(repo, "task-asm", base_sha, c1, "sub/task-asm", cand_path, implementation_branch="task/asm")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: asm squashed"], check=True)

        man_path = self.records_dir / "man_asm.json"
        cmd_accept(cand_path, man_path, designer_accepted=True, verification_evidence="verified by test")

        int_repo = self.root / "int_repo_asm"
        self._clone_repo(repo, int_repo)

        # 1. Tamper reviewed_head in manifest to 40 'f' characters
        man_data = read_json_record(man_path)
        man_data["reviewed_head"] = "f" * 40
        write_json_record(man_path, man_data)

        with self.assertRaises(ValueError) as ctx:
            cmd_assemble(int_repo, base_sha, "pr/tamper-head", [man_path], self.records_dir / "ass_t1.json")
        self.assertIn("does not exist as a commit object", str(ctx.exception))

        # 2. Tamper designer_accepted to False
        man_data["reviewed_head"] = c1
        man_data["designer_accepted"] = False
        write_json_record(man_path, man_data)

        with self.assertRaises(ValueError) as ctx:
            cmd_assemble(int_repo, base_sha, "pr/tamper-acc", [man_path], self.records_dir / "ass_t2.json")
        self.assertIn("designer_accepted set to true", str(ctx.exception))

        # 3. Tamper verification_evidence to empty string
        man_data["designer_accepted"] = True
        man_data["verification_evidence"] = "   "
        write_json_record(man_path, man_data)

        with self.assertRaises(ValueError) as ctx:
            cmd_assemble(int_repo, base_sha, "pr/tamper-ev", [man_path], self.records_dir / "ass_t3.json")
        self.assertIn("verification_evidence", str(ctx.exception))

        # 4. Tamper commit_message to empty string
        man_data["verification_evidence"] = "valid evidence"
        man_data["commit_message"] = "   "
        write_json_record(man_path, man_data)

        with self.assertRaises(ValueError) as ctx:
            cmd_assemble(int_repo, base_sha, "pr/tamper-msg", [man_path], self.records_dir / "ass_t4.json")
        self.assertIn("commit_message", str(ctx.exception))

    def test_assemble_rejects_empty_task_on_fast_forward(self):
        """Assemble rejects empty single-parent task even on fast-forward path."""
        repo = self.root / "repo_ff_empty"
        base_sha = self._init_repo(repo)

        # Create branch from base with empty commit
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/ff-empty", base_sha], check=True)
        # Create commit that modifies a file, then revert so diff is nonempty at implementation time
        c1 = self._commit_files(repo, {"f.txt": "real edit\n"}, "feat: checkpoint")

        cand_path = self.records_dir / "cand_ff_e.json"
        cmd_prepare(repo, "task-ffe", base_sha, c1, "sub/task-ffe", cand_path, implementation_branch="task/ff-empty")

        # Now suppose designer manually resets/reverts the changes before committing on sub branch
        # so submitted commit has empty diff against base
        subprocess.run(["git", "-C", str(repo), "reset", "--hard", base_sha], check=True)
        subprocess.run(
            ["git", "-C", str(repo), "commit", "--allow-empty", "-m", "feat: empty submission"],
            check=True,
        )

        man_path = self.records_dir / "man_ff_e.json"
        # Accept will reject because submitted tree != reviewed tree
        with self.assertRaises(ValueError) as ctx:
            cmd_accept(cand_path, man_path, designer_accepted=True, verification_evidence="evidence")
        self.assertIn("does not match reviewed implementation tree", str(ctx.exception))

        # Even if a hand-crafted manifest bypassed accept, assemble fast-forward rejects empty task
        base_tree = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", f"{base_sha}^{{tree}}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        empty_sha = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        fake_manifest = {
            "schema_version": 1,
            "record_type": "submission_manifest",
            "task_id": "task-ffe",
            "repo": str(repo),
            "status": "accepted",
            "base_commit": base_sha,
            "reviewed_head": empty_sha,
            "reviewed_tree": base_tree,
            "submission_branch": "sub/task-ffe",
            "submitted_sha": empty_sha,
            "submitted_tree": base_tree,
            "commit_message": "feat: empty submission\n",
            "dependencies": [],
            "designer_accepted": True,
            "verification_evidence": "tampered",
            "accepted_at": "2026-11-05T14:00:00Z",
        }
        write_json_record(man_path, fake_manifest)

        int_repo = self.root / "int_repo_ffe"
        self._clone_repo(repo, int_repo)

        ass_path = self.records_dir / "ass_ffe.json"
        with self.assertRaises(ValueError) as ctx:
            cmd_assemble(int_repo, base_sha, "pr/ff-empty", [man_path], ass_path)
        self.assertIn("empty delta", str(ctx.exception))

    def test_dependencies_validation_unique_non_self_and_base_ancestry(self):
        """Dependencies must be unique, non-self, and present in base ancestry (rejecting multi-tip prerequisites)."""
        repo = self.root / "repo_dep_rules"
        base_sha = self._init_repo(repo)

        # Independent Task A
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/a", base_sha], check=True)
        ca = self._commit_files(repo, {"a.txt": "a\n"}, "feat: task A")

        # Independent Task B
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/b", base_sha], check=True)
        cb = self._commit_files(repo, {"b.txt": "b\n"}, "feat: task B")

        cand_path = self.records_dir / "cand_dep_rules.json"

        # 1. Self dependency rejected
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-b",
                base_ref=base_sha,
                reviewed_ref=cb,
                submission_branch="sub/task-b-self",
                output_path=cand_path,
                implementation_branch="task/b",
                dependencies=[{"task_id": "task-b", "accepted_sha": ca}],
            )
        self.assertIn("Self-dependency is forbidden", str(ctx.exception))

        # 2. Duplicate dependency rejected
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-b",
                base_ref=base_sha,
                reviewed_ref=cb,
                submission_branch="sub/task-b-dup",
                output_path=cand_path,
                implementation_branch="task/b",
                dependencies=[
                    {"task_id": "task-a", "accepted_sha": ca},
                    {"task_id": "task-a", "accepted_sha": ca},
                ],
            )
        self.assertIn("Duplicate dependency", str(ctx.exception))

        # 3. Multi-tip / absent from base ancestry rejected:
        # Task C is based on Task A (base=ca), but claims Task B (cb) as dependency even though cb is not in ca's ancestry!
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/c", ca], check=True)
        cc = self._commit_files(repo, {"c.txt": "c\n"}, "feat: task C")

        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-c",
                base_ref=ca,
                reviewed_ref=cc,
                submission_branch="sub/task-c",
                output_path=cand_path,
                implementation_branch="task/c",
                dependencies=[
                    {"task_id": "task-a", "accepted_sha": ca},
                    {"task_id": "task-b", "accepted_sha": cb},  # cb is NOT in ca's ancestry!
                ],
            )
        self.assertIn("is not an ancestor", str(ctx.exception))

    def test_git_read_failures_fail_closed(self):
        """Essential Git reads fail closed on nonzero exit codes."""
        repo = self.root / "repo_fail_closed"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/fc", base_sha], check=True)
        c1 = self._commit_files(repo, {"fc.txt": "content\n"}, "feat: fc commit")

        cand_path = self.records_dir / "cand_fc.json"

        # Mock git that returns exit 128 specifically for 'git diff --quiet'
        mock_git_diff = self.root / "mock_git_diff.sh"
        mock_git_diff.write_text(
            '#!/bin/sh\n'
            'is_diff=0\n'
            'is_quiet=0\n'
            'for arg in "$@"; do\n'
            '  if [ "$arg" = "diff" ]; then is_diff=1; fi\n'
            '  if [ "$arg" = "--quiet" ]; then is_quiet=1; fi\n'
            'done\n'
            'if [ "$is_diff" = "1" ] && [ "$is_quiet" = "1" ]; then\n'
            '  # Check if diff-files or diff-index: allow those, fail on diff <base> <head>\n'
            '  for arg in "$@"; do\n'
            '    if [ "$arg" = "diff-files" ] || [ "$arg" = "diff-index" ]; then\n'
            '      exec /usr/bin/git "$@"\n'
            '    fi\n'
            '  done\n'
            '  echo "fatal: corrupted diff engine" >&2\n'
            '  exit 128\n'
            'fi\n'
            'exec /usr/bin/git "$@"\n',
            encoding="utf-8",
        )
        mock_git_diff.chmod(0o755)

        with self.assertRaises(RuntimeError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-fc",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/task-fc",
                output_path=cand_path,
                implementation_branch="task/fc",
                git_bin=str(mock_git_diff),
            )
        self.assertIn("git diff failed (exit 128)", str(ctx.exception))

    def test_prepare_requires_exact_shas_and_explicit_branch(self):
        """Prepare requires exact 40-char SHAs (rejecting symbolic refs) and explicit implementation branch."""
        repo = self.root / "repo_strict_inputs"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/strict", base_sha], check=True)
        c1 = self._commit_files(repo, {"st.txt": "content\n"}, "feat: strict")

        cand_path = self.records_dir / "cand_strict.json"

        # 1. Symbolic ref 'HEAD' rejected as base
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-st",
                base_ref="HEAD~1",
                reviewed_ref=c1,
                submission_branch="sub/task-st",
                output_path=cand_path,
                implementation_branch="task/strict",
            )
        self.assertIn("Expected an exact 40-character hexadecimal SHA", str(ctx.exception))

        # 2. Symbolic ref branch name rejected as reviewed SHA
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-st",
                base_ref=base_sha,
                reviewed_ref="task/strict",
                submission_branch="sub/task-st",
                output_path=cand_path,
                implementation_branch="task/strict",
            )
        self.assertIn("Expected an exact 40-character hexadecimal SHA", str(ctx.exception))

        # 3. Missing or empty implementation branch rejected
        with self.assertRaises(ValueError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-st",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/task-st",
                output_path=cand_path,
                implementation_branch="",
            )
        self.assertIn("Explicit implementation branch is required", str(ctx.exception))

    def test_prepare_verifies_staged_tree_equals_reviewed_tree(self):
        """Prepare verifies actual staged write-tree equals reviewed tree after squash merge."""
        repo = self.root / "repo_staged_tree"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/tree-chk", base_sha], check=True)
        c1 = self._commit_files(repo, {"file.txt": "content\n"}, "feat: tree check")

        cand_path = self.records_dir / "cand_tree_chk.json"

        # Mock git that returns a different tree for write-tree
        mock_git_tree = self.root / "mock_git_tree.sh"
        mock_git_tree.write_text(
            '#!/bin/sh\n'
            'for arg in "$@"; do\n'
            '  if [ "$arg" = "write-tree" ]; then\n'
            '    echo "1111111111111111111111111111111111111111"\n'
            '    exit 0\n'
            '  fi\n'
            'done\n'
            'exec /usr/bin/git "$@"\n',
            encoding="utf-8",
        )
        mock_git_tree.chmod(0o755)

        with self.assertRaises(RuntimeError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-tc",
                base_ref=base_sha,
                reviewed_ref=c1,
                submission_branch="sub/task-tc",
                output_path=cand_path,
                implementation_branch="task/tree-chk",
                git_bin=str(mock_git_tree),
            )
        self.assertIn("does not match reviewed tree", str(ctx.exception))

        # Check incomplete status recorded
        self.assertTrue(cand_path.exists())
        cand = read_json_record(cand_path)
        self.assertEqual(cand["status"], "incomplete")
        self.assertEqual(cand["stage"], "staged_tree_mismatch")

    def test_cli_invocation_end_to_end(self):
        """CLI invocation of prepare, accept, and assemble subcommands works end-to-end."""
        repo = self.root / "repo_cli"
        base_sha = self._init_repo(repo)

        # Prepare branch
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/cli-test", base_sha], check=True)
        c1 = self._commit_files(repo, {"cli.txt": "cli content\n"}, "feat: cli commit")

        cand_path = self.records_dir / "cli_cand.json"
        man_path = self.records_dir / "cli_man.json"
        ass_path = self.records_dir / "cli_ass.json"

        # 1. prepare CLI
        prep_code = main([
            "prepare",
            "--repo", str(repo),
            "--task-id", "task-cli",
            "--base", base_sha,
            "--reviewed-sha", c1,
            "--submission-branch", "sub/cli-test",
            "--output", str(cand_path),
            "--implementation-branch", "task/cli-test",
        ])
        self.assertEqual(prep_code, 0)
        self.assertTrue(cand_path.exists())

        # Designer commits
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: cli squashed"], check=True)

        # 2. accept CLI
        acc_code = main([
            "accept",
            "--candidate", str(cand_path),
            "--output", str(man_path),
            "--accepted",
            "--verification-evidence", "CLI tests passed",
        ])
        self.assertEqual(acc_code, 0)
        self.assertTrue(man_path.exists())

        # 3. assemble CLI
        int_repo = self.root / "repo_cli_int"
        self._clone_repo(repo, int_repo)

        ass_code = main([
            "assemble",
            "--repo", str(int_repo),
            "--base", base_sha,
            "--branch", "pr/cli-assembly",
            "--manifests", str(man_path),
            "--output", str(ass_path),
        ])
        self.assertEqual(ass_code, 0)
        self.assertTrue(ass_path.exists())

        # Bad subcommand CLI
        with self.assertRaises(SystemExit) as cm:
            main(["--help"])
        self.assertEqual(cm.exception.code, 0)

    def test_dirty_index_with_failed_head_read_rejected(self):
        """When HEAD verification fails (e.g. exit 7), check_clean_worktree fails closed rather than skipping diff-index."""
        repo = self.root / "repo_head_fail"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/impl", base_sha], check=True)
        c1 = self._commit_files(repo, {"a.txt": "changed\n"}, "feat: checkpoint")
        cand = self.records_dir / "cand_hf.json"
        cmd_prepare(repo, "task-hf", base_sha, c1, "sub/hf", cand, implementation_branch="task/impl")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: submission"], check=True)

        fake_git = self.root / "fake_git_head_fail.sh"
        fake_git.write_text(
            f"#!{sys.executable}\n"
            "import subprocess, sys\n"
            "args = sys.argv[1:]\n"
            "res = subprocess.run(['/usr/bin/git', *args])\n"
            "sys.exit(7 if args[2:] == ['rev-parse', '--verify', '-q', 'HEAD'] else res.returncode)\n"
        )
        fake_git.chmod(0o700)

        # Stage an extra unreviewed file
        (repo / "extra.txt").write_text("staged unreviewed\n")
        subprocess.run(["git", "-C", str(repo), "add", "extra.txt"], check=True)

        # cmd_accept must fail closed instead of ignoring staged changes
        man = self.records_dir / "man_hf.json"
        with self.assertRaises(RuntimeError) as ctx:
            cmd_accept(cand, man, True, "evidence", git_bin=str(fake_git))
        self.assertIn("Failed to verify HEAD", str(ctx.exception))
        self.assertFalse(man.exists())

    def test_check_ref_absent_distinguishes_absent_from_error(self):
        """check_ref_absent succeeds for absent ref (exit 1), rejects existing (exit 0), and fails on error (exit > 1)."""
        repo = self.root / "repo_ref_check"
        base_sha = self._init_repo(repo)

        # 1. Ref does not exist -> exit 1 from rev-parse -> check_ref_absent returns None
        check_ref_absent(repo, "refs/heads/nonexistent", "Branch")

        # 2. Ref exists -> exit 0 from rev-parse -> ValueError
        with self.assertRaises(ValueError) as ctx:
            check_ref_absent(repo, "refs/heads/trunk", "Branch")
        self.assertIn("already exists", str(ctx.exception))

        # 3. Read error -> exit 128 / > 1 -> RuntimeError
        fake_git = self.root / "fake_git_ref_err.sh"
        fake_git.write_text(
            f"#!{sys.executable}\n"
            "import sys\n"
            "sys.exit(128)\n"
        )
        fake_git.chmod(0o700)

        with self.assertRaises(RuntimeError) as ctx:
            check_ref_absent(repo, "refs/heads/any", "Branch", git_bin=str(fake_git))
        self.assertIn("Unexpected error checking ref", str(ctx.exception))

    def test_assemble_rejects_noop_fast_forward(self):
        """When merge --ff-only returns 0 without moving HEAD, cmd_assemble rejects and records head_not_advanced."""
        repo = self.root / "repo_noop_ff"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/ff", base_sha], check=True)
        c1 = self._commit_files(repo, {"f.txt": "f\n"}, "feat: ff task")
        cand = self.records_dir / "cand_ff.json"
        cmd_prepare(repo, "task-ff", base_sha, c1, "sub/ff", cand, implementation_branch="task/ff")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: ff squashed"], check=True)
        man = self.records_dir / "man_ff.json"
        cmd_accept(cand, man, True, "ev")

        int_repo = self.root / "int_noop_ff"
        self._clone_repo(repo, int_repo)

        fake_git = self.root / "fake_git_noop_ff.sh"
        fake_git.write_text(
            f"#!{sys.executable}\n"
            "import subprocess, sys\n"
            "args = sys.argv[1:]\n"
            "sys.exit(0 if args[2:4] == ['merge', '--ff-only'] else subprocess.run(['/usr/bin/git', *args]).returncode)\n"
        )
        fake_git.chmod(0o700)

        ass_path = self.records_dir / "ass_noop_ff.json"
        with self.assertRaises(RuntimeError) as ctx:
            cmd_assemble(
                repo_path=int_repo,
                base_ref=base_sha,
                pr_branch="pr/noop-ff",
                manifest_paths=[man],
                output_path=ass_path,
                git_bin=str(fake_git),
            )
        self.assertIn("failed to advance HEAD", str(ctx.exception))
        self.assertTrue(ass_path.exists())
        ass_rec = read_json_record(ass_path)
        self.assertEqual(ass_rec["status"], "incomplete")
        self.assertEqual(ass_rec["stage"], "head_not_advanced")

    def test_prepare_protects_ignored_files_from_data_loss(self):
        """Exact base/reviewed shape: base tracks cache, implementation removes it and ignores cache.
        Existing ignored cache with precious local content must not be overwritten or lost."""
        repo = self.root / "repo_ignored_loss"
        base_sha = self._init_repo(repo)

        # Base tracks cache
        base_sha = self._commit_files(repo, {"cache": "base cache content\n"}, "chore: base tracks cache")

        # Feature branch removes cache, adds cache to .gitignore
        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/cache-test", base_sha], check=True)
        subprocess.run(["git", "-C", str(repo), "rm", "cache"], check=True)
        (repo / ".gitignore").write_text("cache\n")
        subprocess.run(["git", "-C", str(repo), "add", ".gitignore"], check=True)
        rev_sha = self._commit_files(repo, {}, "feat: remove cache and add to gitignore")

        # In working tree, untracked ignored cache exists with precious local content
        precious_content = "precious local ignored state\n"
        (repo / "cache").write_text(precious_content)

        cand_path = self.records_dir / "cand_ignored.json"
        with self.assertRaises(RuntimeError) as ctx:
            cmd_prepare(
                repo_path=repo,
                task_id="task-cache",
                base_ref=base_sha,
                reviewed_ref=rev_sha,
                submission_branch="sub/cache-test",
                output_path=cand_path,
                implementation_branch="task/cache-test",
            )
        self.assertIn("Operation aborted to prevent data loss", str(ctx.exception))
        self.assertIn("cache", str(ctx.exception))

        # Precious content is intact
        self.assertTrue((repo / "cache").exists())
        self.assertEqual((repo / "cache").read_text(), precious_content)

        # Current branch was not switched
        cur_branch = subprocess.check_output(
            ["git", "-C", str(repo), "symbolic-ref", "--short", "HEAD"], text=True
        ).strip()
        self.assertEqual(cur_branch, "task/cache-test")

    def test_assemble_protects_ignored_files_from_data_loss(self):
        """cmd_assemble preflights existing ignored files against all target commits to prevent overwrite."""
        repo = self.root / "repo_asm_ignored"
        base_sha = self._init_repo(repo)

        subprocess.run(["git", "-C", str(repo), "checkout", "-b", "task/asm-ign", base_sha], check=True)
        c1 = self._commit_files(repo, {"artifact.bin": "binary content\n"}, "feat: add artifact")
        cand = self.records_dir / "cand_asm_ign.json"
        cmd_prepare(repo, "task-asm-ign", base_sha, c1, "sub/asm-ign", cand, implementation_branch="task/asm-ign")
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "feat: squashed artifact"], check=True)
        man = self.records_dir / "man_asm_ign.json"
        cmd_accept(cand, man, True, "ev")

        # Switch repo back to trunk so clone checks out trunk where artifact.bin does not exist
        subprocess.run(["git", "-C", str(repo), "checkout", "trunk"], check=True)

        int_repo = self.root / "int_asm_ignored"
        self._clone_repo(repo, int_repo)

        # In integration repo, ignore artifact.bin and create local ignored copy
        (int_repo / ".gitignore").write_text("artifact.bin\n")
        subprocess.run(["git", "-C", str(int_repo), "add", ".gitignore"], check=True)
        subprocess.run(["git", "-C", str(int_repo), "commit", "-m", "chore: ignore artifact.bin"], check=True)
        base_int = subprocess.check_output(["git", "-C", str(int_repo), "rev-parse", "HEAD"], text=True).strip()

        precious = "precious integration ignored file\n"
        (int_repo / "artifact.bin").write_text(precious)

        ass_path = self.records_dir / "ass_asm_ign.json"
        with self.assertRaises(RuntimeError) as ctx:
            cmd_assemble(
                repo_path=int_repo,
                base_ref=base_int,
                pr_branch="pr/asm-ign",
                manifest_paths=[man],
                output_path=ass_path,
            )
        self.assertIn("Operation aborted to prevent data loss", str(ctx.exception))
        self.assertTrue((int_repo / "artifact.bin").exists())
        self.assertEqual((int_repo / "artifact.bin").read_text(), precious)


if __name__ == "__main__":
    unittest.main()
