#!/usr/bin/env bash
# Oracle 26 — the Problems panel reports errors from the RUNNING app, not only static analysis.
#
# WHY THIS EXISTS. tsc/eslint/ruff can only tell you what is wrong with the source. They cannot tell
# you the app threw at runtime, which is the failure a user actually hits. The Preview panel is
# already driving headless Chrome at the running app, so the console it prints is free evidence --
# Chrome with --enable-logging=stderr --v=1 emits both console.error output and uncaught exceptions
# as `[...:CONSOLE:N] "MESSAGE", source: URL (LINE)`. Preview parses those into a small log and
# Problems reads it. No CDP client, no websocket, no new dependency.
#
# Runs entirely OFFLINE and never launches Chrome: every case feeds libexec/problems a hand-written
# fixture log. Chrome behaviour is not what is under test here -- the PARSER and the panel are.
#
# 🔴 The two cases that matter most are 26b and 26c. Chrome's format is comma-delimited and quote-
# wrapped, so a naive split lands mid-message on any real error text: "Cannot read properties of
# null, reading 'f'" would be truncated at the comma, and a message containing its own quotes would
# end early. A parser that works only on messages without punctuation is a parser that works only on
# examples.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A throwaway git repo so the panel has a root to resolve and a real file to map a URL back onto.
REPO="$TMP/repo"
mkdir -p "$REPO/src"
( cd "$REPO" && git init -q . && printf 'x\n' > src/app.js && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1

STATE="$TMP/state"
LOGDIR="$STATE/herdr-extensions"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/preview-console.log"

US="$(printf '\037')" # the unit separator the contract uses -- NOT a tab, which is IFS whitespace

# write_log <line>... — each argument is one already-assembled record.
write_log() {
  : > "$LOG"
  for rec in "$@"; do printf '%s\n' "$rec" >> "$LOG"; done
}

# run_problems — run the panel against the fixture and capture stdout.
# 🔴 HARD BOUNDED. The regression this guards is a panel that waits forever, and an unbounded oracle
# hangs the gate rather than failing it -- a hanging gate is no better than one that is never run.
# macOS ships no `timeout`, so background-and-poll is the portable shape.
run_problems() {
  local out="$TMP/out.$$"
  ( cd "$REPO" && XDG_STATE_HOME="$STATE" /bin/bash "$ROOT/libexec/problems" </dev/null >"$out" 2>&1 ) &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge 25 ]; then
      kill -9 "$pid" 2>/dev/null
      echo "__TIMEOUT__"
      return 1
    fi
  done
  wait "$pid" 2>/dev/null
  cat "$out"
}

# --- 26a: a runtime record reaches the panel, mapped, with its line and message ------------------
write_log \
  "http://localhost:3000/src/app.js${US}12${US}widget failed to mount" \
  "http://localhost:3000/src/app.js${US}7${US}second problem here"
got="$(run_problems)"

if [ "$got" = "__TIMEOUT__" ]; then
  no "26a: problems returned without hanging"
else
  ok "26a: problems returned without hanging"

  case "$got" in
    *"src/app.js"*) ok "26a: the URL is mapped back to the repo-relative file" ;;
    *) no "26a: the URL was not mapped to src/app.js" ;;
  esac
  case "$got" in
    *"12:"*) ok "26a: the record reports the right line" ;;
    *) no "26a: line 12 is missing from the output" ;;
  esac
  case "$got" in
    *"widget failed to mount"*) ok "26a: the record reports the message" ;;
    *) no "26a: the message is missing from the output" ;;
  esac
  # The section has to be legible as RUNTIME, or a user reads a thrown exception as a lint error
  # and goes looking in the wrong place entirely.
  case "$got" in
    *[Rr]untime*) ok "26a: the runtime section is clearly labelled, distinct from tsc/eslint/ruff" ;;
    *) no "26a: nothing in the output identifies these as runtime problems" ;;
  esac
fi

# --- 26b: a message containing a comma survives -------------------------------------------------
# Chrome's line is comma-delimited. Splitting on the comma truncates every real error message.
write_log "http://localhost:3000/src/app.js${US}3${US}Cannot read properties of null, reading f"
got="$(run_problems)"
case "$got" in
  *"Cannot read properties of null, reading f"*) ok "26b: a message containing commas survives intact" ;;
  *) no "26b: a comma truncated the message" ;;
esac

# --- 26c: a message containing double quotes survives -------------------------------------------
# The message arrives quote-wrapped, so an inner quote ends it early under a lazy match.
write_log "http://localhost:3000/src/app.js${US}4${US}Unexpected token \"}\" in JSON"
got="$(run_problems)"
case "$got" in
  *'Unexpected token "}" in JSON'*) ok "26c: a message containing quotes survives intact" ;;
  *) no "26c: an embedded quote truncated the message" ;;
esac

# --- 26d: a stale log is ignored ----------------------------------------------------------------
# A log from a preview that ran an hour ago describes an app that no longer exists. Reporting it is
# worse than silence: the user chases an error they already fixed.
write_log "http://localhost:3000/src/app.js${US}9${US}ancient stale failure"
/usr/bin/touch -t 200001010000 "$LOG" 2>/dev/null || touch -d "2000-01-01" "$LOG" 2>/dev/null
got="$(run_problems)"
case "$got" in
  *"ancient stale failure"*) no "26d: a stale log's records still surfaced" ;;
  *) ok "26d: a stale log's records do not surface" ;;
esac
case "$got" in
  *[Rr]untime*) no "26d: a stale log still printed a runtime section" ;;
  *) ok "26d: a stale log prints nothing extra -- absence is not an error" ;;
esac

# --- 26e: a missing log is silent, and does not disturb static analysis -------------------------
rm -f "$LOG"
got="$(run_problems)"
case "$got" in
  *[Rr]untime*) no "26e: a missing log still produced a runtime section" ;;
  *) ok "26e: a missing log produces no runtime section" ;;
esac
case "$got" in
  *Problems*) ok "26e: the existing static-analysis output is unaffected by a missing runtime log" ;;
  *) no "26e: the panel stopped printing its normal output when the log was absent" ;;
esac

echo
printf "  %d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
