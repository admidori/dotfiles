---
step: <NN>
attempt: <n>
verdict: <accept|rework|reject>
commit: <sha or deferred>
---

# Review: Step <NN>

## Step boundary and commit status

- **Commit authorization:** <current permission and scope>
- **Mode:** <fresh | resume (source attempt <n>)>
- **Conversation ID:** <conversation ID from metrics>
- **Status:** <execution finished | verified | accepted | awaiting commit>
- **Reviewed against:** <preceding commit SHA or accepted checkpoint>
- **Accepted checkpoint (if deferred):** <path, base/predecessor, content manifest>
- **Planned commit scope:** <this step's behavior; separately recorded corrections>
- **Implementer attribution:** <actual trailer from this step's metrics>
- **Commit (when authorized):** <SHA corresponding to this step>

## Acceptance criteria review

<Check each criterion from the brief against observed evidence and actual
assertions/triggers. Note met, unmet, or pending criteria.>

- <Criterion from brief>: <met | unmet | pending> — <evidence reference, assertion/trigger checked, or pending reason>

## Verification

<Re-run by the designer. Check claims against evidence and actual
assertions/triggers; distinguish independent designer reruns from
implementer-only reports. Process SUCCESS from the runner indicates execution
finished, not verification or acceptance. Note any result that differs from the
report, and run anything the report lists as blocked or not verified (including
designer-assigned live checks). If unavailable to the designer too, record
why and leave the affected criteria pending; assignment is not authorization
to bypass permissions.>

- `<command>` (cwd: `<dir>`, scope: <static|mock|integration|live>): <result> — exit <code|unknown>; <one-line evidence, tested attempt/checkpoint if known> (report said: <result>)

## Findings

- <Defect or concern in the diff, with file:line.>

## Polished by the designer

- <Small fixes made directly before committing, or "None".>

## Report accuracy and evidence discipline

<Check report claims against diff and actual command evidence. Note anything
changed but unreported, reported but not done, corrected or retracted claims,
ungrounded claims (invented outputs, log paths, or APIs), and remaining gaps.>

## Shared context updates

<Designer verifies facts before promoting to context.md. Distinguish active
hypotheses from reviewed facts; keep entries compact and carry corrections
explicitly into future handoffs and resume prompts.>

- **Promoted:** <facts with paths/symbols, evidence scope/freshness, or rejected paths promoted from report to context.md, or "None">
- **Rejected / Retracted:** <implementer claims rejected, unverified, or retracted, with reason; carry corrections explicitly into next handoff/resume, or "None">

## Compute audit (when compute.json was used)

- <Verify remote resources were cleanly released, or preserved with valid reason.>
- <Confirm remote edits were not kept as source of truth; all fixes landed in the local diff.>
- <Verify neither state.json nor events.jsonl contains credentials, tokens, dataset contents, or other secrets.>
- <Verify job ID, input/data hashes, runtime facts, and collected artifacts match the manifest.>
- <Verify artifacts are collected into attempt-specific artifacts/ directory (not into source worktree; for Colab, confirm bounded text/JSON cell output or external upload, no base64 inlining or unpromised binary downloads).>

## Harness notes

<What in the brief, the templates, or the instructions caused a problem or
helped. This section is the input for improving the harness itself.>
