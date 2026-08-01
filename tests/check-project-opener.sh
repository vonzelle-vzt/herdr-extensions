#!/usr/bin/env bash
# Oracle 28 — the project opener re-roots the editor AND the space on a real repo.
#
# WHY IT MATTERS. A new herdr space starts in $HOME, so the editor that auto-opens with it has no
# project to show. You then start an agent and cd into a repo, but the editor pane opened BEFORE
# that and never learns. The observable symptom is "the folders do not show up" -- an editor pane
# sitting next to an agent that is working somewhere else entirely.
#
# Runs fully OFFLINE: a stub herdr on PATH records every subcommand, so what the opener ASKS FOR is
# asserted rather than assumed. No real panes are opened and no real workspace is renamed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/log"

mkdir -p "$TMP/projects/plain-dir"
PROJECTS="$(cd "$TMP/projects" && pwd -P)"
/usr/bin/git init -q "$PROJECTS/alpha-svc"
/usr/bin/git init -q "$PROJECTS/beta-web"

cat > "$TMP/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list") printf '%s' "${HERDR_STUB_PANES:-}" ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wA","label":"%s","number":1}]},"type":"workspace_list"}' "$FZF_PICK"
    ;;
  "pane edges")
    printf '{"result":{"edges":{"layout":{"area":{"height":50,"width":200,"x":0,"y":1},"panes":[{"pane_id":"wA:p2","rect":{"height":50,"width":200,"x":0,"y":1}},{"pane_id":"wA:p9","rect":{"height":50,"width":100,"x":100,"y":1}}],"splits":[{"direction":"right","ratio":0.5,"rect":{"height":50,"width":200,"x":0,"y":1}}]}}},"type":"pane_edges"}'
    ;;
  "plugin pane")
    printf '{"result":{"plugin_pane":{"pane":{"pane_id":"wA:p9"}}},"type":"plugin_pane"}'
    ;;
esac
exit 0
STUB
chmod +x "$TMP/herdr"

# fzf stub: always picks whatever FZF_PICK names, so the choice is deterministic.
cat > "$TMP/fzf" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$FZF_PICK"
exit 0
STUB
chmod +x "$TMP/fzf"

OPEN_PANEL="$TMP/open-panel.sh"
/usr/bin/python3 - "$ROOT/plugin/open-panel.sh" "$OPEN_PANEL" "$TMP/herdr" "$PROJECTS" <<'PYEOF'
import sys
src, dst, herdr, projects = sys.argv[1:5]
open(dst, "w").write(open(src).read()
    .replace("@@HERDR@@", herdr)
    .replace("@@PROJECTS_ROOT@@", projects))
PYEOF
chmod +x "$OPEN_PANEL"

SCRIPT="$TMP/project.sh"
/usr/bin/python3 - "$ROOT/plugin/project.sh" "$SCRIPT" "$TMP/herdr" "$TMP/fzf" "$PROJECTS" <<'PYEOF'
import sys
src, dst, herdr, fzf, projects = sys.argv[1:6]
open(dst, "w").write(open(src).read()
    .replace("@@HERDR@@", herdr)
    .replace("@@FZF@@", fzf)
    .replace("@@GIT@@", "/usr/bin/git")
    .replace("@@PROJECTS_ROOT@@", projects))
PYEOF
chmod +x "$SCRIPT"

PANES='{"result":{"panes":[{"pane_id":"wA:p1","workspace_id":"wA","label":"Edit","focused":false},{"pane_id":"wA:p2","workspace_id":"wA","agent":"claude","focused":true}]},"type":"pane_list"}'

run_opener() {
  : > "$LOG"
  printf '\n' | env HERDR_STUB_LOG="$LOG" HERDR_STUB_PANES="$PANES" \
    HERDR_WORKSPACE_ID="wA" FZF_PICK="$1" /bin/bash "$SCRIPT" >"$TMP/out" 2>&1
}

# --- 28a: the editor is reopened ROOTED AT the chosen repo --------------------------------------
run_opener "beta-web"
if grep -q -- "--cwd $PROJECTS/beta-web" "$LOG"; then
  ok "28a: the editor is reopened with --cwd at the chosen repo"
else
  no "28a: no --cwd for the chosen repo; herdr saw: $(grep 'pane open' "$LOG" | head -1)"
fi
if grep -q "plugin pane open .*--entrypoint editor" "$LOG"; then
  ok "28a: and it is the editor entrypoint, not some other pane"
else
  no "28a: the editor entrypoint was not opened"
fi

# --- 28b: the OLD editor pane is closed first ---------------------------------------------------
# Reopening without closing leaves two editors side by side rooted at different projects, which is
# the confusion this panel exists to remove.
if grep -q "pane close wA:p1" "$LOG"; then
  ok "28b: the existing Edit pane is closed before reopening"
else
  no "28b: the old editor pane was left open"
fi

# --- 28c: the agent pane is NEVER closed --------------------------------------------------------
# Closing the pane the user is talking to would be catastrophic and is entirely possible if the
# close filter matches on the wrong field.
if grep -q "pane close wA:p2" "$LOG"; then
  no "28c: the AGENT pane was closed"
else
  ok "28c: the agent pane is untouched"
fi

# --- 28d: the space is renamed, so auto-open resolves it unaided next time -----------------------
if grep -q "workspace rename wA beta-web" "$LOG"; then
  ok "28d: the space is renamed after the repo, so it opens itself next time"
else
  no "28d: the space was not renamed"
fi

# --- 28e: a plain directory is never offered ----------------------------------------------------
# The listing must contain only real checkouts; opening a non-repo gives a tree with no git status
# and every panel degrading.
run_opener "plain-dir"
if grep -q -- "--cwd $PROJECTS/plain-dir" "$LOG"; then
  no "28e: a directory with no .git was opened as a project"
else
  ok "28e: a directory with no .git is refused"
fi

echo
printf "  %d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
