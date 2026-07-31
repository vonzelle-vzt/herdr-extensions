#!/usr/bin/env bash
# Oracle — the Debug panel MIRRORS the editor session and DRIVES it, rather than inventorying the
# debuggers installed on the machine and handing off.
#
# The panel reads two files the editor publishes into $XDG_STATE_HOME/spiceedit:
#
#   active.json         which file the cursor is in            (the shared panel contract)
#   debug-session.json  what the debug adapter is doing         (new in Lane B stage 5)
#
# and writes debug-request.json back through `herdr-edit --debug <action>`. 🔴 It never speaks the
# debug adapter protocol itself. The client lives in herdr-edit (internal/dap) because a breakpoint
# has to move when you insert a line above it, which is a few dozen lines in-process and needs the
# editor to publish every edit from out here. SPEC says anything inside the editor is out of scope
# for this package, and that is the rule being FOLLOWED, not bent.
#
# 🔴 STALENESS IS THE INTERESTING HALF, and it is why this suite exists at all. A cleanly quit
# editor publishes state "idle" on its way out. A SIGKILLed one publishes nothing, so its last
# payload sits on disk saying "stopped" forever -- and a panel that believes it describes a program
# that has not existed since Tuesday, in a file the user may since have rewritten. The panel must
# age a live payload out on its timestamp.
#
# 🔴 THE STALE ORACLE ASSERTS THE POSITIVE FIRST. "The panel does not say stopped" passes against a
# panel that says nothing at all -- including the one that shipped before this stage, which had
# never heard of debug-session.json. So the fresh-payload case runs FIRST and proves the location IS
# printed; only then does the aged case mean anything by its absence.
#
# 🔴 EVERY RUN IS HARD BOUNDED, and never with `timeout`: that command DOES NOT EXIST on macOS, and
# `timeout 5 foo` reports "command not found", which reads as a failure of foo rather than a missing
# tool. Each panel run is backgrounded and polled against a tick deadline, with a trap that kills
# every pid on any exit path. The panel waits on a keypress by design, so an unbounded run here
# would hang the gate rather than fail it.
#
# Runs entirely offline: no herdr server, no editor process, just fabricated state files.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY=/usr/bin/python3
PANEL="$ROOT/libexec/debug"

pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
PIDS_FILE="$TMP/pids"
: >"$PIDS_FILE"

# Cleanup on EVERY path, not just the happy one: a pid is recorded the instant it is backgrounded,
# before anything that could fail, so a bug between spawning and reading still leaves nothing behind.
cleanup() {
  if [ -f "$PIDS_FILE" ]; then
    while IFS= read -r p; do
      kill -9 "$p" 2>/dev/null || true
    done <"$PIDS_FILE"
  fi
  pkill -9 -f "$PANEL" 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

STATE="$TMP/state"
REPO="$TMP/repo"
mkdir -p "$STATE/spiceedit" "$REPO/.vscode"

cat >"$REPO/main.go" <<'GOEOF'
package main

import "fmt"

func add(a, b int) int {
	sum := a + b
	return sum
}

func main() {
	fmt.Println(add(2, 3))
}
GOEOF

# A real launch.json, JSONC and all -- comments and a trailing comma, which json.load rejects and
# nearly every checked-in launch.json has.
cat >"$REPO/.vscode/launch.json" <<'JSONEOF'
{
  // The name below is what the panel must print.
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug Package",
      "type": "go",
      "request": "launch",
      "program": "${workspaceFolder}",
    }
  ]
}
JSONEOF

# write_session <state> <age-in-seconds> -- fabricate debug-session.json exactly as the editor
# publishes it: 1-BASED lines on the wire, the staleness window carried in the payload so the
# reader uses the editors own number rather than a second hardcoded 60.
write_session() {
  "$PY" - "$STATE/spiceedit/debug-session.json" "$REPO" "$1" "$2" ${3:+"$3"} <<'PYEOF'
import json, sys, time

path, repo, state, age = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
main = repo + "/main.go"
stopped = state == "stopped"
doc = {
    "adapter": "delve",
    "config": repo,
    "state": state,
    "reason": "breakpoint" if stopped else "",
    "file": main if stopped else "",
    "line": 6 if stopped else 0,
    "threadId": 17,
    "frames": ([{"name": "main.add", "file": main, "line": 6},
                {"name": "main.main", "file": main, "line": 11}]
               if stopped else []),
    "frameTotal": 2 if stopped else 0,
    "breakpoints": [{"file": main, "line": 6, "enabled": True, "verified": True}],
    "breakpointTotal": 1,
    "root": repo,
    "staleAfter": 60,
    "ts": int((time.time() - age) * 1000),
}
# A third argument drops staleAfter, which is what a payload written by an editor older than the
# field looks like. The panel has to fall back to its own window rather than treating "no window"
# as "never stale" -- the more forgiving reading is the one that keeps a dead editor lying.
if len(sys.argv) > 5:
    del doc["staleAfter"]
with open(path, "w") as fh:
    fh.write(json.dumps(doc))
PYEOF
}

# write_active <file> -- the shared active-file contract. \x1f-separated on the panel side; here it
# is just JSON. An empty file is the no-file-open shape check-panels.sh 16c exercises.
write_active() {
  "$PY" - "$STATE/spiceedit/active.json" "$REPO" "$1" <<'PYEOF'
import json, sys

# 🔴 The active LINE is deliberately not the stop line. Both end up in the panel output, and with
# them equal the "the stop location is printed" oracle passed against the OLD panel, which was
# echoing the active-file header and had never heard of a debug session at all.
path, repo, active = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as fh:
    fh.write(json.dumps({"file": active, "line": 12, "col": 1, "root": repo, "ts": 1}))
PYEOF
}

# DEADLINE_TICKS -- 15s at 0.25s a tick. The panel prints and then waits on a keypress; with stdin
# at EOF that read returns immediately, so a run that is still alive after 15s is wedged, and this
# is what makes that a FAIL instead of a hang.
DEADLINE_TICKS=60

# run_panel <outfile> -- run the panel against the fabricated state with stdin already at EOF, and
# bound it. Returns 1 when the deadline fired.
run_panel() {
  local out="$1"
  : >"$out"
  ( printf '' | XDG_STATE_HOME="$STATE" "$PANEL" >"$out" 2>&1 ) &
  local pid=$!
  printf '%s\n' "$pid" >>"$PIDS_FILE"

  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$DEADLINE_TICKS" ]; do
    sleep 0.25
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    return 1
  fi
  wait "$pid" 2>/dev/null
  return 0
}

# has <file> <pattern> -- fixed-string search over a captured panel run.
has() { grep -qF -- "$2" "$1"; }

# ---------------------------------------------------------------------------------------------
# 1. A STOPPED session prints where it stopped and what is on the stack.
# ---------------------------------------------------------------------------------------------
write_active "$REPO/main.go"
write_session stopped 0
OUT="$TMP/stopped.out"
if ! run_panel "$OUT"; then
  no "DEBUG 1: the panel never terminated on a stopped session (deadline fired)"
else
  if has "$OUT" "stopped"; then
    ok "DEBUG 1a: a stopped session is reported as stopped"
  else
    no "DEBUG 1a: the panel did not report the session as stopped"
  fi
  # 1-BASED on the wire, and the panel must print it verbatim rather than doing arithmetic of its
  # own. A panel that helpfully subtracted one would point a reader at the wrong line.
  #
  # 🔴 Anchored on the LABEL as well as the location. A bare "main.go:6" was matched by the old
  # panel echoing the active-file header, so this oracle passed against a panel that could not read
  # a debug session at all -- and DEBUG 3b, which is an absence check, is only meaningful because
  # this one is a real positive.
  if grep -qE "stopped at.*main\.go:6" "$OUT"; then
    ok "DEBUG 1b: the stop location is printed, 1-based, as main.go:6"
  else
    no "DEBUG 1b: the stop location main.go:6 is missing"
  fi
  if has "$OUT" "main.add" && has "$OUT" "main.main"; then
    ok "DEBUG 1c: the top frames are printed"
  else
    no "DEBUG 1c: the call stack frames are missing"
  fi
  if has "$OUT" "breakpoint"; then
    ok "DEBUG 1d: the breakpoints the editor published are printed"
  else
    no "DEBUG 1d: no breakpoints in the output"
  fi
  # On the SESSION line, not merely somewhere on screen: the old panel listed "delve (dlv)" in its
  # inventory of debuggers installed on this machine, which is a different claim entirely.
  if grep -qE "session:.*delve" "$OUT"; then
    ok "DEBUG 1e: the session line names the adapter that is running"
  else
    no "DEBUG 1e: the session line does not name the adapter"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 2. An IDLE session shows what you could launch, and how.
#
# This is the state the panel spends most of its life in, and the one where the old panel earned
# its keep: .vscode/launch.json is how a project already describes what running it means.
# ---------------------------------------------------------------------------------------------
write_session idle 0
OUT="$TMP/idle.out"
if ! run_panel "$OUT"; then
  no "DEBUG 2: the panel never terminated on an idle session (deadline fired)"
else
  if has "$OUT" "Debug Package"; then
    ok "DEBUG 2a: the launch configuration from .vscode/launch.json is listed"
  else
    no "DEBUG 2a: the launch configuration is missing (JSONC comments/trailing comma?)"
  fi
  if has "$OUT" "press s to start"; then
    ok "DEBUG 2b: an idle panel says how to start a session"
  else
    no "DEBUG 2b: an idle panel does not say how to start a session"
  fi
  # An idle session has no location. Printing one would point at a line nothing is stopped on.
  if has "$OUT" "stopped at"; then
    no "DEBUG 2c: an idle session still printed a stop location"
  else
    ok "DEBUG 2c: an idle session prints no stop location"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 3. A 10-MINUTE-OLD non-idle session is STALE, not stopped.
#
# 🔴 Ordered deliberately AFTER case 1. The absence assertion below is only worth anything because
# DEBUG 1b already proved this panel DOES print that location when the payload is fresh -- an
# absence check on its own passes against a panel that prints nothing, which is exactly what the
# pre-stage-5 panel did.
# ---------------------------------------------------------------------------------------------
write_session stopped 600
OUT="$TMP/stale.out"
if ! run_panel "$OUT"; then
  no "DEBUG 3: the panel never terminated on a stale session (deadline fired)"
else
  if grep -qi "stale" "$OUT"; then
    ok "DEBUG 3a: a 10-minute-old stopped session is called stale"
  else
    no "DEBUG 3a: a 10-minute-old stopped session was not called stale"
  fi
  if has "$OUT" "stopped at"; then
    no "DEBUG 3b: a stale session is still presented as stopped somewhere -- a killed editor lies forever"
  else
    ok "DEBUG 3b: a stale session does not claim a stop location"
  fi
fi

# The window travels IN the payload so the two sides cannot drift, which leaves the panel needing a
# fallback for a payload written before the field existed. 🔴 The forgiving reading -- no window
# means never stale -- is the one that reinstates the exact bug this whole section exists to stop,
# and it is the reading you get for free by writing `if window:`. Both halves are checked, because
# a fallback that ages EVERYTHING out immediately would pass a stale-only assertion.
write_session stopped 0 no-window
OUT="$TMP/nowindow-fresh.out"
if run_panel "$OUT" && grep -qE "stopped at.*main\.go:6" "$OUT" && ! grep -qi "stale" "$OUT"; then
  ok "DEBUG 3c: a payload with no staleAfter is believed while it is fresh"
else
  no "DEBUG 3c: a fresh payload with no staleAfter was not believed"
fi

write_session stopped 600 no-window
OUT="$TMP/nowindow-old.out"
if run_panel "$OUT" && grep -qi "stale" "$OUT"; then
  ok "DEBUG 3d: a payload with no staleAfter still goes stale on the fallback window"
else
  no "DEBUG 3d: a 10-minute-old payload with no staleAfter was still believed"
fi

# ---------------------------------------------------------------------------------------------
# 4. Absence degrades, and junk does not.
#
# A missing file means no editor has published here; a malformed one means something wrote garbage.
# Both must read as ABSENT rather than as an error -- the panel is a reader of somebody elses file.
# ---------------------------------------------------------------------------------------------
rm -f "$STATE/spiceedit/debug-session.json"
OUT="$TMP/missing.out"
if run_panel "$OUT" && has "$OUT" "$REPO"; then
  ok "DEBUG 4a: a missing debug-session.json degrades to the repo view"
else
  no "DEBUG 4a: the panel failed or lost the repo with no debug-session.json"
fi

printf 'not json at all {{{' >"$STATE/spiceedit/debug-session.json"
OUT="$TMP/junk.out"
if run_panel "$OUT" && has "$OUT" "$REPO"; then
  ok "DEBUG 4b: a malformed debug-session.json reads as absent, not as an error"
else
  no "DEBUG 4b: malformed JSON broke the panel"
fi

# A truncated-but-parseable payload: every field the panel reads is missing. This is the shape a
# half-written file would have if the editor were not writing atomically, and the panel has no way
# to know which of the two it is looking at.
printf '{}' >"$STATE/spiceedit/debug-session.json"
OUT="$TMP/empty.out"
if run_panel "$OUT" && has "$OUT" "$REPO"; then
  ok "DEBUG 4c: an empty JSON object reads as absent, not as an error"
else
  no "DEBUG 4c: an empty JSON object broke the panel"
fi

# ---------------------------------------------------------------------------------------------
# 5. The panel names the keys it drives the editor with, and routes them through the EDITOR.
#
# 🔴 @@SPICEEDIT@@, not @@HERDR@@. render_plugin() substitutes @@SPICEEDIT@@ into libexec/ as well
# as the manifest; routing panel-to-editor traffic through the editor binary is the whole design,
# because the editor is the process holding the debug adapter client. A panel that reached for a
# herdr action instead would be trying to drive a debugger from outside the process that owns it.
# ---------------------------------------------------------------------------------------------
if grep -q "@@SPICEEDIT@@" "$PANEL"; then
  ok "DEBUG 5a: the panel drives the editor binary through the @@SPICEEDIT@@ placeholder"
else
  no "DEBUG 5a: the panel does not reference @@SPICEEDIT@@ -- it cannot reach the editor"
fi

if grep -qE -- "--debug" "$PANEL"; then
  ok "DEBUG 5b: the panel writes debug requests with the editors --debug flag"
else
  no "DEBUG 5b: the panel never invokes --debug"
fi

# Every key the panel advertises must actually be dispatched. A legend listing a key that falls
# through to "any other key closes the panel" is worse than not listing it: the panel appears to
# quit at random.
write_session idle 0
OUT="$TMP/keys.out"
if ! run_panel "$OUT"; then
  no "DEBUG 5c: the panel never terminated while checking its key legend"
else
  missing=""
  for k in "s start" "c continue" "n next" "i step in" "o step out" "x stop" "q quit"; do
    has "$OUT" "$k" || missing="$missing [$k]"
  done
  if [ -z "$missing" ]; then
    ok "DEBUG 5c: the key legend names start, continue, the three steps, stop and quit"
  else
    no "DEBUG 5c: the key legend is missing:$missing"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 6. The panel still honours the shared panel contract it shares with the other nine.
#
# check-panels.sh owns the full version of this; the two assertions repeated here are the ones a
# rewrite of THIS file is most likely to break, and finding that out in this suite names the panel
# rather than the whole tree.
# ---------------------------------------------------------------------------------------------
write_active ""
write_session idle 0
OUT="$TMP/nofile.out"
if ! run_panel "$OUT"; then
  no "DEBUG 6: the panel never terminated with no file open (deadline fired)"
else
  # The \x1f-versus-tab bug: with no file open the payload starts with an empty field, and a tab
  # separator drops it, shifting the line number into the filename.
  if grep -qE "active: *[0-9]+:" "$OUT"; then
    no "DEBUG 6a: the empty-file payload was misread (a line number landed in the filename)"
  else
    ok "DEBUG 6a: the empty-file payload parsed with every field in place"
  fi
  # debug is REPO-scoped: with no file open it must still name the repo rather than refusing.
  if has "$OUT" "$REPO"; then
    ok "DEBUG 6b: the panel names the repo with no file open"
  else
    no "DEBUG 6b: the panel lost the repo with no file open"
  fi
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
