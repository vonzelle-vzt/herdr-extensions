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
useful="${8:-0}"            # columns below which this panel loses its point (0 = no such width)
herdr_bin="${HERDR_BIN_PATH:-herdr}"
PY=/usr/bin/python3
GIT=/usr/bin/git

# Where to point the editor when a keypress happens outside any repo. Shows project folders
# instead of $HOME's dotfiles. Rendered by `herdr-extensions install --projects-root DIR`.
PROJECTS_ROOT="@@PROJECTS_ROOT@@"

# ============================ GEOMETRY POLICY — ONE SOURCE OF TRUTH ============================
# These three numbers decide both "is a split possible at all?" (the viability guard below) and
# "how wide should the panel be?" (the clamp at the bottom). They used to live in two places and
# DISAGREED, which is the bug this block exists to prevent: the guard tested the RAW requested
# width (88) while the clamp would have shrunk that same panel to fit (60 on a 109-column split).
# So the guard sent the editor to its own tab on a geometry the clamp handles perfectly well —
# rejecting a layout on a number the code never actually uses.
#
# The division of labour is now strict, and it is what keeps them from drifting apart again:
#   * the GUARD answers a FLOOR question only — is there room for MIN_COLS + MIN_PEER? It never
#     looks at the requested width, because the requested width is negotiable and the floor is not.
#   * the CLAMP answers the sizing question — it alone owns MAX_FRAC and the ceilings.
# Both read these variables; neither hardcodes a number. tests/check-sizing.py parses them straight
# out of this file, so changing one here moves the test with it.
MIN_COLS=56          # SpiceEdit minWidth(50) + tab bar/status margin, so the wall is never hit
MIN_PEER=44          # below this the pane you split AWAY from stops being readable
MAX_FRAC=0.55        # past this the panel is eating the agent, which defeats the layout

# A panel can be wide enough to DRAW and still too narrow to be the thing you asked for. An Edit
# panel with no file tree renders a hamburger and the words "click open from the tree" with nothing
# to click — technically fine, useless as a file explorer.
#
# MAX_FRAC alone cannot see that: at a 130-column split it caps the panel at 71 columns without ever
# asking what 71 columns can actually SHOW — the same mistake as the old viability guard. So the
# launcher takes a per-panel "useful" threshold (argument 8) and lifts the panel to clear it whenever
# the split can host it alongside a readable peer. The bottom panels pass 0; they have no such width.
#
# 70 = herdr-edit defaultSidebarWidth(30) + minEditorAfterDrag(40): the width at which it gives the
# tree its FULL 30 columns. It is not a cliff — since the tree-narrowing change the tree stays on
# screen down to treeNeeds(42), shrinking toward minSidebarWidth(18) — so this is a comfort target,
# not a floor, which is why it may lose to MIN_PEER. (It used to be 76, the old `sidebarNeeds`, back
# when the tree vanished below that instead of narrowing. That constant no longer exists.)
TREE_COLS=70         # herdr-edit gives the file tree its full width at or above this

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

ws_id = ctx.get("workspace_id") or cur.get("workspace_id") or ""

print("\t".join([decision, out_pane or "", tab_id, cwd, ws_id]))
EOF
)"

IFS=$'\t' read -r decision target tab_id cwd ws_id <<<"${plan:-}"
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

# Still nothing? Try the WORKSPACE LABEL against PROJECTS_ROOT before giving up.
#
# WHY. A workspace whose pane cwd is $HOME gets no editor at all on auto-open, because rooting the
# tree at $HOME is the dotfile-soup problem this launcher exists to avoid. But a workspace LABELLED
# "affiliate crm" plainly names a project — herdr-plus Projects and a plain `herdr workspace create`
# both leave the root pane at $HOME unless you pass --cwd, so the label is the only thing that knows
# which repo you meant, and the panel silently never appeared. That reads as a broken extension.
#
# Matching is deliberately conservative, because opening the WRONG repo is worse than opening none:
# slugify the label, accept an exact directory match, else a UNIQUE prefix match ("affiliate crm" ->
# affiliate-crm-fintech), and require a git repo. Two or more candidates means we do not actually
# know, so we stay silent and let the existing fallbacks run.
if [ -z "$proj" ] && [ -n "${ws_id:-}" ] && [ -d "$PROJECTS_ROOT" ]; then
  proj="$("$PY" - "$("$herdr_bin" workspace list 2>/dev/null)" "$ws_id" "$PROJECTS_ROOT" <<'EOF' 2>/dev/null || true
import json, os, re, sys

ws_raw, ws_id, root = sys.argv[1:4]
try:
    spaces = json.loads(ws_raw)["result"]["workspaces"]
except Exception:
    spaces = []

label = ""
for w in spaces:
    if w.get("workspace_id") == ws_id:
        label = w.get("label") or ""
        break

# "Affiliate CRM (v2)" -> "affiliate-crm-v2". A label that slugifies to nothing cannot match.
slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
if slug:
    try:
        names = sorted(os.listdir(root))
    except OSError:
        names = []

    def is_repo(name):
        return os.path.isdir(os.path.join(root, name, ".git"))

    # Tried in order of how sure each rule is, and every rule requires a UNIQUE
    # answer: opening the wrong repository is worse than opening none, so two
    # candidates always means we stay silent and let the caller fall back.
    #
    # The suffix rule is the one that earns its keep here. Directories are
    # routinely namespaced with an owner prefix -- "vzt-prop-trading-tech" --
    # while the workspace gets called "Prop Trading Tech". A prefix-only matcher
    # scores that as zero candidates and the editor never appears, which reads
    # as the extension being broken rather than as a naming mismatch.
    def unique(cands):
        return cands[0] if len(cands) == 1 else ""

    hit = ""
    if slug in names and is_repo(slug):
        hit = slug
    if not hit:
        hit = unique([n for n in names if n.startswith(slug) and is_repo(n)])
    if not hit:
        hit = unique([n for n in names if n.endswith("-" + slug) and is_repo(n)])
    if not hit:
        # Last and loosest: the slug appears whole, delimited, somewhere in the
        # name. Still unique-or-nothing.
        hit = unique([n for n in names
                      if ("-" + slug + "-") in ("-" + n + "-") and is_repo(n)])
    if hit:
        print(os.path.join(root, hit))
EOF
)"
fi

if [ -z "$proj" ]; then
  # Not a git repo. lazygit simply cannot run here, so bail regardless of trigger.
  [ "$entrypoint" = "git" ] && exit 0
  # Auto-open stays silent rather than dumping $HOME into the tree.
  #
  # It was tempting to fall back to PROJECTS_ROOT here so a new space always got
  # SOMETHING, and that is wrong: a workspace created for a scratch shell or a
  # remote session would sprout an editor nobody asked for. ORACLE 5 guards this
  # deliberately. The right fix for "my project files do not appear" is a better
  # LABEL match (see the matcher above), not opening an editor everywhere.
  [ "$trigger" = "auto" ] && exit 0
  if [ -d "$PROJECTS_ROOT" ]; then proj="$PROJECTS_ROOT"
  elif [ -n "$cwd" ];        then proj="$cwd"
  else                            proj="$HOME"
  fi
fi

# ============================ IS A SPLIT EVEN VIABLE? ============================
# A side-by-side needs enough room for BOTH panes, and on a genuinely narrow terminal it does not
# exist at any width. Observed on a 105-column window: herdr's sidebar takes 36, leaving 69 to
# split; the editor claims its 56-column minimum and the agent is left with 13 — technically a
# split, practically useless, and the agent is the pane you were reading. THAT is what this guard
# is for, and 69 still fails it below.
#
# What it must NOT do is test the REQUESTED width. The request is a preference; the clamp shrinks
# it to fit. Asking "can I fit 88?" made the fallback fire on every split from 100 to 131 columns
# wide — a 109-column split is fine, the clamp puts the editor at 60 and leaves the agent 49 —
# so the editor kept landing in its own tab on screens that could host it perfectly well.
# The only genuinely impossible case is when the two FLOORS cannot coexist, so that is the whole
# test: MIN_COLS for the panel, MIN_PEER for the pane we split away from.
#
# Only applies to a horizontal split with a column-based size; a vertical panel and a fractional
# size are both left alone.
if [ "$mode" = "split" ] && [ "$direction" = "right" ] && [ -n "$ratio" ]; then
  avail="$("$PY" - "$("$herdr_bin" pane edges --pane "${target:-}" 2>/dev/null)" <<'EOF' 2>/dev/null || true
import json, sys
try:
    lay = json.loads(sys.argv[1])["result"]["edges"]["layout"]
    print(lay["area"]["width"])
except Exception:
    pass
EOF
)"
  if [ -n "$avail" ]; then
    case "$ratio" in
      *.*) : ;;                      # a fraction, not columns — this floor is in the wrong unit
      [0-9]*)
        # Only the editor has a tab variant to fall back to. Everything else is a bottom panel
        # (direction=down) and never reaches this branch, but be explicit rather than building an
        # entrypoint id by string concatenation that could name a pane the manifest does not have.
        if [ "$avail" -lt "$((MIN_COLS + MIN_PEER))" ] && [ "$entrypoint" = "editor" ]; then
          mode="tab"
          entrypoint="editor-tab"
        fi
        ;;
    esac
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
  move="$("$PY" - "$edges_json" "$new_pane" "$ratio" "$MIN_COLS" "$MIN_PEER" "$MAX_FRAC" "$useful" <<'EOF' 2>/dev/null || true
import json, sys

# SpiceEdit refuses to draw below 50 columns and its file tree is a fixed 30, so a panel sized as
# a bare FRACTION is a trap: 0.40 of a 200-col screen is a comfortable 80, but 0.40 of a 120-col
# laptop is 48 — under the wall, and the panel renders "Window too small — please resize".
# So the requested size is a COLUMN COUNT (>=1), converted to a ratio against the actual split,
# then clamped: never below the usable minimum, never more than MAX_FRAC of the screen, and never
# so wide that the pane we split away from drops under MIN_PEER.
#
# The requested width is a PREFERENCE, not a demand — this is the only place allowed to decide the
# final number, and the viability guard above deliberately does not second-guess it. That is why a
# 109-column split now yields a 60-column editor beside a 49-column agent instead of a fallback to
# a separate tab.
#
# NOTE no apostrophes anywhere in this heredoc. bash 3.2 (what /bin/bash still is on macOS, and
# what launchd PATH resolves) mis-parses a lone quote inside a heredoc nested in $( ), and the
# whole script then fails to parse — silently, because herdr just sees the action do nothing.
# A value below 1 is still accepted and taken as a literal fraction, for a vertical panel where
# columns are the wrong unit.
edges_raw, pane_id, target, min_cols, min_peer, max_frac, min_useful = sys.argv[1:8]
MIN_COLS = int(min_cols)     # minWidth(50) + tab bar/status margin, so the wall is never hit
MIN_PEER = int(min_peer)     # the pane we split away from stays readable
MAX_FRAC = float(max_frac)   # past this the panel is eating the agent, which defeats the layout
MIN_USEFUL = int(min_useful) # width below which this panel stops being the thing you asked for
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
        horiz = mine["direction"] == "right"      # vertical divider, panes side by side
        want = float(target)
        if want >= 1:                      # column count -> fraction of the extent of THIS split
            span = mine["rect"]["width"] if horiz else mine["rect"]["height"]
            if span <= 0:
                raise ValueError("degenerate split")
            # Cap first, then floor — and the FLOOR WINS. On a narrow terminal the two limits
            # genuinely conflict (50 cols of a 80-col screen is already 63%, over MAX_FRAC), and
            # an oversized panel is merely annoying while an under-minimum one renders nothing
            # but "Window too small". Prefer usable. Capped at 0.9 so the agent never vanishes.
            #
            # Two ceilings, both required. MAX_FRAC is a share of the screen and MIN_PEER is an
            # absolute column count, and neither implies the other: on a wide split MAX_FRAC binds
            # first, while a hand-tuned MAX_FRAC closer to 1.0 would starve the peer without the
            # second term. Taking the min of both means the requested width shrinks to fit rather
            # than being refused, which is the whole reason the guard above can stay a floor test.
            want = min(want / span, MAX_FRAC, (span - MIN_PEER) / float(span))

            # Lift to the useful threshold when it fits beside a readable peer. This deliberately
            # overrides MAX_FRAC: a panel at 55% that cannot show its file tree is not a milder
            # version of the layout, it is a different and worse one. Guarded by the same peer
            # ceiling as everything else, so it can never be the thing that starves the agent.
            if MIN_USEFUL and MIN_USEFUL <= span - MIN_PEER:
                want = max(want, MIN_USEFUL / float(span))

            want = max(want, min(MIN_COLS / span, 0.9))

        # `ratio` is the share belonging to the FIRST child, so a second-child panel that wants
        # `want` needs the ratio set to 1-want. Getting this backwards sizes the wrong pane.
        first = me["x"] == mine["rect"]["x"] and me["y"] == mine["rect"]["y"]
        delta = (want if first else 1.0 - want) - float(mine["ratio"])

        # Direction names where the DIVIDER moves, not which pane grows — verified live: on a
        # first-child pane, `--direction right --amount 0.05` took ratio 0.315 -> 0.365. So the
        # sign of the ratio delta alone picks the direction, regardless of which child we are.
        if abs(delta) >= 0.01:
            up, down = ("right", "left") if horiz else ("down", "up")
            print("%s %.4f" % (up if delta > 0 else down, abs(delta)))
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
