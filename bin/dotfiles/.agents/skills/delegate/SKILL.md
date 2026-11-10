---
name: delegate
description: Implement an operator-approved design through Antigravity when the operator asks Claude or Codex to implement or delegate that plan. Load at implementation time, including after Plan mode; do not use during design or for work the operator wants the designer to implement directly. The designer writes briefs, reviews each `agy -p` run, verifies changes, and accepts the task submission.
---

Runs the delegation loop: agreed design → `design.md` → per step, `brief.md` → Antigravity implements, runs the verification itself, and returns a report → the designer re-checks, reviews, polishes, and records/commits under the applicable Git policy (or records a reproducible checkpoint if deferred) → next step.

## Commit authorization and boundaries

Standing commit authorization depends on the active Git policy:
- In **Strict mode (`HARNESS_GIT_POLICY=strict`, default on Host and Docker Sandbox)**, the designer operates under standing authorization to make focused local commits for each accepted step before starting the next, without repeated requests for commit approval.
- In **Docker Sandbox mode with `HARNESS_GIT_POLICY=task-commits`**, Antigravity creates linear checkpoint commits for each step on the assigned task branch. The designer reviews each step's checkpoint delta, and upon task completion creates the single accepted task submission commit at task base (`sandbox/submit.py`).
- In **both modes**, exact designer model resolution (resolving Codex model via `resolve-codex-model.py` or checking Claude configuration) is strictly required before every delegation and before final commit creation; never guess or write model labels from memory.

### Separation of Concepts

- **PR (Pull Request)**: The unit of integration to the main branch; may contain one or multiple accepted task commits.
- **Task**: The unit of isolation and delegation (`one task = one Docker Sandbox = one private clone/checkout = one accepted submission commit`).
- **Step / Attempt**: The unit of delegation within a task (`brief.md` -> `agy -p` run -> `report-<n>.md` -> `review-<n>.md`). Multiple implementation steps and checkpoint commits belong to one final task submission commit.

### Git Policies

- In **Host mode (`HARNESS_GIT_POLICY=strict`)**, machine-local Antigravity sandbox restrictions and `"command(git commit)"` under `permissions.deny` enforce this mechanically. Antigravity must never stage or commit.
- In **Docker Sandbox mode**, the harness supports two explicit policies:
  - **Strict policy (`HARNESS_GIT_POLICY=strict`, default):** Role separation is strictly observed and monitored by the runner. Antigravity must never stage or commit (`git commit`, `git add`, checkout). The runner captures Git state (HEAD, branch, index) before and after each run and rejects acceptance (`status: GIT_STATE_MUTATED`, nonzero exit) if any Git state was modified.
  - **Task-commits policy (`HARNESS_GIT_POLICY=task-commits`, explicit opt-in):** Authorized exclusively in Docker Sandbox mode for assigned task branches (`HARNESS_TASK_BRANCH`) from accepted base (`HARNESS_TASK_BASE`). Antigravity may create linear checkpoint commits using Conventional Commits and the exact runner trailer. Checkpoint commits are unreviewed implementation artifacts; full-access checks detect mistakes rather than enforce confinement. Successful runs require clean tracked and untracked files.
- **Explicit Deny Precedence & Live Probe Evidence:** Explicit `permissions.deny` rules have documented precedence over allow/proceed and skip-permissions. Live non-mutating probes verified direct requests (`git commit --dry-run`, `git push --dry-run`, `git merge -h`) were denied before Git execution under full access (conversation `2fc0915a-ce16-450d-9bd9-58da6ae37872`). However, command prefix matching is supplemental and NOT a hostile-agent boundary: a second live probe (`476beb63-0994-4fb4-84f6-269910815ef7`) showed `/usr/bin/git push --dry-run` and `git -C /tmp push --dry-run` executed outside any repo, while `timeout 5 git push --dry-run` was denied. Full container egress allows external connections; deny strings are not an unbypassable external-write barrier.
- **Task Submission & Acceptance:** Once all steps for a task are verified and accepted, the designer freezes the reviewed checkpoint SHA, squashes the changes to a submission branch at the task base via `sandbox/submit.py prepare`, commits the single accepted task commit with all contributor trailers, and records the accepted submission manifest via `sandbox/submit.py accept`. (See [`sandbox/submit.md`](../../../../../sandbox/submit.md)).

If the operator explicitly requests commit deferral or stricter applicable constraints apply, record that exception in `design.md` and follow [Deferred commits](references/deferred-commits.md) to preserve each step without creating commits.

Deferring commits changes their timing; it does not alter the approved task boundaries or silently change task grouping upon resume. In Docker Sandbox mode, deferral preserves step review evidence across runs without committing; when deferral ends (or commit authority is released by the operator), the task still yields one accepted submission commit at base via `sandbox/submit.py` in the same clone without requiring a second worktree. In legacy host or strict mode, deferred steps are reconstructed as separate focused commits in a dedicated worktree before publishing, retaining full designer and implementer attribution. Operator-withheld commit authority must be respected until released. If the planned mapping cannot be reproduced safely, present the concrete problem and proposed grouping for operator approval before committing.

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

In Docker Sandbox mode, harness state remains in the container-local state directory outside the repo (`$AGENT_HARNESS_DIR`) and is preserved via `sandbox/task.py preserve` before sandbox retirement (see [`sandbox/task.md`](../../../../../sandbox/task.md)).

Templates are in `templates/` next to this file; the runner is `scripts/run-task.sh`.

## Prerequisite: execution modes and sandbox settings

The harness supports two execution modes via `HARNESS_EXECUTION_MODE=host|docker-sandbox` (default `host`):

- **Host mode (`HARNESS_EXECUTION_MODE=host`):** Commands run inside the machine-local Antigravity terminal sandbox configured in `~/.gemini/antigravity-cli/settings.json` (`"enableTerminalSandbox": true`, `"toolPermission": "proceed-in-sandbox"`, `"command(git commit)"` under `permissions.deny`, and denied credential files). Sandboxed commands receive no network access, `.git` is read-only, and writes are restricted. Runs execute from an empty scratch cwd to prevent workspace read-only restrictions. Never pass `--dangerously-skip-permissions` on the host: the sandbox is the boundary. If settings are missing, every command is denied.
- **Docker Sandbox mode (`HARNESS_EXECUTION_MODE=docker-sandbox`):** Commands execute inside an isolated task Sandbox container (`sandbox/task.py create`). Settings disable inner terminal sandboxing (`{"enableTerminalSandbox": false}`), and the runner runs `agy` directly in `$workdir` with `--dangerously-skip-permissions`. Commands have unconfined internal access within the container, and outbound network access follows the external container network policy. Accidental host execution is prevented by requiring nonempty `SANDBOX_ID`, `SANDBOX_VM_ID`, `SBX_AGENT` and the root-owned non-symlink `/etc/agent-harness/docker-sandbox` marker shipped by the kit (the microVM rootfs has NO `/.dockerenv`). Role separation is monitored by the runner's pre/post Git state check under strict mode, or guided by `git-task-policy.py` under `task-commits`.

## Setup

1. **Check the implementation request against the agreed plan.** The operator must have seen the approach, affected files, risks, and step boundaries, and explicitly asked to implement or delegate that plan. An explicit invocation of this skill for the agreed plan counts as that implementation approval; so does an explicit request such as "implement this plan" after Plan mode. Do not ask for the same approval again merely because the skill was loaded. Automatic skill selection, a preselected UI option, and silence are not operator approval. If the plan is missing, the request is ambiguous, or the implementation would materially change the agreed scope, resolve that before the first `agy` run. Reconfirm any substantially reworked design rather than treating an earlier request as approval for new work.

2. **Write `design.md` and seed `context.md`** in the task directory:
   - Write `design.md` from `templates/design.md`. Record the reason behind each non-obvious decision and the alternatives rejected: the implementer gets no chat history, and the reasons are what let it handle cases the design didn't foresee. Fill in the steps table:
     - One committable behavior change per step, ordered by dependency, each leaving the tree working.
     - Size each step to one `agy` run — about one concern and a handful of files.
     - Don't invent artificial splits; a genuinely atomic change is one step.
   - Seed `context.md` from `templates/context.md` with exploration knowledge: compact navigation (key files, entry points), established facts with paths/symbols, reasons, and evidence scope (static, mock, integration, live), superseded or corrected claims (compactly, avoiding raw history dumps), rejected paths, verification constraints, and uncertainties (clearly distinguishing hypotheses from verified facts). Set freshness (base commit SHA and initial checkpoint). Designer verifies findings before promoting them. Keep secrets, raw credentials, and verbose log dumps out.
   - Legacy tasks lacking `context.md` are supported: the runner preserves legacy runs with a visible notice, but the designer should seed `context.md` whenever exploration context exists.

   Use the agreed step list as the decomposition. If writing `design.md` reveals a material change to the steps, show the revised list and obtain the operator's approval before the first run. Otherwise continue under the implementation request from step 1.

3. **Create an implementation worktree (Host mode) or use the task clone checkout (Docker Sandbox mode):**
   - **Host mode (`HARNESS_EXECUTION_MODE=host`):** Create an implementation worktree branched from your task branch, reused for every step:
     ```
     git worktree add ../<repo>-<task>-impl -b <task>-impl HEAD
     ```
     `<task>-impl` stacks on the unmerged task branch only for the loop's duration; close-out fast-forwards it back and deletes it. If you're not in a task worktree, branch from the integration branch instead, passing the base explicitly when HEAD isn't it. Never target a directory with unrelated uncommitted changes.
   - **Docker Sandbox mode (`HARNESS_EXECUTION_MODE=docker-sandbox`):** Provision a dedicated task Sandbox using `sandbox/task.py create` (see [`sandbox/task.md`](../../../../../sandbox/task.md)). The host task source checkout seeds the container clone read-only via `sbx create --clone`. Sequential designer->agy->designer execution operates directly in the same task clone checkout (`$workdir`), without creating an additional implementation worktree. The clone is directly writable on the assigned implementation branch (`task/...`). Keep all harness artifacts in Sandbox-local state outside the repository (`$AGENT_HARNESS_DIR`, default `~/.local/state/agent-harness`), and preserve them via `sandbox/task.py preserve` before retiring the container.

## Per-step loop

Repeat for each step in order, one step per run. Never batch steps.

4. **Write `steps/<NN>-<slug>/brief.md`** from `templates/brief.md`. Carry the part of the design this step depends on and what earlier steps already changed, including whether they are committed or held as checkpoints — each new step starts a fresh Antigravity session. Point to shared knowledge in `context.md` without copying it all; keep the specific scope boundary and acceptance criteria in `brief.md`. Map each acceptance criterion to required evidence and scope (`static`, `mock`, `integration`, or `live`), and explicitly assign unavailable live checks (e.g. requiring network or external environments) to the designer. Do not introduce a new mandatory live test for all tasks; require live checks where relevant, and keep required but unavailable checks pending. State the scope boundary explicitly, and list in "Verification" the commands that must pass with their cwd, scope, and expected status. In host mode, commands run sandboxed without network access; in Docker Sandbox mode, commands follow the external container network policy. For resumed runs, the latest brief defines scope; current code and actual logs settle facts, and previous model statements from earlier turns are not proof. The run rules (no confirmation stops, evidence discipline, verify your own work, the selected Git policy rules) and the report format are appended by the runner from `templates/report.md`, so don't repeat them.

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
   HARNESS_DESIGNER="<you> (<model>)" [HARNESS_EXECUTION_MODE=host|docker-sandbox] [HARNESS_GIT_POLICY=strict|task-commits] <skill-dir>/scripts/run-task.sh <step-dir> <workdir> [brief] [--resume-attempt <N>]
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
   - **Role separation & Git policies (`HARNESS_GIT_POLICY=strict|task-commits`):**
     - **Strict policy (default):** Antigravity must never push, stage, or commit (`git commit`, `git add`, branch creation, or checkout). The runner captures `HEAD`, symbolic branch name, and index stage contents before the model probe and implementation run. If any Git state changed after `agy` completes (on either `SUCCESS` or error exit), the runner overrides status to `GIT_STATE_MUTATED`, records `git_state_changed: true` in `metrics.jsonl`, prints an error notice, and exits with code 1. Git mutations are preserved for designer inspection (never silently undone).
     - **Task-commits policy (explicit Docker opt-in):** Authorized exclusively for Docker Sandbox mode on assigned task branches (`HARNESS_TASK_BRANCH`) from accepted base (`HARNESS_TASK_BASE`). Antigravity creates linear checkpoint commits using Conventional Commits and the exact runner trailer. Policy checks (`git-task-policy.py`) verify linear ancestry, branch consistency, and that no uncommitted tracked or untracked changes remain upon completion. Checkpoints are unreviewed implementation artifacts; the designer reviews all work and creates the accepted task submission commit.
   - **Model resolution and probe:**
     - The runner defaults to `gemini-3.8-flash-high` when `AGY_MODEL` is unset or empty; the run stops (exit 2) if the model cannot be resolved. Set `AGY_MODEL` to override the model and `AGY_EFFORT` to override reasoning effort. The model probe and implementation receive the same arguments and execution mode flags.
   - **Designer attribution and session resolution:**
     - Before the model probe or allocating attempt files, the runner derives the designer label and records provenance fields `designer_source` (`codex-session`, `provided`, or `unknown`) and `designer_session_id`.
     - When `CODEX_THREAD_ID` is present locally and `HARNESS_DESIGNER` is unset, `unknown`, `Codex`, or starts with `Codex (...)`, the runner invokes `resolve-codex-model.py` to resolve the executing session's model from its latest complete `turn_context` record under `CODEX_HOME/sessions`, setting the label to `Codex (<resolved-model>)` and overriding stale text.
     - If session resolution fails in this identified Codex path, the runner stops immediately (exit 2) before invoking `agy` or allocating attempt files.
     - Explicit non-Codex designer labels (e.g. `Claude (Opus 4.8)`) are preserved. For remote designer calls over SSH without forwarding local session logs or credentials, explicit supplied labels are retained with `designer_source: "provided"`. Supplied labels are unverified by the remote runner; do not assume they are session-derived.
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

6. **Check against the diff, not the report.**
   - **Under `task-commits` policy (Docker Sandbox mode):** Each step is committed by Antigravity as a linear checkpoint on the assigned task branch, so the working-tree dirty diff is normally EMPTY. Never accept based on an empty dirty diff! Confirm `git -C <workdir> status` is clean (no untracked or uncommitted files). Retrieve the starting checkpoint SHA (the preceding reviewed checkpoint or task base commit) and ending checkpoint SHA from `metrics.jsonl` (or `git rev-parse HEAD`), and inspect the exact checkpoint delta: `git -C <workdir> diff <starting-checkpoint>..<ending-checkpoint>`. Inspect the commit history (`git -C <workdir> log <starting-checkpoint>..<ending-checkpoint>`) to verify Conventional Commits format and the exact runner trailer.
   - **Under strict policy (Host mode or strict Docker mode):** Run `git -C <workdir> status` and `diff`. If earlier steps are committed, the working-tree diff is exactly this step. If commits are deferred, compare the current tree against the preceding accepted checkpoint; the cumulative diff from HEAD is not this step's diff.
   - **Re-run verification:** Re-run the brief's verification commands yourself and compare the results with the report's "Verification" section. Antigravity running them first saves rework rounds, but its report is a claim, not proof. Runner exit `SUCCESS` means only that execution finished; it is not verification or review acceptance. Distinguish four lifecycle states: execution finished, verified, accepted, and awaiting commit. Check claims against evidence, inspected paths/symbols, and actual assertions/triggers, distinguishing independent designer reruns from implementer-only reports. Mock success is not live verification; after relevant code changes, rerun affected checks. Checks the report lists as blocked or not verified (anything needing the network or assigned to the designer, for example) are yours to run. Changes outside the step's scope are dropped or preserved for a separate focused commit; say which.

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
     ```bash
     # Under Codex, resolve the model from the active session (stops on failure):
     if ! CODEX_MODEL="$(<skill-dir>/scripts/resolve-codex-model.py)"; then
       echo "Failed to resolve Codex model from session" >&2
       exit 1
     fi
     HARNESS_DESIGNER="Codex ($CODEX_MODEL)" <skill-dir>/scripts/run-task.sh <step-dir> <workdir> <rework-brief> [--resume-attempt <N>]
     ```
     (When running locally with `CODEX_THREAD_ID` set, `run-task.sh` also resolves and overrides stale Codex labels automatically).
   - The attempt counter advances, keeping earlier artifacts intact. Bound rework at two rounds, then bring it to the operator. If the review shows the step's premise was wrong, stop (step 10).

9. **Commit or checkpoint this reviewed step:**
   - **Host mode or strict Docker mode:** Under standing authorization, once this step's review is complete, required fixes are done, and relevant re-verification passes, commit in the worktree before proceeding, without asking for commit approval. The commit covers only this step, with a Conventional Commits message whose body draws on the design's reasoning, and both trailers:
     ```
     Co-authored-by: <you> (<model>) <noreply@...>
     Co-authored-by: Antigravity (<model>) <noreply@google.com>
     ```
     Both trailers are mandatory on every delegated step, including a step you only reviewed or polished. Take Antigravity's trailer verbatim from the runner's `trailer for the commit:` line, or from the run's `trailer` field in `metrics.jsonl`. Take your own model from your actual configuration or active session, never from memory:
     - Codex: resolve from the executing session via `<skill-dir>/scripts/resolve-codex-model.py` again at commit time, never from an earlier metrics row, memory, static assumptions, or generic family names like `GPT-6`. App, CLI, or profile overrides take precedence over `config.toml` defaults; the latest complete `turn_context` record in the session rollout is the source of truth. If resolution fails, stop rather than guess:
       ```bash
       if ! CODEX_MODEL="$(<skill-dir>/scripts/resolve-codex-model.py)"; then
         echo "Failed to resolve Codex model from session" >&2
         exit 1
       fi
       ```
       On-disk rollout JSONL logs are an observed internal format, not a stable public API; if format changes or evidence is missing/ambiguous, fail fast. For remote designer calls over SSH without copying histories or credentials, resolve on the host first and pass `HARNESS_DESIGNER="Codex ($CODEX_MODEL)"`.
     - Claude: take your model from your actual configuration; Claude Code appends its own versioned co-author trailer automatically (check `git log -1` to avoid duplicates).
     Record the commit SHA in the review, confirm `git status` is clean, report the commit to the operator in a line or two, and continue. Don't push or merge mid-loop; standing local commit authority never authorizes pushing or creating a PR.
   - **Docker Sandbox mode with `task-commits`:** Antigravity created linear checkpoint commit(s) on the task branch carrying the runner Antigravity trailer. The designer reviews the diff and commit, runs verification, and records the reviewed checkpoint SHA in `review-<n>.md`.
   - **Task completion & submission commit:** Once all steps for a task are completed and verified:
     1. Freeze the final reviewed checkpoint SHA.
     2. In the same checkout, run `sandbox/submit.py prepare` to squash the reviewed commit to a submission branch at base without committing.
     3. The designer inspects the staged diff, writes the single accepted task commit with Conventional Commits, full body explanation, and all contributor trailers (`Co-authored-by: <designer>`, `Co-authored-by: Antigravity (...)`), and commits in the same checkout.
     4. Run `sandbox/submit.py accept` to validate the commit object, parent = base, tree = reviewed tree, and write the immutable accepted submission manifest. (See [`sandbox/submit.md`](../../../../../sandbox/submit.md)).

   If commits are explicitly deferred by the operator or blocked by stricter constraints, save the accepted checkpoint and record its base, predecessor, verification results, and deferred commit status in the review before proceeding.

## Stopping and closing out

10. **Stop if a review invalidates the remaining plan.** When the design or decomposition was wrong rather than the implementation sloppy, pause, report what the committed steps established, update `design.md`, and re-confirm the remaining steps with the operator.

11. **Close out worktrees, preserve state, and assemble PR:**
    - **Host mode:** Fast-forward and remove the implementation worktree as soon as the last step is committed. From your task worktree:
      ```
      git merge --ff-only <task>-impl
      git worktree remove ../<repo>-<task>-impl
      git branch -d <task>-impl
      ```
      Always `--ff-only`; if it refuses, something moved the task branch — stop and report. Remove only a clean worktree, never with `--force`. Delete the branch after the removal, with `-d`.
    - **Docker Sandbox mode:**
      - The task submission commit is prepared and accepted via `sandbox/submit.py` (see [`sandbox/submit.md`](../../../../../sandbox/submit.md)).
      - Preserve task state using `sandbox/task.py preserve --record RECORD --dest DEST --quiesced` (see [`sandbox/task.md`](../../../../../sandbox/task.md)). This captures and verifies a full Git bundle (`--all HEAD`), staged binary patch, worktree archive, and guest harness archive on the host.
      - Explicit retirement: preservation and submission acceptance do not authorize deletion. Removing a sandbox (`sbx rm <name>`) requires separate explicit operator approval, a fresh state check confirming a quiesced container, and verified host export before deletion. There is no routine retention as a persistent project environment. Interrupted tasks remain recorded until resumed (`task.py start`) or explicitly retired.
      - Multi-task PR assembly: when multiple tasks form a PR, assemble accepted task manifests onto a clean PR branch in dependency order via `sandbox/submit.py assemble`. Run final combined tests across the assembled PR branch.
      - PR review feedback is addressed by creating a new task commit on the PR branch.

   If commits remain deferred, retain the implementation worktree (Host mode) or task clone checkout (Docker Sandbox mode) and checkpoints, and report why they remain open. Once constraints are resolved or explicit commit permission arrives from the operator, finalize the commits under the applicable workflow (for Docker Sandbox mode, record a reviewed checkpoint if needed and create the single accepted task submission commit via `sandbox/submit.py` in the same clone; for legacy host/strict mode, materialize each separate step commit in a dedicated worktree) before closing out.

12. **Close out.** Don't push or merge to the integration branch without the operator's explicit instruction. Tell the operator where the task's artifacts are, and summarize anything from the harness notes worth changing in the templates or instructions.
