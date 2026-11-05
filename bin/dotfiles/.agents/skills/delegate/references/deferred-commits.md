# Deferred commits

Use this workflow as an exception when commits are deferred—such as when the
operator explicitly requests deferral or stricter repository constraints
temporarily block local commits. (By default, the designer commits accepted
steps under standing authorization, or Antigravity creates linear checkpoint
commits when opted into `HARNESS_GIT_POLICY=task-commits` in Docker Sandbox mode.)
Keep checkpoints outside the project repository, alongside the harness.

## Distinction from Task Checkpoint Commits

In Docker Sandbox mode with `HARNESS_GIT_POLICY=task-commits`, Antigravity is
authorized to create linear checkpoint commits directly on the assigned task branch.
Those checkpoint commits are unreviewed implementation artifacts. At task completion,
the designer uses `sandbox/submit.py prepare` and `sandbox/submit.py accept` to
squash the checkpoints into a single accepted task submission commit on a clean
submission branch at base.

In contrast, this deferred-commits workflow is an exception procedure used only
when no commits may be created on Git branches at all (such as when the operator
explicitly requests deferring all commits, or under temporary repository constraints
in host or strict mode).

## Preserve each step

1. Before the first run, record the exact base commit and a reproducible
   initial tree. The worktree must contain no unrelated changes.
2. After accepting each step, save its complete resulting tree or a
   lossless delta from the preceding accepted checkpoint. Include added,
   modified, and deleted files, binary content, symlinks, and executable
   modes. Include new source files even though Git still calls them
   untracked; exclude `.git`, secrets, caches, and runtime artifacts.
3. Record the checkpoint location, base/predecessor, and content manifest
   in `review-<n>.md`, together with verification results and any pending
   checks. Record the step's implementer attribution from `metrics.jsonl`.
4. Review the next step against that checkpoint, including deletions and
   additions. A cumulative HEAD diff cannot isolate a later step.

Accepted checkpoints are immutable. If a later step corrects earlier
work, record that correction in its review and preserve it as a focused
correction checkpoint when it is independent of the current step. Do not
hide it by changing an earlier checkpoint or replacing all checkpoints
with the final tree.

## When deferral ends: finalizing deferred work

Resume committing under applicable standing authorization once blocking
constraints are resolved, or once explicit operator permission is received if
the operator had specifically withheld commit authority. Operator-withheld
commit authority must be respected until released.

Do not silently alter approved task grouping on resume:

- **Approved Docker Sandbox task workflow (`one task = one Docker Sandbox = one accepted submission commit`):**
  Deferral preserves step review evidence across steps without creating commits. When deferral ends:
  1. If the tree was deferred without checkpoint commits and `sandbox/submit.py prepare` requires a reviewed commit SHA, record a reviewed checkpoint commit on the assigned task branch in the task clone.
  2. In the same clone (no second publication worktree is mandatory), run `sandbox/submit.py prepare` to squash the reviewed checkpoint to a clean submission branch at base.
  3. The designer inspects the staged diff, verifies all work, writes the single accepted task commit with all contributor trailers, and accepts the submission via `sandbox/submit.py accept`.
- **Legacy host / strict workflows (`one commit per accepted step`):**
  1. Confirm the authorization scope and record a mapping from accepted steps and corrections to planned commits.
  2. Reconstruct the checkpoints in dependency order from the recorded base in a dedicated worktree (a fresh publication worktree may be used if needed to preserve the final implementation tree during reconstruction).
  3. Apply the same review, fix, and verification gate as live steps: inspect and re-verify each resulting diff, ensuring review is complete, required fixes are done, and relevant checks pass. Then commit just that step with its reasoning and the required designer/implementer trailers. Record each SHA in the corresponding review. Keep unavailable checks explicit.
  4. Compare the reconstructed final tree with the accepted final checkpoint, including added/deleted files and modes; confirm no intended changes were lost or added. Confirm the publication worktree is clean.
- **In both workflows:**
  Publish only with explicit push/PR authorization (standing local commit authority never permits push or PR actions). Follow the skill's worktree close-out or task preservation procedure and report any worktree or sandbox retained.

If checkpoint reconstruction or task submission fails or the planned grouping must change,
show the affected steps, concrete diff, and proposed grouping to the
operator before committing. Never publish an unapproved combined fallback commit or
rewrite already published history without explicit authorization.
