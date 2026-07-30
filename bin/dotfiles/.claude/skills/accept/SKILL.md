---
name: accept
description: Use when a design or implementation plan has already been agreed with the user and you are ready to accept it into implementation — Claude decomposes it into small tasks, then hands them to Codex one at a time (Codex edits only), reviewing, polishing, and committing each task before starting the next. Triggers on "/accept", "これで実装して", "Codexに実装させて", "Codexに投げてレビューして", "accept and implement this then review it". Not for tasks the user wants Claude to implement directly.
---

Runs the accept flow — an agreed design → Claude decomposes it into tasks → for each task, Codex implements (edits only) and Claude reviews, polishes, and commits — driven non-interactively via `codex exec`, without bypassing Codex's sandbox or approval gate.

The loop is deliberately per-task rather than one big handoff: each Codex round produces one small diff that can be reviewed in isolation and committed on its own, so a mistake surfaces in a reviewable change instead of being buried in a large one, and the commit history ends up as a sequence of focused commits per the AGENTS.md convention.

## Steps

1. **Confirm the design is final.** This skill hands off a concrete plan, not a vague request. If the design hasn't been agreed with the user yet in this conversation, produce it first and get explicit go-ahead before invoking Codex. Before decomposing and handing anything off, show the operator a short summary of what will be implemented (approach, files touched, anything risky) and get an explicit go-ahead — even if a design was discussed earlier in the conversation, restate it as a final checkpoint immediately before the handoff; an earlier open-ended discussion is not equivalent to this confirmation. If a previous handoff's result on this same branch is being substantially reworked or reverted, treat that as a sign the design wasn't actually final — pause and re-confirm with the operator rather than issuing another ad-hoc handoff.

2. **Decompose the design into an ordered task list.** Split the agreed design into the smallest pieces that are each independently committable — one behavior change per task, matching the focused-commit convention. For each task, write down: a one-line imperative title (it becomes the commit header), the files it's expected to touch, and how it will be verified. Then:
   - **Order by dependency, and keep every step green.** Each task must leave the tree in a working, verifiable state, so no commit in the resulting history is broken on its own.
   - **Size each task to one Codex run** — roughly one concern and a handful of files. If a task needs more than that to describe, split it.
   - **Get the operator's go-ahead on the decomposition itself**, showing the numbered list, before the first handoff. This is a separate checkpoint from step 1: the operator is agreeing to the sequence of commits, not just to the end state.
   - **Don't invent artificial splits.** If the design is genuinely one atomic change, say so and run the loop once. Slicing a change into pieces that don't independently work is worse than a single commit.
   - Track the list (task tools if available, otherwise restate it) and keep it visible as the loop progresses, so at any point the operator can see what has landed and what is left.

3. **Give Codex its own worktree branched from the task branch.** Per the worktree-per-task rule in CLAUDE.md, Claude works in its own task worktree; Codex implements in a *separate* worktree so this session's tree stays clean for review and the two don't fight over files. Create it once and reuse it for every task in the loop. From the task worktree (its `HEAD` is the task branch), create a child worktree on a new `<task>-impl` branch:
   ```
   git worktree add ../<repo>-<task>-impl -b <task>-impl HEAD
   ```
   This deliberately stacks `<task>-impl` on the still-unmerged task branch — intended here, but it means the two must land together: merge `<task>-impl` back into the task branch before opening the PR to the integration branch, or, if the task branch has no commits of its own, PR `<task>-impl` directly. The stack must not be left open silently — call it out when reporting.
   - If Claude is *not* in a task worktree (e.g. a handoff outside the worktree-per-task flow), fall back to an existing `aiwt`-created worktree, or create one branched from the integration branch: check the branch where you'd run it (`git rev-parse --abbrev-ref HEAD`) and if it isn't `main`/the integration branch, pass the base explicitly (`aiwt <branch> main`) rather than letting `aiwt` default to that HEAD.
   - Never target a directory with uncommitted unrelated changes — check `git -C <dir> status` first.

## Per-task loop

Repeat steps 4–8 for each task in the list, in order, one task per `codex exec` invocation. Never batch several tasks into one invocation: the whole point is that each review sees one small diff and each commit covers one change.

4. **Hand a single task to Codex non-interactively:**
   ```
   codex exec -C <dir> -s workspace-write "<one task>" < /dev/null
   ```
   - **The prompt must carry all of the following, or the run stalls, overreaches, or produces the wrong thing:**
     1. The single task to implement, stated concretely.
     2. Enough of the overall design as context, plus what earlier tasks already landed. Each invocation is a fresh Codex session with no memory of previous rounds — the committed tree shows their *result*, but not the intent behind them.
     3. An explicit scope boundary: implement *only* this task and do not start on later ones. Without this, Codex tends to run ahead, and the diff stops being reviewable in isolation.
     4. That the design is already approved by the operator and reviewer and that Codex must NOT pause to ask for confirmation — `codex exec` is non-interactive, so Codex's own pre-implementation-confirmation habit will otherwise stop the run with nobody to answer and nothing gets built.
     5. That Codex makes the edits and verifies them (`bash -n`, `shellcheck`, build/test as relevant) but does NOT commit — Claude commits after review. A linked worktree's git metadata lives outside the `workspace-write` root anyway, so Codex cannot commit there even if asked.
   - `-s workspace-write`: Codex can edit files and run commands inside `<dir>` without asking.
   - No `-a`/`--ask-for-approval` flag: `exec` has no such flag at all (as of v0.145.0) — it's non-interactive by design and never prompts for approval. That flag exists only on the top-level interactive `codex` command; passing it to `exec` is a hard CLI error. Anything `workspace-write` can't do surfaces back as a failure instead of an approval prompt.
   - `< /dev/null`: required. `codex exec` reads stdin to append to the prompt ("Reading additional input from stdin..."), and under the Bash tool — especially `run_in_background` — stdin is never closed, so without this redirect the process hangs forever waiting for EOF instead of finishing. If a past invocation is found hanging, check `git -C <dir> status`/`diff` before killing it (Codex may not have written anything yet, or may be mid-edit), then kill it and rerun with the redirect.
   - Never add `--dangerously-bypass-approvals-and-sandbox`. If Codex needs something outside the sandbox, that must surface as a failure for a human to decide on, not be auto-granted.
   - **If Codex's output shows a sandbox/permission denial** while editing, call this out explicitly to the user as a blocked step needing a decision — don't silently retry with a wider sandbox, ignore it, or move on to the next task.
   - This call blocks until Codex finishes. Use a generous Bash timeout, or `run_in_background` for tasks likely to run long.

5. **Inspect the actual diff, not Codex's self-report.** Run `git -C <dir> status` / `git -C <dir> diff`. Codex leaves everything uncommitted and every earlier task is already committed, so the working-tree diff is exactly this task and the whole story — treat it as the source of truth, not Codex's final message. If the diff contains changes outside the task's scope, don't just sweep them into the commit: decide whether to drop them or commit them separately, and say which.

6. **Review the diff** using the same lens as `/code-review`: correctness bugs first, then reuse/simplification/efficiency. Read the changed code directly rather than trusting Codex's final message. Where practical, exercise the change (e.g. run the affected script against an isolated fixture) rather than reasoning about it alone.

7. **Rework what the review found.** Trivial polish (dead code, awkward naming, stale comments, a one-line fix) — edit it yourself; that's faster than another round trip. Anything substantive — hand it back with a fresh `codex exec` against the same worktree, describing the defect and pointing at the uncommitted attempt already in the tree; the tree state is the context, so no session resume is needed. Re-review the result. Bound this: if two rework rounds haven't converged, stop and bring it to the operator instead of grinding. If the review shows the task's *premise* was wrong rather than its implementation, go to step 9.

8. **Commit this one task, then confirm the tree is clean.** Commit the reviewed result yourself in the worktree, covering only this task, with a Conventional Commits message and both co-author trailers:
   ```
   Co-authored-by: Claude (<your version>) <noreply@anthropic.com>
   Co-authored-by: Codex (<version>) <noreply@openai.com>
   ```
   Add the Codex trailer manually (use the actual `codex --version`/model if the plain model version isn't known). For Claude's trailer, don't duplicate one the harness already appends — check `git log -1` after committing and drop any duplicate. Then verify `git -C <dir> status` is clean before starting the next task: the next Codex round must begin from a committed baseline, or its diff won't be this task alone. Never carry uncommitted leftovers into the next round. Report the commit to the operator in a line or two and continue the loop. Do NOT push or merge at any point in the loop: that still needs the operator's explicit instruction, per this project's git safety rules.

## Stopping and closing out

9. **Stop the loop if a review invalidates the remaining plan.** When a task's review shows the design or the decomposition was wrong — not just sloppily implemented — pause, report what the completed commits already established, and re-confirm the remaining task list with the operator. Don't quietly redesign mid-loop: the operator agreed to a specific sequence in step 2, and the commits already landed are part of the record.

10. **Free the branch for review, then close the loop on the worktrees/branches.** An accept run in the worktree-per-task flow leaves a two-level stack (the `<task>-impl` worktree/branch on the task branch on the integration branch), with Claude's reviewed commits — one per task — on `<task>-impl`. Once the last task is committed, remove the child impl worktree (`git worktree remove <dir>`) — it was only a Codex edit sandbox, and while it holds `<task>-impl` the operator cannot check that branch out to review it in the main tree. Removal keeps the branch and its commits intact and is reversible, so do it before the operator reviews, not after they land the work. Only remove a clean worktree; never `--force`. Keep the branch (don't delete it) until the work has landed. Once the operator has landed the work, fold `<task>-impl` back into the task branch (or confirm it was PR'd directly), delete the now-merged branch, and close out the task worktree per CLAUDE.md. Say explicitly if any worktree is staying open for follow-up. Before starting a new accept run, check `git worktree list` / `git branch -a` for stale or overlapping branches left over from earlier runs on this same task.
