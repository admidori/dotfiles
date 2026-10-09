# Step <NN>: <title>

## Task

<The single change to make, stated concretely.>

## Context

<The part of the design this step depends on, including the reasons behind
the relevant decisions. Each new step starts a fresh Antigravity session
(while rework within the same step may explicitly resume via --resume-attempt),
so say what earlier steps changed and why, and whether they are committed or
preserved as reviewed checkpoints. Point to shared knowledge in context.md
without copying it all into this brief; keep the specific scope boundary
and acceptance criteria focused here. For resumed runs, this brief defines
current scope; current code and logs settle facts, and prior model statements
are not proof.>

## Scope

- **In:** <what this step covers>
- **Out:** <later steps and anything else that must not be touched>

## Acceptance criteria

<Map each observable condition to required evidence and scope (static, mock,
integration, or live). Explicitly assign unavailable live checks to the
designer. Do not make live tests mandatory for all tasks; only require them
where relevant; keep required but unavailable checks pending.>

- <Observable condition>: required evidence: <inspected paths/symbols, command output, or assertion>; scope: <static | mock | integration | live> (if live check is unavailable in sandbox, note: assigned to designer)

## Verification

<Commands you must run and get passing before you finish. They run
sandboxed, so they can't use the network. Specify command, working directory (if
different from worktree), expected exit status, and evidence scope (static/mock/integration).>

- `<command>` (scope: <static|mock|integration>, expected: exit 0)

## Constraints

- Follow the surrounding code's style, naming, and idiom.
- <Step-specific constraints.>
