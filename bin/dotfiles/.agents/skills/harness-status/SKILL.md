---
name: harness-status
description: Inspect the current progress of an Antigravity implementation recorded by the delegate harness. Use for status, blockers, verification gaps, or completion questions about a delegated task; do not use to run or resume delegation.
---

# Harness status

Report what the `delegate` harness has established about a task. This is a
read-only inspection: do not run `agy`, edit artifacts, rerun verification,
commit, or change a worktree as part of a status check.

## Locate the task

Artifacts live at `${AGENT_HARNESS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-harness}/<repo>/<task>/`.
Use a task path or repo/task name supplied by the operator. Otherwise, look
for task directories containing `design.md` and identify the relevant task
from the current repo and the operator's request. If multiple tasks still
fit, ask which one they mean. Never infer that the newest directory is the
intended task.

Read `design.md` for the planned steps, then inspect each corresponding
`steps/<NN>-<slug>/` directory. The evidence for an attempt is its
`prompt-<n>.md`, `run-<n>.jsonl`, `stderr-<n>.log`, `report-<n>.md`, and
`review-<n>.md`, plus the matching `step` and `attempt` row in
`metrics.jsonl`. Attempts are numbered; use the latest attempt for the
current state while retaining earlier attempts as history. Read only the
relevant parts of large logs. Do not reproduce prompts or logs wholesale.

## Determine the state

The runner appends a metrics row only after `agy` exits. A prompt or run log
without a matching row means **result unknown**; file recency alone does not
prove the process is still running. A `status: SUCCESS` row and a nonempty
report mean Antigravity returned an implementation report, not that the step
was reviewed or completed.

For each planned step, distinguish these milestones:

| Evidence | State to report |
| --- | --- |
| No brief | Planned |
| Brief, no attempt | Ready to run |
| Attempt files, no matching metrics row | Result unknown |
| Non-success exit/status or empty report | Run failed or incomplete |
| Successful run and report, no review for that attempt | Awaiting designer review |
| Latest review says `rework` or `reject` | Rework requested or rejected |
| Latest review says `accept`, no recorded commit | Accepted, awaiting commit |
| Latest review says `accept`, with a verifiable commit | Committed |

Match reviews to their `attempt` frontmatter. An earlier acceptance does not
complete a later attempt. Verify a recorded commit with a read-only Git
query when the repository is available; if it cannot be verified, report
that uncertainty instead of calling the step committed. If the design and
artifact directories disagree about the step list, report the discrepancy.

Check `denied_tool_calls` against the corresponding `ERROR` events in the
run log before describing a call as permission-denied: older runner versions
could count unrelated errors that merely mentioned permissions. Also inspect
the report's `Verification` and `Not verified` sections and the designer
review's `Verification` and `Findings`. Show blocked or unverified checks
separately from the implementation state.
Treat the implementer's verification as a claim until the designer review
confirms it. A successful run can still have denied tool calls or pending
checks. Do not describe the task as complete until every planned step has
an accepted review and verified commit.

## Respond

Give a short task summary, a step-by-step status with links or paths to the
supporting artifacts, the latest meaningful timestamp, and the next action
or blocker. State clearly whether a conclusion comes from metrics, the
implementer's report, the designer's review, or Git. If artifacts are
missing or contradictory, name the gap and avoid guessing.
