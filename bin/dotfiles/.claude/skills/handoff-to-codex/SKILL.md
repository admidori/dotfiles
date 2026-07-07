---
name: handoff-to-codex
description: Use when a design or implementation plan has already been agreed with the user and should be handed off to Codex to implement, then reviewed by Claude once Codex finishes. Triggers on requests like "Codexに実装させて", "Codexに投げてレビューして", "implement this with Codex and review it". Not for tasks the user wants Claude to implement directly.
---

Runs the design → Codex-implements → Claude-reviews handoff non-interactively via `codex exec`, without bypassing Codex's sandbox or approval gate.

## Steps

1. **Confirm the design is final.** This skill hands off a concrete plan, not a vague request. If the design hasn't been agreed with the user yet in this conversation, produce it first and get explicit go-ahead before invoking Codex. Before running `codex exec`, show the operator a short summary of what will be implemented (approach, files touched, anything risky) and get an explicit go-ahead — even if a design was discussed earlier in the conversation, restate it as a final checkpoint immediately before the handoff; an earlier open-ended discussion is not equivalent to this confirmation. If a previous handoff's result on this same branch is being substantially reworked or reverted, treat that as a sign the design wasn't actually final — pause and re-confirm with the operator rather than issuing another ad-hoc handoff.

2. **Give Codex its own worktree branched from the task branch.** Per the worktree-per-task rule in CLAUDE.md, Claude works in its own task worktree; Codex implements in a *separate* worktree so this session's tree stays clean for review and the two don't fight over files. From the task worktree (its `HEAD` is the task branch), create a child worktree on a new `<task>-impl` branch:
   ```
   git worktree add ../<repo>-<task>-impl -b <task>-impl HEAD
   ```
   This deliberately stacks `<task>-impl` on the still-unmerged task branch — intended here, but it means the two must land together: merge `<task>-impl` back into the task branch before opening the PR to the integration branch, or, if the task branch has no commits of its own, PR `<task>-impl` directly. The stack must not be left open silently — call it out when reporting.
   - If Claude is *not* in a task worktree (e.g. a handoff outside the worktree-per-task flow), fall back to an existing `aiwt`-created worktree, or create one branched from the integration branch: check the branch where you'd run it (`git rev-parse --abbrev-ref HEAD`) and if it isn't `main`/the integration branch, pass the base explicitly (`aiwt <branch> main`) rather than letting `aiwt` default to that HEAD.
   - Never target a directory with uncommitted unrelated changes — check `git -C <dir> status` first.

3. **Invoke Codex non-interactively:**
   ```
   codex exec -C <dir> -s workspace-write "<design>" < /dev/null
   ```
   - `-s workspace-write`: Codex can edit files and run commands inside `<dir>` without asking.
   - No `-a`/`--ask-for-approval` flag: `exec` has no such flag at all (as of v0.142.5) — it's non-interactive by design and never prompts for approval. That flag exists only on the top-level interactive `codex` command; passing it to `exec` is a hard CLI error. Anything `workspace-write` can't do surfaces back as a failure instead of an approval prompt.
   - `< /dev/null`: required. `codex exec` reads stdin to append to the prompt ("Reading additional input from stdin..."), and under the Bash tool — especially `run_in_background` — stdin is never closed, so without this redirect the process hangs forever waiting for EOF instead of finishing. If a past invocation is found hanging, check `git -C <dir> status`/`diff` before killing it (Codex may not have written anything yet, or may be mid-edit), then kill it and rerun with the redirect.
   - Never add `--dangerously-bypass-approvals-and-sandbox`. If Codex needs something outside the sandbox, that must surface as a failure for a human to decide on, not be auto-granted.
   - This call blocks until Codex finishes. Use a generous Bash timeout, or `run_in_background` for tasks likely to run long.

4. **Inspect the actual diff, not Codex's self-report.** Run `git -C <dir> status` / `git -C <dir> diff` (and `git -C <dir> log` if Codex committed). Treat this as the source of truth.

5. **Review the diff** using the same lens as `/code-review`: correctness bugs first, then reuse/simplification/efficiency. Read the changed code directly rather than trusting the commit message or Codex's final message.

6. **If Codex's output shows a sandbox/permission denial**, call this out explicitly to the user as a blocked step needing a decision — don't silently retry with a wider sandbox or ignore it.

7. **Report findings and stop.** Do not commit, amend, or push on the user's behalf as part of this flow — Codex may have committed locally inside the worktree, but pushing or merging still requires the user's explicit instruction, per this project's normal git safety rules.

8. **Close the loop on the worktrees/branches.** A handoff in the worktree-per-task flow leaves a two-level stack (Codex's `<task>-impl` worktree on the task branch on the integration branch). Once the operator has landed the work, fold `<task>-impl` back into the task branch (or confirm it was PR'd directly), then remove the child worktree (`git worktree remove <dir>`) and delete its branch — and separately close out the task worktree per CLAUDE.md. Say explicitly if either is staying open for follow-up. Before starting a new handoff, check `git worktree list` / `git branch -a` for stale or overlapping branches left over from earlier handoffs on this same task.
