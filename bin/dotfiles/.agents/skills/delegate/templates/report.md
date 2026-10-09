## Rules for this run

- The design and this step are approved by the operator and the designer.
  This is a non-interactive run: do not stop to ask for confirmation, and do
  not ask questions. For reversible design choices the brief leaves open,
  make a reasonable choice and record it under "Decisions" below.
- Implement only this step. Do not start later steps or make unrelated changes.
- Evidence discipline: For consequential claims (those affecting correctness,
  completion, or subsequent implementation), distinguish observed facts,
  inferences, and unknowns. Cite inspected paths/symbols or actual command
  evidence; never invent outputs, log paths, or API behavior. Verify CLI and
  API claims against installed help (`--help`), source code, or
  version-appropriate official documentation when needed; unavailable evidence
  remains unknown. Ordinary descriptive prose does not need exhaustive citations.
- Preserve autonomy without guessing: Reversible design choices may be made
  with reasons (record under "Decisions"), but unknown facts cannot be filled
  by guessing. If a critical unknown blocks correctness, report affected work
  as incomplete under "Not done / open questions" and continue independent work.
- Resumed conversations: In resumed runs, previous turns and prior model
  statements are fallible background context, not proof. The latest brief
  defines scope, and current code and actual command evidence settle facts.
- Verify your own work. Run the brief's verification commands, plus any
  obvious checks for what you changed (syntax checks, linters, the relevant
  tests), with your terminal tool. Fix what fails and run them again until
  they pass, or until you can explain why they can't pass.
  - Record command, working directory (`cwd`), actual terminal exit status (or
    `unknown`), result/evidence reference, scope (`static`, `mock`,
    `integration`, or `live`), and tested attempt/checkpoint when known.
  - Status `passed` requires observed completion and a successful result. Distinguish `passed`,
    `failed`, `blocked`, `not run`, and `running`; never guess exit codes or
    fabricate checkpoint identifiers.
  - Keep logs bounded and secret-free; evidence may reference actual tool
    outputs without inventing files. Mock success is not live verification;
    after relevant code changes, rerun affected checks.
- Commands run in a sandbox: there is no network access, `.git` is
  read-only, and `git commit` is denied. Don't try to work around a blocked
  command. Record it under "Verification" as blocked and carry on.
- Don't commit, stage, or branch. The designer reviews and commits.
- Report discoveries and corrections below; do not edit the shared context.md.
  The designer verifies and merges findings before the next handoff.

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

## Context discoveries / corrections
- <New codebase facts, corrections to shared context, or investigated paths with evidence (paths/symbols, command output), or "None".>

## Not done / open questions
- <Anything left incomplete or needing the designer's judgment, or "None".>

## Acceptance criteria results
- <Criterion from brief>: <met | unmet | pending> — <result/evidence reference, tested scope, or pending reason>

## Verification
- `<command>` (cwd: `<dir>`, scope: <static|mock|integration|live>): <passed | failed | blocked | not run | running> — exit <code|unknown>; <one-line result/evidence reference, tested attempt/checkpoint if known>

## Not verified
- <What you could not check yourself (needs network, a device, a human; assigned to designer), or "None".>

## Remote compute (when compute.json was used)
- Backend: <coder | colab>
- Target / session: <workspace or notebook/session>
- Job ID: <remote job ID>
- Input / data hashes: <hashes of staged inputs and dataset references>
- Runtime facts: <GPU model, driver/CUDA version, host facts>
- Attempts: <number of execution attempts>
- Exit status: <remote command exit code or status>
- Artifacts: <collected artifacts in attempt-specific artifacts/ directory (for Colab: bounded text/JSON outputs saved locally; large/binary artifacts uploaded to external destination or reported not collected; no base64 inlining)>
- Release outcome: <released | preserved with reason>
```
