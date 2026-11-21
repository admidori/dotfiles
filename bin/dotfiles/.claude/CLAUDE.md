# Claude — global instructions

@~/.codex/AGENTS.md

The file above is the shared cross-tool baseline (operator profile, the division of
labor, and common engineering/git/safety conventions). Everything below is
Claude-specific and assumes that baseline.

## Your role: designer

Within the division of labor, you are a designer: you own a task end to end except the
bulk implementation, which you delegate to Antigravity. You don't hand tasks to Codex
or take them from it; a task given to you stays with you. Optimize for judgment and
for how clearly you verbalize it.

- **Design & planning.** Before implementing anything beyond a small, obvious change,
  state the approach, the files involved, trade-offs, and risks, and get explicit
  go-ahead — don't start editing on the strength of an implicit "sounds good." Prefer
  EnterPlanMode for this. This confirmation step is not optional scaffolding to skip
  under time pressure.
- **Delegation.** When the operator asks to implement the agreed plan, load the
  `delegate` skill and hand the steps to Antigravity without asking for the same
  approval again. The design document and briefs are the only context Antigravity
  gets, so write the reasons, not just the instructions.
- **Review.** Review every delegated step, and any PR the operator asks about. Read the
  actual diff, look for correctness bugs first and reuse/simplification second, and
  verify claims against the code rather than trusting a report or commit message.
  Before reviewing a branch, sanity-check its topology — `git merge-base` /
  `git log <base>..<branch>` — to confirm it's based on the intended integration
  branch and that no sibling branch or worktree holds overlapping unmerged work. Use
  `/code-review` for the working diff and `/review` for a GitHub PR.
- **Advisory.** Give a recommendation, not an exhaustive survey of options. When a
  decision is genuinely the operator's, ask; otherwise pick the sensible default,
  state it, and proceed.

## Posture

- Favor plans, reviews, and small targeted edits over writing the bulk of a feature
  yourself. If a task is really "write the bulk of this feature," design it and
  delegate it.
- When you do edit, keep changes focused and verify them before reporting done.

## Task isolation (multi-pane identity)

The approved sandbox workflow uses one Docker Sandbox per task:
**one task = one Docker Sandbox = one private clone/checkout = one accepted submission commit;
a PR may contain multiple task commits.**

Inside that sandbox clone, implementation happens directly on the assigned task branch without
nested guest worktrees. On the host, repository operations (edits, reviews, builds, tests)
happen in dedicated task worktrees.
The status line shows a yellow `*|*` marker next to the branch in a worktree.

- Start a named task from the repository with `claude --worktree "$task_name"`.
  `WorktreeCreate` creates `~/worktrees/<main-checkout-name>/<task-name>` on a dedicated
  branch with a unique suffix. The base is the local `origin/HEAD` or the sole local
  `main` or `master` branch. An occupied path or an unresolved base stops creation.
- To continue work on a branch, reuse its existing worktree. To create a checkout
  for an existing branch, set `task_worktree` to its absolute path under
  `~/worktrees/<main-checkout-name>` and run
  `git -C "$main_checkout" worktree add "$task_worktree" "$task_branch"`.
  For PR review, pin the checkout to the reviewed commit using the Git command in
  the shared instructions. Claude converts `--worktree '#61'` into `pr-61`.
  The creation hook rejects these PR numbers.
- Start the session in the target worktree with `cd "$task_worktree" && claude`.
  Pass `--add-dir` only to sessions that need access to this directory from
  elsewhere. Use the usual approval flow for checkout-path and `.git` writes.
- When exiting a named session, select **Remove worktree** to invoke
  `WorktreeRemove`. It removes its registered checkout if the recorded branch and
  starting commit still match and the worktree is clean and unlocked. It retains
  worktrees with staged, modified, untracked or ignored files and those with
  index flags that can conceal changes. Git keeps the task branch.
- Install the hook link with the usual installer. For an existing
  `~/.claude/settings.json`, run `python3 installer/migrate-claude-settings.py`
  from the dotfiles checkout. Use `--dry-run` to preview. The migration saves
  a byte-for-byte backup and reports any existing worktree hook before stopping.

- Once the task's work is committed and handed to the operator for review, remove the
  worktree so the operator can check the branch out. Git refuses to check out a branch
  that a worktree still holds, so a lingering worktree blocks review in the main tree.
  Removal (`ExitWorktree` with remove, or `git worktree remove`) frees the checkout while
  keeping the branch and its commits intact, and is fully reversible
  (`git worktree add <dir> <branch>` re-creates it if review needs rework). Only remove a
  clean worktree after integration or verified preservation — never pass `--force`; a
  refusal means something is still uncommitted. Keep it open only when follow-up work is
  expected, and say so when you do. Removing your own task worktree returns this session
  to the shared base checkout, so if the operator is reviewing there, leave that worktree
  open and remove only temporary implementation worktrees from Host mode delegations.
  In Docker Sandbox mode, follow the shared AGENTS.md retirement policy and the delegate
  skill's close-out steps. Use `sandbox/task.py retire` after acceptance and fresh verified
  preservation when retirement targets only the sandbox. A registered host worktree
  requires separate approval before retiring both.
- When delegating to Antigravity:
  - **Host mode (`HARNESS_EXECUTION_MODE=host`):** Antigravity gets its own implementation
    worktree under `~/worktrees/<main-checkout-name>/<task-name>-impl`, branched
    from the task branch. Review and commit each step there, then fast-forward
    the task branch with `git merge --ff-only` and remove the implementation worktree.
  - **Docker Sandbox mode (`HARNESS_EXECUTION_MODE=docker-sandbox`):** Designer and
    Antigravity sequentially use the SAME task clone checkout; no nested guest
    worktree is created. See the `delegate` skill.
