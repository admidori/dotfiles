---
name: handoff-to-codex
description: Use when a design or implementation plan has already been agreed with the user and should be handed off to Codex to implement, then reviewed by Claude once Codex finishes. Triggers on requests like "Codexに実装させて", "Codexに投げてレビューして", "implement this with Codex and review it". Not for tasks the user wants Claude to implement directly.
---

Runs the design → Codex-implements → Claude-reviews handoff non-interactively via `codex exec`, without bypassing Codex's sandbox or approval gate.

## Steps

1. **Confirm the design is final.** This skill hands off a concrete plan, not a vague request. If the design hasn't been agreed with the user yet in this conversation, produce it first and get explicit go-ahead before invoking Codex. Before running `codex exec`, show the operator a short summary of what will be implemented (approach, files touched, anything risky) and get an explicit go-ahead — even if a design was discussed earlier in the conversation, restate it as a final checkpoint immediately before the handoff; an earlier open-ended discussion is not equivalent to this confirmation. If a previous handoff's result on this same branch is being substantially reworked or reverted, treat that as a sign the design wasn't actually final — pause and re-confirm with the operator rather than issuing another ad-hoc handoff.

2. **Pick the target directory.** Prefer an existing `aiwt`-created worktree for the task's branch. If none exists and the change is non-trivial, ask whether to create one. Before running `aiwt <branch>`, check the branch currently checked out where you'd run it (`git rev-parse --abbrev-ref HEAD`) — if it isn't `main` (or the repo's stated integration branch), don't let `aiwt` default its base to that HEAD; pass the base explicitly (`aiwt <branch> main`) or `cd` to an integration-branch checkout first. Never target a directory with uncommitted unrelated changes — check `git -C <dir> status` first.

3. **Invoke Codex non-interactively:**
   ```
   codex exec -C <dir> -s workspace-write -a never "<design>"
   ```
   - `-s workspace-write`: Codex can edit files and run commands inside `<dir>` without asking.
   - `-a never`: no approval prompts are attempted; anything outside the sandbox fails back to Codex as an error instead of hanging on an approval nobody can answer.
   - Never add `--dangerously-bypass-approvals-and-sandbox`. If Codex needs something outside the sandbox, that must surface as a failure for a human to decide on, not be auto-granted.
   - This call blocks until Codex finishes. Use a generous Bash timeout, or `run_in_background` for tasks likely to run long.

4. **Inspect the actual diff, not Codex's self-report.** Run `git -C <dir> status` / `git -C <dir> diff` (and `git -C <dir> log` if Codex committed). Treat this as the source of truth.

5. **Review the diff** using the same lens as `/code-review`: correctness bugs first, then reuse/simplification/efficiency. Read the changed code directly rather than trusting the commit message or Codex's final message.

6. **If Codex's output shows a sandbox/permission denial**, call this out explicitly to the user as a blocked step needing a decision — don't silently retry with a wider sandbox or ignore it.

7. **Report findings and stop.** Do not commit, amend, or push on the user's behalf as part of this flow — Codex may have committed locally inside the worktree, but pushing or merging still requires the user's explicit instruction, per this project's normal git safety rules.

8. **Close the loop on the worktree/branch.** Once the operator has merged or rebased this branch's work elsewhere, remove the worktree (`git worktree remove <dir>`) and delete the branch — or say explicitly that it's staying open for follow-up. Before starting a new handoff, check `git worktree list` / `git branch -a` for stale or overlapping branches left over from earlier handoffs on this same task.
