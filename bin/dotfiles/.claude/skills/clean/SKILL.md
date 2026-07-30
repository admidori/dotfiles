---
name: clean
description: Use when local git branches and worktrees have piled up and the ones already merged into main/master should be cleaned out. Surveys every local branch and worktree, classifies each as safe to remove or must-keep with a reason, shows the operator the classification, and only deletes after an explicit go-ahead. Triggers on "/clean", "ブランチを掃除して", "worktreeを片付けて", "マージ済みのブランチを消して", "clean up merged branches and worktrees". Not for deleting remote branches or unmerged work.
---

Cleans up local git branches and worktrees whose work has already landed on the integration branch. Survey first, classify everything with a reason, show the operator, and delete only after an explicit go-ahead — never as the first action.

This machine runs several Claude sessions side by side in different tmux panes, each in its own worktree (see the worktree-per-task rule in CLAUDE.md). A cleanup that deletes eagerly can pull the rug out from under a live parallel session, so the survey/confirm/execute split is not ceremony — it is the whole safety design.

## Steps

1. **Refresh remote state, then find the integration branch.** Run `git fetch --prune` so merge status is judged against current remotes rather than a stale cache. Resolve the integration branch instead of assuming a name:
   ```
   git symbolic-ref refs/remotes/origin/HEAD    # e.g. refs/remotes/origin/master
   ```
   If that ref is missing, `git remote set-head origin -a` restores it. Use the resolved name (`master` here, `main` elsewhere) everywhere below — never hardcode one.

2. **Survey worktrees and branches.**
   ```
   git worktree list --porcelain     # paths, HEADs, branches, locked/prunable markers
   git branch -vv                    # local branches with upstream and ahead/behind
   git branch --merged <integration>
   ```
   For each worktree also check `git -C <dir> status --porcelain` — a non-empty result means uncommitted or untracked work lives there.

3. **Classify every worktree.** Each one lands in exactly one bucket, and the *keep* buckets are absolute — no flag, no operator instruction inside this skill's run overrides them:
   - **Never touch — this session's own worktree.** Removing it would yank the ground out from under the running session. Report it; leave it.
   - **Never touch — locked** (`locked` in `git worktree list --porcelain`). A lock means another session or the operator deliberately pinned it, most likely a live Claude pane — the lock reason spells this out, e.g. `locked claude session <name> (pid <pid> start <n>)`. Report it as locked, quoting that reason so the operator can see which session owns it, and move on.
   - **Never touch — dirty.** Non-empty `git -C <dir> status --porcelain`, i.e. uncommitted or untracked files. That work exists nowhere else. `git worktree remove` refuses these on its own unless forced, which is exactly why this skill never forces.
   - **Candidate for removal** — clean, unlocked, not this session's, and its branch is already merged into the integration branch. Note the branch it holds; the branch itself is judged separately in step 4.
   - **Prunable** — registered but its directory is gone (`prunable` in the porcelain output). These are bookkeeping leftovers with no working tree to lose, cleared by `git worktree prune` in step 6.

4. **Classify every branch.**
   - **Never touch** the integration branch, and never the branch currently checked out in *this* worktree.
   - **Never touch a branch held by a worktree that is staying.** `git branch -vv` prefixes worktree-held branches with `+` and names the holding worktree in parentheses, which is the quickest cross-check against step 3. If that worktree fell into a *keep* bucket, its branch is off limits too — git refuses to delete it anyway, but classifying it here means the report explains why instead of surfacing a raw refusal. If the worktree is itself an approved removal candidate, the branch is *not* excluded by this rule: step 6 removes the worktree first, which frees the branch for `-d`.
   - **Never touch a branch with unpushed commits** — `git branch -vv` showing `ahead`, or no upstream at all combined with commits not in the integration branch. Report these as unpushed work.
   - **Candidate for deletion** — appears in `git branch --merged <integration>` and none of the above applies. These are removable with `git branch -d`, which re-checks the merge itself. Apply the exclusions above rather than taking `--merged` at face value: its output includes the integration branch and the current branch too, since both are trivially their own ancestors.
   - **Report-only: possibly squash- or rebase-merged.** `git branch --merged` is an ancestry test, so a branch whose PR was squash- or rebase-merged never appears there even though its work has landed. Detect these with `gh pr list --state merged --head <branch>` — a merged PR is the trustworthy signal — and **report them without deleting**. They would need `-D`, which skips git's own merge check, so they stay a manual decision for the operator. (`git cherry <integration> <branch>` is only a weak hint here: it flags commits as `-` when they are individually patch-equivalent to something upstream, which a squash merge generally makes false for anything past a one-commit branch. Don't treat a `+` from it as proof the work is unmerged.)
   - **Out of scope: remote branches.** Deleting a remote branch leaves this machine and affects anyone else reading the repo. Never do it here, even for a branch whose PR is merged; if the operator wants it, that is a separate explicit request.

5. **Show the classification and get an explicit go-ahead.** Present it compactly — one line per worktree and per branch, each with its bucket and the reason — so what will be deleted and what will be kept is visible side by side before anything happens. Then stop and wait. Invoking `/clean` is a request to survey; it is not standing approval to delete. If nothing is a candidate, say so plainly and stop — there is nothing to confirm.

6. **Execute in this order, after approval.** The order is mandatory, not tidiness: git refuses to delete a branch that any worktree still has checked out, so the worktree has to go first.
   ```
   git worktree remove <dir>     # for each approved candidate worktree
   git branch -d <branch>        # for each approved candidate branch
   git worktree prune            # clear prunable registrations
   ```
   - **Never `--force` and never `-D`.** Both exist to skip a safety check this skill relies on. A refusal is information, not an obstacle: `git worktree remove` refusing means the tree has modified or untracked files after all, and `git branch -d` refusing means the work is not actually merged. Stop on any refusal, report it, and re-classify that entry as must-keep — don't escalate the flag.
   - Run `git worktree prune --dry-run` first if the prunable list wasn't already established in step 3.
   - Print the SHA of each deleted branch (`git branch -d` prints it) and keep it in the report — a deleted branch is recoverable via that SHA or `git reflog`, and a removed worktree is re-creatable with `git worktree add <dir> <branch>` as long as the branch survives.

7. **Verify and report.** Re-run `git worktree list` and `git branch -vv`, then report what was removed (with the recorded SHAs), what was kept and why — especially anything locked, dirty, or holding unpushed work — and anything the operator still needs to decide, such as the possibly-squash-merged branches from step 4. If a refusal in step 6 changed the plan mid-run, say so rather than quietly reporting the original plan as done.
