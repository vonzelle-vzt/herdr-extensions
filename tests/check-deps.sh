#!/usr/bin/env bash
# Oracle 25 — the dependency installer taps the repo that actually contains each formula.
#
# THE BUG THIS PINS. install_deps tapped `cloudmanic/spice-edit` — upstream, which ships only
# spice-edit.rb — and then installed `vonzelle-vzt/herdr-edit/herdr-edit`, from a tap it had never
# added. On any machine without the editor already present, the very first step of a fresh install
# died with:
#
#   Error: No available formula or cask with the name "vonzelle-vzt/herdr-edit/herdr-edit".
#   This command requires the tap vonzelle-vzt/herdr-edit.
#
# It was invisible to everyone who already had the editor, because that whole branch is skipped when
# `editor_bin()` finds one — i.e. invisible to every machine that had ever worked, and broken on every
# machine that had not. Exactly the class of failure this package exists to prevent, sitting in its own
# installer.
#
# Runs offline: the check is a static consistency property of the source, not a brew invocation.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

# --- 25a: every (install-from-tap, tap-added) pair must name the SAME tap ------------------------
if /usr/bin/python3 - "$ROOT/bin/herdr-extensions" <<'PYEOF'
import re, sys

src = open(sys.argv[1]).read()

# Each step is ("name", ["brew","install", <spec>], ["brew","tap", <tap>, <url>] | None).
# Pull the install spec and the tap out of every step that has both, then require agreement.
steps = re.findall(
    r'steps\.append\(\(\s*"(?P<name>[^"]+)"\s*,\s*\[(?P<cmd>[^\]]*)\]\s*,\s*'
    r'(?:\[(?P<tap>[^\]]*)\]|None)\s*\)\s*\)',
    src, re.S)

problems = []
checked = 0
for name, cmd, tap in steps:
    spec = re.findall(r'"([^"]+)"', cmd)
    if len(spec) < 3 or spec[1] != "install":
        continue
    formula = spec[2]
    # A bare formula name (lazygit) needs no tap; a user/repo/formula spec does.
    if formula.count("/") != 2:
        if tap.strip():
            problems.append("%s: installs core formula %r but also adds a tap" % (name, formula))
        continue
    checked += 1
    want_tap = "/".join(formula.split("/")[:2])
    if not tap.strip():
        problems.append("%s: installs %r from a tap that is never added (needs %r)"
                        % (name, formula, want_tap))
        continue
    tap_args = re.findall(r'"([^"]+)"', tap)
    got_tap = tap_args[2] if len(tap_args) > 2 else "<none>"
    if got_tap != want_tap:
        problems.append("%s: installs from %r but taps %r — a fresh install cannot resolve it"
                        % (name, want_tap, got_tap))
        continue
    # The URL, when present, must point at the same repo as the tap.
    url = tap_args[3] if len(tap_args) > 3 else ""
    if url:
        owner, repo = want_tap.split("/")
        if not url.rstrip("/").endswith("%s/%s" % (owner, repo)):
            problems.append("%s: taps %r but the URL is %r" % (name, want_tap, url))

if checked == 0:
    print("no tapped formulas found to check — the parser has drifted from the source")
    sys.exit(1)
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PYEOF
then
  ok "25a: every tapped formula is installed from the tap that is actually added"
else
  no "25a: a tap/install mismatch would break a fresh install"
fi

# --- 25b: the tap named in the source is the repo that holds our formula ------------------------
# Belt and braces on the specific one that broke, checked against the sibling checkout when present.
FORMULA_REPO="$HOME/github-projects/herdr-edit"
if [ -f "$FORMULA_REPO/Formula/herdr-edit.rb" ]; then
  if grep -q '"brew", "tap", "vonzelle-vzt/herdr-edit"' "$ROOT/bin/herdr-extensions"; then
    ok "25b: taps vonzelle-vzt/herdr-edit, which is where Formula/herdr-edit.rb lives"
  else
    no "25b: the editor tap does not match the repo containing Formula/herdr-edit.rb"
  fi
else
  ok "25b: skipped — no local herdr-edit checkout to cross-check against"
fi

# --- 25c: upstream must not be tapped for our formula ------------------------------------------
# The original bug in its exact form, so it cannot come back by copy-paste.
if grep -A3 '"herdr-edit", \["brew", "install"' "$ROOT/bin/herdr-extensions" \
   | grep -q "cloudmanic/spice-edit"; then
  no "25c: the editor step still taps upstream cloudmanic/spice-edit"
else
  ok "25c: the editor step does not tap upstream, which ships spice-edit.rb only"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
