#!/usr/bin/env bash
# Oracle 18 — a workspace named after a project opens that project, and an ambiguous name opens
# nothing.
#
# WHY. `herdr workspace create` and herdr-plus Projects both leave the root pane at $HOME unless you
# pass --cwd. The launcher refuses to root the file tree at $HOME on auto-open (dotfile soup), so a
# workspace labelled "affiliate crm" got no editor at all and the extension looked broken. The label
# is the only thing that knows which repo you meant, so we resolve it against PROJECTS_ROOT.
#
# The risk this pins is the opposite failure: opening the WRONG repo is worse than opening none. So
# a prefix match must be UNIQUE, and a non-repo directory must never win.
#
# Renders the launcher the way `herdr-extensions install` does (PROJECTS_ROOT is a @@template@@ in
# the repo copy, so the raw file can never exercise this path) and drives it against a stub herdr.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECTS="$TMP/projects"
LOG="$TMP/log"

# Two repos sharing a prefix, plus a plain directory that is NOT a repo.
mkdir -p "$PROJECTS/demo-alpha/.git" "$PROJECTS/demo-alpha-extra/.git" "$PROJECTS/notes-only"
# An OWNER-PREFIXED repo: the directory carries a namespace the workspace label does not.
# "Prop Trading Tech" -> prop-trading-tech, while the checkout is vzt-prop-trading-tech.
mkdir -p "$PROJECTS/vzt-prop-trading-tech/.git"
# An AMBIGUOUS pair: two repos a single label could plausibly mean.
mkdir -p "$PROJECTS/vzt-protocol-core/.git" "$PROJECTS/vzt-protocol-docs/.git"

# Render the launcher exactly as install does.
LAUNCHER="$TMP/open-panel.sh"
/usr/bin/python3 - "$ROOT/plugin/open-panel.sh" "$LAUNCHER" "$PROJECTS" <<'PYEOF'
import sys
src, dst, projects = sys.argv[1:4]
open(dst, "w").write(open(src).read().replace("@@PROJECTS_ROOT@@", projects))
PYEOF
chmod +x "$LAUNCHER"

cat > "$TMP/herdr" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list")
    # cwd is $HOME, i.e. not a repo — the whole point of this oracle.
    printf '{"result":{"panes":[{"pane_id":"wT:p1","tab_id":"wT:t1","workspace_id":"wT","focused":true,"cwd":"%s","foreground_cwd":"%s"}]},"type":"pane_list"}' \
      "$HOME" "$HOME"
    ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wT","label":"%s","number":1}]},"type":"workspace_list"}' \
      "$HERDR_STUB_LABEL"
    ;;
  "pane edges")
    printf '{"result":{"edges":{"layout":{"area":{"height":50,"width":200,"x":0,"y":1},"panes":[{"pane_id":"wT:p1","rect":{"height":50,"width":200,"x":0,"y":1}}],"splits":[]}},"pane_id":"wT:p1"},"type":"pane_edges"}'
    ;;
  "plugin pane")
    printf '{"result":{"plugin_pane":{"pane":{"pane_id":"wT:p9"}}},"type":"plugin_pane"}'
    ;;
esac
exit 0
STUBEOF
chmod +x "$TMP/herdr"

# Runs the auto-open path for a workspace with the given label; prints the --cwd it chose, if any.
resolved_for() {
  : > "$LOG"
  HERDR_BIN_PATH="$TMP/herdr" HERDR_STUB_LOG="$LOG" HERDR_STUB_LABEL="$1" \
  HERDR_PANE_ID="wT:p1" HERDR_PLUGIN_CONTEXT_JSON="" \
    /bin/bash "$LAUNCHER" editor Edit split right auto yes 88 76 >/dev/null 2>&1
  grep -o -- "--cwd [^ ]*" "$LOG" | head -1 | awk '{print $2}'
}

# --- 18a: a unique prefix match wins ------------------------------------------------------------
# "affiliate crm" -> affiliate-crm-fintech was the real case; here "demo alpha extra" is unique.
got="$(resolved_for "demo alpha extra")"
if [ "$got" = "$PROJECTS/demo-alpha-extra" ]; then
  ok "18a: label 'demo alpha extra' -> demo-alpha-extra (unique prefix)"
else
  no "18a: label 'demo alpha extra' -> ${got:-<nothing>}, expected $PROJECTS/demo-alpha-extra"
fi

# --- 18b: an EXACT match beats a longer prefix sibling ------------------------------------------
# "demo alpha" also prefixes demo-alpha-extra. Exactness must win, or the wrong repo opens.
got="$(resolved_for "demo alpha")"
if [ "$got" = "$PROJECTS/demo-alpha" ]; then
  ok "18b: label 'demo alpha' -> demo-alpha (exact beats the longer sibling)"
else
  no "18b: label 'demo alpha' -> ${got:-<nothing>}, expected $PROJECTS/demo-alpha"
fi

# --- 18c: an ambiguous prefix NEVER guesses a repo ----------------------------------------------
# "demo" prefixes two repos. Guessing would root the tree in the wrong project, which is worse than
# not opening one -- you would edit the wrong checkout without noticing. The fallback is the project
# list, never one of the candidates.
got="$(resolved_for "demo")"
if [ -z "$got" ]; then
  ok "18c: ambiguous label 'demo' opens nothing rather than guessing"
else
  no "18c: ambiguous label 'demo' resolved to $got"
fi

# --- 18d: a directory that is not a repo never wins ---------------------------------------------
got="$(resolved_for "notes only")"
if [ -z "$got" ]; then
  ok "18d: 'notes only' matches a plain directory, so it is not used"
else
  no "18d: non-repo directory resolved to $got"
fi

# --- 18e: a label that matches nothing stays silent on auto-open --------------------------------
# The contract: auto-open must never dump $HOME into the tree, and must not sprout an editor in a
# workspace created for something other than a project. ORACLE 5 guards the live half of this.
got="$(resolved_for "nothing like this exists")"
if [ -z "$got" ]; then
  ok "18e: an unmatched label still opens no editor on auto-open"
else
  no "18e: unmatched label resolved to $got"
fi
if [ "$got" != "$HOME" ]; then
  ok "18e: and it is never \$HOME"
else
  no "18e: auto-open rooted the tree at \$HOME"
fi

# --- 18f: a label that slugifies to nothing cannot match ----------------------------------------
got="$(resolved_for "~")"
if [ -z "$got" ]; then
  ok "18f: a label with no alphanumerics resolves to nothing"
else
  no "18f: label '~' resolved to $got"
fi

# --- 18g: a real repo cwd still outranks the label ----------------------------------------------
# Label resolution is a FALLBACK. If the pane is already inside a repo, that repo wins.
: > "$LOG"
HERDR_BIN_PATH="$TMP/herdr" HERDR_STUB_LOG="$LOG" HERDR_STUB_LABEL="demo alpha" \
HERDR_PANE_ID="wT:p1" \
HERDR_PLUGIN_CONTEXT_JSON="{\"workspace_id\":\"wT\",\"tab_id\":\"wT:t1\",\"focused_pane_id\":\"wT:p1\",\"focused_pane_cwd\":\"$ROOT\"}" \
  /bin/bash "$LAUNCHER" editor Edit split right auto yes 88 76 >/dev/null 2>&1
got="$(grep -o -- "--cwd [^ ]*" "$LOG" | head -1 | awk '{print $2}')"
if [ "$got" = "$ROOT" ]; then
  ok "18g: a pane already inside a repo ignores the label"
else
  no "18g: repo cwd gave ${got:-<nothing>}, expected $ROOT"
fi

# --- 18h: an OWNER-PREFIXED directory is found by suffix ----------------------------------------
# This is the case that sent a real workspace to no editor at all: directories are routinely
# namespaced ("vzt-prop-trading-tech") while the space is named for the product ("Prop Trading
# Tech"). A prefix-only matcher scores that zero and gives up.
got="$(resolved_for "Prop Trading Tech")"
if [ "$got" = "$PROJECTS/vzt-prop-trading-tech" ]; then
  ok "18h: an owner-prefixed repo is matched from the product-named label"
else
  no "18h: 'Prop Trading Tech' resolved to ${got:-<nothing>}, expected $PROJECTS/vzt-prop-trading-tech"
fi

# --- 18i: ambiguity NEVER guesses a repo -------------------------------------------------------
# Two plausible candidates means we do not know. Opening the wrong repository is worse than opening
# none, so this must land on the project list rather than pick a winner.
got="$(resolved_for "VZT Protocol")"
case "$got" in
  "$PROJECTS/vzt-protocol-core"|"$PROJECTS/vzt-protocol-docs")
    no "18i: an ambiguous label GUESSED $got" ;;
  "")
    ok "18i: an ambiguous label refuses to guess and opens nothing" ;;
  *)
    no "18i: ambiguous label resolved to $got" ;;
esac

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
