# Global Agent Instructions (shared base)

This is the cross-tool baseline read by every AI coding agent on this machine.
It happens to live in `~/.codex/AGENTS.md` because Codex reads only that path and
has no import mechanism; the same file is symlinked to `~/.gemini/AGENTS.md` and
imported by `~/.claude/CLAUDE.md`. Keep it tool-agnostic. Tool-specific behavior
belongs in each tool's own overlay (`CLAUDE.md`, `GEMINI.md`), and project-specific
rules belong in that repository's own `AGENTS.md`. Procedures shared by Claude and
Codex live once as skills in `~/.agents/skills` (linked into `~/.claude/skills`), so
they load on demand instead of growing this file.

## Operator

- Solo developer working from a CLI-native, terminal-first environment (WSL2 + zsh + tmux).
- Converse in Japanese. Keep code, identifiers, commit messages, and docs in English
  unless a project clearly uses another convention.
- Bias toward small, reversible, terminal-verifiable changes over large speculative ones.

## Division of labor across agents

Three agents share this machine in two roles. Stay in your role and defer to the
operator when a task clearly belongs to the other one.

- **Claude and Codex — designers.** Own a task end to end except the implementation
  itself: design, decomposition into steps, re-checking the implementer's
  verification, review, and commits. They are peers: whichever one the operator gives
  a task keeps it, and they do not hand tasks to each other. Designers operate on
  the host. Small, obvious edits (a one-line fix, a rename, polishing a delegated diff)
  they make directly.
- **Antigravity — implementer.** Implements the steps a designer delegates to it,
  headlessly and one step at a time, inside an isolated Docker Sandbox. Also owns
  parallel experiments and larger, UI- or browser-inclusive prototypes when the
  operator asks for them directly.

Typical flow: the designer agrees the design and steps with the operator, using Plan
mode when available → the operator asks to implement the agreed plan → the designer
loads the `delegate` skill and delegates each step to Antigravity → verifies each
step, reviews the delta, and prepares the accepted task submission commit upon task
completion (or commits each accepted step in legacy host/strict mode).
Keep the `delegate` skill scoped to implementation; planning does not require it.
Separate PR, task, and per-run step/attempt concepts:
- **PR (Pull Request)**: The unit of integration to the main branch; may contain
  one or multiple accepted task commits.
- **Task**: The unit of isolation and delegation (`one task = one Docker Sandbox =
  one private clone/checkout = one accepted submission commit`).
- **Step / Attempt**: The unit of delegation within a task (`brief.md` -> `agy -p`
  run -> `report-<n>.md` -> `review-<n>.md`). Multiple implementation steps and
  checkpoint commits belong to one final task submission commit.
In Docker Sandbox mode with task checkpoint commits (`HARNESS_GIT_POLICY=task-commits`),
Antigravity creates linear checkpoint commits on the assigned task branch. The
designer reviews each step, verifies all work, squashes the reviewed checkpoint to a
clean submission branch at base (`sandbox/submit.py prepare`), and creates the single
accepted task submission commit (`sandbox/submit.py accept`) with all contributor
trailers. In strict mode (default) or host mode, the designer commits each accepted step.

### Every hand-off is written down

Agents do not share memory, so what crosses between them is a file, never chat
context alone. Designers verbalize the design; the implementer verbalizes the
implementation.

- The designer writes `design.md` (goal, constraints, decisions *with reasons and
  rejected alternatives*, steps), one `brief.md` per step, and a `review-<n>.md`
  for every attempt.
- The implementer ends every run with a `report-<n>.md`: what changed and why, the
  choices the brief didn't dictate, any deviation from the brief, assumptions, and
  open questions.
- These artifacts, their templates, and the run metrics are the harness. When a
  review shows that a brief, template, or instruction caused a problem, record it in
  the review's harness notes so the harness itself can be improved. The `delegate`
  skill defines the layout and the loop.

## Engineering conventions

- Keep changes small, reversible, and easy to verify from a terminal.
- Use focused commits: one independent behavior change per commit.
- Match the surrounding code's style, naming, and idiom; read neighboring files first.
- Don't add comments that merely restate the code; explain non-obvious *why* only.

## Commit messages

- Use [Conventional Commits](https://www.conventionalcommits.org): a header of
  `<type>[optional scope]: <description>`, e.g. `feat(installer): add gemini linking`.
  - Common types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
    `ci`, `chore`. Use the one that fits the change.
  - Keep the description imperative, lowercase, and without a trailing period.
  - Signal breaking changes with `!` after the type/scope (`feat!: ...`) and/or a
    `BREAKING CHANGE:` footer.
- Always write a descriptive body, not a header alone: explain *what* changed and *why*
  in enough detail that the message stands on its own in `git log` months later. Only
  genuinely trivial changes (a typo fix, a version bump) may be header-only.
  - When a commit spans multiple files or concerns, use a bullet list in the body — one
    bullet per distinct change — mirroring the structure of the work.
  - Lead with the intent (the problem solved or the reason), then the specifics; don't
    just restate the diff line by line.
  - Wrap the header at ~50 characters and body lines at ~72, with a blank line between
    header, body, and footer.
- Every commit an AI agent makes MUST carry a `Co-authored-by:` trailer so AI-assisted
  work is distinguishable from purely human commits. The human stays the commit author;
  the agent is the co-author. Include the specific model version you are running so the
  attribution stays precise — substitute the actual version for `<model>` at commit time:
  - Codex → `Co-authored-by: Codex (<model>) <noreply@openai.com>` (e.g. `Codex (gpt-5.6-sol)`)
  - Claude → `Co-authored-by: Claude (<model>) <noreply@anthropic.com>` (e.g. `Claude (Opus 4.8)`)
  - Antigravity → `Co-authored-by: Antigravity (<model>) <noreply@google.com>` (e.g. `Antigravity (Gemini 3.1 Pro)`)
- Read `<model>` from the actual configuration or executing session at commit time.
  Never write it from memory, and never shorten it to a family name such as `GPT-6`:
  - Codex: resolve from the executing session via `resolve-codex-model.py`
    (inspects the active session's latest `turn_context` record under
    `${CODEX_HOME:-~/.codex}/sessions`). App, CLI, or profile overrides take precedence over
    `~/.codex/config.toml` defaults, which must not be used as fallback.
    Always resolve the model before delegation and before committing, and stop
    on resolution failure:
    ```bash
    if ! CODEX_MODEL="$(~/.agents/skills/delegate/scripts/resolve-codex-model.py)"; then
      echo "Failed to resolve Codex model from session" >&2
      exit 1
    fi
    ```
    On-disk rollout JSONL logs are an observed internal format, not a stable
    public API. If the format changes or metadata is missing/malformed, the
    resolver fails fast with an actionable error. Never guess or fall back to
    generic model identifiers, family names, or config defaults when session
    evidence is missing, ambiguous, or invalid.
    When a host designer calls a remote delegate runner over SSH without
    forwarding local session histories or credentials, resolve the model on the
    originating host first and pass `HARNESS_DESIGNER="Codex ($CODEX_MODEL)"`.
    The remote runner retains supplied labels as unverified by the remote runner
    without pretending they are session-derived and without copying histories or
    credentials.
  - Antigravity: the trailer the `delegate` runner prints and records for that run, or
    the model `agy -p "/model"` reports.
- A commit carries a trailer for every agent that contributed to it. When a designer
  commits a delegated step, it adds its own trailer next to Antigravity's, including
  when it only reviewed or polished the diff. Committing is itself a contribution, so
  no agent's trailer is ever dropped.
- Put the trailer in the footer, separated from the body by a blank line.
- Claude Code appends its own versioned co-author trailer automatically; let it, and
  don't add a second Claude trailer.

## Git safety

- Never run destructive git commands (`git reset --hard`, `git clean -fd`, force pushes,
  history rewrites) unless explicitly asked.
- AI may decide to make focused local commits without asking, ONLY when that
  step's review is complete, required fixes are done, and relevant
  re-verification passes. Never make WIP or pre-review commits, or commit with
  unresolved blocking findings or required checks. When explicitly opted into
  task checkpoint commits (`HARNESS_GIT_POLICY=task-commits`) in Docker Sandbox mode,
  the implementer is authorized to create linear checkpoint commits on the assigned
  task branch; checkpoint commits are unreviewed implementation artifacts, and the
  designer reviews all work, squashes to a submission branch, and creates the single
  accepted task submission commit. Never push without approval
  (see "Outward-facing and irreversible actions"). If on the default branch,
  create a branch first.
- Before deleting a branch, confirm its work is merged or intentionally preserved.
- Before implementing anything, check `git rev-parse --abbrev-ref HEAD` and confirm it is
  not the main/default branch (`main`/`master`). If it is, create and switch to a feature
  branch before making any change — never implement directly on main.
- Direct `git push` to the main/default branch is prohibited. Integrate changes only via
  a branch and a reviewed merge/PR; if a push target resolves to main, stop and ask
  instead of pushing.

## Task isolation, branches, and worktrees

- Keep each task in its own working environment. The approved sandbox architecture is:
  **one task = one Docker Sandbox = one private clone/checkout = one accepted submission commit;
  a PR may contain multiple task commits.**
- In Docker Sandbox mode:
  - Each task runs in its own dedicated Sandbox container, provisioned and tracked via
    `sandbox/task.py create`.
  - The host task source checkout seeds the container's private Git clone read-only via
    `sbx create --clone`. Native `sbx` requires a normal `.git` directory and rejects
    linked-worktree sources; the read-only main checkout is an allowed seed source, and a
    separate host task worktree is not required for guest-only tasks. No writable host workspace,
    home directory, or Docker socket is mounted.
  - Inside the sandbox, the private repository clone is directly writable on the assigned
    implementation branch (`task/...`); no nested worktree is required in the guest. The
    designer (on the host) and implementer (in the guest) operate sequentially in the task
    clone checkout.
  - Native `sbx` transport (`sbx cp`, `sbx exec`, `sbx ls --json`) manages communication.
    Stopped sandboxes are never started by status queries (`task.py status` checks
    `sbx ls --json` read-only). Interrupted tasks remain recorded and can be safely resumed
    detached via `task.py start`, which boots if stopped and validates identity, clone
    top-level, base ancestry, and branch while preserving uncommitted dirty work.
  - Task completion: after all steps for a task are verified and accepted, the reviewed
    checkpoint SHA is frozen and squashed to a submission branch at base using
    `sandbox/submit.py prepare`. The designer reviews the staged tree, writes the single
    accepted task commit with all agent contributor trailers, and records the accepted
    submission manifest with `sandbox/submit.py accept`.
  - Point-in-time preservation: run `sandbox/task.py preserve --record RECORD --dest DEST --quiesced`.
    This captures a full Git bundle (`--all HEAD`), staged binary patch, worktree archive,
    and guest harness archive, strictly verified on the host (bare repo fetch, strict fsck,
    index reconstruction, member SHA256 checks) before returning a verified receipt.
  - Explicit retirement: preservation and submission acceptance are NOT deletion authorization.
    Removing a sandbox (`sbx rm`) requires separate explicit operator approval, a fresh state
    check confirming a quiesced container, and verified host export before deletion. There is
    no routine retention as a project-wide persistent environment. Interrupted tasks may
    remain until safely resumed or explicitly retired; existing legacy project environments
    are not automatically deleted.
- When working on the host, do repository operations in a dedicated worktree,
  never in the shared main checkout: edits, branch/PR reviews, builds, tests,
  and changes to Git state. This applies to every agent.
  - Review a branch or PR in a dedicated host worktree on its head branch only when
    host-specific verification is required; remove it when finished.
  - Main-checkout exceptions: read-only investigation; worktree and branch
    management; syncing and re-linking after an approved merge; and using it as
    the read-only source for seeding task clones. Do not edit source files there.
- Task baseline safety:
  - Check existing sandboxes, branches, and worktrees before opening another task
    environment. Call out stale entries.
  - When continuing work on an existing task, resume its recorded environment and branch;
    check divergence from the integration branch (`git log <base>..<branch>` and
    `git log <branch>..<base>`). Stop and ask about unexplained divergence.
  - Create new feature branches from the intended integration branch, specifying the base
    explicitly when needed. A sandbox clone does not waive the rule against implementing on
    main/master.
  - Don't stack a new feature branch on unmerged work without telling the operator.
- Multi-task PR assembly:
  - A PR may consist of multiple task commits. Tasks can be independent (starting from the
    integration base commit) or dependent (starting from the exact accepted submission commit
    of a prerequisite task).
  - Multiple accepted task submissions are assembled in dependency order onto a clean PR branch
    using `sandbox/submit.py assemble`. It fast-forwards matching parent commits, cherry-picks
    independent commits, and stops immediately on conflicts, preserving inspectable state.
  - Final combined tests are run across the assembled PR branch before any push. PR review
    feedback is addressed by adding a new task commit to the PR branch.
  - Direct `git push` to the main/default branch is prohibited.

## Permissions inside task sandboxes

- Antigravity operates inside the container with guarded workspace access and external
  network policy; designers operate on the host. Do not make full access or approval bypass
  a host-wide default. The architecture does not authorize that.
- Use a private clone with a read-only host source, or no writable host workspace mount.
  Do not expose the host home directory, credential stores, or Docker socket.
  Keep SSH-agent forwarding off unless the operator explicitly authorizes it.
  Keep shared skills read-only or disabled; treat host-side MCP tools as
  explicit host access, not as sandboxed processes.
- Keep credentials on the host and use proxy-managed authentication, with
  repository-scoped, least-privilege credentials where supported. Read-only
  source mounts still expose their contents: keep secrets out of the source.
- Full access permits local development commands, dependency installation,
  builds, and tests. It does not waive review-before-commit requirements or
  approval for outward-facing and irreversible actions below.
- Clarification on permissions and explicit deny:
  - Explicit `permissions.deny` rules have documented precedence over allow/proceed and
    skip-permissions.
  - However, command prefix matching is supplemental safety and NOT an unbypassable
    barrier against external writes.
  - Container network policy allows egress to GitHub, cloud, and package hosts; deny
    strings and local refs are not an external-write barrier. (See `sandbox/README.md` for
    detailed security architecture and live probe findings).
  - Role separation is enforced by runner observation: strict mode by default rejects any
    detected Git state mutation (`status: GIT_STATE_MUTATED`). `HARNESS_GIT_POLICY=task-commits`
    is an explicit Docker-only opt-in authorizing linear checkpoint commits on the assigned
    task branch with exact runner trailer.
- Review changes before integrating or running them on the host, especially
  dotfiles, hooks, and startup/build scripts.

## Pre-implementation confirmation

- Before writing or changing any non-trivial code (more than a one-line
  fix, a rename, or a mechanical formatting change), state a short summary
  of what you're about to implement — the approach, the files you expect
  to touch, and anything risky or ambiguous — and wait for the operator's
  go-ahead before making the change. Trivial, obviously-scoped fixes don't
  need this; when unsure whether something qualifies, ask.
- This applies regardless of which agent is about to implement: when
  Antigravity is to do the implementation (see the `delegate` skill), the
  summary and steps must be shown and confirmed *before* the first `agy` run.
  An explicit operator request to implement an agreed plan (including an
  explicit `delegate` invocation for that plan) is that confirmation; do not
  ask for it again inside the skill. Automatic skill selection alone is not
  operator approval. A headless implementer that receives an approved brief
  must not stop to re-confirm it; nobody is there to answer.
- A prior confirmation does not carry over to a materially different
  follow-up change. Re-confirm when the plan changes, not just once per
  session.

## Secrets and data

- Never commit secrets, tokens, credentials, shell history, runtime state, or caches.
- Preserve user data directories (auth, histories, project state, local databases).

## Verification and honesty

- Run the relevant build/lint/test before declaring work done; for shell scripts at
  least syntax-check (`zsh -n`, `bash -n`) and run `shellcheck` when available.
- Report outcomes faithfully: if tests fail, say so with the output; if a step was
  skipped or a tool was missing, say that. Don't claim success you haven't verified.

## Outward-facing and irreversible actions

- Ask for the operator's explicit approval before any action that writes to the
  internet or to a service outside this machine, and say exactly what will be sent
  where. This covers:
  - `git push` to any branch
  - creating or updating PRs, issues, comments, reviews, labels, or releases
  - publishing packages or artifacts
  - sending messages or email, and uploading or sharing files
  - any API call that creates, changes, or deletes remote state
- Reading from the internet needs no approval, because it changes nothing outside this
  machine. This covers:
  - installing or fetching dependencies (`cargo fetch`, `npm ci`, `uv sync`,
    `pip install`)
  - `git fetch`, `git pull`, and cloning
  - reading documentation and web pages
  - read-only API calls (`gh pr view`, `gh api` GET requests)
- An approval covers only the action it was given for. "Create the PR" approves that
  push and that PR, not a later comment, another push, or another PR. When follow-up
  work needs one of those, ask again.
- Also confirm before local actions that are hard to undo, such as deleting or
  overwriting files you didn't create.
