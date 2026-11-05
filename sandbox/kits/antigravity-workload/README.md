# Antigravity Workload Kit (`sandbox/kits/antigravity-workload`)

Neutral Docker Sandbox workload for Antigravity (`agy`) execution based on `docker.io/sbx/shell-docker-image:latest`.

## Specification

- **Descriptor:** `antigravity-workload.yaml` (schema v3, `kind: workload`)
- **Base image:** `docker.io/sbx/shell-docker-image:latest`
- **Capabilities:**
  - `com.docker.sandbox/sbx@1`
- **Installed system utilities:** `python3`, `jq`, `util-linux` (`flock`, `setsid`), `coreutils` (`timeout`).
- **User & Workdir:** User `agent` (UID 1000), `WORKDIR /home/agent/workspace`.
- **Accidental host guard:** Root-owned `0644 /etc/agent-harness/docker-sandbox`.
- **Entrypoint:** `agy --dangerously-skip-permissions --settings '{"enableTerminalSandbox":false}'`

## Composition with `antigravity-mixin`

> [!IMPORTANT]
> The standalone workload image provides the base container OS, system tools, user environment, and entrypoint, but does **not** vendor or install `agy` itself.
>
> It must be composed with `sandbox/kits/antigravity-mixin`, which installs the official Antigravity CLI, provisions full-access settings, and configures proxy OAuth sentinels (`service: antigravity`) and network policy.

### Creating a Sandbox

For task-scoped sandboxes, `sandbox/task.py create` automates provisioning, clone seeding, base commit resolution, branch initialization, and lifecycle tracking (see [`sandbox/task.md`](../../task.md)):

```bash
python3 sandbox/task.py create \
  --record /path/to/task.json \
  --task-id task-01 \
  --name dotfiles-agy-task-01 \
  --repo "$HOME/dotfiles" \
  --base HEAD \
  --branch task/feature-01 \
  --workload ./sandbox/kits/antigravity-workload \
  --mixin ./sandbox/kits/antigravity-mixin
```

Alternatively, create a standalone sandbox manually using native `sbx`:

```bash
sbx create --name dotfiles-agy --cpus 2 --memory 4g --skills off --clone \
  --kit ./sandbox/kits/antigravity-mixin ./sandbox/kits/antigravity-workload "$HOME/dotfiles"
```

### Preflight TLS Check

Inside the sandbox, verify proxy TLS interception for Antigravity without contacting OpenAI:

```bash
python3 sandbox/kits/check_proxy_tls.py --service antigravity
```
