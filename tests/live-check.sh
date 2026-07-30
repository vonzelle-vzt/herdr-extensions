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
    if "$HERDR" pane read "$ED" --source visible --lines 10 --format text 2>/dev/null | "$PY" -c "
import sys
raw=sys.stdin.buffer.read().decode('utf-8','replace')
sys.exit(0 if any(0xE000<=ord(c)<=0xF8FF or 0xF0000<=ord(c)<=0xFFFFD for c in raw) else 1)"; then
      ok "ORACLE 8: file-tree icons are being emitted"
    else
      note "ORACLE 8: no icon glyphs (expected if no Nerd Font is installed)"
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

# --- ORACLE 6: toggle cycle on the git panel --------------------------------------------------
echo
echo "ORACLE 6: git panel toggles open -> closed"
if [ -n "${WS_REPO:-}" ]; then
  AG="$(panes_json | "$PY" -c "
import json,sys
ws=sys.argv[1]
ps=json.load(sys.stdin)['result']['panes']
print(next((p['pane_id'] for p in ps if p['workspace_id']==ws and not (p.get('label') or '')),''))" "$WS_REPO")"
  "$HERDR" pane zoom "$AG" --on >/dev/null 2>&1; "$HERDR" pane zoom "$AG" --off >/dev/null 2>&1
  sleep 1
  "$HERDR" plugin action invoke open-git --plugin herdr-extensions >/dev/null 2>&1; sleep 6
  GP="$(find_pane "$WS_REPO" Git)"
  if [ -n "$GP" ]; then
    ok "git panel opened (rooted at $(pane_field "$GP" cwd))"
    "$HERDR" pane zoom "$GP" --on >/dev/null 2>&1; "$HERDR" pane zoom "$GP" --off >/dev/null 2>&1
    sleep 1
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

# --- cleanup ----------------------------------------------------------------------------------
for w in "${WS_REPO:-}" "${WS_HOME:-}"; do
  [ -n "$w" ] && "$HERDR" workspace close "$w" >/dev/null 2>&1
done
rm -rf "$TMP"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
