## Rules for this run

- The design and this step are approved by the operator and the designer.
  This is a non-interactive run: do not stop to ask for confirmation, and do
  not ask questions. Where the brief is ambiguous, make the most reasonable
  choice and record it under "Decisions" below.
- Implement only this step. Do not start later steps or make unrelated changes.
- Edit files only. Do not commit, stage, branch, or run other git commands
  that change state. The designer verifies, reviews, and commits.

## Your final response is the implementation report

End the run with a final response in exactly this Markdown structure. It is
saved verbatim as the step's report and is the designer's primary record of
what you did and why, so write it for a reader who sees only this report and
the diff.

```
# Report: Step <NN>

## Summary
<One or two sentences: what now works that didn't before.>

## Changes
- `<path>`: <what changed> — <why>

## Decisions
- <A choice the brief did not dictate>: <what you chose> — <why>

## Deviations from the brief
- <Anything done differently from the brief, or "None".>

## Assumptions
- <Facts you relied on but could not confirm, or "None".>

## Not done / open questions
- <Anything left incomplete or needing the designer's judgment, or "None".>

## Suggested verification
- <Commands or checks the reviewer should run.>
```
