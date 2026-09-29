## Rules for this run

- The design and this step are approved by the operator and the designer.
  This is a non-interactive run: do not stop to ask for confirmation, and do
  not ask questions. Where the brief is ambiguous, make the most reasonable
  choice and record it under "Decisions" below.
- Implement only this step. Do not start later steps or make unrelated changes.
- Verify your own work. Run the brief's verification commands, plus any
  obvious checks for what you changed (syntax checks, linters, the relevant
  tests), with your terminal tool. Fix what fails and run them again until
  they pass, or until you can explain why they can't pass.
- Commands run in a sandbox: there is no network access, `.git` is
  read-only, and `git commit` is denied. Don't try to work around a blocked
  command. Record it under "Verification" as blocked and carry on.
- Don't commit, stage, or branch. The designer reviews and commits.

## Your final response is the implementation report

End the run with a final response in exactly this Markdown structure. It is
saved verbatim as the step's report and is the designer's primary record of
what you did and why, so write it for a reader who sees only this report and
the diff. Write it as plain Markdown, not wrapped in a code block.

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

## Verification
- `<command>`: <passed | failed | blocked> — <exit code and a one-line result>

## Not verified
- <What you could not check yourself (needs network, a device, a human), or "None".>
```
