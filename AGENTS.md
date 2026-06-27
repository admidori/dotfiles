# Agent Instructions

This repository manages a personal CLI-native development environment.
Keep changes small, reversible, and easy to verify from a terminal.

## Repository Shape

- Tracked dotfiles live under `bin/dotfiles/`.
- Installer entry points live under `installer/`.
- `make install` installs packages, installs oh-my-zsh if missing, and links dotfiles.
- `make link` only refreshes symlinks.
- `make unlink` removes only symlinks managed by this repository.
- `make test` runs the installer in a clean Debian container.

## Change Rules

- Prefer editing tracked source files instead of generated files in `$HOME`.
- Do not commit secrets, tokens, shell history, runtime state, or machine-local caches.
- Do not vendor large third-party trees. The installer should fetch external tools when needed.
- Keep `.claude`, `.codex`, and other AI-tool configs scoped to reusable settings only.
- Preserve user data directories such as `~/.claude/projects`, histories, and local credentials.

## Git Safety

- Do not run destructive git commands such as `git reset --hard`, `git clean -fd`, or force pushes unless explicitly requested.
- Before deleting a branch, verify that its remote is gone and that useful commits are merged or intentionally preserved.
- Use focused commits. Each independent behavior change should have its own commit.

## Verification

- Run `make test` after installer or shell configuration changes when Docker is available.
- For smaller changes, at least run `zsh -n bin/dotfiles/.zshrc` and shellcheck relevant scripts when available.
- If a command cannot be run because a tool is missing or sandboxed, report that clearly.
