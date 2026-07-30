#!/usr/bin/env bash
# Oracle 23 — image paste resolves the right image and types it into the right pane.
#
# WHY THE PANE CHOICE IS THE INTERESTING PART. Typing a path is trivial; typing it into the pane the
# user is actually talking to is not. Focus is very often parked on one of our own panels — the editor
# auto-opens focused with every new workspace — and a path typed into the file tree or the Problems
# list does nothing at all, silently. The fallback also must not wander: dropping a path into a live
# agent session in an unrelated project is worse than doing nothing.
#
# Runs entirely offline. A stub on HERDR_BIN_PATH answers `pane list` with a fabricated layout and
# records every `send-text`, so the target pane is asserted rather than assumed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/log"

# Render the launcher the way install does — the repo copy still holds the @@HERDR@@ template.
SCRIPT="$TMP/image-paste.sh"
/usr/bin/python3 - "$ROOT/plugin/image-paste.sh" "$SCRIPT" "$TMP/herdr" <<'PYEOF'
import sys
src, dst, herdr = sys.argv[1:4]
open(dst, "w").write(open(src).read().replace("@@HERDR@@", herdr))
PYEOF
chmod +x "$SCRIPT"

cat > "$TMP/herdr" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list") printf '%s' "$HERDR_STUB_PANES" ;;
esac
exit 0
STUBEOF
chmod +x "$TMP/herdr"

# A tiny valid PNG, so "is this a real image" never depends on the machine's clipboard.
IMG="$TMP/shot.png"
/usr/bin/python3 - "$IMG" <<'PYEOF'
import struct, sys, zlib
def chunk(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
w = h = 4
raw = b"".join(b"\x00" + b"\x10\x20\x30" * w for _ in range(h))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw))
       + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
PYEOF

run() { # run <panes-json> [args...] -> prints the pane that received the path
  : > "$LOG"
  HERDR_BIN_PATH="$TMP/herdr" HERDR_STUB_LOG="$LOG" HERDR_STUB_PANES="$1" \
    /bin/bash "$SCRIPT" "${@:2}" >/dev/null 2>&1
  grep -o "pane send-text [^ ]*" "$LOG" | head -1 | awk '{print $3}'
}

panes() { # panes <focused-label> — a workspace with one agent and one of our panels
  printf '{"result":{"panes":[{"pane_id":"wT:p1","tab_id":"wT:t1","workspace_id":"wT","agent":"claude","focused":%s},{"pane_id":"wT:p2","tab_id":"wT:t1","workspace_id":"wT","label":"Edit","focused":%s}]},"type":"pane_list"}' \
    "$([ "$1" = agent ] && echo true || echo false)" \
    "$([ "$1" = Edit ] && echo true || echo false)"
}

# --- 23a: an absolute path is printed for an explicit file (the Finder-drop path) ----------------
got="$(HERDR_BIN_PATH="$TMP/herdr" HERDR_STUB_LOG="$LOG" HERDR_STUB_PANES="$(panes agent)" \
        /bin/bash "$SCRIPT" --print "$IMG" 2>/dev/null)"
# Compare RESOLVED paths. On macOS $TMPDIR lives under /var, a symlink to /private/var, and the
# script uses `pwd -P` on purpose: a resolved absolute path is the one an agent can always open.
# Comparing the raw strings fails on a correct result.
real() { /usr/bin/python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1"; }
IMG_REAL="$(real "$IMG")"
if [ "$(real "$got")" = "$IMG_REAL" ]; then
  ok "23a: --print resolves an explicit file to its absolute path"
else
  no "23a: --print gave '${got:-<nothing>}', expected $IMG_REAL"
fi

# A relative path must still come back absolute, or the agent cannot open it from its own cwd.
rel_got="$(cd "$TMP" && HERDR_BIN_PATH="$TMP/herdr" HERDR_STUB_LOG="$LOG" \
            HERDR_STUB_PANES="$(panes agent)" /bin/bash "$SCRIPT" --print "shot.png" 2>/dev/null)"
case "$rel_got" in
  /*) ok "23a: a relative path is resolved to absolute ($rel_got)" ;;
  *)  no "23a: relative path stayed relative: '${rel_got:-<nothing>}'" ;;
esac

# --- 23b: the focused agent pane receives the path ----------------------------------------------
got="$(run "$(panes agent)" "$IMG")"
if [ "$got" = "wT:p1" ]; then
  ok "23b: a focused agent pane receives the path"
else
  no "23b: path went to '${got:-<nothing>}', expected wT:p1"
fi

# --- 23c: focus parked on one of OUR panels falls back to the agent -----------------------------
# This is the real-world case: the editor auto-opens focused, so the agent is not focused at all.
got="$(run "$(panes Edit)" "$IMG")"
if [ "$got" = "wT:p1" ]; then
  ok "23c: focus on the Edit panel still delivers to the agent"
else
  no "23c: path went to '${got:-<nothing>}', expected the agent wT:p1"
fi

# --- 23d: every panel label is excluded, not just the editor ------------------------------------
bad_labels=""
for label in Git Problems Search TODO Debug Blame Markdown Tests Files; do
  p="$(printf '{"result":{"panes":[{"pane_id":"wT:p1","tab_id":"wT:t1","workspace_id":"wT","agent":"claude","focused":false},{"pane_id":"wT:p2","tab_id":"wT:t1","workspace_id":"wT","label":"%s","focused":true}]},"type":"pane_list"}' "$label")"
  [ "$(run "$p" "$IMG")" = "wT:p1" ] || bad_labels="$bad_labels $label"
done
if [ -z "$bad_labels" ]; then
  ok "23d: all panel labels are excluded as injection targets"
else
  no "23d: a path would be typed into:$bad_labels"
fi

# --- 23e: the fallback prefers the SAME TAB over a stranger elsewhere ---------------------------
# Dropping a path into a live agent in an unrelated project is worse than doing nothing.
two_ws='{"result":{"panes":[
{"pane_id":"other:p1","tab_id":"other:t1","workspace_id":"other","agent":"claude","focused":false},
{"pane_id":"wT:p1","tab_id":"wT:t1","workspace_id":"wT","agent":"claude","focused":false},
{"pane_id":"wT:p2","tab_id":"wT:t1","workspace_id":"wT","label":"Edit","focused":true}]},"type":"pane_list"}'
got="$(run "$two_ws" "$IMG")"
if [ "$got" = "wT:p1" ]; then
  ok "23e: the fallback stays in the focused pane's own tab"
else
  no "23e: path went to '${got:-<nothing>}', expected the same-tab agent wT:p1"
fi

# --- 23f: no Enter is sent, so you can add your question ----------------------------------------
: > "$LOG"
HERDR_BIN_PATH="$TMP/herdr" HERDR_STUB_LOG="$LOG" HERDR_STUB_PANES="$(panes agent)" \
  /bin/bash "$SCRIPT" "$IMG" >/dev/null 2>&1
if grep -q "send-keys" "$LOG"; then
  no "23f: something sent a keypress — the path must not be submitted"
else
  ok "23f: the path is typed without submitting it"
fi
# ...and with a trailing space, so the next word does not run into the filename.
if grep -q "send-text wT:p1 .*shot.png $" "$LOG" || grep -qE "shot\.png $" "$LOG"; then
  ok "23f: a trailing space separates the path from your question"
else
  no "23f: no trailing space after the path"
fi

# --- 23g: --clipboard-only NEVER falls back to a screenshot -------------------------------------
# A deliberate keypress may reach for the last screenshot; a "paste THIS" that silently pastes
# something else is astonishing. So the contract is "never the fallback", and that is what is asserted.
#
# NOT asserted by emptying the clipboard or hiding pngpaste. An earlier version set PATH=/usr/bin:/bin
# to hide it, which never worked -- the script prepends Homebrew to PATH itself, correctly, so the real
# pngpaste was always found. That version passed only while the machine's clipboard happened to hold no
# image, and broke the moment one did: an environment-dependent oracle, which is worse than none.
mkdir -p "$TMP/Desktop"
FALLBACK="$TMP/Desktop/screenshot-fallback.png"
cp "$IMG" "$FALLBACK"
: > "$LOG"
got="$(HERDR_BIN_PATH="$TMP/herdr" HERDR_STUB_LOG="$LOG" HERDR_STUB_PANES="$(panes agent)" \
        HOME="$TMP" /bin/bash "$SCRIPT" --print --clipboard-only 2>/dev/null || true)"
if [ "$got" = "$FALLBACK" ]; then
  no "23g: --clipboard-only fell back to a screenshot ($got)"
elif [ -z "$got" ]; then
  ok "23g: --clipboard-only refuses outright when the clipboard holds no image"
else
  ok "23g: --clipboard-only used the clipboard, never the screenshot fallback"
fi

# ...and WITHOUT the flag the fallback is allowed, which is what makes the flag meaningful. Only
# checked when the clipboard is empty of images, since a real clipboard image legitimately wins.
if [ -z "$got" ]; then
  got2="$(HERDR_BIN_PATH="$TMP/herdr" HERDR_STUB_LOG="$LOG" HERDR_STUB_PANES="$(panes agent)" \
           HOME="$TMP" /bin/bash "$SCRIPT" --print 2>/dev/null || true)"
  if [ "$got2" = "$FALLBACK" ]; then
    ok "23g: without the flag it does fall back to the newest screenshot"
  else
    no "23g: expected the screenshot fallback, got '${got2:-<nothing>}'"
  fi
else
  ok "23g: fallback case skipped — a real clipboard image is present"
fi

# --- 23h: --prune deletes only old staged shots ------------------------------------------------
export HOME="$TMP/home"
mkdir -p "$HOME/.vzt/shots"
touch "$HOME/.vzt/shots/clip-old.png" "$HOME/.vzt/shots/clip-new.png" "$HOME/.vzt/shots/keep.txt"
touch -t 202001010000 "$HOME/.vzt/shots/clip-old.png"
HERDR_BIN_PATH="$TMP/herdr" HERDR_STUB_LOG="$LOG" /bin/bash "$SCRIPT" --prune 14 >/dev/null 2>&1
missing_old=0; [ -f "$HOME/.vzt/shots/clip-old.png" ] || missing_old=1
kept_new=0;   [ -f "$HOME/.vzt/shots/clip-new.png" ] && kept_new=1
kept_other=0; [ -f "$HOME/.vzt/shots/keep.txt" ] && kept_other=1
if [ "$missing_old" = 1 ] && [ "$kept_new" = 1 ] && [ "$kept_other" = 1 ]; then
  ok "23h: --prune removes old clips, keeps recent ones and touches nothing else"
else
  no "23h: prune wrong (old_gone=$missing_old new_kept=$kept_new other_kept=$kept_other)"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
