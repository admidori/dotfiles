# Shared Exploration Context: <task-title>

## Freshness

- **Base commit:** <starting commit SHA>
- **Reviewed checkpoint:** <latest reviewed step/checkpoint for uncommitted changes, or "initial exploration">
- **Last updated:** <YYYY-MM-DD>

## Compact navigation

<Key files, entry points, and module layout. Keep brief; avoid copying whole file trees.>

- `<path>`: <role in codebase, entry points, key interfaces>

## Established facts and architecture

<Concrete codebase facts verified by exploration or accepted implementation steps.
Include paths/symbols and reasons. Keep raw secrets, tokens, and verbose log dumps out.>

- `<path#symbol>`: <concrete fact, structure, or behavior> — <reason / evidence>

## Rejected paths

<Approaches investigated and rejected, including useful findings from failed attempts or rework.
Explain why each was rejected so later steps do not re-explore them.>

- <Approach investigated and rejected>: <why it was rejected or failed>

## Verification constraints

<Tooling, sandbox boundaries, environment quirks, offline constraints, or test suite limits.>

- <Constraint>: <details and workaround/implication>

## Uncertainties and hypotheses

<Open questions, unconfirmed assumptions, or hypotheses under active investigation.
Always distinguish hypotheses from verified facts.>

- <Hypothesis/uncertainty>: <what is assumed or being checked>
