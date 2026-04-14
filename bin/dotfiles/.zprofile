export PATH=/usr/local/texlive/2025/bin/x86_64-linux:$PATH

# Load local environment variables that should not be tracked by Git.
ZPROFILE_SOURCE="${(%):-%N}"
if command -v readlink >/dev/null 2>&1; then
  ZPROFILE_SOURCE="$(readlink -f "$ZPROFILE_SOURCE" 2>/dev/null || printf '%s' "$ZPROFILE_SOURCE")"
fi
ZPROFILE_SOURCE_DIR="$(cd "$(dirname "$ZPROFILE_SOURCE")" && pwd)"
if [ -f "$ZPROFILE_SOURCE_DIR/.zprofile.local" ]; then
  . "$ZPROFILE_SOURCE_DIR/.zprofile.local"
fi
unset ZPROFILE_SOURCE
unset ZPROFILE_SOURCE_DIR
