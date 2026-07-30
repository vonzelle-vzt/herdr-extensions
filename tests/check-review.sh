#!/usr/bin/env bash
# Oracle — the Review panel sends accumulated file:line notes to the AGENT pane, never one of our
# own panels, and derives that exclusion set from the manifest instead of restating it.
#
# WHY THE PANE CHOICE IS THE INTERESTING PART, same reasoning as oracle 23 for image-paste: focus
# is very often parked on one of our own panels (the editor auto-opens focused with every new
# workspace, and the Review panel itself is a pane you are typing INTO), so "just use whatever is
# focused" would frequently mean "type the note into the Review panel's own transcript" — which
# goes nowhere. The fallback must also not wander past the current project: dropping a note into a
# live agent session in an unrelated tab/workspace is worse than doing nothing.
#
# Runs entirely offline. A stub on HERDR_BIN_PATH answers `pane list` with a fabricated layout and
# records every `send-text`, so the target pane is asserted rather than assumed. The panel's diff
# and baseline machinery is exercised against a real throwaway git repo so it never touches this
# checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

GIT=/usr/bin/git
PY=/usr/bin/python3

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/log"

# ---- render the panel the way install does: @@HERDR@@ -> a stub on PATH ------------------------
render_script() {  # render_script <src> <dst>
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
src, dst = sys.argv[1:3]
open(dst, "w").write(open(src).read().replace("@@HERDR@@", "herdr"))
PYEOF
  chmod +x "$2"
}

SCRIPT="$TMP/review"
render_script "$ROOT/libexec/review" "$SCRIPT"

# The manifest sits BESIDE the rendered script, exactly as render_plugin() lays out the installed
# plugin directory (herdr-plugin.toml and every PANEL_SCRIPTS entry are flat siblings there).
MANIFEST="$TMP/herdr-plugin.toml"
cat >"$MANIFEST" <<'EOF'
[[panes]]
id = "editor"
title = "Edit"

[[panes]]
id = "problems"
title = "Problems"

[[panes]]
id = "preview"
title = "Preview"

[[panes]]
id = "review"
title = "Review"

[[actions]]
id = "open-review"
title = "Not a pane title — must never be excluded"
EOF

mkdir -p "$TMP/home"

# Publish an active-file record naming the throwaway repo as its root — the panel's PRIMARY route
# to a repo, same contract blame/debug/todo already read. $PWD is only its last-resort fallback and
# is not this repo (herdr execs a plugin pane from the plugin directory, not the project), so the
# fixture is what actually drives repo resolution here.
STATE_HOME="$TMP/state"
mkdir -p "$STATE_HOME/spiceedit"
cat >"$STATE_HOME/spiceedit/active.json" <<EOF
{"file": "$TMP/repo/file.txt", "line": 1, "root": "$TMP/repo"}
EOF

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/herdr" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list") printf '%s' "$HERDR_STUB_PANES" ;;
esac
exit 0
STUBEOF
chmod +x "$STUB_BIN/herdr"

# ---- a throwaway git repo the panel's diff/baseline logic runs against -------------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
(
  cd "$REPO"
  "$GIT" init -q
  "$GIT" config user.email test@example.com
  "$GIT" config user.name test
  printf 'one\ntwo\nthree\n' >file.txt
  "$GIT" add file.txt
  "$GIT" commit -qm base
  "$GIT" branch -m main
  printf 'one\nTWO CHANGED\nthree\nfour\n' >file.txt
)

panes() {  # panes <focused-label> — one agent pane (wT:p1) and one of our panels (wT:p2), same tab
  printf '{"result":{"panes":[{"pane_id":"wT:p1","tab_id":"wT:t1","workspace_id":"wT","agent":"claude","focused":%s},{"pane_id":"wT:p2","tab_id":"wT:t1","workspace_id":"wT","label":"%s","focused":%s}]},"type":"pane_list"}' \
    "$([ "$1" = agent ] && echo true || echo false)" \
    "$2" \
    "$([ "$1" = panel ] && echo true || echo false)"
}

# run <input-lines> <panes-json> -> the log of everything the stub herdr saw
# $PWD is the panel's ONLY route to the repo when no active.json exists (a fresh $HOME here), so
# the panel is invoked FROM inside the throwaway repo, the same way herdr execs a pane in whatever
# directory `plugin pane open --cwd` picked.
run() {
  : > "$LOG"
  printf '%s\n' "$1" | \
    (cd "$REPO" && HOME="$TMP/home" XDG_STATE_HOME="$STATE_HOME" PATH="$STUB_BIN:$PATH" HERDR_BIN_PATH=herdr HERDR_STUB_LOG="$LOG" HERDR_STUB_PANES="$2" \
    /bin/bash "$SCRIPT" >"$TMP/out" 2>&1)
}

sent_pane() {  # sent_pane -> the pane_id the note landed in, from the last run's log
  grep -o "pane send-text [^ ]*" "$LOG" | tail -1 | awk '{print $3}'
}

# =================================================================================================
# (a) a note reaches the agent pane, never a panel pane, when the agent is focused
# =================================================================================================
run "$(printf 'file.txt:2 fix this comparison\ns\nq')" "$(panes agent Preview)"
got="$(sent_pane)"
if [ "$got" = "wT:p1" ]; then
  ok "a) a note typed while the agent is focused is sent to the agent pane"
else
  no "a) note went to '${got:-<nothing>}', expected the agent wT:p1"
fi
if grep -q "fix this comparison" "$LOG"; then
  ok "a) the sent message contains the note text"
else
  no "a) the sent message did not contain the note text -- log: $(cat "$LOG")"
fi

# =================================================================================================
# (b) a focused Review/Edit/Problems pane is skipped in favour of the agent
# =================================================================================================
for label in Review Edit Problems; do
  run "$(printf 'file.txt:3 needs a null check\ns\nq')" "$(panes panel "$label")"
  got="$(sent_pane)"
  if [ "$got" = "wT:p1" ]; then
    ok "b) focus on the $label panel still delivers the note to the agent"
  else
    no "b) with $label focused, note went to '${got:-<nothing>}', expected the agent wT:p1"
  fi
done

# =================================================================================================
# (c) the excluded-label list is DERIVED from the manifest, not restated in the script
# =================================================================================================
# Positive half: a label unique to THIS oracle's manifest ("Preview") must be excluded. If the
# script instead hardcoded some other set, an unrecognised label like "Preview" here could easily
# pass straight through as "usable" and this would go undetected -- 23d's exact blind spot.
run "$(printf 'file.txt:1 hello\ns\nq')" "$(panes panel Preview)"
got="$(sent_pane)"
if [ "$got" = "wT:p1" ]; then
  ok "c) a label taken from the manifest (Preview) is excluded, proving it was read at runtime"
else
  no "c) note went to '${got:-<nothing>}', expected the agent wT:p1"
fi

# Negative half: an [[actions]] title ("Not a pane title...") must NOT be treated as an excluded
# pane label -- only [[panes]] blocks are panel titles. If parsing degenerated to "any title=
# anywhere in the file", a pane legitimately labelled that way would be wrongly excluded.
run "$(printf 'file.txt:1 hello\ns\nq')" "$(panes panel "Not a pane title — must never be excluded")"
got="$(sent_pane)"
if [ "$got" = "wT:p2" ]; then
  ok "c) an [[actions]] title is not mistaken for a [[panes]] title"
else
  no "c) an action title wrongly excluded the pane; note went to '${got:-<nothing>}'"
fi

# The oracle itself must actually be reading the manifest, not merely trusting the panel's own
# claim to. Confirm RED: point the script at an EMPTY manifest (via a broken copy in an otherwise
# identical rendering) and check that "Preview" is then NOT excluded -- i.e. the exclusion really
# does come from manifest content, this is not a script that always excludes "Preview" no matter
# what the manifest says.
EMPTY_DIR="$TMP/empty"
mkdir -p "$EMPTY_DIR"
render_script "$ROOT/libexec/review" "$EMPTY_DIR/review"
: >"$EMPTY_DIR/herdr-plugin.toml"
: > "$LOG"
printf 'file.txt:1 hello\ns\nq\n' | \
  (cd "$REPO" && HOME="$TMP/home" XDG_STATE_HOME="$STATE_HOME" PATH="$STUB_BIN:$PATH" HERDR_BIN_PATH=herdr HERDR_STUB_LOG="$LOG" \
  HERDR_STUB_PANES="$(panes panel Preview)" /bin/bash "$EMPTY_DIR/review" >"$TMP/out2" 2>&1)
got="$(grep -o "pane send-text [^ ]*" "$LOG" | tail -1 | awk '{print $3}')"
if [ "$got" = "wT:p2" ]; then
  ok "c) against an EMPTY manifest, Preview is no longer excluded -- proves the set is derived"
else
  no "c) with an empty manifest, note went to '${got:-<nothing>}', expected wT:p2 (nothing excluded)"
fi

# =================================================================================================
# (d) same-tab is preferred over another workspace's agent
# =================================================================================================
two_ws='{"result":{"panes":[
{"pane_id":"other:p1","tab_id":"other:t1","workspace_id":"other","agent":"claude","focused":false},
{"pane_id":"wT:p1","tab_id":"wT:t1","workspace_id":"wT","agent":"claude","focused":false},
{"pane_id":"wT:p2","tab_id":"wT:t1","workspace_id":"wT","label":"Edit","focused":true}]},"type":"pane_list"}'
run "$(printf 'file.txt:1 same tab please\ns\nq')" "$two_ws"
got="$(sent_pane)"
if [ "$got" = "wT:p1" ]; then
  ok "d) the fallback stays in the focused pane's own tab, not another workspace's agent"
else
  no "d) note went to '${got:-<nothing>}', expected the same-tab agent wT:p1"
fi

# =================================================================================================
# extra coverage: multiple notes accumulate and go out as ONE message, and are cleared after send
# =================================================================================================
run "$(printf 'file.txt:1 first note\nfile.txt:4 second note\ns\nq')" "$(panes agent Preview)"
sends="$(grep -c "pane send-text" "$LOG")"
if [ "$sends" -eq 1 ]; then
  ok "multiple notes are sent as a single message (one send-text call)"
else
  no "expected exactly 1 send-text call, saw $sends"
fi
if grep -q "first note" "$LOG" && grep -q "second note" "$LOG"; then
  ok "the single sent message contains both accumulated notes"
else
  no "the sent message is missing a note -- log: $(cat "$LOG")"
fi
if grep -q "noted: file.txt:1 first note" "$TMP/out"; then
  ok "each note is echoed back as confirmation when typed"
else
  no "no echoed confirmation found in output"
fi

# A second 's' with nothing queued must not send an empty/duplicate message.
run "$(printf 'file.txt:1 only note\ns\ns\nq')" "$(panes agent Preview)"
sends2="$(grep -c "pane send-text" "$LOG")"
if [ "$sends2" -eq 1 ]; then
  ok "sending twice with nothing new queued does not send again"
else
  no "expected 1 send-text call across two 's' presses, saw $sends2"
fi

# =================================================================================================
# extra coverage: the diff itself is grouped by file with citable line numbers
# =================================================================================================
run "q" "$(panes agent Preview)"
if grep -q "== file.txt ==" "$TMP/out"; then
  ok "the diff is grouped under a file header"
else
  no "no per-file header found in the printed diff -- output: $(cat "$TMP/out")"
fi
if grep -qE "^\s*[0-9]+ \+" "$TMP/out"; then
  ok "an added line is printed with a citable line number"
else
  no "no numbered added line found in the printed diff"
fi

# 'q' quits without requiring a note or a send.
if [ -s "$LOG" ] && grep -q "pane list" "$LOG"; then
  : # fine either way -- printing the diff does not require a pane lookup at all
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
