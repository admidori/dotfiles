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
- **Reviewed against:** <preceding commit SHA or accepted checkpoint>
- **Accepted checkpoint (if deferred):** <path, base/predecessor, content manifest>
- **Planned commit scope:** <this step's behavior; separately recorded corrections>
- **Implementer attribution:** <actual trailer from this step's metrics>
- **Commit (when authorized):** <SHA corresponding to this step>

## Verification

<Re-run by the designer. Note any result that differs from the one in the
report, and anything the report lists as blocked or not verified.>

- `<command>`: <result> (report said: <result>)

## Findings

- <Defect or concern in the diff, with file:line.>

## Polished by the designer

- <Small fixes made directly before committing, or "None".>

## Report accuracy

<Does the report match the diff? Note anything changed but unreported, or
reported but not actually done.>

## Shared context updates

- **Promoted:** <facts, rejected paths, or constraints promoted from report to context.md, or "None">
- **Rejected:** <implementer claims rejected or not merged into context.md, with reason, or "None">

## Compute audit (when compute.json was used)

- <Verify remote resources were cleanly released, or preserved with valid reason.>
- <Confirm remote edits were not kept as source of truth; all fixes landed in the local diff.>
- <Verify neither state.json nor events.jsonl contains credentials, tokens, dataset contents, or other secrets.>
- <Verify job ID, input/data hashes, runtime facts, and collected artifacts match the manifest.>
- <Verify artifacts are collected into attempt-specific artifacts/ directory (not into source worktree; for Colab, confirm bounded text/JSON cell output or external upload, no base64 inlining or unpromised binary downloads).>

## Harness notes

<What in the brief, the templates, or the instructions caused a problem or
helped. This section is the input for improving the harness itself.>
