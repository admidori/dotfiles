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
Include paths/symbols, reasons, and evidence scope (static, mock, integration, or live).
Designer verifies facts before promoting. Keep raw secrets, tokens, and verbose log dumps out.
For resumed conversations, the latest brief defines scope, current code and actual logs settle
facts, and previous model statements are not proof.>

- `<path#symbol>` (scope: <static|mock|integration|live>): <concrete fact, structure, or behavior> — <reason / evidence and applicable attempt/checkpoint; flag stale evidence>

## Superseded or corrected claims

<Claims previously considered or stated by earlier attempts or models that were corrected
or retracted. Keep entries compact; record the correction with evidence, or explicitly retract the claim as
unverified when no replacement fact is established. Carry corrections explicitly into future handoffs and resume prompts
without dumping verbose history or raw logs.>

- <Superseded claim or assumption>: <correction with evidence, or retracted as unverified; applicable attempt/checkpoint>

## Rejected paths

<Approaches investigated and rejected, including useful findings from failed attempts or rework.
Explain why each was rejected so later steps do not re-explore them.>

- <Approach investigated and rejected>: <why it was rejected or failed>

## Verification constraints

<Tooling, sandbox boundaries, environment quirks, offline constraints, or test suite limits.>

- <Constraint>: <details and workaround/implication>

## Uncertainties and hypotheses

<Open questions, unconfirmed assumptions, or hypotheses under active investigation.
Always distinguish unknown hypotheses from reviewed facts.>

- <Hypothesis/uncertainty>: <what is assumed or being checked>
