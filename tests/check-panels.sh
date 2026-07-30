#!/usr/bin/env bash
# Oracle 16 — panel scripts parse under the bash that actually runs them, and read the active-file
# contract correctly in BOTH states.
#
# The second half exists because of a bug that produced no error at all: the panels split the
# active.json payload on a TAB, and tab is IFS *whitespace*, so bash collapses runs of it and drops
# leading and trailing empty fields. With no file open the payload begins with an empty field, so
# every value shifted left and the line number landed in the filename variable. The panel then
# happily reported `active: 1:` and carried on. \x1f is non-whitespace and preserves empty fields.
#
# Runs entirely offline: no herdr server, no editor, just a fabricated active.json.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

PANELS="$(ls "$ROOT"/libexec/ | grep -v herdr-fmt)"

# --- 16a: every panel parses under /bin/bash, which on macOS is still 3.2 -----------------------
for p in $PANELS; do
  if /bin/bash -n "$ROOT/libexec/$p" 2>/dev/null; then
    ok "16a: libexec/$p parses under bash $(/bin/bash --version | head -1 | grep -o '[0-9]\+\.[0-9]\+')"
  else
    no "16a: libexec/$p does not parse under bash 3.2"
  fi
done

# --- 16b: no apostrophe inside a heredoc (bash 3.2 mis-parses it inside $( )) -------------------
if /usr/bin/python3 - "$ROOT" <<'PYEOF'
import glob, os, sys
bad = []
for fn in glob.glob(os.path.join(sys.argv[1], "libexec", "*")) + glob.glob(os.path.join(sys.argv[1], "plugin", "*.sh")):
    inside = False
    for i, line in enumerate(open(fn, errors="replace").read().splitlines(), 1):
        if "<<" + chr(39) + "EOF" + chr(39) in line:
            inside = True
            continue
        if line.strip() == "EOF":
            inside = False
            continue
        if inside and chr(39) in line:
            bad.append("%s:%d" % (os.path.basename(fn), i))
if bad:
    print(" ".join(bad))
sys.exit(1 if bad else 0)
PYEOF
then
  ok "16b: no apostrophes inside any heredoc"
else
  no "16b: an apostrophe inside a heredoc will break bash 3.2"
fi

# --- 16c: the active-file contract, in both states ----------------------------------------------
STATE="$(mktemp -d)"
mkdir -p "$STATE/spiceedit"
REPO="$(cd "$ROOT" && /usr/bin/git rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")"

# Panels split into two kinds, and conflating them makes this test lie:
#   repo-scoped  (search, todo, problems, tests, debug) work without any file and must name the repo
#   file-scoped  (blame, markdown) are meaningless without one and must SAY so, not guess
REPO_SCOPED="search todo problems tests debug"
FILE_SCOPED="blame markdown"

# No file open. The payload starts with an empty field — the exact shape that used to shift every
# value one position left and put the line number into the filename.
printf '{"file":"","line":1,"col":1,"root":"%s","ts":1}\n' "$REPO" > "$STATE/spiceedit/active.json"
for p in $PANELS; do
  out="$(printf '' | XDG_STATE_HOME="$STATE" "$ROOT/libexec/$p" 2>&1 | head -6)"
  # This is the regression itself: a bare number where a path belongs.
  if printf '%s' "$out" | grep -qE 'active: *[0-9]+:'; then
    no "16c: $p misread the empty-file payload (line number landed in the filename)"
    continue
  fi
  case " $FILE_SCOPED " in
    *" $p "*)
      if printf '%s' "$out" | grep -q "No active file"; then
        ok "16c: $p correctly reports it has no file to work on"
      else
        no "16c: $p should say it has no active file"
      fi
      ;;
    *)
      if printf '%s' "$out" | grep -q "$REPO"; then
        ok "16c: $p resolved the repo with no file open"
      else
        no "16c: $p did not resolve the repo with no file open"
      fi
      ;;
  esac
done

# A file IS open. Asserting on the filename appearing in the output is wrong for a renderer like
# glow, which shows the file CONTENT; the invariant that actually holds for all of them is that
# none may still claim there is no active file.
printf '{"file":"%s/README.md","line":42,"col":7,"root":"%s","ts":1}\n' "$REPO" "$REPO" > "$STATE/spiceedit/active.json"
for p in $FILE_SCOPED debug; do
  [ -f "$ROOT/libexec/$p" ] || continue
  out="$(printf '' | XDG_STATE_HOME="$STATE" "$ROOT/libexec/$p" 2>&1 | head -20)"
  if printf '%s' "$out" | grep -q "No active file"; then
    no "16d: $p did not pick up the active file"
  else
    ok "16d: $p picked up the active file"
  fi
done

# Absent active.json must degrade, not error.
rm -f "$STATE/spiceedit/active.json"
for p in $PANELS; do
  if printf '' | XDG_STATE_HOME="$STATE" "$ROOT/libexec/$p" >/dev/null 2>&1; then
    ok "16e: $p survives a missing active.json"
  else
    no "16e: $p failed with no active.json"
  fi
done

rm -rf "$STATE"
echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
