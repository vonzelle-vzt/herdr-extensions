#!/usr/bin/env bash
# resize-pane.sh — nudge the split divider one step, bound to a single keypress.
#
#   resize-pane.sh <left|right|up|down> [amount]
#
# WHY THIS EXISTS. herdr 0.7.5 has no mouse divider drag. Its full keybinding action list —
# readable straight out of the binary — is split_vertical, close_pane, resize_mode, toggle_sidebar
# and friends: there is no drag action and no sash concept anywhere, and `mouse_capture = true`
# hands mouse events to any pane app that requests them, which a mouse-first editor does. So
# grabbing the divider with the mouse does nothing, and the only built-in path is `resize_mode`
# (prefix+r), a modal you enter and leave.
#
# This is the missing middle: one keypress moves the divider one step, the way cmd+alt+arrow does
# in a normal IDE. It cannot make the mouse work — only herdr can do that — but it removes the mode.
#
# DIRECTION IS WHERE THE DIVIDER GOES, not which pane grows. That is herdr's own convention for
# `pane resize --direction`, and it is the one that stays predictable no matter which pane has
# focus: right always means "the boundary moves right".
set -uo pipefail

dir="${1:-right}"
amount="${2:-0.05}"

# Absolute path, rendered at install time. The herdr server execs plugin actions under launchd with
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, where neither /opt/homebrew/bin nor /usr/local/bin exists, so
# a bare `herdr` never resolves and the action fails silently.
herdr_bin="${HERDR_BIN_PATH:-@@HERDR@@}"
PY=/usr/bin/python3

case "$dir" in
  left | right | up | down) : ;;
  *)
    exit 0
    ;;
esac

# Resolve the pane to resize. Order of truth matches open-panel.sh: the context herdr injects for an
# action, then the invoking pane, then whatever `pane list` calls focused. `pane current --current`
# is deliberately NOT used — it resolves $HERDR_PANE_ID, i.e. the pane the CLI was invoked FROM.
pane="$("$PY" - "$("$herdr_bin" pane list 2>/dev/null)" "${HERDR_PLUGIN_CONTEXT_JSON:-}" "${HERDR_PANE_ID:-}" <<'EOF' 2>/dev/null || true
import json, sys

panes_raw, ctx_raw, env_pane = sys.argv[1:4]
try:
    panes = json.loads(panes_raw)["result"]["panes"]
except Exception:
    panes = []
try:
    ctx = json.loads(ctx_raw) if ctx_raw else {}
except Exception:
    ctx = {}

by_id = {p.get("pane_id"): p for p in panes}
pid = ctx.get("focused_pane_id") or env_pane or ""
if pid not in by_id:
    pid = next((p.get("pane_id") for p in panes if p.get("focused")), "")
print(pid or "")
EOF
)"

[ -n "${pane:-}" ] || exit 0
exec "$herdr_bin" pane resize --pane "$pane" --direction "$dir" --amount "$amount"
