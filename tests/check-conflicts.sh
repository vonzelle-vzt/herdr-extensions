#!/usr/bin/env bash
# Oracle -- Conflict Guard reports agents sharing one checkout and treats separate git worktrees
# from the same repo as the safe Orca-style shape.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/log"

REPO="$TMP/repo"
/usr/bin/git init -q "$REPO"
(
  cd "$REPO" || exit 1
  /usr/bin/git config user.email test@example.com
  /usr/bin/git config user.name Test
  printf "base\n" > README.md
  /usr/bin/git add README.md
  /usr/bin/git commit -q -m init
)
/usr/bin/git -C "$REPO" worktree add -q -b unit-a "$TMP/wt-a" HEAD
/usr/bin/git -C "$REPO" worktree add -q -b unit-b "$TMP/wt-b" HEAD

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list") printf '%s' "$HERDR_STUB_PANES" ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"

run_panel() {
  : > "$LOG"
  PATH="$STUB_BIN:$PATH" HERDR_PANEL_NO_WAIT=1 HERDR_BIN_PATH=herdr HERDR_STUB_LOG="$LOG" HERDR_STUB_PANES="$1" \
    /bin/bash "$ROOT/libexec/conflicts" >"$TMP/out" 2>&1
}

PANES_SAME="$(printf '{"result":{"panes":[
{"pane_id":"p1","workspace_id":"w1","agent":"claude","agent_status":"working","cwd":"%s","foreground_cwd":"%s"},
{"pane_id":"p2","workspace_id":"w2","agent":"codex","agent_status":"working","cwd":"%s","foreground_cwd":"%s"}
]}}' "$REPO" "$REPO" "$REPO" "$REPO")"

run_panel "$PANES_SAME"
if grep -q "DANGER: multiple agents share the same checkout" "$TMP/out"; then
  ok "a) same-checkout agents are reported as dangerous"
else
  no "a) same-checkout agents were not reported -- output: $(cat "$TMP/out")"
fi
if grep -q "p1 claude working" "$TMP/out" && grep -q "p2 codex working" "$TMP/out"; then
  ok "a) the colliding agent panes are named"
else
  no "a) colliding panes are missing -- output: $(cat "$TMP/out")"
fi

PANES_WT="$(printf '{"result":{"panes":[
{"pane_id":"p1","workspace_id":"w1","agent":"claude","agent_status":"working","cwd":"%s","foreground_cwd":"%s"},
{"pane_id":"p2","workspace_id":"w2","agent":"codex","agent_status":"working","cwd":"%s","foreground_cwd":"%s"}
]}}' "$TMP/wt-a" "$TMP/wt-a" "$TMP/wt-b" "$TMP/wt-b")"

run_panel "$PANES_WT"
if grep -q "No same-checkout agent collisions found" "$TMP/out"; then
  ok "b) separate worktrees are not treated as a collision"
else
  no "b) separate worktrees were reported incorrectly -- output: $(cat "$TMP/out")"
fi
if grep -q "Isolated worktrees from the same repo" "$TMP/out"; then
  ok "b) separate worktrees are explicitly identified as isolated"
else
  no "b) isolated worktree summary missing -- output: $(cat "$TMP/out")"
fi

PANES_HOME='{"result":{"panes":[{"pane_id":"p3","workspace_id":"w3","agent":"claude","agent_status":"idle","cwd":"/tmp","foreground_cwd":"/tmp"}]}}'
run_panel "$PANES_HOME"
if grep -q "Agents outside a git repo" "$TMP/out"; then
  ok "c) agents outside a git repo are called out"
else
  no "c) non-repo agent was not called out -- output: $(cat "$TMP/out")"
fi

echo
printf "  %d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
