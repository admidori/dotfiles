# Deferred commits

Use this workflow as an exception when commits are deferred—such as when the
operator explicitly requests deferral or stricter repository constraints
temporarily block local commits. (By default, the designer commits accepted
steps under standing authorization.) Keep checkpoints outside the project
repository, alongside the harness.

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

## When deferral ends: committing deferred steps

Resume committing under applicable standing authorization once blocking
constraints are resolved, or once explicit operator permission is received if
the operator had specifically withheld commit authority.

1. Confirm the authorization scope and record a mapping from accepted
   steps and corrections to planned commits. A request to commit all work
   does not request one combined commit.
2. Reconstruct the checkpoints in dependency order from the recorded base
   in a dedicated worktree. Use a fresh publication worktree if it is
   needed to preserve the final implementation tree during reconstruction.
3. Apply the same review, fix, and verification gate as live steps: inspect
   and re-verify each resulting diff, ensuring review is complete, required
   fixes are done, and relevant checks pass. Then commit just that step with
   its reasoning and the required designer/implementer trailers. Record each
   SHA in the corresponding review. Keep unavailable checks explicit.
4. Compare the reconstructed final tree with the accepted final checkpoint,
   including added/deleted files and modes; confirm no intended changes
   were lost or added. Confirm the publication worktree is clean.
5. Publish only with explicit push/PR authorization (standing local commit
   authority never permits push or PR actions). Follow the skill's worktree
   close-out procedure and report any worktree retained.

If checkpoint reconstruction fails or the planned grouping must change,
show the affected steps, concrete diff, and proposed grouping to the
operator before committing. Never publish a combined fallback commit or
rewrite already published history without explicit authorization.
