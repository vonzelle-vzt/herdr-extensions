#!/usr/bin/env bash
# Project opener — pick a repo, and re-root the editor (and this space) on it.
#
# WHY THIS EXISTS. A new herdr space starts in $HOME, so the editor that auto-opens with it has no
# project to show; you then start an agent and cd into a repo, but the editor pane opened BEFORE
# that and never learns about it. The result is a space where the agent is working in a project and
# the file tree is showing something else, or nothing. The auto-open label matcher covers the case
# where the space is already NAMED for a project; this covers the case where it is not, which is
# every space you create and then decide what to do with.
#
# What it does, in one keypress:
#   1. lists the git repos under PROJECTS_ROOT
#   2. you pick one
#   3. closes the current editor pane and reopens it ROOTED AT that repo, so the tree shows it
#   4. renames the space to the repo, so the auto-open matcher finds it next time by itself
#
# Step 4 is the part that compounds: after using this once, a space keeps working without it.
set -uo pipefail

HERDR="@@HERDR@@"
GIT="@@GIT@@"
FZF="@@FZF@@"
PROJECTS_ROOT="@@PROJECTS_ROOT@@"
PY=/usr/bin/python3
DIRNAME=/usr/bin/dirname

die() { printf 'project: %s\n' "$*"; echo; echo "Press any key to close..."; IFS= read -r -n1 -s _ || true; exit 1; }

[ -x "$HERDR" ] || die "herdr not found at $HERDR"
[ -d "$PROJECTS_ROOT" ] || die "projects root does not exist: $PROJECTS_ROOT"

# Only real git checkouts, one per line, newest-touched first so the repo you were last in is at
# the top rather than whatever sorts alphabetically.
listing="$("$PY" - "$PROJECTS_ROOT" <<'EOF'
import os, sys
root = sys.argv[1]
rows = []
for name in os.listdir(root):
    p = os.path.join(root, name)
    if not os.path.isdir(os.path.join(p, ".git")):
        continue
    try:
        mtime = os.path.getmtime(p)
    except OSError:
        mtime = 0
    rows.append((mtime, name))
for _, name in sorted(rows, reverse=True):
    print(name)
EOF
)"

[ -n "$listing" ] && [ "$listing" != "" ] || die "no git repositories under $PROJECTS_ROOT"

echo "Open a project — the editor and this space both re-root on your choice."
echo

if [ -x "$FZF" ]; then
  choice="$(printf '%s\n' "$listing" | "$FZF" --height=100% --reverse --prompt="project> " --border 2>/dev/null)"
else
  # fzf is optional. A numbered list is worse to use and works everywhere.
  echo "(install fzf for fuzzy search)"
  echo
  printf '%s\n' "$listing" | head -40 | nl -w3 -s'  '
  echo
  printf 'number: '
  IFS= read -r n
  choice="$(printf '%s\n' "$listing" | sed -n "${n}p" 2>/dev/null)"
fi

[ -n "${choice:-}" ] || die "nothing picked"
proj="$PROJECTS_ROOT/$choice"
[ -d "$proj/.git" ] || die "$choice is not a git repository"

ws="${HERDR_WORKSPACE_ID:-}"
if [ -z "$ws" ]; then
  ws="$("$HERDR" pane list 2>/dev/null | "$PY" -c "
import sys, json
try:
    panes = json.load(sys.stdin)['result']['panes']
except Exception:
    sys.exit(0)
p = next((p for p in panes if p.get('focused')), None)
print((p or {}).get('workspace_id', ''))
" 2>/dev/null)"
fi

# Close any editor pane already open in this space. Reopening without closing would leave two
# editors side by side, each rooted somewhere different -- which is the confusion this fixes.
if [ -n "$ws" ]; then
  "$HERDR" pane list 2>/dev/null | "$PY" -c "
import sys, json, subprocess
herdr, ws = sys.argv[1:3]
try:
    panes = json.load(sys.stdin)['result']['panes']
except Exception:
    sys.exit(0)
for p in panes:
    if p.get('workspace_id') == ws and (p.get('label') or '') == 'Edit':
        subprocess.run([herdr, 'pane', 'close', p['pane_id']],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
" "$HERDR" "$ws" 2>/dev/null
fi

# Rename the space after the repo, so the auto-open matcher resolves it unaided next time. This is
# what stops you needing this panel twice for the same space.
if [ -n "$ws" ]; then
  "$HERDR" workspace rename "$ws" "$choice" >/dev/null 2>&1
fi

target_pane=""
if [ -n "$ws" ]; then
  target_pane="$("$HERDR" pane list 2>/dev/null | "$PY" -c "
import sys, json
ws = sys.argv[1]
try:
    panes = json.load(sys.stdin)['result']['panes']
except Exception:
    panes = []
same_ws = [p for p in panes if p.get('workspace_id') == ws]
agent = next((p for p in same_ws if p.get('agent')), None)
focused = next((p for p in same_ws if p.get('focused')), None)
pick = agent or focused or (same_ws[0] if same_ws else {})
print(pick.get('pane_id', ''))
" "$ws" 2>/dev/null)"
fi

ctx="$("$PY" - "$ws" "$target_pane" "$proj" <<'EOF'
import json, sys
ws, pane, proj = sys.argv[1:4]
d = {"focused_pane_cwd": proj, "workspace_cwd": proj}
if ws:
    d["workspace_id"] = ws
if pane:
    d["focused_pane_id"] = pane
print(json.dumps(d, separators=(",", ":")))
EOF
)"

# Re-root the editor through the same launcher as the normal editor action. That keeps the selected
# project cwd, VS-Code-left swap and explorer-visible width policy in one place.
plugin_dir="$(cd "$("$DIRNAME" "$0")" && pwd)"
HERDR_BIN_PATH="$HERDR" HERDR_PANE_ID="$target_pane" HERDR_PLUGIN_CONTEXT_JSON="$ctx" HERDR_PROJECT_CWD="$proj" \
  /bin/bash "$plugin_dir/open-panel.sh" editor Edit split right key yes 88 70 >/dev/null 2>&1

echo "opened $choice"
echo "  editor re-rooted at $proj"
[ -n "$ws" ] && echo "  space renamed to \"$choice\" so it opens itself next time"
echo
echo "Press any key to close..."
IFS= read -r -n1 -s _ || true
