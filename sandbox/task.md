# Task Sandbox Lifecycle CLI (`sandbox/task.py`)

The `sandbox/task.py` script manages the lifecycle of per-task Docker Sandboxes
and their persistence records, using standard library Python and native `sbx`
commands.

State is stored in caller-provided JSON task records outside the repository.

---

## Subcommands

### 1. `create`

Provisions a task Sandbox using native `sbx create --clone --skills off` and
initializes the implementation branch at the exact resolved base commit.

```bash
python3 sandbox/task.py create \
  --record /path/to/task-record.json \
  --task-id task-01 \
  --name task-01-sbx \
  --repo /path/to/host/repo \
  --base HEAD \
  --branch task/feature-branch \
  --workload sandbox/kits/antigravity-workload \
  --mixin sandbox/kits/antigravity-mixin \
  [--bundle /path/to/dependency.bundle] \
  [--depends-on dep-task-id] \
  [--harness-path /home/agent/.local/state/agent-harness/task-01] \
  [--cpus 2] \
  [--memory 4g]
```

**Invariants & Behavior:**
- Resolves `--base` ref or SHA to an exact 40-character hex commit SHA in a
  temporary bare Git context (supporting HEAD-only and ancestor bundles) before
  provisioning.
- Validates branch name using `git check-ref-format --branch`, rejecting control
  characters, options, and master/main.
- Rejects existing branch refs in host repo or guest clone before any mutation
  (uses validated new branch creation, not `checkout -B`).
- Refuses if the record file already exists (`FileExistsError`).
- Refuses if a sandbox with the same name already exists in `sbx ls` (never
  adopts an existing VM).
- Protects concurrent operations on the same record using advisory file locking
  (`fcntl.flock`).
- Requires host repo to be a normal Git repository with a `.git` directory;
  rejects linked worktrees (where `.git` is a file).
- Records observed guest working directory, Git clone repository path, and guest
  harness path.
- Requires explicit task-scoped guest harness path when provided; removes implicit
  whole-harness selection (no default to `/home/agent/.local/state/agent-harness`,
  and rejects the whole-harness root).
- Validates that guest harness path is absolute, canonical, and mutually disjoint
  from the guest repository path.
- In case of failure during setup, retains the record with `status: "failed"`
  and `last_error` for diagnosis; never deletes the sandbox VM.

---

### 2. `status`

Queries the task record and compares it against live `sbx ls --json`.

```bash
python3 sandbox/task.py status --record /path/to/task-record.json [--json]
```

**Invariants & Behavior:**
- Uses read-only `sbx ls --json` for stopped, missing, or mismatched sandboxes;
  **never** runs `sbx exec` or `sbx cp` against stopped/missing VMs or when
  identity mismatches.
- Separates task lifecycle state (`provisioning`, `ready`, `running`, `preserved`,
  `failed`) from VM runtime state (`running`, `stopped`, `missing`).
- Reports identity and status mismatches; never calls unknown/lost state completed.
- Only when running with matching identity, queries current HEAD branch and
  commit via `sbx exec`.

---

### 3. `start`

Explicitly resumes an existing recorded sandbox that has stopped.

```bash
python3 sandbox/task.py start --record /path/to/task-record.json
```

**Invariants & Behavior:**
- Requires a known, non-empty `sandbox_id` in the record and strictly verifies
  sandbox identity against observed `sbx ls` metadata. Refuses resumption on
  mismatch.
- Resumes detached via `sbx run -d --name <name>`.
- Validates the private repository clone top-level path, base commit ancestry
  (`merge-base --is-ancestor`), and expected branch.
- If the guest repository is on an unexpected branch, refuses with an error
  rather than performing a reset or checkout.
- Preserves dirty work: validates `git status` without running checkout or reset.

---

### 4. `preserve`

Captures a complete verified snapshot of all Git refs, staged index changes,
repository working tree files, and guest harness state.

```bash
python3 sandbox/task.py preserve \
  --record /path/to/task-record.json \
  --dest /path/to/host/destination \
  --quiesced \
  [--harness-path /home/agent/.local/state/agent-harness/task-01]
```

**Invariants & Behavior:**
- Requires explicit `--quiesced` confirmation from the caller, asserting that
  development and agent processes are stopped.
- Requires the sandbox to be running with verified matching identity; performs
  no implicit start.
- Requires an explicit task harness path in the task record or passed via `--harness-path`.
  Removes implicit whole-harness selection (no fallback to `/home/agent/.local/state/agent-harness`).
- Validates guest harness existence and real guest path inside the sandbox (`check_real_guest_harness`),
  rejecting repository/staging overlap including symlink aliases, and fails before
  destination creation when selection is absent or invalid.
- Requires `--dest` to be an exclusively newly created private directory outside
  the host source repo (`0700` permissions); refuses pre-existing directories even
  if empty (`FileExistsError`).
- Rejects unmerged index conflict states (`git ls-files -u`) before preservation.
- Generates guest staging using unique `mktemp -d /tmp/preserve.XXXXXX`.
- Captures lossless NUL-delimited index records via `git ls-files -z --stage`,
  splitting metadata from path at the first TAB only to preserve exact filenames
  with repeated spaces, tabs, newlines, and non-ASCII characters without quoting distortion.
- Captures full manifest BEFORE archive creation (HEAD commit/ref, all raw refs via
  `for-each-ref`, lossless index stage entries, worktree manifest with SHA256/modes/types/symlink
  targets, and guest harness manifest).
- Propagates directory scanning errors immediately (`onerror=raise`) and detects
  unsupported special files (FIFOs, sockets, character/block devices).
- Creates a full Git bundle (`--all HEAD`), captures binary staged changes via
  `git diff --cached --binary --full-index --output=<stage>/staged.patch HEAD`, and
  creates compressed archives for worktree (using anchored `--exclude=./.git`) and
  harness.
- Captures snapshot AFTER archive creation and verifies equality with initial snapshot.
- Verifies transferred SHA256 checksums match guest checksums for bundle, staged patch,
  worktree tar, and harness tar.
- Verifies the bundle on the host in a temporary bare repository:
  - Fetches `+refs/*:refs/*` and `HEAD` (into `FETCH_HEAD`, preventing collision with
    any real branch named `BUNDLE_HEAD`).
  - Verifies raw ref equality without `^{commit}` peeling (supporting annotated tags,
    tree tags, and blob tags).
  - Runs `git fsck --full --strict`.
  - Reconstructs and verifies the exact index stage in the bare repository using
    `GIT_INDEX_FILE`, `git read-tree FETCH_HEAD`, and `git apply --cached staged.patch`,
    comparing exact entries parsed losslessly via `ls-files -z --stage`.
- Verifies archive completeness on the host without extracting untrusted files:
  - Streams each file member chunked into SHA256 and checks against manifest hash
    (detecting same-size corrupted contents).
  - Verifies member permission modes (`mode & 0o777`).
  - Rejects duplicate member names, absolute paths (`/`), and traversal paths (`..`).
- Captures a final snapshot AFTER all transfers and host artifact checks and compares
  with the initial snapshot before issuing a verified receipt. Any concurrent modification
  during transfer or verification fails preservation.
- On failure, retains transferred data, diagnostic manifests (`manifest_before.json`,
  `manifest_after.json`), and guest staging directory, writing failure `receipt.json`
  (with `verified: false`, `guest_stage`, and `error`); cleans up staging ONLY on verified success.
- States in `receipt.json` and task records:
  `"verification_scope": "Verification covers this point in time; retirement always requires a fresh check and explicit authorization."`
- Writes verified receipt (`receipt.json`), `manifest_before.json`, and
  `manifest_after.json` in destination with `0600` permissions.

---

## JSON Task Record Schema

```json
{
  "schema_version": 1,
  "task_id": "task-01",
  "sandbox_name": "task-01-sbx",
  "sandbox_id": "sbx-uuid-001",
  "host_repo": "/home/user/repo",
  "base_ref": "HEAD",
  "base_commit": "1d64a6c6c1024cc6f7565655fc4bef1d0f94d9d2",
  "branch": "task/feature-01",
  "workload_path": "/home/user/repo/sandbox/kits/antigravity-workload",
  "mixin_path": "/home/user/repo/sandbox/kits/antigravity-mixin",
  "cpus": 2,
  "memory": "4g",
  "dependency_bundle": null,
  "dependency_task_ids": [],
  "guest_cwd": "/home/agent",
  "guest_repo_path": "/home/user/repo",
  "guest_harness_path": "/home/agent/.local/state/agent-harness/task-01",
  "status": "ready",
  "created_at": "2026-11-05T12:00:00Z",
  "updated_at": "2026-11-05T12:00:00Z",
  "preservations": [
    {
      "timestamp": "2026-11-05T12:30:00Z",
      "verified": true,
      "destination": "/tmp/preserved",
      "verification_scope": "Verification covers this point in time; retirement always requires a fresh check and explicit authorization.",
      "bundle_sha256": "...",
      "staged_patch_sha256": "...",
      "worktree_sha256": "...",
      "harness_sha256": "...",
      "status": "verified"
    }
  ],
  "last_error": null
}
```

Task record files are created with `0600` permissions and companion `.lock` files
for synchronization.
