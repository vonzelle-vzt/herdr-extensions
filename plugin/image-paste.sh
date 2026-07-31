#!/usr/bin/env bash
# image-paste.sh — put an image in front of the agent, from the clipboard or a file.
#
#   image-paste.sh                  clipboard image, else newest screenshot -> inject path
#   image-paste.sh <file>           use an explicit file (what a Finder drop gives you)
#   image-paste.sh --print [...]    resolve + stage, print the path, do NOT inject
#   image-paste.sh --clipboard-only skip the screenshot fallback: clipboard or nothing
#   image-paste.sh --prune [DAYS]   delete staged shots older than DAYS (default 14)
#
# WHY THIS IS PATH INJECTION AND NOT A CLIPBOARD BRIDGE. Terminals carry text, not image bytes, so
# there is no way to "paste a PNG" into a pane. But an agent reads image PATHS natively — so the
# whole problem reduces to getting a path onto the prompt line, which is plain text and works fully
# locally with the mouse UI intact. herdr's own image paste is --remote only for exactly this
# reason; this needs none of that machinery.
#
# The path is typed WITHOUT a trailing Enter, so you add your question before submitting. That is the
# difference between a tool and an annoyance.
#
# 🔴 PATH. herdr `[[keys.command]]` and plugin actions are exec'd by the herdr server, which launchd
# starts with PATH=/usr/bin:/bin:/usr/sbin:/sbin. Homebrew is invisible there, so pngpaste would
# never resolve and the binding would silently do nothing. Prepend explicitly.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-@@HERDR@@}"
PY=/usr/bin/python3
SHOT_DIR="$HOME/.vzt/shots"

note() { printf 'image-paste: %s\n' "$*" >&2; }

print_only=0
clipboard_only=0
watch_mode=0
probe_mode=0
args=()
for a in "$@"; do
  case "$a" in
    --print) print_only=1 ;;
    --clipboard-only) clipboard_only=1 ;;
    --watch) watch_mode=1 ;;
    --probe) probe_mode=1 ;;
    --prune)
      days="${2:-14}"
      [ -d "$SHOT_DIR" ] || { note "nothing to prune"; exit 0; }
      find "$SHOT_DIR" -maxdepth 1 -type f -name 'clip-*' -mtime "+$days" -delete 2>/dev/null
      note "pruned staged shots older than $days days"
      exit 0
      ;;
    *) args+=("$a") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

mkdir -p "$SHOT_DIR" 2>/dev/null || { note "cannot create $SHOT_DIR"; exit 1; }

# --- probe mode ---------------------------------------------------------------------------------
# Drag-and-drop of a FILE is handled by the terminal emulator, not by herdr and not by us: the
# terminal turns the drop into typed text (the POSIX path) and that text travels the normal input
# path. When a drop "does nothing", the useful question is therefore not what WE do with it but
# whether any bytes arrive at all -- and that is answerable only by looking.
#
# This prints every byte the pane receives, so a drop that produces nothing is distinguishable from
# a drop that produces a path something later discards. Guessing between those two has already
# wasted more time than the probe took to write.
if [ "$probe_mode" = 1 ]; then
  echo "Input probe — every byte this pane receives is printed below."
  echo
  echo "  Drag an image file onto this window now."
  echo "  Nothing at all appearing means the TERMINAL is not turning the drop into text,"
  echo "  and no plugin can fix that from inside. A path appearing means the drop works"
  echo "  and whatever consumes it is the thing to look at."
  echo
  echo "  Ctrl+C to stop."
  echo
  while IFS= read -r -n1 -s ch; do
    if [ -z "$ch" ]; then
      printf '  [newline]\n'
    else
      printf '%s' "$ch" | od -An -c | tr -s " " | sed "s/^ /  /"
    fi
  done
  exit 0
fi

# --- watch mode ---------------------------------------------------------------------------------
# WHY THIS EXISTS. herdr cannot receive a Finder drag-and-drop locally: its own config documents
# `remote_image_paste` as "only active in herdr --remote", and there is no local equivalent. So
# rather than explain that limitation to a user who just wants to send a picture, invert it --
# watch the folders images actually land in, and the moment a new one appears, type its path to
# the agent. Dragging the image to your Desktop becomes dragging it into the conversation.
#
# Polling, not fswatch: fswatch is a Homebrew binary that would be one more thing to install and
# one more thing to be missing under launchd PATH. A 2-second poll over three directories costs
# nothing and has no dependency.
if [ "$watch_mode" = 1 ]; then
  shot_loc="$(defaults read com.apple.screencapture location 2>/dev/null || true)"
  watch_dirs=""
  for d in "$shot_loc" "$HOME/Desktop" "$HOME/Downloads"; do
    [ -n "$d" ] && [ -d "$d" ] && watch_dirs="$watch_dirs
$d"
  done
  watch_dirs="$(printf '%s\n' "$watch_dirs" | grep -v "^$" | sort -u)"
  if [ -z "$watch_dirs" ]; then
    # Degrade, never refuse: a panel that exits the instant it opens shows the user nothing at all
    # and reads as a broken keybinding. Say which folders were looked for and stay put.
    echo "Images: nothing to watch."
    echo
    echo "Looked for the macOS screenshot folder, ~/Desktop and ~/Downloads; none of them exist."
    echo "Create one of those, or pass paths explicitly:  image-paste.sh <file>"
    exit 0
  fi

  echo "Watching for new images. Drop or save one into any of these and it goes to the agent:"
  printf '%s\n' "$watch_dirs" | sed "s|^|  |"
  echo
  echo "Ctrl+C to stop."
  echo "If a Finder drag-and-drop onto this window does nothing, run the probe to find out why:"
  echo "  herdr plugin action invoke paste-image --plugin herdr-extensions -- --probe"
  echo

  # Only files created AFTER the watcher starts. Without this marker the first tick would dump
  # every image already sitting on the Desktop into the conversation.
  marker="$(mktemp)"
  trap 'rm -f "$marker"' EXIT
  seen="$(mktemp)"
  trap 'rm -f "$marker" "$seen"' EXIT

  while :; do
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      find "$d" -maxdepth 1 -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \
        -o -iname "*.gif" -o -iname "*.webp" \) -newer "$marker" -print 2>/dev/null | while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -qxF "$f" "$seen" 2>/dev/null && continue
        printf '%s\n' "$f" >>"$seen"
        # Let a large file finish being written before handing over a truncated path.
        sleep 1
        if "$0" "$f" >/dev/null 2>&1; then
          echo "sent: $f"
        else
          echo "could not send: $f"
        fi
      done
    done <<WATCHEOF
$watch_dirs
WATCHEOF
    sleep 2
  done
fi

img=""

if [ $# -gt 0 ] && [ -f "$1" ]; then
  # An explicit file wins, and this is also the Finder-drop path: dropping a file on the terminal
  # inserts its path, so `image-paste.sh <that path>` is the same operation. Resolved to absolute so
  # the agent can open it regardless of its own cwd.
  img="$(cd "$(dirname "$1")" && printf '%s/%s' "$(pwd -P)" "$(basename "$1")")"
else
  stamp="$(date +%Y%m%d-%H%M%S)"
  # 1) An image sitting on the clipboard — Cmd+Ctrl+Shift+4, or any Copy Image.
  if command -v pngpaste >/dev/null 2>&1; then
    cand="$SHOT_DIR/clip-$stamp.png"
    if pngpaste "$cand" >/dev/null 2>&1 && [ -s "$cand" ]; then
      img="$cand"
    else
      rm -f "$cand"
    fi
  fi
  # 2) Otherwise the newest screenshot wherever macOS is configured to put them. Reading the real
  #    setting matters: plenty of people move captures off the Desktop, and hardcoding ~/Desktop
  #    makes the fallback quietly useless for them.
  if [ -z "$img" ] && [ "$clipboard_only" -eq 0 ]; then
    shot_dir="$(defaults read com.apple.screencapture location 2>/dev/null || true)"
    case "$shot_dir" in
      "" | *"does not exist"*) shot_dir="$HOME/Desktop" ;;
    esac
    shot_dir="${shot_dir/#\~/$HOME}"
    if [ -d "$shot_dir" ]; then
      newest="$(find "$shot_dir" -maxdepth 1 -type f \
                \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) \
                -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
      [ -n "$newest" ] && [ -f "$newest" ] && img="$newest"
    fi
  fi
fi

if [ -z "$img" ]; then
  if [ "$clipboard_only" -eq 1 ]; then
    note "no image on the clipboard"
  elif command -v pngpaste >/dev/null 2>&1; then
    note "no image on the clipboard and no screenshot found"
  else
    note "pngpaste is not installed, so the clipboard cannot be read (brew install pngpaste)"
  fi
  exit 1
fi

if [ "$print_only" -eq 1 ]; then
  # Path on stdout, diagnostics on stderr, so `p=$(image-paste.sh --print)` is always clean. Callers
  # that do their own injection need this: a VS Code integrated terminal never delivers the paste
  # keystroke to a running TUI.
  printf '%s\n' "$img"
  exit 0
fi

# Choose the pane to type into. The focused pane is usually right, but focus is often parked on one
# of our own panels — the editor auto-opens focused with every new workspace — and typing a path
# into the file tree or the Problems list does nothing at all. So: the focused pane if it is not one
# of ours, else an agent pane as close to it as possible (same tab, then same workspace) before
# considering anywhere else. Jumping straight to "any agent" can drop a path into a live session in
# an unrelated project.
pane="$("$herdr_bin" pane list 2>/dev/null | "$PY" -c "
import sys, json
# DERIVED from the [[panes]] titles in herdr-plugin.toml at install time, never restated here.
# A hand-written copy went stale twice: it once named a Files panel that no longer existed while
# omitting Preview, which made the Preview pane a legal target for a pasted path, and it went stale
# again the moment the Spaces panel was added. Oracle 23d parses the same manifest and fails on any
# drift, so a restated list here is a gate failure rather than a silent hole.
PANELS = {@@PANEL_TITLES@@}
try:
    panes = json.load(sys.stdin)['result']['panes']
except Exception:
    sys.exit(0)

def usable(p):
    return (p.get('label') or '') not in PANELS

focused = next((p for p in panes if p.get('focused')), None)
pick = None
if focused and usable(focused):
    pick = focused
elif focused:
    for scope in ('tab_id', 'workspace_id'):
        pick = next((p for p in panes if usable(p) and p.get(scope) == focused.get(scope)), None)
        if pick:
            break
if pick is None:
    pick = next((p for p in panes if usable(p) and p.get('agent')), None)
print(pick['pane_id'] if pick else '')
" 2>/dev/null)"

if [ -z "$pane" ]; then
  note "no usable pane found; the path is: $img"
  exit 1
fi

# Trailing space, deliberately no Enter.
if "$herdr_bin" pane send-text "$pane" "$img " >/dev/null 2>&1; then
  note "-> $pane  $img"
else
  note "send-text failed; the path is: $img"
  exit 1
fi
