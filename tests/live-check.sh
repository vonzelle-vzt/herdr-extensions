#!/usr/bin/env bash
# live-check.sh — run herdr-extensions' behavioral oracles against a RUNNING herdr session.
#
#   tests/live-check.sh
#
# These are the checks that cannot be unit-tested, because the thing under test is herdr's live
# pane layout. Each corresponds to a numbered oracle in SPEC.md. The script creates and destroys
# its own throwaway workspace and git repo, and touches nothing of yours.
#
# Exits non-zero if any oracle fails, so it is usable as a release gate.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERDR="$(command -v herdr)"
PY=/usr/bin/python3
TMP="${TMPDIR:-/tmp}/herdr-extensions-livecheck.$$"
pass=0
fail=0

ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
no()   { echo "  FAIL  $1"; fail=$((fail+1)); }
note() { echo "        $1"; }

[ -n "$HERDR" ] || { echo "herdr not on PATH"; exit 1; }
"$HERDR" pane list >/dev/null 2>&1 || { echo "no running herdr session — start herdr first"; exit 1; }

# A throwaway repo with a subdirectory, so we can prove the editor widens to the REPO ROOT.
mkdir -p "$TMP/repo/nested/deep"
( cd "$TMP/repo" && /usr/bin/git init -q . \
  && /usr/bin/git config user.email t@t.co && /usr/bin/git config user.name t \
  && echo hi > file.txt && /usr/bin/git add -A && /usr/bin/git commit -qm init ) >/dev/null 2>&1

# Remember where the user actually was. Creating a workspace FOCUSES it, so this script moves the
# user out of their own workspace and must put them back — "touches nothing of yours" has to include
# where you were looking. Closing the throwaway workspaces at the end does not restore focus.
WS_ORIG="$("$HERDR" workspace list 2>/dev/null | "$PY" -c "
import json,sys
try:
    ws=json.load(sys.stdin)['result']['workspaces']
    print(next((w['workspace_id'] for w in ws if w.get('focused')),''))
except Exception:
    print('')")"

panes_json() { "$HERDR" pane list 2>/dev/null; }

# Find a pane by its manifest title within a workspace.
find_pane() {
  panes_json | "$PY" -c "
import json,sys
ws,label=sys.argv[1],sys.argv[2]
ps=json.load(sys.stdin)['result']['panes']
print(next((p['pane_id'] for p in ps if p['workspace_id']==ws and (p.get('label') or '')==label),''))" "$1" "$2"
}

pane_field() {
  panes_json | "$PY" -c "
import json,sys
pid,f=sys.argv[1],sys.argv[2]
ps=json.load(sys.stdin)['result']['panes']
print(next((str(p.get(f,'')) for p in ps if p['pane_id']==pid),''))" "$1" "$2"
}

count_label() {
  panes_json | "$PY" -c "
import json,sys
ws,label=sys.argv[1],sys.argv[2]
ps=json.load(sys.stdin)['result']['panes']
print(sum(1 for p in ps if p['workspace_id']==ws and (p.get('label') or '')==label))" "$1" "$2"
}

# Focus a pane by id and WAIT until herdr agrees, rather than sleeping and hoping.
#
# herdr has no focus-by-id, so this is the same zoom --on/--off cycle the launcher uses. The waiting
# is the point: `plugin action invoke` resolves the globally focused pane, so an unconfirmed focus
# makes the next oracle assert against whichever pane herdr still thinks is current. That is how the
# toggle-off half of ORACLE 6 started failing the moment another workspace-creating oracle was added
# ahead of it — a sleep 1 that was always a race, and only lost the race once the churn increased.
focus_pane() {
  pid="$1"; i=0
  "$HERDR" pane zoom "$pid" --on  >/dev/null 2>&1
  "$HERDR" pane zoom "$pid" --off >/dev/null 2>&1
  while [ "$i" -lt 20 ]; do
    [ "$(pane_field "$pid" focused)" = "True" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

echo
echo "ORACLE 4+5: auto-open scopes to the repo root, and stays silent outside a repo"

# --- in a repo SUBDIRECTORY: expect an editor rooted at the repo root -------------------------
out="$("$HERDR" workspace create --cwd "$TMP/repo/nested/deep" --label htcheck-repo 2>/dev/null)"
WS_REPO="$(printf '%s' "$out" | "$PY" -c "
import json,sys
try: print(json.load(sys.stdin)['result']['workspace']['workspace_id'])
except Exception: print('')")"
sleep 6
if [ -z "$WS_REPO" ]; then
  no "could not create test workspace"
else
  ED="$(find_pane "$WS_REPO" Edit)"
  if [ -n "$ED" ]; then
    ok "editor auto-opened in a new repo workspace"
    # Compare RESOLVED paths: on macOS $TMPDIR lives under /var, which is a symlink to
    # /private/var, and `git rev-parse --show-toplevel` returns the resolved form. Comparing the
    # raw strings fails on a correct result.
    cwd="$(/usr/bin/python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$(pane_field "$ED" cwd)")"
    want="$(/usr/bin/python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$TMP/repo")"
    if [ "$cwd" = "$want" ]; then
      ok "ORACLE 4: rooted at repo root, not the launch subdir ($cwd)"
    else
      no "ORACLE 4: expected $want, got $cwd"
    fi
    # --- ORACLE 3: the editor must be LEFT of the agent -------------------------------------
    AG="$(panes_json | "$PY" -c "
import json,sys
ws=sys.argv[1]
ps=json.load(sys.stdin)['result']['panes']
print(next((p['pane_id'] for p in ps if p['workspace_id']==ws and not (p.get('label') or '')),''))" "$WS_REPO")"
    geo="$("$HERDR" pane edges --pane "$AG" 2>/dev/null | "$PY" -c "
import json,sys
ed,ag=sys.argv[1],sys.argv[2]
lay=json.load(sys.stdin)['result']['edges']['layout']
r={p['pane_id']:p['rect'] for p in lay['panes']}
print('%d %d' % (r.get(ed,{}).get('x',-1), r.get(ag,{}).get('x',-1)))" "$ED" "$AG")"
    edx="${geo% *}"; agx="${geo#* }"
    if [ "$edx" -ge 0 ] && [ "$agx" -ge 0 ] && [ "$edx" -lt "$agx" ]; then
      ok "ORACLE 3: editor is LEFT of the agent (x=$edx vs x=$agx)"
    else
      no "ORACLE 3: editor x=$edx is not left of agent x=$agx"
    fi
    # --- ORACLE 8: Nerd Font icons are emitted ----------------------------------------------
    # NO --lines. `pane read --lines N` returns the LAST N lines, like tail — and the file tree is
    # drawn at the TOP of the pane, so a short tree in a tall pane put every icon outside the
    # window. This oracle spent its life reading blank rows and reporting "no icon glyphs (expected
    # if no Nerd Font is installed)" while 11 glyphs were on screen: a false negative wearing a
    # plausible excuse, which is worse than a failure because nobody investigates it.
    if "$HERDR" pane read "$ED" --source visible --format text 2>/dev/null | "$PY" -c "
import sys
raw=sys.stdin.buffer.read().decode('utf-8','replace')
sys.exit(0 if any(0xE000<=ord(c)<=0xF8FF or 0xF0000<=ord(c)<=0xFFFFD for c in raw) else 1)"; then
      ok "ORACLE 8: file-tree icons are being emitted"
    else
      note "ORACLE 8: no icon glyphs (expected if no Nerd Font is installed)"
    fi
    # --- ORACLE 19: the panel actually SHOWS FILES ------------------------------------------
    # The end-to-end assertion, and the only one that covers the whole chain at once: the panel
    # auto-opened, the launcher sized it wide enough, and the editor chose to draw its tree there.
    #
    # This is the failure the geometry work was chasing, and every layer of it reported success
    # while the user saw no files. The pane existed, its width cleared the editor minimum, and the
    # editor drew "click open from the tree" — with no tree, because it hid the tree below 76
    # columns and the panel was 60. Only reading the pane catches that.
    edw="$("$HERDR" pane edges --pane "$ED" 2>/dev/null | "$PY" -c "
import json,sys
try:
    lay=json.load(sys.stdin)['result']['edges']['layout']
    print(next(p['rect']['width'] for p in lay['panes'] if p['pane_id']==sys.argv[1]))
except Exception:
    print(0)" "$ED")"
    # Again no --lines: the EXPLORER header is the FIRST row of the pane.
    if "$HERDR" pane read "$ED" --source visible --format text 2>/dev/null \
        | grep -q "EXPLORER"; then
      ok "ORACLE 19: the panel shows the file tree (${edw} columns wide)"
    elif [ "${edw:-0}" -lt 42 ]; then
      note "ORACLE 19: panel is ${edw} columns, below the editor tree floor (42) — tree correctly hidden"
    else
      no "ORACLE 19: no file tree in a ${edw}-column panel. Upstream spiceedit hides its tree below 76 columns; install herdr-edit, which narrows it instead"
    fi
  else
    no "ORACLE 4/3: no editor pane appeared in the repo workspace"
  fi
fi

# --- in $HOME (not a repo): expect NO editor --------------------------------------------------
out="$("$HERDR" workspace create --cwd "$HOME" --label htcheck-home 2>/dev/null)"
WS_HOME="$(printf '%s' "$out" | "$PY" -c "
import json,sys
try: print(json.load(sys.stdin)['result']['workspace']['workspace_id'])
except Exception: print('')")"
sleep 6
if [ -n "$WS_HOME" ]; then
  if [ "$(count_label "$WS_HOME" Edit)" = "0" ]; then
    ok "ORACLE 5: no editor auto-opened outside a repo (no \$HOME dotfile dump)"
  else
    no "ORACLE 5: an editor opened in a non-repo workspace"
  fi
fi

# --- ORACLE 21: in $HOME, but LABELLED after a project: expect that project -------------------
# The positive counterpart to ORACLE 5, and the case a user actually hits. `herdr workspace create`
# and herdr-plus Projects both leave the root pane at $HOME unless given --cwd, so a workspace called
# "affiliate crm" used to get no editor at all -- ORACLE 5 passing was the whole bug, because it only
# ever proved the silent path with a label matching nothing.
#
# The fixture repo has to live under the REAL PROJECTS_ROOT, read from the INSTALLED launcher: the
# server execs that copy, not the one in this repo, and the repo copy still has the @@template@@.
PROJ_ROOT="$("$PY" - "$HOME/.config/herdr/plugins/local/herdr-extensions/open-panel.sh" <<'PYEOF' 2>/dev/null || true
import re, sys
try:
    src = open(sys.argv[1]).read()
except OSError:
    sys.exit(0)
m = re.search(r'^PROJECTS_ROOT="(.*)"$', src, re.M)
if m and not m.group(1).startswith("@@"):
    print(m.group(1))
PYEOF
)"
LABEL_REPO=""
if [ -n "${PROJ_ROOT:-}" ] && [ -d "$PROJ_ROOT" ]; then
  LABEL_REPO="$PROJ_ROOT/htcheck-labelmatch"
  mkdir -p "$LABEL_REPO"
  ( cd "$LABEL_REPO" && /usr/bin/git init -q . \
    && /usr/bin/git config user.email t@t.co && /usr/bin/git config user.name t \
    && mkdir -p src && echo hi > src/file.txt \
    && /usr/bin/git add -A && /usr/bin/git commit -qm init ) >/dev/null 2>&1

  out="$("$HERDR" workspace create --cwd "$HOME" --label "htcheck labelmatch" 2>/dev/null)"
  WS_LABEL="$(printf '%s' "$out" | "$PY" -c "
import json,sys
try: print(json.load(sys.stdin)['result']['workspace']['workspace_id'])
except Exception: print('')")"
  sleep 6
  if [ -n "$WS_LABEL" ]; then
    LED="$(find_pane "$WS_LABEL" Edit)"
    if [ -z "$LED" ]; then
      no "ORACLE 21: no editor for a \$HOME workspace labelled after a real project"
    else
      lcwd="$("$PY" -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$(pane_field "$LED" cwd)")"
      lwant="$("$PY" -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$LABEL_REPO")"
      if [ "$lcwd" = "$lwant" ]; then
        ok "ORACLE 21: label resolved the project ($lcwd)"
      else
        no "ORACLE 21: expected $lwant, got $lcwd"
      fi
      # And it must actually DISPLAY the folders, not just be rooted correctly.
      if "$HERDR" pane read "$LED" --source visible --format text 2>/dev/null | grep -q "EXPLORER"; then
        ok "ORACLE 21: and it displays the project folders"
      else
        no "ORACLE 21: rooted correctly but showing no file tree"
      fi
    fi
  fi
else
  note "ORACLE 21: skipped — no rendered PROJECTS_ROOT in the installed launcher"
fi

# --- ORACLE 6: toggle cycle on the git panel --------------------------------------------------
echo
echo "ORACLE 6: git panel toggles open -> closed"
if [ -n "${WS_REPO:-}" ]; then
  AG="$(panes_json | "$PY" -c "
import json,sys
ws=sys.argv[1]
ps=json.load(sys.stdin)['result']['panes']
print(next((p['pane_id'] for p in ps if p['workspace_id']==ws and not (p.get('label') or '')),''))" "$WS_REPO")"
  # `plugin action invoke` has no --pane: an action always resolves the GLOBALLY focused pane. So
  # the workspace has to be focused for real, and only `workspace focus` does that.
  #
  # This used to be a `pane zoom --on/--off` cycle, which focuses a pane WITHIN a workspace and
  # cannot cross workspaces. ORACLE 5 had just created its non-repo workspace and left it focused,
  # so open-git resolved a $HOME pane, correctly refused (lazygit needs a work tree) and opened
  # nothing — and this oracle reported "git panel did not open" as though the panel were broken.
  # A harness that steals focus has to be explicit about where it puts it back.
  "$HERDR" workspace focus "$WS_REPO" >/dev/null 2>&1
  focus_pane "$AG" || no "ORACLE 6: could not focus the agent pane"
  "$HERDR" plugin action invoke open-git --plugin herdr-extensions >/dev/null 2>&1; sleep 6
  GP="$(find_pane "$WS_REPO" Git)"
  if [ -n "$GP" ]; then
    ok "git panel opened (rooted at $(pane_field "$GP" cwd))"
    focus_pane "$GP" || no "ORACLE 6: could not focus the git pane"
    "$HERDR" plugin action invoke open-git --plugin herdr-extensions >/dev/null 2>&1; sleep 4
    if [ "$(count_label "$WS_REPO" Git)" = "0" ]; then
      ok "ORACLE 6: second invoke closed it"
    else
      no "ORACLE 6: git panel did not toggle off"
    fi
  else
    no "git panel did not open"
  fi
fi

# --- offline oracles (no live server needed) --------------------------------------------------
# These are the checks that would have caught the two v0.1.0 regressions, so they must run even
# when the server is unreachable (e.g. a protocol mismatch after a brew upgrade).

# ORACLE 13: bash 3.2 -- /bin/bash on macOS is still 3.2.57 and mis-parses an apostrophe inside a
# heredoc nested in $( ). The failure is silent: herdr just sees the action produce nothing.
if /bin/bash -n "$ROOT/plugin/open-panel.sh" 2>/dev/null; then
  ok "ORACLE 13a: /bin/bash ($(/bin/bash --version | head -1 | grep -o '[0-9]\+\.[0-9]\+')) parses open-panel.sh"
else
  no "ORACLE 13a: open-panel.sh does not parse under bash 3.2"
fi
if /usr/bin/python3 - "$ROOT/plugin/open-panel.sh" <<'PYEOF'
import sys
inside = False
bad = []
for i, l in enumerate(open(sys.argv[1]).read().splitlines(), 1):
    if "<<" + chr(39) + "EOF" + chr(39) in l:
        inside = True
        continue
    if l.strip() == "EOF":
        inside = False
        continue
    if inside and chr(39) in l:
        bad.append(i)
sys.exit(1 if bad else 0)
PYEOF
then
  ok "ORACLE 13b: no apostrophes inside any heredoc"
else
  no "ORACLE 13b: an apostrophe inside a heredoc will break bash 3.2"
fi

# ORACLE 11: our keybindings must not shadow any herdr built-in.
if "$ROOT/bin/herdr-extensions" doctor 2>/dev/null | grep -q "collide with none of"; then
  ok "ORACLE 11: no keybinding collisions"
else
  no "ORACLE 11: keybinding collision detected (or the check could not run)"
fi

# ORACLE 14: panel sizing -- deterministic, against a fixture, so it needs no live server.
if /usr/bin/python3 "$ROOT/tests/check-sizing.py" >/dev/null 2>&1; then
  ok "ORACLE 14: panel sizing correct, clamped, and idempotent"
else
  no "ORACLE 14: panel sizing wrong -- run tests/check-sizing.py"
fi

# The remaining offline suites. This script is documented as usable as a release gate, and it was
# not: three of the four offline suites existed and it ran none of them, so a gate that looked green
# had never executed 39 of its own oracles. Each is delegated rather than reimplemented, so there is
# still exactly one definition of every check.
for suite in check-panels check-viability check-project-resolve check-image-paste check-preview; do
  if [ ! -x "$ROOT/tests/$suite.sh" ]; then
    no "$suite.sh missing or not executable"
  elif out="$("$ROOT/tests/$suite.sh" 2>&1)"; then
    ok "$suite.sh: $(printf '%s' "$out" | grep -o '[0-9]* passed' | tail -1)"
  else
    no "$suite.sh failed -- run tests/$suite.sh"
    printf '%s\n' "$out" | grep FAIL | sed 's/^/        /'
  fi
done

# --- cleanup ----------------------------------------------------------------------------------
for w in "${WS_REPO:-}" "${WS_HOME:-}" "${WS_LABEL:-}"; do
  [ -n "$w" ] && "$HERDR" workspace close "$w" >/dev/null 2>&1
done
# The ORACLE 21 fixture is the only thing this script writes outside $TMP, so be exact about
# removing it: guard on the expected basename rather than trusting the variable.
case "${LABEL_REPO:-}" in
  */htcheck-labelmatch) rm -rf "$LABEL_REPO" ;;
esac
# Put the user back where they were. Closing a focused workspace leaves focus wherever herdr
# happens to land, which is not necessarily where the run started.
[ -n "${WS_ORIG:-}" ] && "$HERDR" workspace focus "$WS_ORIG" >/dev/null 2>&1
rm -rf "$TMP"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
