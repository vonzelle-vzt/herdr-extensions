#!/usr/bin/env bash
# Oracle 26 — install_deps() actually installs language servers, and doctor names what's missing.
#
# THE GAP THIS PINS. herdr-extensions installed herdr-edit, lazygit, a Nerd Font and prettier --
# and not one language server. herdr-edit's whole competitive claim is "language intelligence in a
# terminal", so for anyone whose stack is TypeScript or Python (no LSP binary already on PATH from
# some other tool) the editor had no diagnostics, no hover, no go-to-definition, no completion at
# all -- silently, with nothing telling the user why.
#
# This suite checks the pieces bin/herdr-extensions now provides: detect_languages() (marker-file
# scanning under a projects root), lsp_candidates()/the registry-vs-fallback derivation, and
# install_lang_servers()'s dry-run reporting. It imports the CLI as a Python module rather than
# shelling out, because assertions here need to inspect return values (the could_determine
# tri-state) that stdout alone does not carry.
#
# Runs entirely offline against fixtures under mktemp -d -- never the user's real ~/github-projects
# (see CLAUDE.md: never delete/scan foreign work; oracle 25's fixtures follow the same rule).
#
# 🔴 Confirm this suite goes RED before it goes green: `git stash` the fix and re-run it. Against
# the unmodified bin/herdr-extensions, detect_languages/lsp_candidates/install_lang_servers do not
# exist at all. Every section below is wrapped in its own try/except FOR EXACTLY THIS REASON: a
# bare AttributeError would crash the whole Python process before it printed a single PASS/FAIL
# line, and an empty $OUT would silently read back as "0 passed, 0 failed" -- exit 0, a gate that
# looks green while never having run. Each section instead reports itself as a named FAIL when the
# code under test does not exist yet, and the bash side below additionally refuses to treat an
# empty $OUT as success.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/herdr-extensions"
pass=0
fail=0
ok() { printf "  \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass + 1)); }
no() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail + 1)); }

FIXROOT="$(mktemp -d)"
trap 'rm -rf "$FIXROOT"' EXIT

# --- fixtures: a fabricated projects root, never the user's real one ---------------------------
mkdir -p "$FIXROOT/multi/go-svc" "$FIXROOT/multi/ts-app" "$FIXROOT/multi/py-lib"
: > "$FIXROOT/multi/go-svc/go.mod"
: > "$FIXROOT/multi/ts-app/package.json"
: > "$FIXROOT/multi/py-lib/pyproject.toml"

mkdir -p "$FIXROOT/empty/some-repo"
: > "$FIXROOT/empty/some-repo/README.md"

mkdir -p "$FIXROOT/go-only-root/go-svc"
: > "$FIXROOT/go-only-root/go-svc/go.mod"

mkdir -p "$FIXROOT/py-only-root/py-lib"
: > "$FIXROOT/py-only-root/py-lib/pyproject.toml"

MISSING_ROOT="$FIXROOT/does-not-exist"

# A PATH containing exactly one fake language-server binary, so "already installed" can be tested
# without touching the real PATH or actually running npm/go/rustup.
STUBBIN="$FIXROOT/stubbin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/gopls" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$STUBBIN/gopls"

# --- run every assertion inside one Python process: importing the extensionless CLI file needs an
# explicit SourceFileLoader (it has no .py suffix so spec_from_file_location alone can't infer one),
# so pay that cost once rather than once per section. Each numbered section is wrapped in try/except
# so a missing attribute in one (expected pre-fix) fails ONLY that section, not the whole run. -----
OUT="$(FIXROOT="$FIXROOT" MISSING_ROOT="$MISSING_ROOT" STUBBIN="$STUBBIN" CLI="$CLI" /usr/bin/python3 - <<'PYEOF'
import contextlib
import importlib.util
import io
import os
import shutil
import tempfile
import traceback
from importlib.machinery import SourceFileLoader

FIXROOT = os.environ["FIXROOT"]
MISSING_ROOT = os.environ["MISSING_ROOT"]
STUBBIN = os.environ["STUBBIN"]

results = []


def check(label, cond, detail=""):
    results.append((label, bool(cond), detail))


def section(label, fn):
    """Run one numbered check in isolation. A pre-fix checkout is missing every new attribute this
    suite exercises -- without this wrapper the first AttributeError would kill the whole process
    before a single PASS/FAIL line printed, and an empty $OUT reads back on the bash side as
    "0 passed, 0 failed" (exit 0): a gate that looks green because it never ran at all."""
    try:
        fn()
    except Exception:
        check(label, False, "raised:\n" + traceback.format_exc().strip())


loader = SourceFileLoader("hx", os.environ["CLI"])
spec = importlib.util.spec_from_loader("hx", loader)
hx = importlib.util.module_from_spec(spec)
loader.exec_module(hx)


def t_26a():
    langs, could = hx.detect_languages(os.path.join(FIXROOT, "multi"))
    check("26a: detect_languages finds go+typescript+python from go.mod/package.json/pyproject.toml",
          could and langs == {"go", "typescript", "python"},
          "got %r could_determine=%r" % (langs, could))


def t_26b():
    langs, could = hx.detect_languages(os.path.join(FIXROOT, "empty"))
    check("26b: a real root with no marker files scans clean (empty set, could_determine True)",
          could is True and langs == set(), "got %r could_determine=%r" % (langs, could))


def t_26c():
    langs, could = hx.detect_languages(MISSING_ROOT)
    check("26c: a nonexistent projects root reports could_determine=False (never \"no servers needed\")",
          could is False, "got %r could_determine=%r" % (langs, could))


def t_26d():
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        hx.install_lang_servers(True, MISSING_ROOT)
    out = buf.getvalue()
    check("26d: install_lang_servers reports uncertainty on an unreadable root, never a positive verdict",
          ("could not" in out.lower() or "cannot" in out.lower())
          and "all good" not in out.lower() and "no servers needed" not in out.lower(),
          "output: %r" % out)


def t_26e():
    old_path = os.environ.get("PATH", "")
    os.environ["PATH"] = STUBBIN + os.pathsep + old_path
    try:
        root = os.path.join(FIXROOT, "go-only-root")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            hx.install_lang_servers(True, root)
        out = buf.getvalue()
        check("26e: a resolvable server (stub gopls on PATH) is reported present, not queued to install",
              "already installed" in out.lower() and "would install go" not in out.lower(),
              "output: %r" % out)
    finally:
        os.environ["PATH"] = old_path


def t_26f():
    old_path = os.environ.get("PATH", "")
    old_home = os.environ.get("HOME", "")
    # Emptying PATH is NOT enough on its own. which() also searches the directories developer
    # tools install into -- ~/go/bin, ~/.cargo/bin, every ~/.nvm node bin -- because a herdr pane
    # runs under the launchd minimal PATH and would otherwise find nothing. So HOME is redirected to
    # an empty directory too; without it this oracle passed or failed according to whether the
    # machine happened to have basedpyright installed, i.e. it measured the machine and not the
    # code. It went green for exactly as long as nobody had installed one.
    empty_home = tempfile.mkdtemp()
    os.environ["PATH"] = ""
    os.environ["HOME"] = empty_home
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            hx.install_lang_servers(True, os.path.join(FIXROOT, "py-only-root"))
        out = buf.getvalue()
    finally:
        os.environ["PATH"] = old_path
        os.environ["HOME"] = old_home
        shutil.rmtree(empty_home, ignore_errors=True)
    want_cmd = " ".join(dict((n, c) for n, _l, c in hx._FALLBACK_LSP_TABLE)["python"])
    check("26f: a missing server dry-run output names the install command (%r)" % want_cmd,
          want_cmd in out, "output: %r" % out)


def t_26g():
    # Binary names are DERIVED from a reachable herdr-edit checkout registry.go, not restated --
    # skipped (not failed) when no checkout is reachable, same precedent as check-deps.sh 25b.
    live = hx._registry_lsp_entries()
    if live is None:
        check("26g: skipped — no herdr-edit checkout reachable to cross-check the fallback table", True)
        return
    problems = []
    for name, _lang, _cmd in hx._FALLBACK_LSP_TABLE:
        if name not in live:
            problems.append("%s: not a server name in the live registry" % name)
            continue
        fallback_bin = hx._FALLBACK_BINARY.get(name)
        if fallback_bin not in live[name]:
            problems.append("%s: fallback binary %r is not one of the registry candidates %r"
                             % (name, fallback_bin, live[name]))
    check("26g: every fallback-table entry matches a real server+binary in herdr-edit registry.go",
          not problems, "; ".join(problems))
    # And the derivation actually WINS over the fallback when a checkout is present.
    for name in ("typescript", "python"):
        got = hx.lsp_candidates(name)
        check("26g: lsp_candidates(%r) reflects the live registry, not just the fallback binary"
              % name, got == live.get(name), "got %r, registry says %r" % (got, live.get(name)))


section("26a", t_26a)
section("26b", t_26b)
section("26c", t_26c)
section("26d", t_26d)
section("26e", t_26e)
section("26f", t_26f)
section("26g", t_26g)

SEP = "\x1f"
for label, cond, detail in results:
    if cond:
        print("PASS" + SEP + label)
    else:
        print("FAIL" + SEP + label + SEP + detail.replace("\n", " | "))
PYEOF
)"
PYRC=$?

if [ -z "${OUT// /}" ] || [ "$PYRC" -ne 0 ]; then
  no "the Python harness itself failed to run (rc=$PYRC) -- see output below"
  printf '%s\n' "$OUT" >&2
else
  # \x1f, not tab or space: IFS containing tab/space is WHITESPACE-class in bash, which collapses
  # runs and drops empty fields (the exact "active.json" trap this repo's own CLAUDE.md warns
  # about). \x1f is not whitespace-class, so an empty `detail` field on a PASS line survives intact.
  while IFS=$'\x1f' read -r status label detail; do
    [ -z "$status" ] && continue
    if [ "$status" = "PASS" ]; then
      ok "$label"
    else
      no "$label -- $detail"
    fi
  done <<< "$OUT"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
