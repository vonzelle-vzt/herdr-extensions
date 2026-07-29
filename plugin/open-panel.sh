#!/usr/bin/env bash
# Launcher for the SpiceEdit pane.  Usage: open-editor.sh <split|tab> [auto]
#
#   split       open/focus/close the editor beside the current pane (the prefix+e toggle)
#   tab         open the editor full-width in its own tab, or switch to it (prefix+shift+e)
#   ...  auto   fired from the workspace.created event rather than a keypress; see SCOPING below
#
# Behavior, scoped to the target tab (herdr actions/keybindings can only run a COMMAND — there is
# no declarative "open this pane" field, so the launch-or-focus-or-close decision lives here):
#   split: no Edit pane in the tab -> open a split (focused)
#          an Edit pane exists but isn't focused -> focus it
#          the focused pane IS the Edit pane -> close it (herdr has no hide-without-close;
#                                               reopening just re-walks the tree — cheap)
#   tab:   an Edit pane exists anywhere -> switch to its tab;  otherwise open one
#
# ============================ WHERE THE USER IS ============================
# Prefer $HERDR_PLUGIN_CONTEXT_JSON, which herdr injects for BOTH actions and events. Verified
# payload for workspace.created:
#   {"workspace_id":"w2T","workspace_cwd":"/…/tradescriptai","tab_id":"w2T:t1",
#    "focused_pane_id":"w2T:p1","focused_pane_cwd":"/…/tradescriptai","correlation_id":"workspace.created"}
# It names the NEW workspace's pane/tab/cwd, which is the whole point: on workspace.created the
# GLOBAL focus has not moved to the new workspace yet, so trusting `pane list`'s `focused: true`
# raced — it found the OLD workspace's editor and merely re-focused it, leaving the new workspace
# with no editor at all (reproduced twice). Order of truth: context -> $HERDR_PANE_ID -> the
# `focused: true` pane. Never `pane current --current`: that resolves $HERDR_PANE_ID, i.e. the pane
# the CLI was invoked FROM, and reports `focused: false` when the user is elsewhere.
#
# ============================ SCOPING (project only) ============================
# herdr launches a plugin pane in the PLUGIN's own directory, and this config sets
# `new_cwd = "home"`, so an unscoped editor roots at $HOME and shows ~80 dotfiles/dirs instead of
# a project. So we resolve the directory ourselves and pass --cwd:
#   1. the context's focused-pane cwd, else the workspace cwd
#   2. widened to `git rev-parse --show-toplevel` so it opens the REPO ROOT like VS Code
#   3. if that is not a git repo:
#        auto  -> DO NOTHING. Auto-opening $HOME is the "showing all these other folders"
#                 problem; a non-project workspace simply gets no editor.
#        key   -> fall back to PROJECTS_ROOT (below) so an explicit keypress still shows your
#                 project folders rather than dotfile soup.
#
# Absolute paths throughout: the herdr server execs this under launchd's minimal PATH
# (/usr/bin:/bin:/usr/sbin:/sbin), which has no /opt/homebrew/bin. /usr/bin/{git,python3} and
# /bin/bash are all present there.
set -uo pipefail

entrypoint="${1:-editor}"   # manifest [[panes]] id to open
label="${2:-Edit}"          # that pane's manifest title — how we find it again in `pane list`
mode="${3:-split}"          # split | tab
direction="${4:-right}"     # right | down  (split only; we swap afterwards for "left")
trigger="${5:-key}"         # key | auto    (auto = fired from an event, not a keypress)
swap="${6:-yes}"            # yes = swap after opening so the panel lands left/above
herdr_bin="${HERDR_BIN_PATH:-herdr}"
PY=/usr/bin/python3
GIT=/usr/bin/git

# Where to point the editor when a keypress happens outside any repo. Shows project folders
# instead of $HOME's dotfiles. Rendered by `herdr-tools install --projects-root DIR`.
PROJECTS_ROOT="@@PROJECTS_ROOT@@"

panes_json="$("$herdr_bin" pane list 2>/dev/null || true)"

# Resolve target pane/tab/cwd and the open/focus/close decision in one pass.
# Emits: <decision>\t<pane_id>\t<tab_id>\t<cwd>
plan="$("$PY" - "$panes_json" "${HERDR_PLUGIN_CONTEXT_JSON:-}" "${HERDR_PANE_ID:-}" "$mode" "$label" <<'EOF' 2>/dev/null || true
import json, sys

panes_raw, ctx_raw, env_pane, mode, label = sys.argv[1:6]
try:
    panes = json.loads(panes_raw)["result"]["panes"]
except Exception:
    panes = []
try:
    ctx = json.loads(ctx_raw) if ctx_raw else {}
except Exception:
    ctx = {}

by_id = {p.get("pane_id"): p for p in panes}

# Order of truth: injected context -> the invoking pane -> whatever `pane list` calls focused.
pane_id = ctx.get("focused_pane_id") or env_pane or ""
cur = by_id.get(pane_id) or next((p for p in panes if p.get("focused")), None) or {}
pane_id = cur.get("pane_id") or pane_id
tab_id = cur.get("tab_id") or ctx.get("tab_id") or ""
cwd = (ctx.get("focused_pane_cwd") or ctx.get("workspace_cwd")
       or cur.get("foreground_cwd") or cur.get("cwd") or "")
cur_label = cur.get("label") or ""

# Plugin panes carry no plugin_id/entrypoint in `pane list` — identify ours by manifest title.
edits = [p for p in panes if p.get("label") == label]

if mode == "tab":
    decision = "TAB" if edits else "OPEN"
    out_pane = edits[0]["tab_id"] if edits else pane_id
else:
    same_tab = [p for p in edits if p.get("tab_id") == tab_id]
    if cur_label == label and pane_id:
        decision, out_pane = "CLOSE", pane_id
    elif same_tab:
        decision, out_pane = "FOCUS", same_tab[0]["pane_id"]
    else:
        decision, out_pane = "OPEN", pane_id

print("\t".join([decision, out_pane or "", tab_id, cwd]))
EOF
)"

IFS=$'\t' read -r decision target tab_id cwd <<<"${plan:-}"
decision="${decision:-OPEN}"

case "$decision" in
  TAB)   exec "$herdr_bin" tab focus "$target" ;;
  FOCUS)
    # herdr has no focus-by-id; a zoom --on/--off cycle focuses without leaving it maximized.
    "$herdr_bin" pane zoom "$target" --on >/dev/null 2>&1 || true
    exec "$herdr_bin" pane zoom "$target" --off
    ;;
  CLOSE) exec "$herdr_bin" pane close "$target" ;;
esac

# ---- resolve the project directory -----------------------------------------------------------
# Never root inside herdr's own plugin tree (happens when an Edit/Files pane is the focused one).
case "${cwd:-}" in
  "" | "$HOME/.config/herdr/plugins"*) cwd="" ;;
esac

proj=""
if [ -n "$cwd" ] && top="$("$GIT" -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
  proj="$top"                       # inside a repo -> the repo root
fi

if [ -z "$proj" ]; then
  # Not a git repo. lazygit simply cannot run here, so bail regardless of trigger.
  [ "$entrypoint" = "git" ] && exit 0
  # Auto-open stays silent rather than dumping $HOME into the tree.
  [ "$trigger" = "auto" ] && exit 0
  if [ -d "$PROJECTS_ROOT" ]; then proj="$PROJECTS_ROOT"
  elif [ -n "$cwd" ];        then proj="$cwd"
  else                            proj="$HOME"
  fi
fi

if [ "$mode" = "tab" ]; then
  exec "$herdr_bin" plugin pane open \
    --plugin herdr-tools --entrypoint "$entrypoint" \
    --placement tab --cwd "$proj" --focus
fi

# --target-pane pins the split beside the pane the user is actually in — required for the event,
# where global focus is still on the old workspace.
set -- --plugin herdr-tools --entrypoint "$entrypoint" --placement split \
       --direction "$direction" --cwd "$proj" --focus
[ -n "${target:-}" ] && set -- "$@" --target-pane "$target"
opened="$("$herdr_bin" plugin pane open "$@" 2>/dev/null || true)"

new_pane="$("$PY" - "$opened" <<'EOF' 2>/dev/null || true
import json, sys
try:
    print(json.loads(sys.argv[1])["result"]["plugin_pane"]["pane"]["pane_id"])
except Exception:
    pass
EOF
)"

# VS Code layout: EDITOR ON THE LEFT, agent on the right. `plugin pane open` can only split
# `right|down` (there is no `left`), so the editor necessarily lands to the right of the agent —
# then we swap the two panes to put it on the left. Verified by geometry: after the swap the
# editor's rect.x is the smaller one.
if [ "$swap" = "yes" ] && [ -n "$new_pane" ] && [ -n "${target:-}" ]; then
  "$herdr_bin" pane swap --source-pane "$new_pane" --target-pane "$target" >/dev/null 2>&1 || true
fi

# A keypress means "I want the editor" -> leave it focused. An auto-open is just staging the
# reference panel, so hand focus back to the agent pane; otherwise the new workspace would start
# with keystrokes going into the editor instead of the agent.
if [ "$trigger" = "auto" ] && [ -n "${target:-}" ]; then
  "$herdr_bin" pane zoom "$target" --on >/dev/null 2>&1 || true
  "$herdr_bin" pane zoom "$target" --off >/dev/null 2>&1 || true
fi
exit 0
