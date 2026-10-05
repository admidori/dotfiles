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

- **Authorization:** <authorized or deferred; operator instruction and scope>
- **Boundaries:** <one focused commit per step; any explicitly approved grouping>
- **Base:** <exact starting commit SHA>
- **If deferred:** <checkpoint/delta locations, content manifest, and how each
  reviewed step will be reconstructed as a separate commit when authorized>
- **Later corrections:** <how corrections to earlier steps will be recorded
  and kept separate when independent>
