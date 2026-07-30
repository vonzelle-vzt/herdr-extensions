#!/usr/bin/env bash
# Oracle 17 — the split-vs-tab decision comes from the FLOORS, never from the requested width.
#
# THE BUG THIS PINS. open-panel.sh asked "can I fit the requested 88 columns and still leave
# MIN_PEER?" before opening. On a 145-column terminal herdr keeps 36 for its sidebar, leaving 109
# to split: 109 - 88 = 21, under MIN_PEER, so the editor was sent to its own tab. But the clamp
# that runs after opening would have sized that same panel to MAX_FRAC of the split — 60 columns,
# leaving the agent 49 — a perfectly good side-by-side. The guard refused a layout on a number the
# code never actually uses, and did so for every split from MIN_COLS+MIN_PEER up to 131 columns.
#
# The guard now tests only what is genuinely non-negotiable: room for MIN_COLS + MIN_PEER. The
# requested width is a preference and belongs solely to the clamp (tests/check-sizing.py).
#
# Runs entirely offline. A stub on HERDR_BIN_PATH answers `pane list` / `pane edges` with a
# fabricated geometry and records every argv the launcher produced, so we can assert on the
# --placement it actually asked herdr for. Driven with /bin/bash on purpose: that is bash 3.2 on
# macOS, the same interpreter launchd gives the herdr server.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$ROOT/plugin/open-panel.sh"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

# Read the policy out of the launcher rather than restating it, so a retune moves this test too.
policy() { grep -m1 "^$1=" "$LAUNCHER" | cut -d= -f2 | awk '{print $1}'; }
MIN_COLS="$(policy MIN_COLS)"
MIN_PEER="$(policy MIN_PEER)"
if [ -z "$MIN_COLS" ] || [ -z "$MIN_PEER" ]; then
  echo "  could not read the geometry policy out of plugin/open-panel.sh" >&2
  exit 1
fi
SPLITTABLE=$((MIN_COLS + MIN_PEER))

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
LOG="$STUB_DIR/log"

cat > "$STUB_DIR/herdr" <<'STUBEOF'
#!/usr/bin/env bash
# Minimal herdr stand-in: log the call, answer the three queries the launcher makes.
echo "$*" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list")
    printf '{"result":{"panes":[{"pane_id":"wT:p1","tab_id":"wT:t1","focused":true,"cwd":"%s","foreground_cwd":"%s"}]},"type":"pane_list"}' \
      "$HERDR_STUB_CWD" "$HERDR_STUB_CWD"
    ;;
  "pane edges")
    printf '{"result":{"edges":{"layout":{"area":{"height":50,"width":%s,"x":36,"y":1},"panes":[{"pane_id":"wT:p1","rect":{"height":50,"width":%s,"x":36,"y":1}}],"splits":[]}},"pane_id":"wT:p1"},"type":"pane_edges"}' \
      "$HERDR_STUB_WIDTH" "$HERDR_STUB_WIDTH"
    ;;
  "plugin pane")
    printf '{"result":{"plugin_pane":{"pane":{"pane_id":"wT:p9"}}},"type":"plugin_pane"}'
    ;;
esac
exit 0
STUBEOF
chmod +x "$STUB_DIR/herdr"

# Returns the placement the launcher asked herdr for: "split" or "tab".
placement_for() {
  width="$1"; shift
  : > "$LOG"
  HERDR_BIN_PATH="$STUB_DIR/herdr" HERDR_STUB_LOG="$LOG" HERDR_STUB_WIDTH="$width" \
  HERDR_STUB_CWD="$ROOT" HERDR_PANE_ID="wT:p1" HERDR_PLUGIN_CONTEXT_JSON="" \
    /bin/bash "$LAUNCHER" "$@" >/dev/null 2>&1
  grep -o -- "--placement [a-z]*" "$LOG" | head -1 | awk '{print $2}'
}

# The editor action exactly as the manifest invokes it: 88 preferred columns, split to the right.
editor_at() { placement_for "$1" editor Edit split right key yes 88; }

# --- 17a: the regression — a 109-column split hosts the editor side by side ----------------------
got="$(editor_at 109)"
if [ "$got" = "split" ]; then
  ok "17a: 109 cols -> split (was tab: 109 - 88 = 21 < MIN_PEER $MIN_PEER)"
else
  no "17a: 109 cols -> ${got:-<none>}, expected split"
fi

# --- 17b: the decision boundary is MIN_COLS + MIN_PEER, to the column -------------------------
got="$(editor_at "$((SPLITTABLE - 1))")"
if [ "$got" = "tab" ]; then
  ok "17b: $((SPLITTABLE - 1)) cols -> tab (one under the $SPLITTABLE floor)"
else
  no "17b: $((SPLITTABLE - 1)) cols -> ${got:-<none>}, expected tab"
fi
got="$(editor_at "$SPLITTABLE")"
if [ "$got" = "split" ]; then
  ok "17b: $SPLITTABLE cols -> split (exactly MIN_COLS $MIN_COLS + MIN_PEER $MIN_PEER)"
else
  no "17b: $SPLITTABLE cols -> ${got:-<none>}, expected split"
fi

# --- 17c: the whole band the old guard rejected is now usable ------------------------------------
# 88 preferred + 44 peer = 132, so every width from SPLITTABLE to 131 used to fall back to a tab.
band_fail=""
for width in $(seq "$SPLITTABLE" 131); do
  [ "$(editor_at "$width")" = "split" ] || band_fail="$band_fail $width"
done
if [ -z "$band_fail" ]; then
  ok "17c: every width $SPLITTABLE..131 splits (the band the raw-88 test threw away)"
else
  no "17c: still falling back to a tab at:$band_fail"
fi

# --- 17d: a genuinely impossible split still becomes a tab --------------------------------------
# The case the guard was written for: a 105-column window, 36 to the sidebar, 69 left to split.
got="$(editor_at 69)"
if [ "$got" = "tab" ]; then
  ok "17d: 69 cols -> tab (the original motivating case still falls back)"
else
  no "17d: 69 cols -> ${got:-<none>}, expected tab"
fi

# --- 17e: the guard is scoped — it must not divert the bottom panels ----------------------------
# Those are direction=down with a fractional size; columns are the wrong unit and there is no tab
# variant to fall back to. A narrow terminal must still get its Problems panel.
got="$(placement_for 40 problems Problems split down key no 0.35)"
if [ "$got" = "split" ]; then
  ok "17e: a fractional bottom panel splits even at 40 cols (guard does not apply)"
else
  no "17e: bottom panel at 40 cols -> ${got:-<none>}, expected split"
fi

# --- 17f: only the editor has a tab variant to fall back to -------------------------------------
# A column-sized rightward panel that is NOT the editor must never be rewritten to editor-tab —
# that would name a pane the manifest does not have, and herdr would open nothing at all.
: > "$LOG"
placement_for 60 git Git split right key no 88 >/dev/null
if grep -q "editor-tab" "$LOG"; then
  no "17f: a non-editor entrypoint was rewritten to editor-tab"
else
  ok "17f: a non-editor entrypoint is never rewritten to editor-tab"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
