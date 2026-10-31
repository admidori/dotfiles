---
name: delegate
description: Use when a design has been agreed with the operator and its implementation should be delegated to Antigravity — the designer (Claude or Codex) writes the design and one brief per step, Antigravity implements each step headlessly via `agy -p` and reports what it did, and the designer reviews, polishes, and commits each accepted step under standing authorization (or preserves checkpoints when deferred). Every hand-off is a file, so the harness can be inspected and improved. Triggers on "/delegate", "これで実装して", "Antigravityに実装させて", "実装を委譲して", "delegate this to antigravity". Not for changes the operator wants the designer to make directly.
---

Runs the delegation loop: agreed design → `design.md` → per step, `brief.md` → Antigravity implements, runs the verification itself, and returns a report → the designer re-checks, reviews, polishes, and commits under standing authorization (or records a reproducible checkpoint if deferred) → next step.

## Commit authorization and boundaries

The designer operates under standing authorization to make focused local commits for each accepted step. Once a step's review is complete, required fixes are done, and relevant re-verification passes, the designer commits that step before starting the next, without repeated requests for commit approval. Antigravity must never stage or commit:
- In **Host mode**, machine-local Antigravity sandbox restrictions and `"command(git commit)"` under `permissions.deny` enforce this mechanically.
- In **Docker Sandbox mode**, full workspace access is granted without inner terminal sandbox restrictions, so commit deny cannot be mechanically enforced by sandbox rules. Instead, role separation is strictly observed and monitored by the runner: the runner captures Git state (HEAD, branch, index) before and after each run and rejects acceptance (`status: GIT_STATE_MUTATED`, nonzero exit) if any Git state was modified. Standing local commit authority belongs solely to the designer and never permits pushing or creating a PR; outward-facing actions always require explicit operator approval.

If the operator explicitly requests commit deferral or stricter applicable constraints apply, record that exception in `design.md` and follow [Deferred commits](references/deferred-commits.md) to preserve each step without creating commits.

Deferring commits changes their timing; it does not combine the agreed steps. A later request to commit, push, or create a PR preserves the step boundaries unless the operator explicitly approves a different grouping. Before publishing, map each accepted step to its own focused commit and account for corrections separately, retaining full designer and implementer attribution. If that mapping cannot be reproduced safely, present the concrete problem and proposed grouping for approval before committing.

This skill is built around:

- **Every hand-off is written down.** The designer verbalizes the design (`design.md`, `brief.md`, `review.md`); the implementer verbalizes the implementation (`report-<n>.md`). Nothing passes through chat memory alone, so a later reader — human or agent — can see what was asked, what was done, and why.
- **The harness is an experiment.** The templates, this file, and the briefs are the variables; `metrics.jsonl` and the "Harness notes" in each review are the measurements. Label a harness change with `HARNESS_VARIANT` so runs before and after it can be compared.
- **Evidence discipline.** Consequential claims (affecting correctness, completion, or subsequent implementation) require concrete evidence: distinguish observed facts, inferences, and unknowns, cite inspected paths/symbols or actual command outputs, and never invent outputs, log paths, or API behavior. Reversible design choices may be made autonomously with reasons, but unknown facts cannot be filled by guessing. Documentation sets expectations and guides verification; it does not eliminate hallucinations or provide machine enforcement.

## Layout

Artifacts live outside any repository, so they survive worktree removal and never land in a project's history:

```
$AGENT_HARNESS_DIR (default: ${XDG_STATE_HOME:-~/.local/state}/agent-harness)
  <repo>/<task>/
    design.md                  designer: goal, context, constraints, decisions, steps
    context.md                 designer (+ implementer findings): shared exploration facts, boundaries, hypotheses
    steps/<NN>-<slug>/
      brief.md                 designer → implementer: one step
      compute.json             designer → runner: optional remote GPU compute manifest
      prompt-<n>.md            run-task.sh: the exact prompt sent
      run-<n>.jsonl            run-task.sh: agy event log
      report-<n>.md            implementer: what was done and why
      review-<n>.md            designer: verdict, findings, harness notes
      compute-<n>/             run-task.sh: attempt-specific compute audit & artifacts
        state.json             implementer: lifecycle state (no credentials)
        events.jsonl           implementer: remote execution/lifecycle events
        artifacts/             implementer: collected remote artifacts
    metrics.jsonl              run-task.sh: one row per run
```

In Docker Sandbox mode, harness state remains in the container-local state directory outside the repo (`$AGENT_HARNESS_DIR`) and must be exported before container destruction.

Templates are in `templates/` next to this file; the runner is `scripts/run-task.sh`.

## Prerequisite: execution modes and sandbox settings

The harness supports two execution modes via `HARNESS_EXECUTION_MODE=host|docker-sandbox` (default `host`):

- **Host mode (`HARNESS_EXECUTION_MODE=host`):** Commands run inside the machine-local Antigravity terminal sandbox configured in `~/.gemini/antigravity-cli/settings.json` (`"enableTerminalSandbox": true`, `"toolPermission": "proceed-in-sandbox"`, `"command(git commit)"` under `permissions.deny`, and denied credential files). Sandboxed commands receive no network access, `.git` is read-only, and writes are restricted. Runs execute from an empty scratch cwd to prevent workspace read-only restrictions. Never pass `--dangerously-skip-permissions` on the host: the sandbox is the boundary. If settings are missing, every command is denied.
- **Docker Sandbox mode (`HARNESS_EXECUTION_MODE=docker-sandbox`):** Commands execute inside a dedicated, externally isolated Docker Sandbox container. Settings disable inner terminal sandboxing (`{"enableTerminalSandbox": false}`), and the runner runs `agy` directly in `$workdir` with `--dangerously-skip-permissions`. Commands have unconfined internal access within the container, and outbound network access follows the external container network policy. Accidental host execution is prevented by requiring nonempty `SANDBOX_ID`, `SANDBOX_VM_ID`, `SBX_AGENT` and the root-owned non-symlink `/etc/agent-harness/docker-sandbox` marker shipped by the kit (the microVM rootfs has NO `/.dockerenv`). Full access is granted for tool execution, not commit authority: role separation is monitored by the runner's pre/post Git state check.

## Setup

1. **Confirm the design is final.** If it hasn't been agreed with the operator in this conversation, produce it first. Immediately before delegating, restate a short summary (approach, files, risks) and get an explicit go-ahead — an earlier open-ended discussion is not that confirmation. If a previous delegation on this branch is being substantially reworked, treat it as a sign the design wasn't final and re-confirm.

2. **Write `design.md` and seed `context.md`** in the task directory:
   - Write `design.md` from `templates/design.md`. Record the reason behind each non-obvious decision and the alternatives rejected: the implementer gets no chat history, and the reasons are what let it handle cases the design didn't foresee. Fill in the steps table:
     - One committable behavior change per step, ordered by dependency, each leaving the tree working.
     - Size each step to one `agy` run — about one concern and a handful of files.
     - Don't invent artificial splits; a genuinely atomic change is one step.
   - Seed `context.md` from `templates/context.md` with exploration knowledge: compact navigation (key files, entry points), established facts with paths/symbols, reasons, and evidence scope (static, mock, integration, live), superseded or corrected claims (compactly, avoiding raw history dumps), rejected paths, verification constraints, and uncertainties (clearly distinguishing hypotheses from verified facts). Set freshness (base commit SHA and initial checkpoint). Designer verifies findings before promoting them. Keep secrets, raw credentials, and verbose log dumps out.
   - Legacy tasks lacking `context.md` are supported: the runner preserves legacy runs with a visible notice, but the designer should seed `context.md` whenever exploration context exists.

   Show the operator the step list and get a go-ahead on the decomposition itself before the first run.

3. **Create an implementation worktree (Host mode) or use the private clone (Docker Sandbox mode):**
   - **Host mode (`HARNESS_EXECUTION_MODE=host`):** Create an implementation worktree branched from your task branch, reused for every step:
     ```
     git worktree add ../<repo>-<task>-impl -b <task>-impl HEAD
     ```
     `<task>-impl` stacks on the unmerged task branch only for the loop's duration; close-out fast-forwards it back and deletes it. If you're not in a task worktree, branch from the integration branch instead, passing the base explicitly when HEAD isn't it. Never target a directory with unrelated uncommitted changes.
   - **Docker Sandbox mode (`HARNESS_EXECUTION_MODE=docker-sandbox`):** Run sequential designer->agy->designer execution directly in the same task-private clone without creating an additional implementation worktree. The container itself provides isolation from the host. Target the clone directory directly. Keep all harness artifacts in Sandbox-local state outside the repository (`$AGENT_HARNESS_DIR`, default `~/.local/state/agent-harness`), and export them before deleting the container.

## Per-step loop

Repeat for each step in order, one step per run. Never batch steps.

4. **Write `steps/<NN>-<slug>/brief.md`** from `templates/brief.md`. Carry the part of the design this step depends on and what earlier steps already changed, including whether they are committed or held as checkpoints — each new step starts a fresh Antigravity session. Point to shared knowledge in `context.md` without copying it all; keep the specific scope boundary and acceptance criteria in `brief.md`. Map each acceptance criterion to required evidence and scope (`static`, `mock`, `integration`, or `live`), and explicitly assign unavailable live checks (e.g. requiring network or external environments) to the designer. Do not introduce a new mandatory live test for all tasks; require live checks where relevant, and keep required but unavailable checks pending. State the scope boundary explicitly, and list in "Verification" the commands that must pass with their cwd, scope, and expected status. In host mode, commands run sandboxed without network access; in Docker Sandbox mode, commands follow the external container network policy. For resumed runs, the latest brief defines scope; current code and actual logs settle facts, and previous model statements from earlier turns are not proof. The run rules (no confirmation stops, evidence discipline, verify your own work, no commits) and the report format are appended by the runner from `templates/report.md`, so don't repeat them.

   - **Remote GPU compute (optional):** If this step requires ephemeral GPU resources, place a validated `compute.json` in the step directory (see `templates/compute.json` and `templates/compute-colab.json`).
     - Backends: `coder` (file/tar staging, remote commands, logs) or `colab` (official Google `colab-mcp`, notebook cell injection, stable dataset URIs).
     - Lifecycle: probe -> acquire -> stage -> execute -> observe -> diagnose -> collect -> release.
     - Staging rule: remote edits are disposable. Fixes must always be made locally in the implementation worktree and restaged. Colab scripts must be injected only from the manifest; datasets use declared URIs with scheme (`^[A-Za-z][A-Za-z0-9+.-]*://`) and a 64-hexadecimal-character SHA-256 (WARNING: In `templates/compute-colab.json`, `0000000000000000000000000000000000000000000000000000000000000000` is an unmistakable placeholder; users must replace it with the actual dataset SHA-256 before running). Never claim directory sync for Colab.
     - Colab artifact semantics: Official `googlecolab/colab-mcp` exposes notebook cells and outputs, not a general binary download or directory-sync API. Bounded text/JSON results may be emitted as cell output and collected locally into `compute-<n>/artifacts/`. Large or binary artifacts must be uploaded by notebook code to an operator-declared external destination or reported as not collected; never base64-inline them into prompts or cell output, and never promise arbitrary Colab artifact downloads to the local harness.
     - Interrupted-run recovery: the runner creates an attempt-specific directory (`compute-<n>/`) containing `state.json`, `events.jsonl`, and `artifacts/`. The agent updates `state.json` on every transition. Before acquiring new resources, recover unresolved earlier attempts using their recorded backend, target, job ID, and event log, even if the manifest changed or was removed. The runner includes those states in the next prompt and rejects success while any remain unresolved. Record `release_outcome` as `released`, or `preserved` with a nonempty `release_reason` if release is unavailable. Neither `state.json` nor `events.jsonl` may contain credentials, tokens, dataset contents, or other secrets (state records backend, target/session, job ID, phase, attempt count, release outcome).
     - Artifact collection: remote artifacts are collected into `compute-<n>/artifacts/`, not into the source worktree unless explicitly promoted by a later reviewed step.
     - Bounded execution: `timeout_seconds` (1-86400) and `max_attempts` (1-10) are positive integers; path traversal (`..`) and absolute paths are rejected before `agy` runs.
     - Ephemeral cleanup: remote resources must be released cleanly on completion or failure (or recorded as `preserved` with reason if unreleaseable).

5. **Run the step:**
   ```
   HARNESS_DESIGNER="<you> (<model>)" [HARNESS_EXECUTION_MODE=host|docker-sandbox] <skill-dir>/scripts/run-task.sh <step-dir> <workdir> [brief] [--resume-attempt <N>]
   ```
   - **Execution modes (`HARNESS_EXECUTION_MODE=host|docker-sandbox`, default `host`):**
     - Invalid values fail immediately with exit 2 before invoking `agy` or acquiring step locks.
     - **Host mode:** Antigravity runs with `--mode accept-edits` from an isolated scratch working directory to prevent workspace read-only restrictions. Never pass `--dangerously-skip-permissions`: local terminal sandbox settings (`enableTerminalSandbox: true`, `toolPermission: proceed-in-sandbox`) provide the boundary. Outbound network is blocked by the inner sandbox.
     - **Docker Sandbox mode:** Antigravity runs directly from `$workdir` with guarded full access: `--dangerously-skip-permissions --settings '{"enableTerminalSandbox":false}'`. These same flags apply consistently to both the model probe and the implementation run (preserving `-p /model` ordering). Outbound network access adheres to the external container network policy.
     - **Accidental-host guard (Docker Sandbox mode):** Requires nonempty `SANDBOX_ID`, `SANDBOX_VM_ID`, and `SBX_AGENT` environment variables plus the root-owned, non-symlink `/etc/agent-harness/docker-sandbox` marker shipped by the kit. The microVM rootfs has NO `/.dockerenv`; do not require or create it. This guard prevents accidental execution on the host; it is role-coordination and accidental-host prevention, not a security boundary against hostile processes.
     - **Owned scratch vs workdir safety:** In both modes, temporary runner scratch directories are tracked separately (`owned_scratch_dir`). Normal completion, timeout, interruption, and errors must never remove the project workdir.
   - **Workdir locking:**
     - In addition to the step-level file lock (`<step-dir>/.lock`, fd 9), the runner acquires a nonblocking advisory flock on the workdir repository (`git rev-parse --git-path harness.lock`, fd 8, falling back to `$AGENT_HARNESS_DIR/<repo>/workdir.lock`).
     - Two distinct steps targeting the same workdir cannot run concurrently (exits 1 on contention). Separate worktrees targeting the same repository maintain independent locks without colliding. In Docker mode full access can defeat advisory locks; this prevents accidental designer/runner concurrency, not hostile bypass.
   - **Role separation & Git state mutation detection:**
     - The implementer (Antigravity) must never push, stage, or commit (`git commit`, `git add`, branch creation, or checkout). In full-access Docker mode this cannot be mechanically prevented by sandbox rules.
     - The runner captures `HEAD`, symbolic branch name, and index stage contents before the model probe and implementation run.
     - If any Git state changed after `agy` completes (on either `SUCCESS` or error exit), the runner overrides status to `GIT_STATE_MUTATED`, records `git_state_changed: true` in `metrics.jsonl`, prints an error notice, and exits with code 1. Git mutations are preserved for designer inspection (never silently undone).
   - **Model resolution and probe:**
     - The runner defaults to `gemini-3.8-flash-high` when `AGY_MODEL` is unset or empty; the run stops (exit 2) if the model cannot be resolved. Set `AGY_MODEL` to override the model and `AGY_EFFORT` to override reasoning effort. The model probe and implementation receive the same arguments and execution mode flags.
   - Under Codex on the host, `agy` needs network access and writes outside the workspace, so request sandbox escalation for this command rather than widening the sandbox.
   - **Timeout and process management:**
     - It blocks until Antigravity finishes (default limit 30m, `AGY_TIMEOUT`). `AGY_TIMEOUT` format: `40m`, `1h30m`, `90s`, or a bare number of minutes; invalid values exit 2 before anything runs.
     - agy runs in its own process group; after its `result` event the runner waits `AGY_RESULT_GRACE_SECONDS` (30) and then terminates it (`terminated_after_result` in metrics, run still counts as its result's status); without a result by `AGY_TIMEOUT` + `AGY_TIMEOUT_MARGIN_SECONDS` (300) it is terminated with status `TIMEOUT` (exit 124); stopping the runner (INT/TERM) also stops agy.
   - **Exit codes and report validation:**
     - A non-zero exit means the run did not end with `SUCCESS`, Git state was mutated, or it ended without a substantive report.
     - Whitespace-only or missing reports fail with exit 1 and record `report_empty: true` in metrics.
     - Read `stderr-<n>.log` and the tail of `run-<n>.jsonl`. Report a permission or authentication failure to the operator as a blocked step instead of retrying around it.
   - In host mode, the runner prints how many tool calls were denied and records the count in the metrics. Denied calls are commands that couldn't run sandboxed. If there are any, the report's verification may be incomplete.
   - The runner embeds the literal content of `context.md` into `prompt-<n>.md` with a clear heading, source path, and instructions to treat it as reviewed evidence rather than scope authorization (the brief defines this step and source code wins when facts are stale). File contents are never executed or expanded. Missing context preserves legacy runs with a visible notice; an existing unreadable context halts execution before `agy` runs. Previous prompt snapshots remain unchanged.
   - **Conversation lifecycle & reuse:**
     - By default, running without `--resume-attempt` starts a **fresh conversation** (fresh Antigravity session). Plain execution also acts as an explicit fresh reset after earlier resumes.
     - Same-step rework may explicitly continue the conversation of a prior attempt using `--resume-attempt <N>` (where `N` is an integer between 1 and 1,000,000). The global-latest selection flag `--continue` is not supported by the runner.
     - On resume, the runner passes `--conversation <conversation_id>` to `agy`, re-sends the latest full prompt (project directory, exploration context, brief, rules, report format) with a clear precedence section, and records `mode: "resume"` and `source_attempt: N`. The prior conversation history serves only as background context; the current brief and rules take precedence over prior turns. Previous model statements are not proof; current code and actual command evidence settle facts. Each saved prompt snapshot (`prompt-<n>.md`) captures the incremental prompt given to that attempt and relies on the parent-attempt chain for complete conversation context.
     - **Prerequisites and strict validation:** Resume requires that source attempt `N` is within the same step, has a unique terminal metrics record (`SUCCESS`, `ERROR`, `CANCELED`, `INTERRUPTED`, or `INVALID`), canonical `step_dir` and `workdir` matching the current invocation (resolved via `pwd -P`), a valid matching conversation ID in both `metrics.jsonl` and the terminal `result` event in `run-<N>.jsonl`, and is the latest recorded attempt for that conversation.
     - **No silent fallback:** If resume prerequisites are not met (e.g. unknown attempt, ambiguous history, missing conversation ID, incomplete or non-terminal source run, `CONVERSATION_MISMATCH`, workdir or step_dir mismatch, legacy run lacking recorded workdir, or source is not the latest attempt for its conversation), the runner fails immediately with exit code 2. It never silently falls back to a fresh session.
     - **Incomplete runs and lock contention:** Resuming is blocked if newer incomplete attempts exist for the same conversation. A nonblocking file lock (`.lock` in `<step-dir>`, held on file descriptor 9; missing `flock` utility fails immediately) prevents concurrent executions within the same step. Do not remove live lock files or alter sandbox permissions to bypass lock contention. If a run was interrupted, wait for the background process to exit or inspect its state.
     - **Metrics and counter scopes:** In `metrics.jsonl`, provider counters (`duration_seconds`, `num_turns`, `usage`) reported by `agy` in stream-json are cumulative over the whole conversation and are explicitly labeled with `counter_scope: "conversation"`. The runner independently measures per-process wall-clock duration in `wall_duration_seconds` (excluding model probe time). Traceability fields recorded include `step_dir`, `workdir`, `execution_mode`, `mode` (`fresh` or `resume`), `source_attempt`, `requested_conversation_id`, `git_state_changed`, and `report_empty`.

6. **Check against the diff, not the report.** Run `git -C <impl-worktree> status` / `diff`. If earlier steps are committed, the working-tree diff is exactly this step. If commits are deferred, compare the current tree against the preceding accepted checkpoint; the cumulative diff from HEAD is not this step's diff. Then re-run the brief's verification commands yourself and compare the results with the report's "Verification" section. Antigravity running them first saves rework rounds, but its report is a claim, not proof. Runner exit `SUCCESS` means only that execution finished; it is not verification or review acceptance. Distinguish four lifecycle states: execution finished, verified, accepted, and awaiting commit. Check claims against evidence, inspected paths/symbols, and actual assertions/triggers, distinguishing independent designer reruns from implementer-only reports. Mock success is not live verification; after relevant code changes, rerun affected checks. Checks the report lists as blocked or not verified (anything needing the network or assigned to the designer, for example) are yours to run. Changes outside the step's scope are dropped or preserved for a separate focused commit; say which.

7. **Review and write `review-<n>.md`** from `templates/review.md`. Correctness first, then reuse and simplification. Compare the report with the diff and check claims against inspected paths/symbols, actual assertions/triggers, and test evidence; note anything changed but unreported, reported but not done, or ungrounded claims (invented outputs, log paths, or APIs). Note corrected or retracted claims and identify remaining gaps. Apply evidence discipline to designer reporting as well (distinguish observed facts, inferences, and unknowns). Check the report's "Context discoveries / corrections" against diff evidence and record in the review what was promoted to `context.md` or rejected (with reasons). When compute was used, complete the "Compute audit" section: confirm remote resources were released cleanly (or preserved with reason), verify that no remote edits bypassed the local diff review, confirm neither state.json nor events.jsonl contains credentials, tokens, dataset contents, or other secrets, verify that collected artifacts are in the attempt-specific harness directory (confirming truthful Colab artifact handling with no base64 inlining), and check that job ID, input/data hashes, runtime facts, and collected artifacts match expectations. Fill in "Harness notes": what in the brief, templates, or instructions caused a problem or helped.

   Before the next handoff, update `context.md`:
   - Merge verified implementer findings with paths/symbols, reasons, and evidence scope (`static`, `mock`, `integration`, `live`).
   - Compact superseded or corrected claims, noting corrections without dumping verbose logs or raw history.
   - Include useful findings and rejected paths from failed attempts or rework rounds so future runs do not re-explore them.
   - Remove or correct obsolete entries as the codebase evolves.
   - Clearly distinguish active hypotheses from verified facts.
   - Update freshness (base commit SHA and latest reviewed step/checkpoint).
   - Keep secrets, tokens, and verbose log dumps out.

8. **Rework if needed.** Polish trivial issues yourself and list them in the review. For anything substantive:
   - Decide whether the rework should start fresh or reuse conversation context. If the model had good context on the problem and only needs a correction, use `--resume-attempt <N>` with the latest attempt number. If the model was confused or polluted its context, start a fresh attempt by omitting `--resume-attempt`.
   - Write a rework brief in the step directory describing the defect and pointing at the uncommitted attempt in the tree, carry corrected or retracted claims explicitly into the rework brief so the model does not repeat superseded assumptions, update `context.md` if the previous attempt revealed new constraints or rejected paths, and run the runner again:
     ```
     HARNESS_DESIGNER="<you> (<model>)" <skill-dir>/scripts/run-task.sh <step-dir> <impl-worktree> <rework-brief> [--resume-attempt <N>]
     ```
   - The attempt counter advances, keeping earlier artifacts intact. Bound rework at two rounds, then bring it to the operator. If the review shows the step's premise was wrong, stop (step 10).

9. **Commit or checkpoint this reviewed step.** Under standing authorization, once this step's review is complete, required fixes are done, and relevant re-verification passes, commit in the implementation worktree (Host mode) or the task-private clone (Docker Sandbox mode) before proceeding, without asking for commit approval. The commit covers only this step, with a Conventional Commits message whose body draws on the design's reasoning, and both trailers:
   ```
   Co-authored-by: <you> (<model>) <noreply@...>
   Co-authored-by: Antigravity (<model>) <noreply@google.com>
   ```
   Both trailers are mandatory on every delegated step, including a step you only reviewed or polished. Take Antigravity's trailer verbatim from the runner's `trailer for the commit:` line, or from the run's `trailer` field in `metrics.jsonl`. Take your own model from your actual configuration, never from memory; for Codex that is the `model` key in `~/.codex/config.toml`. If your harness already appends your own trailer, don't duplicate it — check `git log -1`. Record the commit SHA in the review, confirm `git status` is clean, report the commit to the operator in a line or two, and continue. Don't push or merge mid-loop; standing local commit authority never authorizes pushing or creating a PR.

   If commits are explicitly deferred by the operator or blocked by stricter constraints, save the accepted checkpoint and record its base, predecessor, verification results, and deferred commit status in the review before proceeding.

## Stopping and closing out

10. **Stop if a review invalidates the remaining plan.** When the design or decomposition was wrong rather than the implementation sloppy, pause, report what the committed steps established, update `design.md`, and re-confirm the remaining steps with the operator.

11. **Close out worktrees or export artifacts:**
    - **Host mode:** Fast-forward and remove the implementation worktree as soon as the last step is committed. From your task worktree:
      ```
      git merge --ff-only <task>-impl
      git worktree remove ../<repo>-<task>-impl
      git branch -d <task>-impl
      ```
      Always `--ff-only`; if it refuses, something moved the task branch — stop and report. Remove only a clean worktree, never with `--force`. Delete the branch after the removal, with `-d`.
    - **Docker Sandbox mode:** No separate implementation worktree is created, so there is no worktree merge or removal step. Commits exist directly on the task branch in the private clone. Export commits and harness artifacts before destroying the container:
      ```
      git bundle create /tmp/<repo>-<task>.bundle HEAD
      # From host:
      sbx cp <sandbox-id>:/tmp/<repo>-<task>.bundle ./
      sbx cp <sandbox-id>:/home/agent/.local/state/agent-harness/<repo>/<task> ./harness-export/
      ```
      Never leave unexported commits or harness artifacts in a transient container.

   If commits remain deferred, retain the implementation worktree and checkpoints, and report why they remain open. Once constraints are resolved or explicit commit permission arrives, materialize and verify the separate commits using the deferred workflow before closing out.

12. **Close out.** Don't push or merge to the integration branch without the operator's explicit instruction. Tell the operator where the task's artifacts are, and summarize anything from the harness notes worth changing in the templates or instructions.
