# Docker Sandbox Kits: Task-Scoped Delegation & Multi-Task Assembly

This directory contains reusable Docker Sandbox Kit (specification schema v3)
descriptors, companion Dockerfiles, and lifecycle/submission CLI tools to run
designers (Codex / Claude) on the host and Antigravity (as implementer) inside
an isolated, task-scoped Docker Sandbox.

The approved architecture is:
**one task = one Docker Sandbox = one private clone/checkout = one accepted submission commit;
a PR may contain multiple task commits.**

Sequential delegation operates directly within the same task clone checkout;
no extra guest worktrees are required.

## Table of Contents

- [Overview & Architecture](#overview--architecture)
- [Evidence Status: Prototype vs. Source Kits](#evidence-status-prototype-vs-source-kits)
- [Security Model & Isolation Boundary](#security-model--isolation-boundary)
- [Host Prerequisites & Keyring Unlock](#host-prerequisites--keyring-unlock)
- [Pre-Flight: Check Proxy Interception Before Any Login](#pre-flight-check-proxy-interception-before-any-login)
- [Kit Definitions](#kit-definitions)
- [Kit Composition & Building](#kit-composition--building)
- [Task Sandbox Lifecycle Management (`sandbox/task.py`)](#task-sandbox-lifecycle-management-sandboxtaskpy)
- [Task Submission & Multi-Task Assembly (`sandbox/submit.py`)](#task-submission--multi-task-assembly-sandboxsubmitpy)
- [Task Sandbox Clone & Implementation Workflow](#task-sandbox-clone--implementation-workflow)
- [Sentinel Verification (Secret-Free)](#sentinel-verification-secret-free)
- [Running Antigravity Inside the Sandbox](#running-antigravity-inside-the-sandbox)
- [Accidental-Host Guard & Environment Marker](#accidental-host-guard--environment-marker)
- [Preserving Task Work & Retirement](#preserving-task-work--retirement)

---

## Overview & Architecture

The task-scoped delegation model pairs a host designer (Codex or Claude) and
a guest implementer (Antigravity, `agy`) in an isolated container environment:

1. **Host Designer (Codex / Claude)** designs the task, decomposes it into
   discrete steps, writes briefs, orchestrates the sandbox lifecycle, and
   reviews implementer results.
2. **Task Sandbox Provisioning:** The designer provisions a dedicated sandbox
   and private clone for the task using `sandbox/task.py create`. The host task
   checkout seeds the guest clone read-only.
3. **Antigravity (Implementer)** executes headlessly inside the task sandbox
   via `run-task.sh`, operating directly within the task clone checkout. Under
   `HARNESS_GIT_POLICY=task-commits`, it creates linear checkpoint commits on
   the assigned task branch.
4. **Designer Verification & Review:** The designer verifies changes, runs tests,
   and reviews each step.
5. **Submission Preparation & Acceptance:** Once the task is complete and verified,
   the designer freezes the reviewed checkpoint SHA, squashes the changes to a
   submission branch at base (`sandbox/submit.py prepare`), commits the accepted
   task submission commit with all contributor trailers, and records the accepted
   manifest (`sandbox/submit.py accept`).
6. **Preservation & Retirement:** After acceptance, export and verify task state with
   `sandbox/task.py preserve`. The delegate workflow then runs `sandbox/task.py retire`
   for eligible task sandboxes under standing authorization.
7. **PR Assembly:** Multiple accepted task submissions are assembled into an
   integration PR branch using `sandbox/submit.py assemble`.

Both designer and implementer share the same task clone checkout sequentially.
No nested guest worktrees are required. Detailed helper references:
- Lifecycle management CLI: [`sandbox/task.md`](task.md)
- Submission & assembly CLI: [`sandbox/submit.md`](submit.md)

---

## Evidence Status: Prototype vs. Source Kits

The historical checks below concern the older combined Codex/Antigravity kits.
The current task workflow uses the neutral Antigravity workload described below.

> [!IMPORTANT]
> **Prototype Verification vs. Final Source Checks**
>
> - **Live-Verified Prototype (`/tmp/auth-prototype`):** Tested on host `sbx 0.50.1`
>   in sandbox `codex-agy-v3-auth`. The minimal v3 descriptor composition passed
>   token-endpoint TLS handshakes and achieved sequential `AUTH_OK` inference calls
>   for both clients using sentinel-only credentials without browser logins.
> - **Historical combined-kit verification (2026-10-31, sbx 0.50.1):** Both persisted kits
>   built successfully. A fresh `dotfiles-agy-dev` sandbox with `--clone` passed
>   proxy TLS checks and sequential Codex / Antigravity `AUTH_OK` calls without
>   browser login. All three credential/config checks passed after inference.
>   The vendor installer and base image float; builds are not bit-for-bit pinned.

---

## Security Model & Isolation Boundary

The Docker Sandbox enforces external isolation while granting agents full
internal access within the container boundary:

- **Read-Only Clone Source Mount:** When `--clone` is specified, `sbx` mounts the
  specified host repository checkout read-only to seed the container clone.
  This is the only intended host mount; no writable host workspace, home directory,
  Docker daemon socket (`/var/run/docker.sock`), or host credential store is mounted.
- **No Native Host Docker Socket:** The host Docker socket is never mounted into the container.
  Any Docker socket present inside the microVM is VM-local, not a host bind.
- **SSH Agent Forwarding Disabled:** Explicit SSH-agent forwarding must be disabled
  separately (ensure `SSH_AUTH_SOCK` is not forwarded or mounted into the sandbox).
- **Skills Flag Boundary:** `--skills off` disables the shared skills store.
  It does not itself prevent credential helper bindings; credential safety relies
  on proxy sentinels, absence of host credential mounts, and disabled forwarding.
- **Proxy-Managed Credentials:** The task kit supplies Antigravity sentinel tokens
  (`agy-oauth-access-proxy-managed`), not host credentials. OpenAI sentinel
  configuration belongs to the legacy Codex workload only.
- **Host-Side Proxy Interception:** Outbound calls to OAuth endpoints and model APIs
  are intercepted by the host sbx proxy daemon (`passthrough: false`), which attaches
  host-managed credentials.
- **Network Policies:** Kit and host policies include model providers, OAuth
  endpoints, and development services such as GitHub and package hosts. Allowed
  egress is not restricted to read-only operations.
  *(Note: Network filtering depends on host Docker daemon capabilities; if host policy
  is allow-all, sandbox policy cannot guarantee deny-all behavior).*

---

## Host Prerequisites & Keyring Unlock

Before creating or managing sandboxes, ensure the host environment is ready:

1. **Docker Engine & sbx CLI:** Ensure Docker and `sbx` (`0.50.1` or higher)
   are installed and running on the host.
2. **Keyring Unlock Check:** `sbx` accesses OAuth sessions through the host Secret
   Service / system keyring. Verify that the login keyring is unlocked:
   ```bash
   busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked
   ```
   An output of `b false` indicates the keyring is unlocked (`b true` indicates locked).
   *(Note: An optional host keyring-unlock helper referencing 1Password is provided by
   a separate pending branch; ensure the keyring is unlocked before invoking sbx).*

---

## Pre-Flight: Check Proxy Interception Before Any Login

> [!CAUTION]
> **DO NOT INSTRUCT OR PERFORM OAUTH LOGIN UNTIL PROXY INTERCEPTION IS CONFIRMED.**
>
> Never execute an interactive browser OAuth login or paste API tokens inside
> the sandbox. If the sbx proxy is not actively intercepting traffic, client
> authentication requests could route directly to upstream services, bypassing
> the proxy and leaking actual credentials.
>
> Verify the HTTPS_PROXY connection for the selected agent service before
> executing any authentication flow.

### Running the Preflight TLS Issuer Check

Inside the sandbox, run the provided executable preflight script before any agent
execution:

```bash
python3 sandbox/kits/check_proxy_tls.py --service antigravity
```

For the task kit, the script connects to `oauth2.googleapis.com:443` using
HTTP CONNECT through `HTTPS_PROXY` and Python's standard TLS verification, inspects the certificate issuers, and
prints only the issuer strings:

```text
oauth2.googleapis.com issuer: commonName=Docker Sandboxes Proxy CA, ...
proxy_tls_intercepted: True
```

- **If intercepted (`Docker Sandboxes Proxy CA`):** Outbound authentication requests are
  intercepted on this tested proxy route. This check does not prove every client
  honors the proxy, or that every filesystem path is free of secrets.
- **If un-intercepted or mismatch:** The script prints `proxy_tls_intercepted: False`
  and exits `1`. **STOP IMMEDIATELY.** Do not initiate login or execute agent commands.
- **OAuth Reuse:** When active OAuth sessions exist on the host, `sbx` prompts to
  bind the sandbox to those credentials on startup. Reuse existing OAuth sessions
  whenever available; distinguish initial host login from ordinary sandbox reuse.

---

## Kit Definitions

The kit sources are located under `sandbox/kits/`:

### 1. Antigravity Workload (`sandbox/kits/antigravity-workload`)

Use the [neutral workload](kits/antigravity-workload/README.md) with the
Antigravity mixin for new tasks. Its base is
`docker.io/sbx/shell-docker-image:latest`; it provides Python, jq, process tools,
and the root-owned harness marker without installing Codex or Claude.
The mixin supplies `agy` and its proxy configuration.

### Legacy Codex Workload (`sandbox/kits/codex-workload`)

Retained for existing environments; this is not the workload for new task sandboxes.
- **Descriptor:** `codex-workload.yaml` (schema v3, `kind: workload`)
- **Dockerfile:** `codex-workload.dockerfile` (based on `docker/sandbox-templates:codex-docker`)
- **Configuration:** Static sentinel `config.toml` and `auth.json`
- **Capabilities:**
  - `com.docker.sandbox/sbx@1`
  - `com.docker.sandbox/network-policy@1` (`auth.openai.com`, `chatgpt.com`)
  - `com.docker.sandbox/credential@1` for service `openai` (`passthrough: false`,
    sentinels `oai-oat01-proxy-managed` / `oai-ort01-proxy-managed`)
- **Codex Settings:**
  - `approval_policy = "never"`
  - `sandbox_mode = "danger-full-access"`
  - `forced_login_method = "api"`
  - `model_provider = "sandboxd"`
  - Model provider `sandboxd` points to `https://chatgpt.com/backend-api/codex` with
    `experimental_bearer_token = "oai-oat01-proxy-managed"` and `requires_openai_auth = false`.

### 2. Antigravity Mixin (`sandbox/kits/antigravity-mixin`)
- **Descriptor:** `antigravity-mixin.yaml` (schema v3, `kind: mixin`)
- **Dockerfile:** `antigravity-mixin.dockerfile` (multi-stage build from `debian:bookworm-slim`
  delivering to `scratch`)
- **Capabilities:**
  - `com.docker.sandbox/network-policy@1` (Google AI APIs, OAuth endpoints, `antigravity.google`)
  - `com.docker.sandbox/credential@1` for service `antigravity` (`passthrough: false`,
    sentinels `agy-oauth-access-proxy-managed` / `agy-oauth-refresh-proxy-managed`,
    `auth_method: consumer`, template expiry `2000-01-01T00:00:00Z`).
    - *Intentional Past Expiry & Token Refresh:* The credential template sets `expiry`
      to a past timestamp (`2000-01-01T00:00:00Z`). This past expiry is intentional:
      it prompts the client to use its sentinel refresh token through the host proxy
      instead of treating an expired real access token as permanently valid (the year-9999
      sentinel expiry produced HTTP 401 errors that cleared after requesting refresh).
    - *Verification Scope:* Token refresh driven by past expiry is live-verified across
      fresh sandbox invocations and guest stop/restart cycles (where the credential file
      retains sentinel markers and inference succeeds without browser login).
      Long-duration session renewal during continuous execution without process
      restart remains untested.
- **Installer Handling & Floating Version Notice:**
  - Official `agy` is fetched during image build via HTTPS installer
    (`https://antigravity.google/cli/install.sh`) into a temporary file. No binaries
    or host credentials are vendored.
  - *Floating Version Limitation:* The vendor installer queries a dynamic release manifest
    at build time, and `agy` performs background updates during runs. Mixin builds pull
    the floating release available at build time rather than an immutable pin.
- **Antigravity Settings:**
  - `~/.gemini/antigravity-cli/settings.json` contains `{"enableTerminalSandbox": false}`
    to disable inner bwrap sandboxing inside the container.

---

## Kit Composition & Building

In `sbx 0.50.1`, image and kit builds occur automatically as part of `sbx create`
(there is no standalone `sbx kit build` subcommand). When `--kit` and the workload path
are passed to `sbx create`, the host daemon builds and composes the workload and mixin
layers automatically.

---

## Task Sandbox Lifecycle Management (`sandbox/task.py`)

Per-task Sandboxes and their persistence records are managed using standard
library Python and native `sbx` commands via `sandbox/task.py`. State is
stored in caller-provided JSON task records outside the repository.

### Key Lifecycle Operations

- **Create a Task Sandbox (`task.py create`):**
  Provisions a task Sandbox using `sbx create --clone --skills off` and initializes
  the implementation branch at the exact resolved base commit:
  ```bash
  python3 sandbox/task.py create \
    --record /path/to/task-record.json \
    --task-id task-01 \
    --name task-01-sbx \
    --repo /path/to/host/repo \
    --base <BASE_REF_OR_SHA> \
    --branch task/feature-01 \
    --workload sandbox/kits/antigravity-workload \
    --mixin sandbox/kits/antigravity-mixin \
    [--bundle /path/to/dependency.bundle] \
    [--depends-on dep-task-id]
  ```
  Resolves base commit SHA in bare Git context, verifies branch name format,
  records guest paths, and reserves record file.

- **Query Status (`task.py status`):**
  ```bash
  python3 sandbox/task.py status --record /path/to/task-record.json [--json]
  ```
  Uses read-only `sbx ls --json` for stopped, missing, or mismatched sandboxes;
  **never** executes commands against stopped VMs, ensuring stopped sandboxes are
  not unintentionally awakened.

- **Resume Interrupted Sandbox (`task.py start`):**
  ```bash
  python3 sandbox/task.py start --record /path/to/task-record.json
  ```
  Resumes detached via `sbx run -d --name <name>`, verifies clone top-level path,
  base ancestry (`merge-base --is-ancestor`), and expected branch, preserving
  uncommitted dirty work without checkout or reset.

- **Preserve Task Work & State (`task.py preserve`):**
  ```bash
  python3 sandbox/task.py preserve \
    --record /path/to/task-record.json \
    --dest /path/to/host/destination \
    --quiesced
  ```
  Captures a complete verified snapshot of all Git refs, staged index changes,
  worktree files, and guest harness state. Strictly verified on the host with
  bare repo bundle fetch (`+refs/*:refs/*`), `git fsck --full --strict`, cached
  index reconstruction, and member SHA256 checksums without extracting untrusted files.

For complete CLI documentation, options, and JSON schemas, see [`sandbox/task.md`](task.md).

---

## Task Submission & Multi-Task Assembly (`sandbox/submit.py`)

The `sandbox/submit.py` script manages the preparation, designer acceptance, and
linear assembly of task submissions, ensuring that implementation checkpoints remain
outside the PR history while supporting multiple accepted task commits in one PR branch.

### Overview

1. **Prepare Submission Branch (`submit.py prepare`):** Validates clean tree, preflights
   ignored files via `git ls-files -z` and `git ls-tree -z`, creates the submission branch
   at base, and squashes reviewed checkpoints into staged changes matching the reviewed tree.
2. **Designer Commit in Same Checkout:** The designer inspects staged diffs, verifies all
   checks, and commits the single accepted task commit with Conventional Commits, body
   reasoning, and all contributor trailers (`Co-authored-by: <designer>`, `Co-authored-by: Antigravity (...)`).
3. **Accept Submission (`submit.py accept`):** Validates exactly one non-merge commit ahead
   of base whose tree equals the reviewed tree, binds evidence and dependencies, and writes
   an immutable accepted submission manifest.
4. **Multi-Task PR Assembly (`submit.py assemble`):** Validates that all declared dependency
   manifests precede in manifest order, fast-forwards matching parent commits, cherry-picks
   independent commits (preserving original author and message while generating a new committer
   and assembled SHA), stops on conflicts, and writes an assembly record mapping submitted SHAs
   to assembled SHAs.

For the canonical CLI syntax, invariants, schemas, and dependency ref-retention rules,
see [`sandbox/submit.md`](submit.md).

---

## Task Sandbox Clone & Implementation Workflow

The task sandbox workflow enforces:
**one task = one Docker Sandbox = one private clone/checkout = one accepted submission commit.**

### In-Guest Task Clone

- **Seeded Read-Only:** When `--clone` is specified, `sbx create` mounts the host
  source checkout read-only to seed the container clone. Native `sbx` requires a normal
  `.git` directory and rejects linked-worktree sources; the read-only main checkout is
  an allowed seed source, and a separate host task checkout is not required for guest-only
  tasks. No writable host workspace or host home directory is mounted.
- **Directly Writable on Task Branch:** Inside the sandbox, the private repository
  clone is directly writable on the assigned implementation branch (`task/...`).
  No nested guest worktrees are required.
- **Sequential Shared Checkout:** Host designer and guest implementer operate sequentially
  within the task clone checkout.
- **Stopped Status Safety:** Status queries (`task.py status`) strictly use
  read-only `sbx ls --json`; stopped sandboxes are never awakened by status checks.
- **Interruption and Resumption:** Interrupted runs leave dirty work preserved in
  the task sandbox. The sandbox can be resumed safely with `task.py start`, which
  boots the container if stopped and validates branch, clone path, and base ancestry.
  If setup fails before `guest_repo_path` is recorded (e.g. an initial exec timeout during
  provisioning), `start` cannot automatically resume; the record and VM are retained
  for manual inspection and initialization completion (no automatic retry).
- **Task Safety & Baseline Invariants:**
  - Check existing sandboxes, branches, and worktrees before opening another task environment.
  - Resume recorded task environments when continuing work rather than creating fresh branches from default.
  - Verify base ancestry and divergence (`git log <base>..<branch>`); explain unexpected divergence.
  - Don't stack a new feature branch on unmerged work without telling the operator.
- **Lifecycle Separation:** A task sandbox lives for the duration of that task.
  Automatic retirement requires an accepted submission, a fresh verified host export,
  and the identity and stopped-state checks in `sandbox/task.py retire`. Keep task
  sandboxes when requested by the operator. Registered host worktrees require separate
  approval before retiring both, and legacy project environments are excluded.

### Known Limitations

1. **Session Renewal:** Long-duration OAuth token renewal during uninterrupted background execution
   without container restart remains unverified.

---

## Load the reviewed agent instructions

After checking out the reviewed task branch in the private clone, link only
instructions and the shared delegate skill. Run these inside the Sandbox with
the clone as cwd, and only when the destination files do not already exist:

```sh
repo=$(pwd -P)
mkdir -p "$HOME/.codex" "$HOME/.gemini" "$HOME/.agents/skills"
ln -s "$repo/bin/dotfiles/.codex/AGENTS.md" "$HOME/.codex/AGENTS.md"
ln -s "$repo/bin/dotfiles/.codex/AGENTS.md" "$HOME/.gemini/AGENTS.md"
ln -s "$repo/bin/dotfiles/.gemini/GEMINI.md" "$HOME/.gemini/GEMINI.md"
ln -s "$repo/bin/dotfiles/.agents/skills/delegate" "$HOME/.agents/skills/delegate"
```

Preserve the kit's Codex proxy configuration and Antigravity OAuth/settings files.
Install project verification dependencies as needed under the external network policy;
these kits do not install every package from the host dotfiles installer.

## Sentinel Verification (Secret-Free)

Inside the sandbox container, verify that credentials and configurations contain
only proxy sentinels without printing secret values to the terminal or logs.

### Using the Python Validation Helper

The validation script `sandbox/kits/validate_credentials.py` checks `auth.json`,
`config.toml`, and `antigravity-oauth-token`. It requires Python >= 3.11, fails
closed on missing files or sentinel mismatches, and outputs strictly boolean flags:

```bash
python3 sandbox/kits/validate_credentials.py
```

Expected output:
```text
codex_auth_sentinel: True
codex_config_ok: True
antigravity_token_sentinel: True
all_sentinels_valid: True
```

> [!WARNING]
> Never inspect credential files with `cat`, `head`, `echo`, or substring searches.
> Use `validate_credentials.py` to confirm sentinels safely.

### GitHub Proxy Sentinel Verification

Verify that GitHub credentials inside the sandbox match only the documented proxy sentinel without printing token strings to logs or the terminal.

#### Host-Managed Dynamic GitHub Secret

Register the GitHub secret on the host for the named task sandbox.

```bash
sbx secret set github --sandbox my-task-sandbox \
  --command '"/mnt/c/Users/<username>/AppData/Local/Microsoft/WinGet/Links/op.exe" read "op://<vault>/<item>/<field>" --no-newline' \
  --refresh 55m
```

Replace the sandbox name and the 1Password placeholders. For a Windows
1Password CLI used from WSL, use the quoted absolute path to `op.exe`.
For a native Linux installation, use the absolute path to `op`. Keep the
executable, its dependencies and configuration, and the host temporary
directory outside writable guest mounts.
See [Docker's dynamic secret documentation](https://docs.docker.com/ai/sandboxes/configuration/credentials/#use-a-dynamic-secret-source).

The host resolves the command and caches the credential for 55 minutes
with this setting. The host 1Password CLI needs an authenticated session
and may request desktop approval during resolution or refresh.

The proxy attaches the host-managed PAT to GitHub API requests. Scope the
PAT to the required repositories and permissions. Use the sandbox's
public sentinel for `gh` so the PAT stays on the host.

#### Secret-Free Sentinel Check

Run an exact literal comparison that prints booleans only:

```bash
# Check GH_TOKEN environment variable in the current session
python3 -c 'import os; print("gh_token_sentinel_valid:", os.environ.get("GH_TOKEN") == "gho_sbxproxymanaged000000000000000000000")'

# Check gh CLI active token output
python3 -c 'import subprocess; tok = subprocess.check_output(["gh", "auth", "token"], text=True).strip(); print("gh_auth_token_sentinel_valid:", tok == "gho_sbxproxymanaged000000000000000000000")'
```

Both checks output strictly boolean status (`True` when proxy authentication is active).

#### Read-Only GitHub API Verification

Test read-only API access through the proxy:

```bash
gh api user
gh api repos/<owner>/<repo>
```

> [!NOTE]
> **Live Verification is Designer-Owned:**
> Live credential verification—including registering the host command secret, executing live GitHub API calls, and verifying that the public sentinel returns HTTP 401 when sent directly to GitHub without the proxy—is owned and performed by the designer. Implementer verification is restricted to mocked unit tests and static syntax/diff checks.

---

## Running Antigravity Inside the Sandbox

Inside the container, `agy` runs with inner sandboxing disabled via settings.
For standalone headless testing, pass full-access bypass flags:

```bash
agy --dangerously-skip-permissions --mode accept-edits -p "Implement task step..."
```

- `--dangerously-skip-permissions`: Bypasses confirmation prompts for shell commands and file edits.
- `--mode accept-edits`: Automatically accepts generated workspace changes.

### Sequential Delegation Runner Mode

For automated delegation loops inside the container, use the harness runner in `docker-sandbox` mode:

```bash
HARNESS_EXECUTION_MODE=docker-sandbox \
  [HARNESS_GIT_POLICY=strict|task-commits] \
  bin/dotfiles/.agents/skills/delegate/scripts/run-task.sh <step-dir> <workdir> [brief] [--resume-attempt <N>]
```

- **Sequential execution:** The designer and Antigravity (implementer) operate sequentially within the same task clone checkout (`$workdir`).
- **Automated full access:** The runner passes `--dangerously-skip-permissions` and `--settings '{"enableTerminalSandbox":false}'` and runs directly from `$workdir`.
- **Git policy and checkpoint commits:**
  - `HARNESS_GIT_POLICY=strict` (default): Antigravity must never stage or commit changes. The runner captures HEAD, symbolic branch, and index state before the model probe and implementation run, rejecting acceptance with `status: "GIT_STATE_MUTATED"` (nonzero exit) if any Git state changed.
  - `HARNESS_GIT_POLICY=task-commits` (explicit Docker opt-in): Antigravity is authorized to create linear checkpoint commits on the assigned task branch (`HARNESS_TASK_BRANCH`) from accepted base (`HARNESS_TASK_BASE`), using Conventional Commits and the runner's exact `Co-authored-by: Antigravity (...)` trailer. Checkpoint commits are unreviewed artifacts; successful completion requires clean tracked and untracked files.
- **Explicit deny precedence and verified live scope:**
  - Upstream documentation states that explicit `permissions.deny` rules take precedence over allow/proceed and skip-permissions.
  - Live non-mutating probes verified this: direct requests like `git commit --dry-run`, `git push --dry-run`, and `git merge -h` were denied before Git execution under full access (conversation `2fc0915a-ce16-450d-9bd9-58da6ae37872`).
  - However, command prefix matching is supplemental and NOT a hostile-agent boundary: a second live probe (`476beb63-0994-4fb4-84f6-269910815ef7`) showed `/usr/bin/git push --dry-run` and `git -C /tmp push --dry-run` executed outside any repo (exiting 128), while `timeout 5 git push --dry-run` was denied.
  - Container network policy allows egress to GitHub, cloud, and package hosts; deny strings are not an unbypassable external-write barrier.
- **Advisory locking:** The runner takes a nonblocking workdir flock (`git rev-parse --git-path harness.lock`) to prevent concurrent runner collisions across steps targeting the same workdir. Note that full-access container execution has permission to defeat advisory locks; locks protect against concurrent runner processes, not malicious processes.
- **External network policy:** Commands executed during verification follow the container's external network policy.

---

## Accidental-Host Guard & Environment Marker

The kits place a root-owned marker inside the container filesystem:
- Path: `/etc/agent-harness/docker-sandbox`
- Permissions: `0644`, owner `root:root` (UID 0, GID 0)

> [!NOTE]
> The actual `sbx` microVM rootfs has **NO `/.dockerenv`** file. Runner harnesses must not check or manufacture `/.dockerenv`.
> Instead, the runner accidental-host guard checks:
> 1. Nonempty environment variables: `SANDBOX_ID`, `SANDBOX_VM_ID`, and `SBX_AGENT`.
> 2. Existing, root-owned, non-symlink marker: `/etc/agent-harness/docker-sandbox`.
>
> This guard provides opt-in safety against accidental execution on the host development machine, not an isolation boundary against malicious processes.

---

## Preserving Task Work & Retirement

After task acceptance, the designer exports and verifies task state before
retirement.

### Point-in-Time Preservation via `sandbox/task.py preserve`

Run preservation from the host after development and agent processes stop.
Keep the VM running for the export:

```bash
python3 sandbox/task.py preserve \
  --record /path/to/task-record.json \
  --dest /path/to/host/preserved-task-01 \
  --quiesced
```

- **Complete Verified Snapshot:** Captures a full Git bundle (`--all HEAD`), staged binary patch, worktree archive (excluding `.git`), and guest harness state.
- **Host-Side Verification:**
  - Fetches the bundle into a temporary bare repository (`+refs/*:refs/*` and `HEAD`), verifying ref equality and running `git fsck --full --strict`.
  - Losslessly reconstructs and verifies the staged index cache using `GIT_INDEX_FILE` and `git apply --cached`.
  - Streams archive members into SHA256 checksums matching guest manifests without extracting untrusted files.
- **Failure Safety:** If verification fails or concurrent modification is detected, failure diagnostics and transferred files are retained with `verified: false`.
- **Receipt:** Writes an immutable `receipt.json` with `"verification_scope": "Verification covers this point in time; retirement always requires a fresh check and explicit authorization."`

### Retirement (`sandbox/task.py retire`)

The delegate workflow invokes `sandbox/task.py retire` automatically after acceptance
and fresh verified preservation when the task record and retirement journal have no
host worktree and the operator has not asked to keep the sandbox. Obtain separate
approval if the command would also remove a host worktree:

```bash
python3 sandbox/task.py retire \
  --record /path/to/task-record.json \
  --manifest /path/to/accepted-manifest.json \
  [--worktree /path/to/host/worktree]
```

- **Gated Cleanup:** Verifies accepted submission manifest, matching verified preservation receipt and artifact checksums, durable host branches at exact SHAs, and fresh quiesced guest state before destruction. Refuses initially stopped sandboxes lacking a journaled retirement stop, requiring resumption and re-preservation.
- **Atomic Preflight & Phase Journaling:** Preflights all destructive targets (sandbox and registered host worktree) before first removal; journals phases so partial failure can be retried without removing unrelated VMs or worktrees.
- **Targeted Non-Interactive Removal:** Quiesces the guest with `sbx stop`, verifies `stopped` status and exact sandbox ID, then removes the container with `sbx rm --force <sandbox-name>`. Using `--force` is safe and non-interactive because exact VM identity and stopped status are confirmed, and removal targets only the specific task sandbox (never `--all` or force-stopping running VMs).
- **Mandatory Branch Retention:** Preserves all branches; imports guest-only branches by fetching only the exact expected commit SHA from the verified bundle (never named refspecs), preventing wrong branch creation from stale bundle refs.
- **Worktree Safety & Recheck:** Removes registered clean host worktrees (`git worktree remove` without `--force` or pruning); cannot swap a previously registered worktree; rechecks worktree cleanliness and ignored files immediately before removal to guard against concurrent mutations between phases. Leaves main checkout, active cwd, and branches untouched.
- Interrupted tasks remain recorded and can be safely resumed with `python3 sandbox/task.py start --record ...`.
- Use the retirement helper so blocked checks and partial failures are recorded in the task record.
- Existing legacy project environments are not automatically deleted.
