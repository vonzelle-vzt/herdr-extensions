#!/usr/bin/env bash
# Oracle — the Spaces panel lists herdr workspaces and acts on them (focus/rename/close) without
# ever closing the space it is running in, and without closing anything on an unconfirmed request.
#
# WHY THIS PANEL EXISTS. Right-click is the discoverable way to rename or close a herdr space, and
# it is UNRELIABLE on Terminal.app, which swallows Button3 -- the only paths left are keybindings
# nobody remembers (ctrl+b shift+w rename, ctrl+b shift+d close, ctrl+b w the picker). This absorbs
# that gap from outside herdr.
#
# WHY THE OWN-SPACE REFUSAL IS THE MOST IMPORTANT ASSERTION HERE. Closing a space takes its panes
# and any running agents with it. Closing the space THIS PANEL is running in would end the panel
# mid-action, and there would be nobody left to see the result of an operation that just deleted the
# surface showing it -- so that path must be refused outright, before any confirmation prompt, and
# must never reach `workspace close`.
#
# Runs entirely offline. A stub on HERDR_BIN_PATH answers `workspace list` / `pane list` with
# fabricated JSON and records every call it receives, so a close/rename is asserted on what the stub
# actually recorded -- never on the printed text, which could say the right thing and still not have
# called anything.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

SCRIPT="$ROOT/libexec/spaces"
if [ ! -f "$SCRIPT" ]; then
  no "libexec/spaces does not exist"
  echo
  echo "  $pass passed, $fail failed"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/log"

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/herdr" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list")      printf '%s' "$HERDR_STUB_PANES" ;;
  "workspace list") printf '%s' "$HERDR_STUB_WS" ;;
  "workspace rename") exit 0 ;;
  "workspace close")  exit 0 ;;
  "workspace focus")  exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB_BIN/herdr"

# Two spaces: #1 is the one the panel itself is running in (agent pane wA:p1, workspace wA);
# #2 ("Beta Project") is a normal second space with two panes.
WS='{"result":{"workspaces":[
  {"workspace_id":"wA","label":"Alpha","number":1,"pane_count":2,"tab_count":1,"agent_status":"idle","focused":true},
  {"workspace_id":"wB","label":"Beta Project","number":2,"pane_count":2,"tab_count":1,"agent_status":"none","focused":false}
]}}'
PANES='{"result":{"panes":[{"pane_id":"wA:p1","tab_id":"wA:t1","workspace_id":"wA","focused":true}]}}'
CONTEXT='{"workspace_id":"wA","focused_pane_id":"wA:p1"}'

REPO="$TMP/repo"
mkdir -p "$REPO"

# run <input-lines> [ws-json] [panes-json] [context] -> stdout captured in $TMP/out, stub calls in $LOG
run() {
  : > "$LOG"
  printf '%s\n' "$1" | \
    (cd "$REPO" && HOME="$TMP/home" PATH="$STUB_BIN:$PATH" HERDR_BIN_PATH=herdr \
     HERDR_STUB_LOG="$LOG" HERDR_STUB_WS="${2:-$WS}" HERDR_STUB_PANES="${3:-$PANES}" \
     HERDR_PLUGIN_CONTEXT_JSON="${4:-$CONTEXT}" \
     /bin/bash "$SCRIPT" >"$TMP/out" 2>&1)
}

# =================================================================================================
# (a) the list renders labels, numbers and the focused marker from the stubbed JSON
# =================================================================================================
run "q"
if grep -q "Alpha" "$TMP/out" && grep -q "Beta Project" "$TMP/out"; then
  ok "a) both space labels appear in the rendered list"
else
  no "a) a label is missing from the output: $(cat "$TMP/out")"
fi
if grep -q "^1 " "$TMP/out" && grep -q "^2 " "$TMP/out"; then
  ok "a) both space numbers appear as row leaders"
else
  no "a) a space number did not appear as a row leader -- output: $(cat "$TMP/out")"
fi
# The focused space (wA, number 1) must carry a visible marker; the unfocused one must not.
focused_line="$(grep "^1 " "$TMP/out")"
unfocused_line="$(grep "^2 " "$TMP/out")"
case "$focused_line" in
  *"*"*) ok "a) the focused space's row carries the focused marker" ;;
  *)     no "a) the focused space's row has no marker -- got: $focused_line" ;;
esac
case "$unfocused_line" in
  *"*"*) no "a) the UNFOCUSED space's row wrongly carries the focused marker -- got: $unfocused_line" ;;
  *)     ok "a) the unfocused space's row carries no focused marker" ;;
esac

# =================================================================================================
# (b) closing the panel's OWN space is refused -- before any confirmation, and it never reaches
#     `workspace close`. This is the single most important assertion in this suite.
# =================================================================================================
run "$(printf 'x 1\nq')"
if grep -q "workspace close" "$LOG"; then
  no "b) CLOSED ITS OWN SPACE -- workspace close was called for wA: $(cat "$LOG")"
else
  ok "b) refused to close its own space -- workspace close was never called"
fi
if grep -qi "refus" "$TMP/out"; then
  ok "b) the refusal is stated in the panel output"
else
  no "b) no refusal message found -- output: $(cat "$TMP/out")"
fi
# The refusal must fire without ever prompting for or accepting a confirmation line -- feeding what
# WOULD be a valid confirmation for space 2 right after "x 1" must not be swallowed as if it were
# read as that confirmation and then acted on for space 1.
run "$(printf 'x 1\nCLOSE Alpha\nq')"
if grep -q "workspace close" "$LOG"; then
  no "b) closing its own space with a matching confirmation line still closed it: $(cat "$LOG")"
else
  ok "b) even a matching confirmation line cannot close the panel's own space"
fi

# =================================================================================================
# (c) a close WITHOUT confirmation (of a DIFFERENT, safe-to-close space) never calls `workspace
#     close` -- asserted on the stub's own log, not on the printed text.
# =================================================================================================
run "$(printf 'x 2\nnot the confirmation\nq')"
if grep -q "workspace close" "$LOG"; then
  no "c) an unconfirmed close still called workspace close: $(cat "$LOG")"
else
  ok "c) an unconfirmed close never reaches workspace close"
fi

run "$(printf 'x 2\nq')"
if grep -q "workspace close" "$LOG"; then
  no "c) quitting instead of confirming still called workspace close: $(cat "$LOG")"
else
  ok "c) quitting at the confirmation prompt never reaches workspace close"
fi

# The correctly confirmed case DOES call it, so (c) is not passing by never calling close at all.
run "$(printf 'x 2\nCLOSE Beta Project\nq')"
if grep -q "workspace close wB" "$LOG"; then
  ok "c) a correctly confirmed close on a DIFFERENT space does call workspace close"
else
  no "c) a correctly confirmed close did not call workspace close -- log: $(cat "$LOG")"
fi

# =================================================================================================
# (d) a rename issues `workspace rename <id> <name>` with the name intact as ONE argument, tested
#     with a name that has a space in it -- the case a naive re-splitting would break.
# =================================================================================================
run "$(printf 'r 2\nNew Team Name\nq')"
if grep -q "workspace rename wB New Team Name" "$LOG"; then
  ok "d) rename issues workspace rename wB with the multi-word name intact"
else
  no "d) rename call malformed -- log: $(cat "$LOG")"
fi
if grep -qi "auto-open" "$TMP/out" || grep -qi "projects root" "$TMP/out"; then
  ok "d) the rename explains the auto-open/label-matching effect"
else
  no "d) rename succeeded but said nothing about the auto-open effect -- output: $(cat "$TMP/out")"
fi

# A blank new name cancels rather than renaming to an empty string.
run "$(printf 'r 2\n\nq')"
if grep -q "workspace rename" "$LOG"; then
  no "d) a blank new name still issued a rename -- log: $(cat "$LOG")"
else
  ok "d) a blank new name cancels the rename"
fi

# =================================================================================================
# (e) the panel survives herdr being unreachable -- prints something honest, exits 0
# =================================================================================================
: > "$LOG"
printf '' | (cd "$REPO" && HOME="$TMP/home" HERDR_BIN_PATH="$TMP/does-not-exist-herdr" \
             /bin/bash "$SCRIPT" >"$TMP/out3" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "e) exits 0 when herdr is unreachable"
else
  no "e) exited $rc when herdr is unreachable (should still be 0)"
fi
if grep -qi "could not reach herdr\|unreachable\|failed" "$TMP/out3"; then
  ok "e) prints an honest message when herdr is unreachable"
else
  no "e) no honest message on an unreachable herdr -- output: $(cat "$TMP/out3")"
fi
if grep -qE 'active: *[0-9]+:' "$TMP/out3"; then
  no "e) the unreachable-herdr path shows the empty-payload regression (active: N:)"
else
  ok "e) no sign of the active.json empty-payload regression when herdr is unreachable"
fi

# Also survives an empty workspace list (herdr reachable, nothing to show) without erroring.
: > "$LOG"
printf '' | (cd "$REPO" && HOME="$TMP/home" PATH="$STUB_BIN:$PATH" HERDR_BIN_PATH=herdr \
             HERDR_STUB_LOG="$LOG" HERDR_STUB_WS='{"result":{"workspaces":[]}}' HERDR_STUB_PANES="$PANES" \
             /bin/bash "$SCRIPT" >"$TMP/out4" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "e) exits 0 on an empty workspace list"
else
  no "e) exited $rc on an empty workspace list"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
