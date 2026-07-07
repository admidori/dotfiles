#!/usr/bin/env bash
#
# Create/update symlinks for AI tool configs only.
# Resolves its own location so it works via `make` or directly.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOTFILES_DIR="$REPO_ROOT/bin/dotfiles"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

echo "##########################"
echo "#  LINK AI TOOL CONFIGS  #"
echo "#       macOS only       #"
echo "##########################"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "note: link-ai is intended for macOS, continuing on $(uname -s)"
fi

for tool in "${TOOL_DIRS[@]}"; do
  link_dir_contents "$DOTFILES_DIR/$tool" "$HOME/$tool" "$tool"
done
