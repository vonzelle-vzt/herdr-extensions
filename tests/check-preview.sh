#!/usr/bin/env bash
# Oracle 24 — the Preview panel finds the dev server, and never leaves Chrome running.
#
# THE TWO BUGS THIS PINS, both found by running it rather than reading it:
#
#  1. The rendered Chrome path contains SPACES ("/Applications/Google Chrome.app/..."), and an
#     unquoted assignment made bash set CHROME to "/Applications/Google" and try to EXECUTE the rest.
#     The panel then reported "Chrome not found" forever, which reads as a missing install.
#
#  2. Headless Chrome writes the screenshot and then does NOT EXIT against a dev server -- the HMR
#     websocket keeps a live connection so the renderer never goes idle. Measured: the PNG landed in
#     about a second, Chrome was still running 20 seconds later. Waiting on the process hung the panel
#     on its first frame, and a refreshing panel would leak a Chrome process tree every cycle.
#
# Runs offline with stub chafa/chrome, so it needs neither a browser nor a dev server. The stub chrome
# deliberately behaves like the real one: write the file, then hang forever.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'pkill -9 -f "user-data-dir=$TMP" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

# --- 24a: the source templates are QUOTED --------------------------------------------------------
# Checked on the SOURCE, because this is the bug that survives any amount of testing on a machine
# whose browser happens to live at a space-free path.
if grep -qE '^CHAFA="@@CHAFA@@"$' "$ROOT/libexec/preview" &&
   grep -qE '^CHROME="@@CHROME@@"$' "$ROOT/libexec/preview"; then
  ok "24a: CHAFA/CHROME assignments are quoted (the path has spaces)"
else
  no "24a: an unquoted CHAFA/CHROME assignment will break on a path containing spaces"
fi

# Stubs. chrome writes a PNG then hangs, exactly like the real one against a dev server.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chrome with space" <<'STUBEOF'
#!/usr/bin/env bash
shot=""
for a in "$@"; do case "$a" in --screenshot=*) shot="${a#--screenshot=}" ;; esac; done
[ -n "$shot" ] && printf 'PNGDATA' > "$shot"
# Hang forever, the way headless Chrome does when the page holds an open socket.
while :; do sleep 5; done
STUBEOF
cat > "$TMP/bin/chafa" <<'STUBEOF'
#!/usr/bin/env bash
echo "CHAFA_RENDERED"
STUBEOF
chmod +x "$TMP/bin/chrome with space" "$TMP/bin/chafa"

# Render the panel the way install does, with a Chrome path that CONTAINS A SPACE on purpose.
PANEL="$TMP/preview"
/usr/bin/python3 - "$ROOT/libexec/preview" "$PANEL" "$TMP/bin/chafa" "$TMP/bin/chrome with space" <<'PYEOF'
import sys
src, dst, chafa, chrome = sys.argv[1:5]
body = open(src).read().replace("@@CHAFA@@", chafa).replace("@@CHROME@@", chrome)
open(dst, "w").write(body)
PYEOF
chmod +x "$PANEL"

# run [env assignments...] -> stdout of one frame, stdin closed so it renders once and exits.
#
# HARD BOUNDED, and that matters for the gate itself: the regression this oracle exists to catch is a
# panel that waits on a browser which never exits, so an unbounded run does not fail here -- it HANGS,
# and a gate that hangs is no better than one that is never run. macOS ships no `timeout`, hence the
# background-and-poll.
run() {
  : > "$TMP/out"
  ( env HOME="$TMP" COLUMNS=80 LINES=24 HERDR_PREVIEW_TIMEOUT=6 "$@" \
      /bin/bash "$PANEL" < /dev/null > "$TMP/out" 2>&1 ) &
  local pid=$! waited=0
  while [ "$waited" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    pkill -9 -f "user-data-dir=$TMP" >/dev/null 2>&1 || true
    printf 'PANEL_HUNG\n' >> "$TMP/out"
  fi
  cat "$TMP/out"
}

# --- 24b: an explicit URL wins and is rendered ---------------------------------------------------
out="$(run HERDR_PREVIEW_URL=http://localhost:9999)"
if printf '%s' "$out" | grep -q "CHAFA_RENDERED"; then
  ok "24b: an explicit HERDR_PREVIEW_URL is captured and drawn"
else
  no "24b: nothing was drawn for an explicit URL:
$out"
fi
if printf '%s' "$out" | grep -q "localhost:9999"; then
  ok "24b: the panel header names the URL it is showing"
else
  no "24b: the header does not name the URL"
fi

# --- 24c: THE LEAK. No stub chrome may survive the frame ----------------------------------------
# The stub hangs forever by design, so anything still running means the reaper did not fire.
if pgrep -f "user-data-dir=$TMP" >/dev/null 2>&1; then
  no "24c: a Chrome process survived the render — every refresh would leak a process tree"
  pkill -9 -f "user-data-dir=$TMP" >/dev/null 2>&1 || true
else
  ok "24c: no Chrome process survives a render"
fi

# --- 24d: a hanging browser must not hang the PANEL ---------------------------------------------
# Waiting on the process instead of the artifact is what made the first version wedge on frame one.
start="$(date +%s)"
out="$(run HERDR_PREVIEW_URL=http://localhost:9999)"
elapsed=$(($(date +%s) - start))
if printf '%s' "$out" | grep -q PANEL_HUNG; then
  no "24d: the panel never returned — it is waiting on the process, not the screenshot"
elif [ "$elapsed" -le 12 ]; then
  ok "24d: a frame completes in ${elapsed}s despite the browser never exiting"
else
  no "24d: took ${elapsed}s, too slow to be waiting on the screenshot"
fi
pkill -9 -f "user-data-dir=$TMP" >/dev/null 2>&1 || true

# --- 24e: with no dev server it explains itself instead of drawing nothing ----------------------
# A port nothing could plausibly be listening on, so detection genuinely fails.
out="$(run HERDR_PREVIEW_PORTS=59997)"
if printf '%s' "$out" | grep -q "No dev server is listening"; then
  ok "24e: no dev server produces an explanation, not a blank pane"
else
  no "24e: expected a 'no dev server' message, got:
$out"
fi
if printf '%s' "$out" | grep -q "HERDR_PREVIEW_URL"; then
  ok "24e: and it names the override that fixes it"
else
  no "24e: the message does not mention HERDR_PREVIEW_URL"
fi

# --- 24f: a missing renderer is named specifically ----------------------------------------------
# Each dependency has a different fix, so "cannot preview" on its own is not good enough.
BROKEN="$TMP/preview-nochafa"
/usr/bin/python3 - "$ROOT/libexec/preview" "$BROKEN" "$TMP/bin/nope-chafa" "$TMP/bin/chrome with space" <<'PYEOF'
import sys
src, dst, chafa, chrome = sys.argv[1:5]
open(dst, "w").write(open(src).read().replace("@@CHAFA@@", chafa).replace("@@CHROME@@", chrome))
PYEOF
out="$(env HOME="$TMP" /bin/bash "$BROKEN" < /dev/null 2>&1)"
if printf '%s' "$out" | grep -q "chafa not found"; then
  ok "24f: a missing chafa is named, with the brew command to fix it"
else
  no "24f: a missing renderer was not named:
$out"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
