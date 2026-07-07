---
name: accept
description: Use when a design or implementation plan has already been agreed with the user and you are ready to accept it into implementation — hand it off to Codex to implement (Codex edits only), then Claude reviews, polishes, and makes one clean commit crediting both. Triggers on "/accept", "これで実装して", "Codexに実装させて", "Codexに投げてレビューして", "accept and implement this then review it". Not for tasks the user wants Claude to implement directly.
---

Runs the accept flow — an agreed design → Codex implements (edits only) → Claude reviews, polishes, and commits — driven non-interactively via `codex exec`, without bypassing Codex's sandbox or approval gate.

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
   - **Put two things in the prompt itself, or the run stalls or produces the wrong thing:** (1) state that the design is already approved by the operator and reviewer and that Codex must NOT pause to ask for confirmation — `codex exec` is non-interactive, so Codex's own pre-implementation-confirmation habit will otherwise stop the run with nobody to answer and nothing gets built; (2) tell Codex to make the edits and verify (`bash -n`, `shellcheck`, build/test as relevant) but NOT to commit — Claude commits after review. A linked worktree's git metadata lives outside the `workspace-write` root anyway, so Codex cannot commit there even if asked.
   - `-s workspace-write`: Codex can edit files and run commands inside `<dir>` without asking.
   - No `-a`/`--ask-for-approval` flag: `exec` has no such flag at all (as of v0.142.5) — it's non-interactive by design and never prompts for approval. That flag exists only on the top-level interactive `codex` command; passing it to `exec` is a hard CLI error. Anything `workspace-write` can't do surfaces back as a failure instead of an approval prompt.
   - `< /dev/null`: required. `codex exec` reads stdin to append to the prompt ("Reading additional input from stdin..."), and under the Bash tool — especially `run_in_background` — stdin is never closed, so without this redirect the process hangs forever waiting for EOF instead of finishing. If a past invocation is found hanging, check `git -C <dir> status`/`diff` before killing it (Codex may not have written anything yet, or may be mid-edit), then kill it and rerun with the redirect.
   - Never add `--dangerously-bypass-approvals-and-sandbox`. If Codex needs something outside the sandbox, that must surface as a failure for a human to decide on, not be auto-granted.
   - This call blocks until Codex finishes. Use a generous Bash timeout, or `run_in_background` for tasks likely to run long.

4. **Inspect the actual diff, not Codex's self-report.** Run `git -C <dir> status` / `git -C <dir> diff`. Codex leaves everything uncommitted, so the working-tree diff is the whole story — treat it as the source of truth, not Codex's final message.

5. **Review the diff** using the same lens as `/code-review`: correctness bugs first, then reuse/simplification/efficiency. Read the changed code directly rather than trusting Codex's final message. Where practical, exercise the change (e.g. run the affected script against an isolated fixture) rather than reasoning about it alone.

6. **If Codex's output shows a sandbox/permission denial** while editing, call this out explicitly to the user as a blocked step needing a decision — don't silently retry with a wider sandbox or ignore it.

7. **Review, polish, then make one clean commit.** Codex leaves its changes uncommitted, and its output can be a bit rough — fix anything sloppy (dead code, awkward naming, stale comments) before it lands, so the commit reflects reviewed, clean state rather than raw Codex output. Then commit the reviewed result yourself in the worktree with a Conventional Commits message and both co-author trailers, e.g.:
   ```
   Co-authored-by: Claude (<your version>) <noreply@anthropic.com>
   Co-authored-by: Codex (<version>) <noreply@openai.com>
   ```
   Add the Codex trailer manually (use the actual `codex --version`/model if the plain model version isn't known). For Claude's trailer, don't duplicate one the harness already appends — check `git log -1` after committing and drop any duplicate. Do NOT push or merge: that still needs the operator's explicit instruction, per this project's git safety rules.

8. **Close the loop on the worktrees/branches.** An accept run in the worktree-per-task flow leaves a two-level stack (the `<task>-impl` worktree/branch on the task branch on the integration branch), with Claude's clean commit on `<task>-impl`. Once the operator has landed the work, fold `<task>-impl` back into the task branch (or confirm it was PR'd directly), then remove the child worktree (`git worktree remove <dir>`) and delete its branch — and separately close out the task worktree per CLAUDE.md. Say explicitly if either is staying open for follow-up. Before starting a new accept run, check `git worktree list` / `git branch -a` for stale or overlapping branches left over from earlier runs on this same task.
