---
step: <NN>
attempt: <n>
verdict: <accept|rework|reject>
commit: <sha, once committed>
---

# Review: Step <NN>

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

## Harness notes

<What in the brief, the templates, or the instructions caused a problem or
helped. This section is the input for improving the harness itself.>
