#!/bin/sh
# Bootstrap herdr-extensions without Homebrew:
#   curl -fsSL https://raw.githubusercontent.com/vonzelle-vzt/herdr-extensions/main/install.sh | sh
#
# Clones (or updates) the package into ~/.local/share/herdr-extensions and symlinks the CLI onto
# ~/.local/bin. Deliberately does NOT run `herdr-extensions install` for you — piping a script from the
# internet straight into a config-mutating installer is a bad habit to encourage. Run it yourself.
set -eu

REPO="${HERDR_EXTENSIONS_REPO:-https://github.com/vonzelle-vzt/herdr-extensions.git}"
DEST="${HERDR_EXTENSIONS_DIR:-$HOME/.local/share/herdr-extensions}"
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
ln -sf "$DEST/bin/herdr-extensions" "$BIN/herdr-extensions"
chmod +x "$DEST/bin/herdr-extensions" "$DEST/plugin/open-panel.sh" "$DEST/libexec/herdr-fmt" \
         "$DEST/tests/live-check.sh" "$DEST/tests/check-panels.sh" \
         "$DEST/tests/check-viability.sh" 2>/dev/null || true

echo
echo "installed: $BIN/herdr-extensions"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "NOTE: $BIN is not on your PATH — add it to your shell profile." ;;
esac
echo "next:  herdr-extensions install"
