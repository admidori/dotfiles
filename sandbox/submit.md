# Task Submission and Multi-Task Assembly CLI (`sandbox/submit.py`)

The `sandbox/submit.py` script manages the preparation, designer acceptance, and linear
assembly of task submissions, ensuring that implementation checkpoints remain outside
the PR history while supporting multiple accepted task commits in one reviewed PR branch.

All state is tracked via validated JSON records stored outside the repository.

---

## Separation of Concepts

- **PR (Pull Request)**: The unit of integration into the main branch. A PR branch contains one or more accepted task submission commits.
- **Task**: The unit of isolation and delegation (`one task = one Sandbox = one private clone/checkout = one accepted submission commit`).
- **Step / Attempt**: The unit of per-run delegation within a task (`brief.md` -> `agy -p` run -> `report-<n>.md` -> `review-<n>.md`). Sized for a single agent session.
- **Implementation Checkpoints vs. Submission Commit**: In Docker Sandbox mode with `HARNESS_GIT_POLICY=task-commits`, Antigravity creates linear checkpoint commits on the assigned task branch. When the task is complete and verified, all checkpoints are squashed to a single accepted task submission commit on a clean submission branch at the task base.

---

## Subcommands

### 1. `prepare`

Prepares a clean submission branch from a reviewed implementation commit in the same checkout, squashing implementation checkpoints into a staged tree matching the reviewed tree without committing.

```bash
python3 sandbox/submit.py prepare \
  --repo /path/to/repo \
  --task-id task-01 \
  --base <BASE_SHA> \
  --reviewed-sha <REVIEWED_SHA> \
  --submission-branch submit/task-01 \
  --output /path/to/candidate-task-01.json \
  --implementation-branch task/feature-01 \
  [--dependency dep-task-00:<DEP_SHA>] \
  [--dependency-manifest /path/to/dep-manifest.json]
```

**Invariants & Behavior:**
- Preflights the working tree: requires clean index and working tree, correct checked-out implementation branch, and that target submission branch does not already exist.
- Validates that `--base` is an ancestor of `--reviewed-sha` (`git merge-base --is-ancestor`), and that the diff between base and reviewed SHA is non-empty.
- Preflights existing ignored files against candidate commits using NUL-delimited `git ls-files --others --ignored --exclude-standard -z` and `git ls-tree -r --name-only -z <commit>` to prevent data loss or collision across branch switch and squash.
- Validates declared dependencies: verifies dependency SHAs are present in the base commit's ancestry (`git merge-base --is-ancestor`).
- Reserves the output candidate record file path before mutating any Git state (`FileExistsError` if candidate file exists).
- Switches to a new submission branch at `--base` (`git checkout -b <submission-branch> <base>`) and performs a squash-merge of the reviewed commit (`git merge --squash <reviewed-sha>`) without committing.
- Verifies that the resulting staged write-tree (`git write-tree`) exactly matches the tree of `--reviewed-sha`.
- On failure, preserves staged or conflicted state for diagnosis without rollback, recording `status: "incomplete"` in the candidate record.

---

### 2. Designer Commit (Manual Step in Same Checkout)

Between `prepare` and `accept`, the designer inspects the staged diff, verifies all changes, and creates the single accepted task commit in the same repository checkout:

```bash
# In the repository on the submission branch:
git diff --cached
# Verify tests / linters ...
git commit -m "feat(scope): concise description

Detailed body explaining what changed, why, and architectural decisions.

Co-authored-by: Designer (<model>) <noreply@...>
Co-authored-by: Antigravity (<model>) <noreply@google.com>"
```

**Requirements:**
- Follows Conventional Commits with an imperative summary header and descriptive body.
- Preserves all contributor trailers: the designer's trailer and Antigravity's trailer.
- Leaves the working tree and index clean.

---

### 3. `accept`

Validates the designer commit on the submission branch and records an immutable accepted submission manifest.

```bash
python3 sandbox/submit.py accept \
  --candidate /path/to/candidate-task-01.json \
  --output /path/to/manifest-task-01.json \
  --accepted \
  --verification-evidence "<evidence-reference-or-summary>" \
  [--repo /path/to/repo]
```

**Invariants & Behavior:**
- Validates the candidate record (`status: "prepared"`). Note: `accept` does not mark the candidate record consumed or prevent accepting it to a new output path; only overwriting an existing output manifest is prohibited (`FileExistsError`).
- Verifies that the repository is on the expected submission branch and the working tree is clean.
- Verifies that the submission branch has exactly one commit ahead of the base commit, that this commit is not a merge commit, and that its parent is the exact base commit SHA.
- Verifies that the accepted commit's tree matches the reviewed implementation tree from the candidate record.
- Validates parent, tree, commit message, and evidence bindings (it does not validate author or committer fields).
- Requires `--accepted` flag and non-empty `--verification-evidence`. Recorded evidence references or describes the verification basis; the manifest does not attest to or re-execute the verification itself.
- Writes the accepted submission manifest to `--output` with `0600` permissions and companion advisory lock. Refuses overwrite of existing manifests.

---

### 4. `assemble`

Assembles multiple accepted task submissions onto a new PR integration branch in dependency order.

```bash
python3 sandbox/submit.py assemble \
  --repo /path/to/clean-integration-repo \
  --base <BASE_SHA> \
  --branch pr/feature-complete \
  --manifests /path/to/manifest-01.json /path/to/manifest-02.json ... \
  --output /path/to/assembly-record.json
```

**Invariants & Behavior:**
- Validates the assembly repository: requires a clean working tree and that the PR branch does not already exist.
- Validates the dependency chain: ALL declared dependency manifests must precede in the input list (`manifest_paths`); there is no implicit exemption for dependencies that are ancestors of the assembly base commit.
- Verifies each manifest: checks that the recorded submission commit exists in the repo and has the expected parent, tree, and message bindings.
- Applies commits in order:
  - If the submission commit's parent equals current HEAD, fast-forwards directly (`git merge --ff-only`).
  - Otherwise, cherry-picks the commit (`git cherry-pick`). Cherry-picking preserves the original commit author and message, but creates a new committer and new assembled commit SHA.
- Stops immediately on any cherry-pick conflict or error, preserving the inspectable state without silent rollback.
- Writes an assembly record to `--output` mapping original submitted SHAs to assembled SHAs and application method (`fast-forward` or `cherry-pick`). The assembly record does not record tree SHAs.
- Designer runs final combined tests on the assembled PR branch before requesting operator approval for push.

---

## Dependency Management & Ref Retention

- **Independent Tasks:** Base is the integration branch HEAD. Can be worked on in parallel.
- **Dependent Tasks:** Base is the accepted submission commit of the prerequisite task.
- **Bundle Import and Ref Retention:**
  When passing a predecessor bundle to `task.py create --bundle <path>`, `task.py` fetches the base commit to seed the clone. However, it does not create persistent branch/tag refs for every checkpoint in the bundle.
  To ensure reviewed dependency objects and intermediate checkpoints remain reachable and survive subsequent `--all` preservation across multiple handoffs, explicitly import ALL bundle refs into a fresh namespace in the guest repository:
  ```bash
  git fetch /path/to/dependency.bundle 'refs/*:refs/dependencies/<dep-task-id>/*'
  ```
  (No force flag is needed when importing into a fresh namespace). These Git commit objects must be present in the repository object database for submission manifest validation. No automatic synchronization across sandboxes is implied.
- **Prerequisite Ancestry:**
  `submit.py prepare` strictly validates that all declared dependencies are present in the task's base ancestry (`git merge-base --is-ancestor`). If a task has multiple independent prerequisite tips, selecting one does not include the others; an explicit integration strategy must resolve the common base before preparation.
