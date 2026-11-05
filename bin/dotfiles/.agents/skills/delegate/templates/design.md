---
task: <task-slug>
repo: <repo>
designer: <Claude|Codex> (<model>)
variant: <HARNESS_VARIANT>
date: <YYYY-MM-DD>
---

# <Task title>

## Goal

<The problem being solved and the observable outcome that means "done".>

## Context

<What exists today that the change builds on: relevant files, current
behavior, prior decisions. Enough that a reader with no chat history can
follow the rest.>

## Constraints

- <Hard requirements: compatibility, conventions, things that must not change.>

## Decisions

<One entry per non-obvious choice. The reason matters more than the choice:
it is what lets the implementer resolve cases this document didn't foresee.>

### <Decision>

- **Chosen:** <what>
- **Why:** <reason>
- **Rejected:** <alternative> — <why not>

## Risks

- <What could go wrong, and how the review will catch it.>

## Steps

<Ordered by dependency. Each step is one committable behavior change that
leaves the tree working.>

| Step | Title (commit header) | Files | Acceptance | Verify |
|---|---|---|---|---|
| 01 | <type(scope): description> | <paths> | <observable criteria> | <commands> |

## Commit plan

- **Architecture:** <one task = one Docker Sandbox = one accepted submission commit; a PR may contain multiple task commits>
- **Authorization:** <standing local authorization after review (Host / strict Docker), task checkpoint commits (HARNESS_GIT_POLICY=task-commits in Docker Sandbox mode), or explicit deferral>
- **Boundaries:** <one focused checkpoint commit per step during implementation; squashed to one accepted task submission commit upon completion>
- **Base:** <exact starting commit SHA>
- **Submission plan:** <task submission commit prepared via sandbox/submit.py prepare, committed with all contributor trailers, and accepted via sandbox/submit.py accept>
- **If deferred:** <recorded exception reason, checkpoint/delta locations, content manifest, and how work will be finalized when deferral ends (for Docker Sandbox tasks, recording a reviewed checkpoint if needed and squashing to the single accepted task submission commit in the same clone; for legacy host/strict mode, reconstructing separate step commits in a dedicated worktree)>
- **Later corrections:** <how corrections to earlier steps will be recorded
  and kept separate when independent>
