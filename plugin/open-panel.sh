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
ratio="${7:-}"              # target fraction of the split for THIS panel; empty = leave herdr's
herdr_bin="${HERDR_BIN_PATH:-herdr}"
PY=/usr/bin/python3
GIT=/usr/bin/git

# Where to point the editor when a keypress happens outside any repo. Shows project folders
# instead of $HOME's dotfiles. Rendered by `herdr-extensions install --projects-root DIR`.
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
    --plugin herdr-extensions --entrypoint "$entrypoint" \
    --placement tab --cwd "$proj" --focus
fi

# --target-pane pins the split beside the pane the user is actually in — required for the event,
# where global focus is still on the old workspace.
set -- --plugin herdr-extensions --entrypoint "$entrypoint" --placement split \
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

# ============================ PANEL WIDTH ============================
# `plugin pane open` has NO --ratio (only `pane split` and `pane move` do), so every plugin panel
# opens at a hard 50/50 — half the screen for a file tree. That is the "the pane is really big"
# complaint, and it is also what pushes the editor toward its own minimum: SpiceEdit refuses to
# draw below 50 columns (minWidth), and its file tree is a fixed 30 (defaultSidebarWidth), so a
# panel is only ever comfortable in a narrow band. We therefore drive the split to a target
# fraction after opening.
#
# `pane resize --amount` is a DELTA on the split ratio, not an absolute — measured live:
# ratio 0.315 --direction right --amount 0.05 -> 0.365 (width 63 -> 73), and the inverse restores
# it exactly. So: read the ratio, compute the signed delta, and issue ONE resize. Direction is
# derived from which side of the split we are on, so this works before or after the swap and for
# a vertical (down) panel too.
if [ -n "$ratio" ] && [ -n "$new_pane" ]; then
  edges_json="$("$herdr_bin" pane edges --pane "$new_pane" 2>/dev/null || true)"
  move="$("$PY" - "$edges_json" "$new_pane" "$ratio" <<'EOF' 2>/dev/null || true
import json, sys

# SpiceEdit refuses to draw below 50 columns and its file tree is a fixed 30, so a panel sized as
# a bare FRACTION is a trap: 0.40 of a 200-col screen is a comfortable 80, but 0.40 of a 120-col
# laptop is 48 — under the wall, and the panel renders "Window too small — please resize".
# So the requested size is a COLUMN COUNT (>=1), converted to a ratio against the actual split,
# then clamped: never below the editor's usable minimum, never more than MAX_FRAC of the screen.
# A value below 1 is still accepted and taken as a literal fraction, for a vertical panel where
# columns are the wrong unit.
MIN_COLS = 56          # minWidth(50) + tab bar/status margin, so the wall is never hit
MAX_FRAC = 0.55        # past this the panel is eating the agent, which defeats the layout

edges_raw, pane_id, target = sys.argv[1:4]
try:
    lay = json.loads(edges_raw)["result"]["edges"]["layout"]
    me = next(p["rect"] for p in lay["panes"] if p["pane_id"] == pane_id)
    splits = lay.get("splits") or []

    def contains(s):
        r = s["rect"]
        return (r["x"] <= me["x"] and r["y"] <= me["y"]
                and r["x"] + r["width"] >= me["x"] + me["width"]
                and r["y"] + r["height"] >= me["y"] + me["height"])

    # With 3+ panes there are several splits; ours is the SMALLEST one that still contains us,
    # i.e. our immediate parent. splits[0] is the root and would resize the wrong divider.
    mine = min((s for s in splits if contains(s)),
               key=lambda s: s["rect"]["width"] * s["rect"]["height"], default=None)
    if mine is not None:
        want = float(target)
        if want >= 1:                      # column count -> fraction of THIS split's extent
            span = mine["rect"]["width"] if mine["direction"] == "right" else mine["rect"]["height"]
            if span <= 0:
                raise ValueError("degenerate split")
            lo = min(MIN_COLS / span, MAX_FRAC)   # a tiny screen still gets the biggest legal panel
            want = max(lo, min(want / span, MAX_FRAC))
        delta = want - float(mine["ratio"])
        # ratio is measured from the split's FIRST child (its top-left corner coincides with the
        # split's). If we are the second child, growing us means lowering the ratio — sign flips.
        first = me["x"] == mine["rect"]["x"] and me["y"] == mine["rect"]["y"]
        if not first:
            delta = -delta
        if abs(delta) >= 0.01:
            grow, shrink = ("right", "left") if mine["direction"] == "right" else ("down", "up")
            print("%s %.4f" % (grow if delta > 0 else shrink, abs(delta)))
except Exception:
    pass
EOF
)"
  if [ -n "$move" ]; then
    # shellcheck disable=SC2086  # deliberate word split: "<direction> <amount>"
    set -- $move
    "$herdr_bin" pane resize --pane "$new_pane" --direction "$1" --amount "$2" >/dev/null 2>&1 || true
  fi
fi

# A keypress means "I want the editor" -> leave it focused. An auto-open is just staging the
# reference panel, so hand focus back to the agent pane; otherwise the new workspace would start
# with keystrokes going into the editor instead of the agent.
if [ "$trigger" = "auto" ] && [ -n "${target:-}" ]; then
  "$herdr_bin" pane zoom "$target" --on >/dev/null 2>&1 || true
  "$herdr_bin" pane zoom "$target" --off >/dev/null 2>&1 || true
fi
exit 0
