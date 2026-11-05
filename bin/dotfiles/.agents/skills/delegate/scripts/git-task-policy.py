#!/usr/bin/env python3
"""Git policy validation and state tracking helper for agent-harness delegation.

Validates pre-run prerequisites and post-run state transitions for:
  - strict: no git mutations allowed (HEAD, branch, or index)
  - task-commits: linear checkpoint commits allowed only on assigned task branch
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

SHA_RE = re.compile(r"^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$")


def run_git(cmd, cwd, check=False):
    """Run a git command in cwd and return CompletedProcess."""
    full_cmd = ["git", "-C", cwd] + cmd
    return subprocess.run(
        full_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=check,
    )


def compute_index_hash(workdir):
    """Compute sha256 hash of git stage listing. Returns (hash, err)."""
    res = run_git(["ls-files", "--stage"], cwd=workdir)
    if res.returncode != 0:
        return None, f"ls-files --stage failed (exit {res.returncode}): {res.stderr.strip()}"
    return hashlib.sha256(res.stdout.encode("utf-8")).hexdigest(), None


def get_dirty_state(workdir):
    """Return (dirty_dict, err). Validates tracked, staged, and untracked cleanliness."""
    # Refresh stat cache first to avoid false positives on mtime/ctime without content diff
    run_git(["update-index", "-q", "--refresh"], cwd=workdir)

    # Check tracked modifications in working tree vs index
    diff_files = run_git(["diff-files", "--quiet"], cwd=workdir)
    if diff_files.returncode not in (0, 1):
        return None, f"diff-files failed (exit {diff_files.returncode}): {diff_files.stderr.strip()}"
    tracked_dirty = (diff_files.returncode == 1)

    # Check staged changes in index relative to HEAD using --cached
    diff_cached = run_git(["diff-index", "--cached", "--quiet", "HEAD", "--"], cwd=workdir)
    if diff_cached.returncode not in (0, 1):
        return None, f"diff-index --cached failed (exit {diff_cached.returncode}): {diff_cached.stderr.strip()}"
    staged_dirty = (diff_cached.returncode == 1)

    # Check untracked files (excluding ignored)
    untracked = run_git(["ls-files", "--others", "--exclude-standard"], cwd=workdir)
    if untracked.returncode != 0:
        return None, f"ls-files --others failed (exit {untracked.returncode}): {untracked.stderr.strip()}"
    untracked_dirty = bool(untracked.stdout.strip())

    is_dirty = tracked_dirty or staged_dirty or untracked_dirty
    return {
        "dirty": is_dirty,
        "tracked": tracked_dirty,
        "untracked": untracked_dirty,
        "staged": staged_dirty,
    }, None


def get_protected_refs(workdir, assigned_branch):
    """Return (protected_dict, err) for all refs outside assigned_branch."""
    res = run_git(["for-each-ref", "--format=%(refname) %(objectname)"], cwd=workdir)
    if res.returncode != 0:
        return None, f"for-each-ref failed (exit {res.returncode}): {res.stderr.strip()}"
    assigned_ref = f"refs/heads/{assigned_branch}"
    protected = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2:
            rname = parts[0]
            rsha = parts[1]
            if rname != assigned_ref:
                protected[rname] = rsha
    return protected, None


def cmd_pre_check(args):
    workdir = os.path.abspath(args.workdir)
    policy = args.policy

    if policy not in ("strict", "task-commits"):
        sys.stderr.write(f"error: invalid HARNESS_GIT_POLICY '{policy}' (expected 'strict' or 'task-commits')\n")
        sys.exit(2)

    if policy == "strict":
        # Check if inside git work tree
        is_git_res = run_git(["rev-parse", "--is-inside-work-tree"], cwd=workdir)
        is_git = (is_git_res.returncode == 0 and is_git_res.stdout.strip() == "true")
        if not is_git:
            snapshot = {
                "policy": "strict",
                "is_git": False,
                "head": "no-git",
                "branch": "no-git",
                "index_hash": "no-git",
            }
        else:
            head_res = run_git(["rev-parse", "--verify", "-q", "HEAD"], cwd=workdir)
            head = head_res.stdout.strip() if head_res.returncode == 0 else "NO_HEAD"

            branch_res = run_git(["symbolic-ref", "-q", "--short", "HEAD"], cwd=workdir)
            if branch_res.returncode == 0:
                branch = branch_res.stdout.strip()
            else:
                branch_abbrev = run_git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=workdir)
                branch = branch_abbrev.stdout.strip() if branch_abbrev.returncode == 0 else "DETACHED_OR_UNKNOWN"

            index_hash, idx_err = compute_index_hash(workdir)
            if idx_err:
                sys.stderr.write(f"error: failed to read git stage listing: {idx_err}\n")
                sys.exit(2)
            snapshot = {
                "policy": "strict",
                "is_git": True,
                "head": head,
                "branch": branch,
                "index_hash": index_hash,
            }

        if args.snapshot_out:
            with open(args.snapshot_out, "w", encoding="utf-8") as f:
                json.dump(snapshot, f, indent=2)
        else:
            print(json.dumps(snapshot, indent=2))
        return

    # policy == "task-commits"
    branch = (args.branch or "").strip()
    if not branch:
        sys.stderr.write("error: HARNESS_GIT_POLICY=task-commits requires nonempty HARNESS_TASK_BRANCH\n")
        sys.exit(2)
    if branch in ("main", "master"):
        sys.stderr.write(f"error: HARNESS_TASK_BRANCH cannot be main or master: {branch}\n")
        sys.exit(2)

    base = (args.base or "").strip()
    if not base:
        sys.stderr.write("error: HARNESS_GIT_POLICY=task-commits requires nonempty HARNESS_TASK_BASE\n")
        sys.exit(2)
    if not SHA_RE.match(base):
        sys.stderr.write(f"error: invalid HARNESS_TASK_BASE '{base}' (full commit SHA expected)\n")
        sys.exit(2)

    # Validate non-bare git repo
    is_git_res = run_git(["rev-parse", "--is-inside-work-tree"], cwd=workdir)
    is_bare_res = run_git(["rev-parse", "--is-bare-repository"], cwd=workdir)
    if is_git_res.returncode != 0 or is_git_res.stdout.strip() != "true" or \
       is_bare_res.returncode != 0 or is_bare_res.stdout.strip() != "false":
        sys.stderr.write(f"error: workdir is not a valid non-bare git repository: {workdir}\n")
        sys.exit(2)

    # Validate named non-main/master branch and matching branch
    sym_branch_res = run_git(["symbolic-ref", "-q", "--short", "HEAD"], cwd=workdir)
    if sym_branch_res.returncode != 0:
        sys.stderr.write("error: detached HEAD state is not permitted for task-commits policy\n")
        sys.exit(2)
    curr_branch = sym_branch_res.stdout.strip()
    if curr_branch in ("main", "master"):
        sys.stderr.write(f"error: task-commits policy cannot be used on main or master branch: {curr_branch}\n")
        sys.exit(2)
    if curr_branch != branch:
        sys.stderr.write(f"error: workdir branch '{curr_branch}' does not match HARNESS_TASK_BRANCH '{branch}'\n")
        sys.exit(2)

    # Validate exact base exists as a commit
    base_verify = run_git(["rev-parse", "--verify", "-q", f"{base}^{{commit}}"], cwd=workdir)
    if base_verify.returncode != 0:
        sys.stderr.write(f"error: HARNESS_TASK_BASE '{base}' does not exist as a commit\n")
        sys.exit(2)

    # Validate base is an ancestor of HEAD
    anc_res = run_git(["merge-base", "--is-ancestor", base, "HEAD"], cwd=workdir)
    if anc_res.returncode != 0:
        sys.stderr.write(f"error: HARNESS_TASK_BASE '{base}' is not an ancestor of HEAD\n")
        sys.exit(2)

    # Validate clean tracked/untracked state
    run_git(["update-index", "-q", "--refresh"], cwd=workdir)
    status_res = run_git(["status", "--porcelain"], cwd=workdir)
    if status_res.returncode != 0:
        sys.stderr.write(f"error: failed to read git status: {status_res.stderr.strip()}\n")
        sys.exit(2)
    if status_res.stdout.strip():
        sys.stderr.write("error: initial git state is not clean (dirty tracked or untracked files present)\n")
        sys.exit(2)

    # Capture initial snapshot
    head_res = run_git(["rev-parse", "--verify", "-q", "HEAD"], cwd=workdir)
    if head_res.returncode != 0:
        sys.stderr.write(f"error: failed to read HEAD commit SHA: {head_res.stderr.strip()}\n")
        sys.exit(2)
    head = head_res.stdout.strip()

    index_hash, idx_err = compute_index_hash(workdir)
    if idx_err:
        sys.stderr.write(f"error: failed to read git stage listing: {idx_err}\n")
        sys.exit(2)

    protected_refs, prot_err = get_protected_refs(workdir, branch)
    if prot_err:
        sys.stderr.write(f"error: failed to read protected refs: {prot_err}\n")
        sys.exit(2)

    snapshot = {
        "policy": "task-commits",
        "is_git": True,
        "head": head,
        "branch": branch,
        "base": base,
        "index_hash": index_hash,
        "protected_refs": protected_refs,
    }

    if args.snapshot_out:
        with open(args.snapshot_out, "w", encoding="utf-8") as f:
            json.dump(snapshot, f, indent=2)
    else:
        print(json.dumps(snapshot, indent=2))


def cmd_post_check(args):
    workdir = os.path.abspath(args.workdir)
    policy = args.policy
    run_status = args.status
    exit_code = int(args.exit_code)

    # Safe inspection of current observables for durable diagnostics
    is_git_res = run_git(["rev-parse", "--is-inside-work-tree"], cwd=workdir)
    is_git = (is_git_res.returncode == 0 and is_git_res.stdout.strip() == "true")

    if is_git:
        head_res = run_git(["rev-parse", "--verify", "-q", "HEAD"], cwd=workdir)
        curr_head = head_res.stdout.strip() if head_res.returncode == 0 else "NO_HEAD"

        branch_res = run_git(["symbolic-ref", "-q", "--short", "HEAD"], cwd=workdir)
        if branch_res.returncode == 0:
            curr_branch = branch_res.stdout.strip()
        else:
            branch_abbrev = run_git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=workdir)
            curr_branch = branch_abbrev.stdout.strip() if branch_abbrev.returncode == 0 else "DETACHED_OR_UNKNOWN"

        dirty_state, dirty_err = get_dirty_state(workdir)
        if dirty_state is None:
            dirty_err_occurred = True
        else:
            dirty_err_occurred = False
    else:
        curr_head = "no-git"
        curr_branch = "no-git"
        dirty_state = None
        dirty_err_occurred = False
        dirty_err = "not_inside_work_tree"

    if not os.path.isfile(args.snapshot_in):
        # Missing snapshot: reject explicitly, preserving observed post state
        result = {
            "git_policy": policy,
            "git_policy_outcome": "rejected",
            "git_policy_reason": "missing_initial_snapshot",
            "git_state_changed": True,
            "git_start_sha": None,
            "git_end_sha": curr_head if curr_head not in ("NO_HEAD", "no-git") else None,
            "git_task_base": None,
            "git_task_branch": curr_branch if curr_branch not in ("DETACHED_OR_UNKNOWN", "no-git") else None,
            "git_created_commits": [],
            "git_dirty": dirty_state["dirty"] if dirty_state else None,
            "git_dirty_state": dirty_state,
        }
        output_result(result, args.output_json)
        return

    try:
        with open(args.snapshot_in, "r", encoding="utf-8") as f:
            snapshot = json.load(f)
    except Exception as e:
        result = {
            "git_policy": policy,
            "git_policy_outcome": "rejected",
            "git_policy_reason": f"malformed_initial_snapshot ({e})",
            "git_state_changed": True,
            "git_start_sha": None,
            "git_end_sha": curr_head if curr_head not in ("NO_HEAD", "no-git") else None,
            "git_task_base": None,
            "git_task_branch": curr_branch if curr_branch not in ("DETACHED_OR_UNKNOWN", "no-git") else None,
            "git_created_commits": [],
            "git_dirty": dirty_state["dirty"] if dirty_state else None,
            "git_dirty_state": dirty_state,
        }
        output_result(result, args.output_json)
        return

    if policy == "strict":
        if not snapshot.get("is_git", False):
            is_now_git = is_git
            result = {
                "git_policy": "strict",
                "git_policy_outcome": "rejected" if is_now_git else "passed",
                "git_policy_reason": "git_repo_created" if is_now_git else "not_a_git_repo",
                "git_state_changed": is_now_git,
                "git_start_sha": None,
                "git_end_sha": curr_head if curr_head not in ("NO_HEAD", "no-git") else None,
                "git_task_base": None,
                "git_task_branch": None,
                "git_created_commits": [],
                "git_dirty": dirty_state["dirty"] if dirty_state else None,
                "git_dirty_state": dirty_state,
            }
            output_result(result, args.output_json)
            return

        if not is_git:
            post_head = "NO_HEAD"
            post_branch = "NO_GIT"
            post_index_hash = "INDEX_READ_FAILED"
        else:
            post_head = curr_head
            post_branch = curr_branch
            post_index_hash, idx_err = compute_index_hash(workdir)
            if idx_err:
                post_index_hash = "INDEX_READ_FAILED"

        pre_head = snapshot.get("head", "")
        pre_branch = snapshot.get("branch", "")
        pre_index_hash = snapshot.get("index_hash", "")

        mutated = (
            post_head != pre_head or
            post_branch != pre_branch or
            post_index_hash != pre_index_hash or
            post_index_hash == "INDEX_READ_FAILED" or
            pre_index_hash == "INDEX_READ_FAILED"
        )
        if mutated:
            if post_head != pre_head:
                reason = "head_mutated"
            elif post_branch != pre_branch:
                reason = "branch_mutated"
            else:
                reason = "index_mutated"
        else:
            reason = "unmodified"

        result = {
            "git_policy": "strict",
            "git_policy_outcome": "rejected" if mutated else "passed",
            "git_policy_reason": reason,
            "git_state_changed": mutated,
            "git_start_sha": pre_head if pre_head != "NO_HEAD" else None,
            "git_end_sha": post_head if post_head != "NO_HEAD" else None,
            "git_task_base": None,
            "git_task_branch": None,
            "git_created_commits": [],
            "git_dirty": dirty_state["dirty"] if dirty_state else None,
            "git_dirty_state": dirty_state,
        }
        output_result(result, args.output_json)
        return

    # policy == "task-commits"
    pre_head = snapshot.get("head", "")
    pre_branch = snapshot.get("branch", "")
    base = snapshot.get("base", "")
    snapshot_refs = snapshot.get("protected_refs", {})

    # Check git repo still valid
    is_bare_res = run_git(["rev-parse", "--is-bare-repository"], cwd=workdir)
    if not is_git or is_bare_res.returncode != 0 or is_bare_res.stdout.strip() != "false":
        err_msg = is_git_res.stderr.strip() if not is_git else is_bare_res.stderr.strip()
        result = {
            "git_policy": "task-commits",
            "git_policy_outcome": "rejected",
            "git_policy_reason": f"git_read_failed (missing_or_corrupted_repo: {err_msg})" if err_msg else "git_read_failed (missing_or_corrupted_repo)",
            "git_state_changed": True,
            "git_start_sha": pre_head,
            "git_end_sha": None,
            "git_task_base": base,
            "git_task_branch": pre_branch,
            "git_created_commits": [],
            "git_dirty": None,
            "git_dirty_state": None,
        }
        output_result(result, args.output_json)
        return

    post_head = curr_head
    post_branch = curr_branch

    # Helper function to construct structured result
    def make_result(outcome, reason, state_changed, commits=None):
        return {
            "git_policy": "task-commits",
            "git_policy_outcome": outcome,
            "git_policy_reason": reason,
            "git_state_changed": state_changed,
            "git_start_sha": pre_head,
            "git_end_sha": post_head if post_head != "NO_HEAD" else None,
            "git_task_base": base,
            "git_task_branch": pre_branch,
            "git_created_commits": created_commits if commits is None else commits,
            "git_dirty": dirty_state["dirty"] if dirty_state else None,
            "git_dirty_state": dirty_state,
        }

    # Inspect created commits if post_head is valid commit
    created_commits = []
    if post_head not in ("NO_HEAD", pre_head):
        anc_test = run_git(["merge-base", "--is-ancestor", pre_head, post_head], cwd=workdir)
        if anc_test.returncode not in (0, 1):
            output_result(make_result("rejected", f"git_read_failed (merge-base failed: {anc_test.stderr.strip()})", True, commits=[]), args.output_json)
            return
        if anc_test.returncode == 0:
            rl = run_git(["rev-list", "--reverse", f"{pre_head}..{post_head}"], cwd=workdir)
            if rl.returncode != 0:
                output_result(make_result("rejected", f"git_read_failed (rev-list --reverse failed: {rl.stderr.strip()})", True, commits=[]), args.output_json)
                return
            created_commits = [c.strip() for c in rl.stdout.splitlines() if c.strip()]

    # Check detached HEAD
    sym_branch_res = run_git(["symbolic-ref", "-q", "--short", "HEAD"], cwd=workdir)
    if sym_branch_res.returncode != 0:
        output_result(make_result("rejected", "detached_head", True), args.output_json)
        return

    # Check branch matches assigned branch
    if post_branch != pre_branch:
        output_result(make_result("rejected", f"branch_changed (expected {pre_branch}, got {post_branch})", True), args.output_json)
        return

    # Check HEAD exists
    if post_head == "NO_HEAD":
        output_result(make_result("rejected", "missing_head", True), args.output_json)
        return

    # Check descendant (fast-forward linear history)
    anc_res = run_git(["merge-base", "--is-ancestor", pre_head, post_head], cwd=workdir)
    if anc_res.returncode not in (0, 1):
        output_result(make_result("rejected", f"git_read_failed (merge-base failed: {anc_res.stderr.strip()})", True), args.output_json)
        return
    if anc_res.returncode == 1:
        output_result(make_result("rejected", "non_descendant_head", True), args.output_json)
        return

    # Check merge commits in pre_head..post_head
    if post_head != pre_head:
        parents_res = run_git(["rev-list", "--parents", f"{pre_head}..{post_head}"], cwd=workdir)
        if parents_res.returncode != 0:
            output_result(make_result("rejected", f"git_read_failed (rev-list --parents failed: {parents_res.stderr.strip()})", True), args.output_json)
            return
        for line in parents_res.stdout.splitlines():
            tokens = line.strip().split()
            if len(tokens) > 2:
                output_result(make_result("rejected", f"merge_commit_detected ({tokens[0]})", True), args.output_json)
                return

    # Check protected refs (all refs outside refs/heads/{branch})
    current_protected, prot_err = get_protected_refs(workdir, pre_branch)
    if prot_err:
        output_result(make_result("rejected", f"git_read_failed ({prot_err})", True), args.output_json)
        return

    # Check modified protected refs
    for ref, sha in snapshot_refs.items():
        if ref in current_protected and current_protected[ref] != sha:
            output_result(make_result("rejected", f"protected_ref_modified ({ref})", True), args.output_json)
            return

    # Check deleted protected refs
    for ref in snapshot_refs:
        if ref not in current_protected:
            output_result(make_result("rejected", f"protected_ref_deleted ({ref})", True), args.output_json)
            return

    # Check created protected refs
    for ref in current_protected:
        if ref not in snapshot_refs:
            output_result(make_result("rejected", f"protected_ref_created ({ref})", True), args.output_json)
            return

    # Check dirty state query error
    if dirty_err_occurred:
        output_result(make_result("rejected", f"git_read_failed ({dirty_err})", True), args.output_json)
        return

    # Compute factual git_state_changed
    post_index_hash, idx_err = compute_index_hash(workdir)
    if idx_err:
        output_result(make_result("rejected", f"git_read_failed ({idx_err})", True), args.output_json)
        return
    pre_index_hash = snapshot.get("index_hash", "")

    is_dirty = dirty_state["dirty"]
    git_state_changed = (
        (post_head != pre_head) or
        (post_index_hash != pre_index_hash) or
        is_dirty
    )

    # Cleanliness evaluation
    if run_status == "SUCCESS" and exit_code == 0:
        # Successful completion requires clean index and clean worktree
        if dirty_state["staged"]:
            outcome = "rejected"
            reason = "staged_changes_uncommitted"
        elif dirty_state["dirty"]:
            outcome = "rejected"
            reason = "dirty_worktree"
        else:
            outcome = "passed"
            reason = "linear_commits" if len(created_commits) > 0 else "clean_noop"
    else:
        # Failure or interruption preserves dirty work and reports it; never reset
        outcome = "passed"
        reason = "dirty_preserved" if is_dirty else ("linear_commits" if len(created_commits) > 0 else "clean_noop")

    output_result(make_result(outcome, reason, git_state_changed), args.output_json)


def output_result(result, out_path):
    if out_path:
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2)
    else:
        print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Git policy helper for agent-harness")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # pre-check
    p_pre = subparsers.add_parser("pre-check")
    p_pre.add_argument("--workdir", required=True, help="Git workdir path")
    p_pre.add_argument("--policy", required=True, choices=["strict", "task-commits"])
    p_pre.add_argument("--branch", default="", help="Task branch (required for task-commits)")
    p_pre.add_argument("--base", default="", help="Task base commit (required for task-commits)")
    p_pre.add_argument("--snapshot-out", default=None, help="Output path for snapshot JSON")

    # post-check
    p_post = subparsers.add_parser("post-check")
    p_post.add_argument("--workdir", required=True, help="Git workdir path")
    p_post.add_argument("--policy", required=True, choices=["strict", "task-commits"])
    p_post.add_argument("--snapshot-in", required=True, help="Input snapshot JSON file")
    p_post.add_argument("--status", required=True, help="Run status string (SUCCESS, ERROR, etc.)")
    p_post.add_argument("--exit-code", required=True, help="Process exit code integer")
    p_post.add_argument("--output-json", default=None, help="Output path for result JSON")

    args = parser.parse_args()

    if args.command == "pre-check":
        cmd_pre_check(args)
    elif args.command == "post-check":
        cmd_post_check(args)


if __name__ == "__main__":
    main()
