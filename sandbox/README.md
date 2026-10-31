# Docker Sandbox Kits: Sequential Codex & Antigravity Delegation

This directory contains reusable Docker Sandbox Kit (specification schema v3)
descriptors and companion Dockerfiles to run Codex (as designer) and
Antigravity (as implementer) inside a persistent Sandbox per project.
Each task uses a dedicated Git worktree in the private clone; the designer
and implementer work sequentially in that task worktree.

## Table of Contents

- [Overview & Architecture](#overview--architecture)
- [Evidence Status: Prototype vs. Source Kits](#evidence-status-prototype-vs-source-kits)
- [Security Model & Isolation Boundary](#security-model--isolation-boundary)
- [Host Prerequisites & Keyring Unlock](#host-prerequisites--keyring-unlock)
- [Pre-Flight: Check Proxy Interception Before Any Login](#pre-flight-check-proxy-interception-before-any-login)
- [Kit Definitions](#kit-definitions)
- [Kit Composition & Building](#kit-composition--building)
- [Creating a Project Sandbox](#creating-a-project-sandbox)
- [Entering the Sandbox](#entering-the-sandbox)
- [Project Sandbox SSH Lifecycle](#project-sandbox-ssh-lifecycle)
- [Sentinel Verification (Secret-Free)](#sentinel-verification-secret-free)
- [Running Antigravity Inside the Sandbox](#running-antigravity-inside-the-sandbox)
- [Accidental-Host Guard & Environment Marker](#accidental-host-guard--environment-marker)
- [Preserving Work & Cleanup](#preserving-work--cleanup)

---

## Overview & Architecture

The delegation model pairs Codex and Antigravity (`agy`) in a serial workflow
inside one externally isolated container:

1. **Codex (Designer)** runs in the sandbox using an image-contained sentinel
   configuration and full access permissions. It explores the private clone,
   writes briefs, and orchestrates tasks.
2. **Antigravity (Implementer)** executes headlessly inside the same container
   to implement changes, without interactive permission prompts.
3. **Codex** inspects modified files, verifies changes, runs tests, and commits
   accepted work under standing authorization.

Both tools share the task worktree sequentially. Other tasks use separate
worktrees in the same project Sandbox; they are not security-isolated from
each other. No nested Sandbox is required.

---

## Evidence Status: Prototype vs. Source Kits

> [!IMPORTANT]
> **Prototype Verification vs. Final Source Checks**
>
> - **Live-Verified Prototype (`/tmp/auth-prototype`):** Tested on host `sbx 0.50.1`
>   in sandbox `codex-agy-v3-auth`. The minimal v3 descriptor composition passed
>   token-endpoint TLS handshakes and achieved sequential `AUTH_OK` inference calls
>   for both clients using sentinel-only credentials without browser logins.
> - **Final-source verification (2026-10-31, sbx 0.50.1):** Both persisted kits
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
- **Sentinel-Only In-Container Credentials:** Neither OpenAI API keys nor Google OAuth
  tokens exist inside the container. Tokens are fixed sentinel strings
  (`oai-oat01-proxy-managed`, `agy-oauth-access-proxy-managed`).
- **Host-Side Proxy Interception:** Outbound calls to OAuth endpoints and model APIs
  are intercepted by the host sbx proxy daemon (`passthrough: false`), which attaches
  host-managed credentials.
- **Scoped Network Policies:** Network access rules in the kit descriptors are strictly
  scoped to the known model providers and OAuth endpoints.
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
> Always verify the HTTPS_PROXY connection to both token endpoints before
> executing any authentication flow.

### Running the Preflight TLS Issuer Check

Inside the sandbox, run the provided executable preflight script before any agent
execution:

```bash
python3 sandbox/kits/check_proxy_tls.py
```

The script connects to `auth.openai.com:443` and `oauth2.googleapis.com:443` using
HTTP CONNECT through `HTTPS_PROXY` and Python's standard TLS verification, inspects the certificate issuers, and
prints only the issuer strings:

```text
auth.openai.com issuer: commonName=Docker Sandboxes Proxy CA, ...
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

### 1. Codex Workload (`sandbox/kits/codex-workload`)
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

## Creating a Project Sandbox

Create a fresh sandbox using `sbx create` (v0.50.1 syntax):

```sh
sbx create --name dotfiles-agy-dev --cpus 2 --memory 4g --skills off --clone \
  --kit ./sandbox/kits/antigravity-mixin ./sandbox/kits/codex-workload "$HOME/dotfiles"
```

### Options & Requirements:
- `--kit <path>`: The mixin directory; the workload is the first positional argument. The host kit
  paths must exist on the reviewed branch or worktree.
- `--clone`: Boolean flag indicating repository cloning. The clone source positional
  argument `"$HOME/dotfiles"` must be a normal checkout (host Git worktrees are
  unsupported as clone sources). The source checkout is mounted read-only by `sbx`
  to seed the container repository.
- `--skills off`: Disables the shared skills store.
- **First-Time Binding Prompts & OAuth Reuse:** When creating the sandbox, `sbx` detects
  the declared `openai` and `antigravity` credential requirements. If the host has
  existing active OAuth sessions, `sbx` prompts to bind the sandbox to those sessions,
  allowing seamless reuse without copying credentials into container layers.

---

The source checkout must contain the reviewed kit/helper/runner changes before ordinary
task use. Until merged, explicitly import the task branch into the private clone.
Do not run `make link` indiscriminately inside the sandbox: host-oriented Codex
configuration can overwrite the image-provided proxy configuration.

## Entering the Sandbox

Start and attach to the newly created sandbox:

```sh
# Start the sandbox container
sbx run --name dotfiles-agy-dev

# Attach an interactive shell inside the running sandbox
sbx exec -it dotfiles-agy-dev bash
```

---

## Project Sandbox SSH Lifecycle

Direct localhost SSH access to the project sandbox is managed via `sandbox/project-ssh.py`.
This enables external tools, IDEs, and the Windows host to connect securely to the
container's `agent` user without opening network exposure.

### Security Architecture

- **Host Loopback Exposure Only:** Binds strictly to `[::1]:PORT:2222/tcp6` on the WSL host.
  Wildcard (`0.0.0.0`) or external LAN listeners on the host are prohibited.
- **Guest Listener:** OpenSSH server listens on guest port `2222` inside the microVM.
- **Hardened Agent-Only Authentication:** Only public-key authentication for user `agent` is permitted
  (`UsePAM yes`, `AuthenticationMethods publickey`, `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AllowUsers agent`).
- **Forwarding Restrictions:** SSH agent forwarding (`AllowAgentForwarding no`) and X11 forwarding are disabled.
  Local-only TCP forwarding (`AllowTcpForwarding local`) is permitted for application tunneling including dynamic SOCKS forwarding; remote forwarding is denied.
- **Preflight & Ownership Safety:** Preflight port checks prevent overwriting configurations if an unmanaged listener already occupies port 2222.
- **Safe Runtime Environment Propagation:** Propagates only an approved allowlist of non-secret runtime variables
  (`PATH`, upper/lowercase proxy variables, CA bundle paths, `NODE_USE_ENV_PROXY`, sandbox identifiers,
  agent/credential mode sentinels) via a single combined `SetEnv` directive. Credential-bearing proxy URLs,
  newlines, and full environment dumps are strictly rejected with errors.
- **Host Key Generation at Runtime:** Host keys are generated on first runtime use inside the container
  (`ssh-keygen -A`) and preserved across runs. No private keys are baked into image layers or copied from host.
- **Transient Foreground Process & Dual Verification:** Held in foreground by a transient WSL systemd user unit
  (`systemd-run --user --unit=sbx-ssh-<name> --collect --property=Restart=no sbx exec ...`).
  Start boundedly verifies both systemd unit activation and guest listener readiness before declaring success.
  Explicit stop terminates the owned listener without killing arbitrary processes or restarting stopped sandboxes.

### CLI Commands

All commands require an existing sandbox and must be run from the host:

```bash
# 1. Start SSH listener for a sandbox (default host port: 40222)
python3 sandbox/project-ssh.py start dotfiles-agy-dev --public-key /mnt/c/Users/admidori/.ssh/id_ed25519_sbx_dotfiles.pub --port 40222

# 2. Query status (read-only; reports sbx status, unit status, and port mapping without starting stopped guests)
python3 sandbox/project-ssh.py status dotfiles-agy-dev --json

# 3. Stop SSH listener (terminates guest sshd, stops host systemd unit, and unpublishes port)
python3 sandbox/project-ssh.py stop dotfiles-agy-dev
```

### Windows Client Configuration (`~/.ssh/config`)

Under WSL with mirrored networking, direct connections from Windows to localhost IPv6 may fail
to route across the virtual network switch. Connect using the verified WSL netcat proxy command:

```ssh-config
Host sbx-dotfiles
    HostName 127.0.0.1
    Port 40222
    User agent
    IdentityFile ~/.ssh/id_ed25519_sbx_dotfiles
    IdentitiesOnly yes
    IdentityAgent none
    ForwardAgent no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    StrictHostKeyChecking yes
    UserKnownHostsFile ~/.ssh/known_hosts_sbx_dotfiles
    ProxyCommand C:/Windows/System32/wsl.exe -d Debian -- /usr/bin/nc -6 ::1 40222
```

### Host Key Verification & `known_hosts`

Upon running `project-ssh.py start`, the script prints the SHA256 fingerprints of the container's
generated host keys. Preserve the existing verified Windows alias and known_hosts entry.
For a new Sandbox, compare the public host key obtained through `sbx exec` with
these fingerprints and register it in the dedicated known_hosts file before
connecting with strict checking. The commands do not edit Windows SSH configuration.

```text
Host Key Fingerprints:
  - 256 SHA256:d8Q... root@sandbox (ED25519)
  - 256 SHA256:7uK... root@sandbox (ECDSA)
```

Never copy private host or client keys into the guest. Staging directories are ephemeral and
cleaned up automatically after public key installation.

### Explicit Stop Before Keyring Lock

Before locking the host session keyring or suspending the host, explicitly stop the SSH service
and the container:

```bash
python3 sandbox/project-ssh.py stop dotfiles-agy-dev
sbx stop dotfiles-agy-dev
```

- `project-ssh.py stop` leaves container data, branches, and worktrees intact.
- Stopping an already-stopped sandbox is idempotent and **never invokes `sbx exec`**, ensuring
  a stopped container is not unintentionally re-awakened.

### Project-Private Clone, Worktrees, and App Workflow

Use one persistent Sandbox per project, seeded by `sbx create --clone`. Create a
dedicated Git worktree for every task and review inside that private clone. Keep
the project base checkout available as the common read-only base, with the
management and approved-sync exceptions described in the shared baseline.
Worktrees prevent accidental edit collisions across tasks; full-access agents can still access other worktrees, so
worktrees do not provide security isolation from each other, and no nested
Sandbox is required.

#### App Project Configuration & Task Selection

- **Fixed App Project Root:** Keep the IDE or app project opened at the main
  project checkout (deployment example: `/home/admidori/dotfiles`). Do not
  prescribe changing or re-opening the app project root for every task.
- **Explicit Task Worktree Targeting:** While work on a task is active,
  explicitly select and target that task's dedicated worktree directory for terminal
  commands, editor focus, and runner `$workdir`.
- **Branch and Base Preflight:** Both manual worktree creation (`git worktree add`)
  and native app worktree creation require preflight verification before work
  starts. Run checks against the task path, using `git -C <task-worktree>`:
  inspect `rev-parse --show-toplevel`, `rev-parse --abbrev-ref HEAD`, and
  `rev-parse HEAD`. Choose the intended integration base explicitly when creating
  a worktree and compare a new worktree's HEAD with that starting commit.
  If native app creation leaves a detached HEAD, create a task feature branch
  there before editing. For continued work, reuse its existing worktree and
  check divergence from the integration branch; do not reset it to the base.
- **Git CLI as Source of Truth:** Run `git status --short`, `git diff`, and
  `git diff --cached` in that task worktree (or with `git -C <task-worktree>`)
  to establish the actual working tree and index state. Do not trust UI filter
  labels or staged/unstaged view indicators,
  which may report misleading status (such as displaying staged additions when
  `git diff --cached` is empty).

#### Task Completion vs. Project Sandbox Lifecycle

- **Task Completion:** When a task's work is finished, verified, and integrated
  or preserved, close only clean temporary worktrees. Never force-remove
  worktrees (`--force`). Before deleting a branch, confirm its commits are merged
  or intentionally preserved and applicable repository checks pass.
- **Persistent Sandbox Reuse:** Keep the project Sandbox running and reusable
  for subsequent tasks; do not destroy or recreate the container between tasks.
- **Sandbox Retirement:** Retiring or deleting a project Sandbox (`sbx rm`) is a
  separate, deliberate operation. Because container deletion destroys its internal
  filesystem including all task worktrees, export and verify all useful commits,
  uncommitted/untracked files, and harness records outside the container before
  removal.

### Known Limitations

1. **No Automatic Boot Enablement:** The SSH service is deliberately not configured as a persistent boot unit
   to ensure operator pauses are respected. After a WSL restart or reboot, unlock
   the keyring, run `project-ssh.py stop NAME` to clean up stale managed state, then
   run `start` again. A real WSL reboot has not been tested.
2. **Netcat Transport Dependency on Windows:** Windows SSH requires `ProxyCommand ... nc -6 ::1 <PORT>` due to
   WSL mirrored networking routing constraints.
3. **Session Renewal:** Long-duration OAuth token renewal during uninterrupted background execution
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
  bin/dotfiles/.agents/skills/delegate/scripts/run-task.sh <step-dir> <workdir> [brief] [--resume-attempt <N>]
```

- **Sequential execution:** Codex (designer) and Antigravity (implementer) operate sequentially within the same task worktree in the project-private clone. Pass that dedicated worktree as `$workdir`; the runner does not create it.
- **Automated full access:** The runner passes `--dangerously-skip-permissions` and `--settings '{"enableTerminalSandbox":false}'` and runs directly from `$workdir`.
- **Role separation & mutation detection:** Antigravity must never stage or commit changes. The runner captures HEAD, symbolic branch, and index state before the model probe and implementation run, rejecting acceptance with `status: "GIT_STATE_MUTATED"` (nonzero exit) if any Git state changed.
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

## Preserving Work & Cleanup

Project Sandboxes are persistent during normal use. Deleting one destroys its
internal filesystem, including every task worktree, so export and verify all
useful commits, uncommitted/untracked files, and harness records before removal.
Retiring a project Sandbox is a separate action from completing individual tasks:

### Handling Git Remotes under WSL Mirrored Networking

Under WSL with mirrored networking, fetching via git-daemon or localhost IPv4 from
the host may fail due to interface routing. Preserve commits using a Git bundle
created inside the container and copied to the host via `sbx cp`.
The example below exports one task's HEAD: repeat for every branch or commit
worth preserving and verify the imported commits on the host before deletion.
Bundles do not include uncommitted or untracked files; preserve those separately.
Run the Git commands inside the relevant task worktree.

1. **Inside the sandbox:** Create a bundle of your commits:
   ```bash
   # Bundle commits on the current branch
   git bundle create /tmp/dotfiles-task.bundle HEAD
   ```
2. **On the host:** Copy the bundle out and import it into a review branch:
   ```bash
   sbx cp dotfiles-agy-dev:/tmp/dotfiles-task.bundle /tmp/dotfiles-task.bundle
   # In the dedicated host review worktree:
   git fetch /tmp/dotfiles-task.bundle HEAD:codex/task-review
   ```
   This safely imports the changes on the host without forcing a working tree reset
   or pushing directly to default branches.

3. **Export harness state:**
   Export the harness transcripts and execution state outside the repository:
   ```bash
   sbx cp dotfiles-agy-dev:/home/agent/.local/state/agent-harness /host/destination/
   ```

4. **Delete the sandbox (retirement only):**
   ```bash
   sbx rm dotfiles-agy-dev
   ```
