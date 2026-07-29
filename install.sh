#!/bin/sh
# Bootstrap herdr-tools without Homebrew:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/herdr-tools/main/install.sh | sh
#
# Clones (or updates) the package into ~/.local/share/herdr-tools and symlinks the CLI onto
# ~/.local/bin. Deliberately does NOT run `herdr-tools install` for you — piping a script from the
# internet straight into a config-mutating installer is a bad habit to encourage. Run it yourself.
set -eu

REPO="${HERDR_TOOLS_REPO:-https://github.com/OWNER/herdr-tools.git}"
DEST="${HERDR_TOOLS_DIR:-$HOME/.local/share/herdr-tools}"
BIN="$HOME/.local/bin"

command -v git >/dev/null 2>&1 || { echo "git is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }

if [ -d "$DEST/.git" ]; then
  echo "updating $DEST"
  git -C "$DEST" pull --ff-only --quiet
else
  echo "cloning into $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --depth 1 --quiet "$REPO" "$DEST"
fi

mkdir -p "$BIN"
ln -sf "$DEST/bin/herdr-tools" "$BIN/herdr-tools"
chmod +x "$DEST/bin/herdr-tools" "$DEST/plugin/open-panel.sh" "$DEST/libexec/herdr-fmt" \
         "$DEST/tests/live-check.sh" 2>/dev/null || true

echo
echo "installed: $BIN/herdr-tools"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "NOTE: $BIN is not on your PATH — add it to your shell profile." ;;
esac
echo "next:  herdr-tools install"
