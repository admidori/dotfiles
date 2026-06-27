# Global Agent Instructions (shared base)

This is the cross-tool baseline read by every AI coding agent on this machine.
It happens to live in `~/.codex/AGENTS.md` because Codex reads only that path and
has no import mechanism; the same file is symlinked to `~/.gemini/AGENTS.md` and
imported by `~/.claude/CLAUDE.md`. Keep it tool-agnostic. Tool-specific behavior
belongs in each tool's own overlay (`CLAUDE.md`, `GEMINI.md`), and project-specific
rules belong in that repository's own `AGENTS.md`.

## Operator

- Solo developer working from a CLI-native, terminal-first environment (WSL2 + zsh + tmux).
- Converse in Japanese. Keep code, identifiers, commit messages, and docs in English
  unless a project clearly uses another convention.
- Bias toward small, reversible, terminal-verifiable changes over large speculative ones.

## Division of labor across agents

Three agents share this machine, each with a distinct lane. Stay in your lane and
hand off rather than overreaching; defer to the operator when a task clearly belongs
to another agent.

- **Codex — primary implementer.** Owns the bulk of CLI-native implementation: writing
  and editing code, running the build/test/run loop, and committing focused changes.
  This is the default executor for "make the change."
- **Claude — design, review, and advisory.** Owns architecture and implementation
  planning, reviewing Codex's commits/PRs, and discussing trade-offs and direction.
  Prefers plans, reviews, and targeted edits over large speculative implementation.
- **Antigravity — parallel experiments and prototypes.** Owns running several candidate
  approaches in parallel and building larger, UI- or browser-inclusive prototypes and
  exploratory spikes that exceed a single focused change.

Typical flow: Claude designs / advises → Codex implements and commits → Claude reviews
the commit or PR. Antigravity is pulled in for parallel exploration or big prototypes.

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
  - Codex → `Co-authored-by: Codex (<model>) <noreply@openai.com>` (e.g. `Codex (GPT-5.5)`)
  - Claude → `Co-authored-by: Claude (<model>) <noreply@anthropic.com>` (e.g. `Claude (Opus 4.8)`)
  - Antigravity → `Co-authored-by: Antigravity (<model>) <noreply@google.com>` (e.g. `Antigravity (Gemini 3.1 Pro)`)
- Put the trailer in the footer, separated from the body by a blank line.
- Claude Code appends its own versioned co-author trailer automatically; let it, and
  don't add a second Claude trailer.

## Git safety

- Never run destructive git commands (`git reset --hard`, `git clean -fd`, force pushes,
  history rewrites) unless explicitly asked.
- Don't commit or push unless asked. If on the default branch, create a branch first.
- Before deleting a branch, confirm its work is merged or intentionally preserved.

## Secrets and data

- Never commit secrets, tokens, credentials, shell history, runtime state, or caches.
- Preserve user data directories (auth, histories, project state, local databases).

## Verification and honesty

- Run the relevant build/lint/test before declaring work done; for shell scripts at
  least syntax-check (`zsh -n`, `bash -n`) and run `shellcheck` when available.
- Report outcomes faithfully: if tests fail, say so with the output; if a step was
  skipped or a tool was missing, say that. Don't claim success you haven't verified.

## Outward-facing and irreversible actions

- Confirm before doing things that are hard to undo or that leave this machine
  (publishing, sending, deleting, overwriting files you didn't create). Approval for
  one such action does not extend to the next.
