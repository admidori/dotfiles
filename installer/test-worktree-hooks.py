#!/usr/bin/env python3
"""Comprehensive regression test suite for Claude Code worktree lifecycle hook and settings migration.

Tests cover:
- Base commit precedence and fallback (origin/HEAD, unique main, unique master, ambiguous, missing, no current-branch inference)
- Task name reuse after clean removal (unique dedicated branches claude/<slug>-<suffix>, both branches survive, branches differ)
- Symlink parent rejection (redirected root and repo parent stay untouched)
- Index flags rendering tracked changes unverifiable (assume-unchanged and skip-worktree with local edits)
- Strict alias refusal and move-with-alias refusal preserving data and paths
- Clean manually created worktree refusal (ownership guard) and foreign worktree refusal
- Dirty worktrees (modified tracked, staged, untracked, ignored), locks, added commits, branch switch, detached HEAD
- Payload and task name validation (PR shapes, invalid chars)
- One-time settings migration (mode 0664 under umask 022, non-clobbering backup, idempotent equal match, focused diff on conflict, symlink refusal)
- Installer link behavior integration with fake HOME
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
HOOK_SCRIPT = os.path.join(REPO_ROOT, "bin", "dotfiles", ".claude", "hooks", "worktree.py")
MIGRATE_SCRIPT = os.path.join(REPO_ROOT, "installer", "migrate-claude-settings.py")
TEMPLATE_SETTINGS = os.path.join(REPO_ROOT, "bin", "dotfiles", ".claude", "settings.json")


def run_cmd(args, cwd=None, input_text=None, env=None, check=False) -> subprocess.CompletedProcess:
    full_env = os.environ.copy()
    full_env["PYTHONDONTWRITEBYTECODE"] = "1"
    if env:
        full_env.update(env)
    res = subprocess.run(
        args,
        cwd=cwd,
        input=input_text,
        text=True,
        capture_output=True,
        env=full_env,
    )
    if check and res.returncode != 0:
        raise subprocess.CalledProcessError(res.returncode, args, output=res.stdout, stderr=res.stderr)
    return res


def init_git_repo(path: str, initial_branch="main") -> str:
    os.makedirs(path, exist_ok=True)
    run_cmd(["git", "init", "-b", initial_branch, path], check=True)
    run_cmd(["git", "-C", path, "config", "user.name", "Test User"], check=True)
    run_cmd(["git", "-C", path, "config", "user.email", "test@example.com"], check=True)
    run_cmd(["git", "-C", path, "commit", "--allow-empty", "-m", "initial commit"], check=True)
    return run_cmd(["git", "-C", path, "rev-parse", "HEAD"]).stdout.strip()


class TestWorktreeLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp(prefix="claude-wt-test-")
        self.fake_home = os.path.join(self.temp_dir, "fakehome")
        os.makedirs(self.fake_home, exist_ok=True)
        self.env = {"HOME": self.fake_home, "PYTHONDONTWRITEBYTECODE": "1"}

        self.repo_dir = os.path.join(self.temp_dir, "main-project")
        self.initial_sha = init_git_repo(self.repo_dir, "main")

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_base_precedence_and_fallback(self):
        """Table-driven test for base commit resolution precedence and fallback."""
        # 1. origin/HEAD precedence
        run_cmd(["git", "-C", self.repo_dir, "commit", "--allow-empty", "-m", "main 2"])
        run_cmd(["git", "-C", self.repo_dir, "branch", "master"])
        run_cmd(["git", "-C", self.repo_dir, "update-ref", "refs/remotes/origin/HEAD", self.initial_sha])

        payload = json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-base-origin", "cwd": self.repo_dir})
        res = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload, env=self.env)
        self.assertEqual(res.returncode, 0, f"Create hook failed: {res.stderr}")
        wt_path = res.stdout.strip()
        wt_sha = run_cmd(["git", "-C", wt_path, "rev-parse", "HEAD"]).stdout.strip()
        self.assertEqual(wt_sha, self.initial_sha, "Should resolve to origin/HEAD commit")

        # 2. Ambiguous base (no origin/HEAD, both main and master exist)
        run_cmd(["git", "-C", self.repo_dir, "update-ref", "-d", "refs/remotes/origin/HEAD"])
        payload_amb = json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-amb", "cwd": self.repo_dir})
        res_amb = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload_amb, env=self.env)
        self.assertNotEqual(res_amb.returncode, 0, "Ambiguous base must fail")
        self.assertIn("Ambiguous base", res_amb.stderr)

        # 3. Unique master fallback
        master_repo = os.path.join(self.temp_dir, "master-only")
        m_sha = init_git_repo(master_repo, "master")
        payload_m = json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-master-only", "cwd": master_repo})
        res_m = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload_m, env=self.env)
        self.assertEqual(res_m.returncode, 0)
        self.assertEqual(run_cmd(["git", "-C", res_m.stdout.strip(), "rev-parse", "HEAD"]).stdout.strip(), m_sha)

        # 4. No current-branch inference
        run_cmd(["git", "-C", self.repo_dir, "branch", "-D", "master"])
        run_cmd(["git", "-C", self.repo_dir, "checkout", "-b", "feature-branch"])
        run_cmd(["git", "-C", self.repo_dir, "commit", "--allow-empty", "-m", "feature commit"])
        main_ref_sha = run_cmd(["git", "-C", self.repo_dir, "rev-parse", "refs/heads/main"]).stdout.strip()
        payload_no_inf = json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-no-inf", "cwd": self.repo_dir})
        res_no_inf = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload_no_inf, env=self.env)
        self.assertEqual(res_no_inf.returncode, 0)
        self.assertEqual(run_cmd(["git", "-C", res_no_inf.stdout.strip(), "rev-parse", "HEAD"]).stdout.strip(), main_ref_sha)

    def test_task_name_reuse_and_dedicated_branch_uniqueness(self):
        """Reusing a task name succeeds after clean removal with dedicated unique branches."""
        task_name = "task-reuse-feature"

        # 1. First creation
        payload_create = json.dumps({"hook_event_name": "WorktreeCreate", "name": task_name, "cwd": self.repo_dir})
        res1 = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload_create, env=self.env)
        self.assertEqual(res1.returncode, 0, f"First create failed: {res1.stderr}")
        wt1_path = res1.stdout.strip()

        branch1 = run_cmd(["git", "-C", wt1_path, "symbolic-ref", "--short", "HEAD"]).stdout.strip()
        self.assertTrue(branch1.startswith(f"claude/{task_name}-"))

        # 2. Clean removal
        payload_remove = json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": wt1_path, "cwd": self.repo_dir})
        res_rem = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload_remove, env=self.env)
        self.assertEqual(res_rem.returncode, 0, f"Remove failed: {res_rem.stderr}")
        self.assertFalse(os.path.exists(wt1_path))

        # Assert prior branch survives in repository
        chk_branch1 = run_cmd(["git", "-C", self.repo_dir, "rev-parse", "--verify", "-q", f"refs/heads/{branch1}"])
        self.assertEqual(chk_branch1.returncode, 0, "Prior branch must survive in git")

        # 3. Second creation with the SAME task name
        res2 = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload_create, env=self.env)
        self.assertEqual(res2.returncode, 0, f"Second create with same name failed: {res2.stderr}")
        wt2_path = res2.stdout.strip()

        branch2 = run_cmd(["git", "-C", wt2_path, "symbolic-ref", "--short", "HEAD"]).stdout.strip()
        self.assertTrue(branch2.startswith(f"claude/{task_name}-"))

        # Assert next branch differs and BOTH branches survive
        self.assertNotEqual(branch1, branch2, "Git shall never reuse a previous task branch")
        chk_branch2 = run_cmd(["git", "-C", self.repo_dir, "rev-parse", "--verify", "-q", f"refs/heads/{branch2}"])
        self.assertEqual(chk_branch2.returncode, 0)
        chk_branch1_again = run_cmd(["git", "-C", self.repo_dir, "rev-parse", "--verify", "-q", f"refs/heads/{branch1}"])
        self.assertEqual(chk_branch1_again.returncode, 0, "Both branches must survive")

    def test_symlink_parent_rejection(self):
        """Reject symlink roots and per-repository parent entries, keeping targets untouched."""
        redirected_root_dir = os.path.join(self.temp_dir, "redirected-root")
        os.makedirs(redirected_root_dir, exist_ok=True)

        # 1. Symlink root: ~/worktrees is a symlink
        worktrees_root = os.path.join(self.fake_home, "worktrees")
        os.symlink(redirected_root_dir, worktrees_root)

        payload = json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-symlink-root", "cwd": self.repo_dir})
        res1 = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload, env=self.env)
        self.assertNotEqual(res1.returncode, 0, "Must reject symlink root")
        self.assertIn("symlink", res1.stderr.lower())
        self.assertEqual(os.listdir(redirected_root_dir), [], "Redirected root must stay untouched")

        os.unlink(worktrees_root)
        os.makedirs(worktrees_root, exist_ok=True)

        # 2. Symlink per-repository parent entry
        redirected_parent_dir = os.path.join(self.temp_dir, "redirected-parent")
        os.makedirs(redirected_parent_dir, exist_ok=True)
        repo_parent = os.path.join(worktrees_root, "main-project")
        os.symlink(redirected_parent_dir, repo_parent)

        payload2 = json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-symlink-parent", "cwd": self.repo_dir})
        res2 = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload2, env=self.env)
        self.assertNotEqual(res2.returncode, 0, "Must reject symlink repo parent")
        self.assertIn("symlink", res2.stderr.lower())
        self.assertEqual(os.listdir(redirected_parent_dir), [], "Redirected repo parent must stay untouched")

        # 3. Dangling symlink root
        os.unlink(repo_parent)
        shutil.rmtree(worktrees_root)
        missing_target = "missing-target"
        self.assertFalse(os.path.lexists(os.path.join(self.fake_home, missing_target)))
        os.symlink(missing_target, worktrees_root)
        res3 = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=payload, env=self.env)
        self.assertNotEqual(res3.returncode, 0, "Must reject dangling symlink root")

    def test_unverifiable_index_flags_refusal(self):
        """Refuse removal when tracked paths have assume-unchanged or skip-worktree flags set."""
        f_assume = os.path.join(self.repo_dir, "assume.txt")
        f_skip = os.path.join(self.repo_dir, "skip.txt")
        with open(f_assume, "w") as f:
            f.write("assume original\n")
        with open(f_skip, "w") as f:
            f.write("skip original\n")
        run_cmd(["git", "-C", self.repo_dir, "add", "assume.txt", "skip.txt"])
        run_cmd(["git", "-C", self.repo_dir, "commit", "-m", "add test files"])

        # 1. Test assume-unchanged flag with local tracked edit
        res1 = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-assume", "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertEqual(res1.returncode, 0)
        wt1 = res1.stdout.strip()

        run_cmd(["git", "-C", wt1, "update-index", "--assume-unchanged", "assume.txt"])
        with open(os.path.join(wt1, "assume.txt"), "a") as f:
            f.write("local uncommitted edit\n")

        res_rem1 = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": wt1, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_rem1.returncode, 0, "Must refuse worktree with assume-unchanged flag")
        self.assertIn("assume-unchanged", res_rem1.stderr)
        self.assertTrue(os.path.exists(wt1), "Worktree must be preserved")
        with open(os.path.join(wt1, "assume.txt"), "r") as f:
            self.assertIn("local uncommitted edit", f.read())

        # 2. Test skip-worktree flag with local tracked edit
        res2 = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-skip", "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertEqual(res2.returncode, 0)
        wt2 = res2.stdout.strip()

        run_cmd(["git", "-C", wt2, "update-index", "--skip-worktree", "skip.txt"])
        with open(os.path.join(wt2, "skip.txt"), "a") as f:
            f.write("local uncommitted edit in skip\n")

        res_rem2 = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": wt2, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_rem2.returncode, 0, "Must refuse worktree with skip-worktree flag")
        self.assertIn("skip-worktree", res_rem2.stderr)
        self.assertTrue(os.path.exists(wt2), "Worktree must be preserved")
        with open(os.path.join(wt2, "skip.txt"), "r") as f:
            self.assertIn("local uncommitted edit in skip", f.read())

    def test_alias_and_moved_worktree_rejection_preserving_data(self):
        """Test both reproduced wrong deletions: alias removal and move-with-alias removal."""
        # 1. Alias removal reproduction
        res1 = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-alias", "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertEqual(res1.returncode, 0)
        wt1 = res1.stdout.strip()

        alias_link = os.path.join(self.temp_dir, "alias-wt1")
        os.symlink(wt1, alias_link)

        # Attempt to remove via alias symlink
        res_alias = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": alias_link, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_alias.returncode, 0, "Must refuse removal via alias symlink")
        self.assertTrue(os.path.exists(wt1), "Worktree must be preserved")
        self.assertTrue(os.path.islink(alias_link), "Alias link must remain")

        # 2. Move worktree + alias at former path reproduction
        res2 = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-moved", "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertEqual(res2.returncode, 0)
        old_path = res2.stdout.strip()
        new_path = os.path.join(os.path.dirname(old_path), "task-moved-new")

        # Move worktree via git
        run_cmd(["git", "-C", self.repo_dir, "worktree", "move", old_path, new_path], check=True)
        # Create symlink at old path pointing to new path
        os.symlink(new_path, old_path)

        # Attempt removal specifying the destination new_path (fails literal record check)
        res_dest = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": new_path, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_dest.returncode, 0, "Must refuse removal of moved worktree with outdated record")
        self.assertTrue(os.path.exists(new_path), "Moved worktree destination must be preserved")
        self.assertTrue(os.path.islink(old_path), "Former path symlink must remain")

        # Attempt removal specifying the old symlink path (fails symlink check)
        res_old = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": old_path, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_old.returncode, 0, "Must refuse removal specifying symlink old path")
        self.assertTrue(os.path.exists(new_path), "Moved worktree destination must be preserved")

    def test_ownership_and_foreign_worktree_guards(self):
        """Clean manually created worktrees and foreign repo worktrees are protected."""
        # 1. Clean manually created worktree (Ownership guard)
        manual_wt = os.path.join(self.fake_home, "worktrees", "main-project", "manual-clean")
        run_cmd(["git", "-C", self.repo_dir, "worktree", "add", manual_wt, "-b", "manual-clean"], check=True)
        res_man = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": manual_wt, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_man.returncode, 0, "Must refuse clean manually created worktree")
        self.assertIn("creation record", res_man.stderr.lower())
        self.assertTrue(os.path.exists(manual_wt), "Manual worktree must be preserved")

        # 2. Foreign worktree refusal when cwd is in git
        other_repo = os.path.join(self.temp_dir, "other-repo")
        init_git_repo(other_repo, "main")
        res_other = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-other", "cwd": other_repo}),
            env=self.env,
        )
        self.assertEqual(res_other.returncode, 0)
        other_wt = res_other.stdout.strip()

        # Call remove on other_wt while cwd is self.repo_dir (foreign repo)
        res_foreign = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": other_wt, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_foreign.returncode, 0, "Must refuse foreign worktree")
        self.assertIn("different repository", res_foreign.stderr.lower())
        self.assertTrue(os.path.exists(other_wt), "Foreign worktree must be preserved")

    def test_dirty_and_lock_guards(self):
        """Locks, dirty status, modified, staged, untracked, and ignored files are refused."""
        res_create = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-guards", "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertEqual(res_create.returncode, 0)
        wt = res_create.stdout.strip()

        # 1. Locked worktree
        run_cmd(["git", "-C", self.repo_dir, "worktree", "lock", wt, "--reason", "guard lock"])
        res_locked = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": wt, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_locked.returncode, 0)
        self.assertIn("locked", res_locked.stderr.lower())
        self.assertTrue(os.path.exists(wt))
        run_cmd(["git", "-C", self.repo_dir, "worktree", "unlock", wt])

        # 2. Untracked file
        untracked = os.path.join(wt, "untracked.txt")
        with open(untracked, "w") as f:
            f.write("untracked\n")
        res_untracked = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": wt, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_untracked.returncode, 0)
        self.assertIn("dirty", res_untracked.stderr.lower())
        os.unlink(untracked)

        # 3. Ignored file
        gitignore = os.path.join(wt, ".gitignore")
        with open(gitignore, "w") as f:
            f.write("ignored.txt\n")
        ignored = os.path.join(wt, "ignored.txt")
        with open(ignored, "w") as f:
            f.write("secret ignored content\n")
        res_ignored = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": wt, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_ignored.returncode, 0)
        self.assertTrue(os.path.exists(ignored), "Ignored content must be preserved")

    def test_head_and_branch_guards(self):
        """Added commits, switched branches, and detached HEAD refuse removal."""
        # 1. Added commits
        res1 = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-extra-commit", "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertEqual(res1.returncode, 0)
        wt1 = res1.stdout.strip()
        run_cmd(["git", "-C", wt1, "commit", "--allow-empty", "-m", "extra commit"])
        res_extra = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": wt1, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_extra.returncode, 0, "Must refuse worktree with added commit")
        self.assertTrue(os.path.exists(wt1))

        # 2. Branch switch
        res2 = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-switch", "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertEqual(res2.returncode, 0)
        wt2 = res2.stdout.strip()
        run_cmd(["git", "-C", wt2, "checkout", "-b", "other-branch"])
        res_switch = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": wt2, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_switch.returncode, 0, "Must refuse worktree with switched branch")
        self.assertTrue(os.path.exists(wt2))

        # 3. Detached HEAD
        res3 = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": "task-detach", "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertEqual(res3.returncode, 0)
        wt3 = res3.stdout.strip()
        run_cmd(["git", "-C", wt3, "checkout", "--detach"])
        res_detach = run_cmd(
            ["python3", "-B", HOOK_SCRIPT],
            input_text=json.dumps({"hook_event_name": "WorktreeRemove", "worktree_path": wt3, "cwd": self.repo_dir}),
            env=self.env,
        )
        self.assertNotEqual(res_detach.returncode, 0, "Must refuse detached HEAD")
        self.assertTrue(os.path.exists(wt3))

    def test_payload_and_name_validation(self):
        """Malformed payloads and invalid task names (including PR shape) are rejected."""
        for bad_input in ["", "not-json", "[]", "{}"]:
            res = run_cmd(["python3", "-B", HOOK_SCRIPT], input_text=bad_input, env=self.env)
            self.assertNotEqual(res.returncode, 0)

        # PR shape rejection
        for pr_name in ["pr-1", "pr-42", "pr-9999"]:
            res = run_cmd(
                ["python3", "-B", HOOK_SCRIPT],
                input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": pr_name, "cwd": self.repo_dir}),
                env=self.env,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("forbidden PR shape", res.stderr)

        # Invalid path / ref names
        for bad_name in ["foo/bar", "foo\\bar", "..", ".", ".hidden", "a..b"]:
            res = run_cmd(
                ["python3", "-B", HOOK_SCRIPT],
                input_text=json.dumps({"hook_event_name": "WorktreeCreate", "name": bad_name, "cwd": self.repo_dir}),
                env=self.env,
            )
            self.assertNotEqual(res.returncode, 0)


class TestSettingsMigration(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp(prefix="claude-mig-test-")
        self.fake_home = os.path.join(self.temp_dir, "fakehome")
        os.makedirs(self.fake_home, exist_ok=True)
        self.claude_dir = os.path.join(self.fake_home, ".claude")
        os.makedirs(self.claude_dir, exist_ok=True)
        self.settings_file = os.path.join(self.claude_dir, "settings.json")

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_migration_mode_0664_under_umask_022(self):
        """Test mode 0664 settings migration under umask 022 preserves exact 0664 on settings and backup."""
        old_umask = os.umask(0o022)
        try:
            initial_data = {
                "permissions": {"allow": ["Bash(ls)"]},
                "model": "opus",
                "hooks": {
                    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "test.sh"}]}]
                },
            }
            initial_bytes = (json.dumps(initial_data, indent=2) + "\n").encode("utf-8")
            with open(self.settings_file, "wb") as f:
                f.write(initial_bytes)
            os.chmod(self.settings_file, 0o664)

            res = run_cmd(["python3", "-B", MIGRATE_SCRIPT, "--settings-file", self.settings_file, "--template-file", TEMPLATE_SETTINGS])
            self.assertEqual(res.returncode, 0, f"Migration failed: {res.stderr}")

            # Verify target permissions remain 0664
            target_mode = stat.S_IMODE(os.stat(self.settings_file).st_mode)
            self.assertEqual(target_mode, 0o664, f"Target settings must retain mode 0664, got {oct(target_mode)}")

            # Verify backup permissions are explicitly 0664 (not filtered to 0644 by umask 022)
            backups = [f for f in os.listdir(self.claude_dir) if "pre-worktrees" in f]
            self.assertEqual(len(backups), 1)
            backup_path = os.path.join(self.claude_dir, backups[0])
            backup_mode = stat.S_IMODE(os.stat(backup_path).st_mode)
            self.assertEqual(backup_mode, 0o664, f"Backup must have mode 0664 under umask 022, got {oct(backup_mode)}")

            # Verify backup bytes
            with open(backup_path, "rb") as f:
                self.assertEqual(f.read(), initial_bytes)

            # Verify hooks merged
            with open(self.settings_file, "r") as f:
                migrated = json.load(f)
            self.assertIn("WorktreeCreate", migrated["hooks"])
            self.assertIn("WorktreeRemove", migrated["hooks"])
            self.assertEqual(migrated["hooks"]["WorktreeCreate"][0]["hooks"][0]["command"], 'python3 "$HOME/.claude/hooks/worktree.py"')
        finally:
            os.umask(old_umask)

    def test_migration_idempotent_equal_values(self):
        """When hooks already exist with equal values, no changes are made and no backup is created."""
        with open(TEMPLATE_SETTINGS, "r") as f:
            template = json.load(f)

        already_migrated = {
            "hooks": {
                "WorktreeCreate": template["hooks"]["WorktreeCreate"],
                "WorktreeRemove": template["hooks"]["WorktreeRemove"],
            }
        }
        with open(self.settings_file, "w") as f:
            json.dump(already_migrated, f)

        res = run_cmd(["python3", "-B", MIGRATE_SCRIPT, "--settings-file", self.settings_file, "--template-file", TEMPLATE_SETTINGS])
        self.assertEqual(res.returncode, 0)
        self.assertIn("matches template value", res.stdout)
        self.assertIn("No changes made", res.stdout)

        backups = [f for f in os.listdir(self.claude_dir) if "pre-worktrees" in f]
        self.assertEqual(len(backups), 0, "No backup should be created on equal no-op")

    def test_migration_conflicting_values_focused_diff(self):
        """When conflicting values exist, no changes are made, focused diff is shown, exits non-zero."""
        conflicting = {
            "hooks": {
                "WorktreeCreate": [{"hooks": [{"type": "command", "command": "./custom/my-create.sh"}]}]
            }
        }
        with open(self.settings_file, "w") as f:
            json.dump(conflicting, f)

        res = run_cmd(["python3", "-B", MIGRATE_SCRIPT, "--settings-file", self.settings_file, "--template-file", TEMPLATE_SETTINGS])
        self.assertNotEqual(res.returncode, 0, "Must exit non-zero on conflict")
        self.assertIn("Conflict: 'WorktreeCreate'", res.stderr)
        self.assertIn("-        \"command\": \"./custom/my-create.sh\"", res.stderr)
        self.assertIn("No changes made", res.stdout)

        backups = [f for f in os.listdir(self.claude_dir) if "pre-worktrees" in f]
        self.assertEqual(len(backups), 0, "No backup should be created on conflict")

    def test_migration_refuses_symlink(self):
        """Refuse to replace a linked settings file."""
        real_target = os.path.join(self.temp_dir, "real_settings.json")
        with open(real_target, "w") as f:
            f.write("{}")
        os.symlink(real_target, self.settings_file)

        res = run_cmd(["python3", "-B", MIGRATE_SCRIPT, "--settings-file", self.settings_file, "--template-file", TEMPLATE_SETTINGS])
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("symlink", res.stderr)

    def test_normal_link_and_migration_integration(self):
        """Test installer link behavior and migration with fake HOME."""
        link_script = os.path.join(REPO_ROOT, "installer", "link.sh")
        env = {"HOME": self.fake_home}

        old_settings = {
            "permissions": {"allow": ["Bash(git status:*)"]},
            "hooks": {
                "PreToolUse": [
                    {"matcher": "Bash", "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/bash-guard.sh"}]}
                ]
            }
        }
        with open(self.settings_file, "w") as f:
            json.dump(old_settings, f, indent=2)

        # Run installer/link.sh
        res_link = run_cmd([link_script], env=env)
        self.assertEqual(res_link.returncode, 0, f"link.sh failed: {res_link.stderr}")

        # Hook symlink must point to worktree.py
        wt_sym = os.path.join(self.fake_home, ".claude", "hooks", "worktree.py")
        self.assertTrue(os.path.islink(wt_sym), "worktree.py must be a symlink")

        # Copy-once settings.json must NOT have been mutated by link.sh
        with open(self.settings_file, "r") as f:
            cur_settings = json.load(f)
        self.assertNotIn("WorktreeCreate", cur_settings.get("hooks", {}))

        # Run migration command
        res_mig = run_cmd(["python3", "-B", MIGRATE_SCRIPT, "--settings-file", self.settings_file], env=env)
        self.assertEqual(res_mig.returncode, 0, f"Migration failed: {res_mig.stderr}")

        with open(self.settings_file, "r") as f:
            migrated_settings = json.load(f)
        self.assertIn("WorktreeCreate", migrated_settings["hooks"])
        self.assertIn("WorktreeRemove", migrated_settings["hooks"])

        # Re-running link.sh leaves migrated settings intact
        res_link2 = run_cmd([link_script], env=env)
        self.assertEqual(res_link2.returncode, 0)
        with open(self.settings_file, "r") as f:
            self.assertEqual(json.load(f), migrated_settings)


if __name__ == "__main__":
    unittest.main(verbosity=2)
