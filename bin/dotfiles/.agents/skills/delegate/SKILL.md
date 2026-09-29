---
name: delegate
description: Use when a design has been agreed with the operator and its implementation should be delegated to Antigravity — the designer (Claude or Codex) writes the design and one brief per step, Antigravity implements each step headlessly via `agy -p` and reports what it did, and the designer reviews, polishes, and commits each step before the next. Every hand-off is a file, so the harness can be inspected and improved. Triggers on "/delegate", "これで実装して", "Antigravityに実装させて", "実装を委譲して", "delegate this to antigravity". Not for changes the operator wants the designer to make directly.
---

Runs the delegation loop: agreed design → `design.md` → per step, `brief.md` → Antigravity implements (edits only) and returns a report → the designer verifies, reviews, polishes, and commits → next step.

Two things this skill is built around:

- **Every hand-off is written down.** The designer verbalizes the design (`design.md`, `brief.md`, `review.md`); the implementer verbalizes the implementation (`report-<n>.md`). Nothing passes through chat memory alone, so a later reader — human or agent — can see what was asked, what was done, and why.
- **The harness is an experiment.** The templates, this file, and the briefs are the variables; `metrics.jsonl` and the "Harness notes" in each review are the measurements. Label a harness change with `HARNESS_VARIANT` so runs before and after it can be compared.

## Layout

Artifacts live outside any repository, so they survive worktree removal and never land in a project's history:

```
$AGENT_HARNESS_DIR (default: ${XDG_STATE_HOME:-~/.local/state}/agent-harness)
  <repo>/<task>/
    design.md                  designer: goal, context, constraints, decisions, steps
    steps/<NN>-<slug>/
      brief.md                 designer → implementer: one step
      prompt-<n>.md            run-task.sh: the exact prompt sent
      run-<n>.jsonl            run-task.sh: agy event log
      report-<n>.md            implementer: what was done and why
      review-<n>.md            designer: verdict, findings, harness notes
    metrics.jsonl              run-task.sh: one row per run
```

Templates are in `templates/` next to this file; the runner is `scripts/run-task.sh`.

## Setup

1. **Confirm the design is final.** If it hasn't been agreed with the operator in this conversation, produce it first. Immediately before delegating, restate a short summary (approach, files, risks) and get an explicit go-ahead — an earlier open-ended discussion is not that confirmation. If a previous delegation on this branch is being substantially reworked, treat it as a sign the design wasn't final and re-confirm.

2. **Write `design.md`** from `templates/design.md` in the task directory. Record the reason behind each non-obvious decision and the alternatives rejected: the implementer gets no chat history, and the reasons are what let it handle cases the design didn't foresee. Fill in the steps table:
   - One committable behavior change per step, ordered by dependency, each leaving the tree working.
   - Size each step to one `agy` run — about one concern and a handful of files.
   - Don't invent artificial splits; a genuinely atomic change is one step.

   Show the operator the step list and get a go-ahead on the decomposition itself before the first run.

3. **Create an implementation worktree** branched from your task branch, reused for every step:
   ```
   git worktree add ../<repo>-<task>-impl -b <task>-impl HEAD
   ```
   `<task>-impl` stacks on the unmerged task branch only for the loop's duration; close-out fast-forwards it back and deletes it. If you're not in a task worktree, branch from the integration branch instead, passing the base explicitly when HEAD isn't it. Never target a directory with unrelated uncommitted changes.

## Per-step loop

Repeat for each step in order, one step per run. Never batch steps.

4. **Write `steps/<NN>-<slug>/brief.md`** from `templates/brief.md`. Carry the part of the design this step depends on and what earlier steps already landed — each run is a fresh Antigravity session. State the scope boundary explicitly. The run rules (no confirmation stops, edits only, no git) and the report format are appended by the runner from `templates/report.md`, so don't repeat them.

5. **Run the step:**
   ```
   HARNESS_DESIGNER="<you> (<model>)" <skill-dir>/scripts/run-task.sh <step-dir> <impl-worktree>
   ```
   - The runner uses `--mode accept-edits`: Antigravity may edit files in the workspace, while shell commands stay at their default deny. Never add `--dangerously-skip-permissions`.
   - Under Codex, `agy` needs network access and writes outside the workspace, so request sandbox escalation for this command rather than widening the sandbox.
   - It blocks until Antigravity finishes (default limit 30m, `AGY_TIMEOUT`). Use a generous timeout or run it in the background.
   - A non-zero exit means the run did not end with `SUCCESS`: read `stderr-<n>.log` and the tail of `run-<n>.jsonl`, and report a permission or authentication failure to the operator as a blocked step instead of retrying around it.

6. **Verify against the diff, not the report.** Run `git -C <impl-worktree> status` / `diff` — every earlier step is committed, so the working-tree diff is exactly this step. Then run the step's verification commands yourself (`bash -n`, `shellcheck`, tests); Antigravity cannot run shell commands in this mode, so verification is always yours. Changes outside the step's scope are dropped or committed separately — say which.

7. **Review and write `review-<n>.md`** from `templates/review.md`. Correctness first, then reuse and simplification. Compare the report with the diff and note anything changed but unreported or reported but not done. Fill in "Harness notes": what in the brief, templates, or instructions caused a problem or helped.

8. **Rework if needed.** Polish trivial issues yourself and list them in the review. For anything substantive, write a rework brief in the step directory describing the defect and pointing at the uncommitted attempt in the tree, and run the runner again with it as the third argument; the attempt counter keeps the earlier record. Bound this at two rework rounds, then bring it to the operator. If the review shows the step's premise was wrong, stop (step 10).

9. **Commit this step, then confirm the tree is clean.** Commit in the implementation worktree, covering only this step, with a Conventional Commits message whose body draws on the design's reasoning, and both trailers:
   ```
   Co-authored-by: <you> (<model>) <noreply@...>
   Co-authored-by: Antigravity (<model>) <noreply@google.com>
   ```
   If your harness already appends your own trailer, don't duplicate it — check `git log -1`. Record the commit SHA in the review, confirm `git status` is clean, report the commit to the operator in a line or two, and continue. Don't push or merge mid-loop.

## Stopping and closing out

10. **Stop if a review invalidates the remaining plan.** When the design or decomposition was wrong rather than the implementation sloppy, pause, report what the committed steps established, update `design.md`, and re-confirm the remaining steps with the operator.

11. **Fast-forward and remove the implementation worktree** as soon as the last step is committed. From your task worktree:
    ```
    git merge --ff-only <task>-impl
    git worktree remove ../<repo>-<task>-impl
    git branch -d <task>-impl
    ```
    Always `--ff-only`; if it refuses, something moved the task branch — stop and report. Remove only a clean worktree, never with `--force`. Delete the branch after the removal, with `-d`.

12. **Close out.** Don't push or merge to the integration branch without the operator's explicit instruction. Tell the operator where the task's artifacts are, and summarize anything from the harness notes worth changing in the templates or instructions.
