# CLAUDE.md — herdr-extensions

Project guidance for Claude Code. Read this before changing anything here; it records the failure
modes that are invisible from the code alone.

## What this is

An **installer**, not a framework. It makes [herdr](https://herdr.dev) behave like a tiny VS Code by
writing a plugin manifest, some scripts, and a marker-delimited block of keybindings. There is no
plugin manager and no config DSL, deliberately. Read [README.md](README.md) for the product and
[SPEC.md](SPEC.md) for every design decision and the reason behind it — SPEC.md is the authority, and
each numbered decision is a bug this package prevents.

`bin/herdr-extensions` is stdlib-only Python targeting **3.9** (what macOS ships), so there is no
`tomllib`. Config edits are marker-delimited text splices, never TOML round-trips — that is also why
your comments and settings survive.

## Repository map

```
bin/herdr-extensions      the whole CLI: install / uninstall / doctor / skin
plugin/herdr-plugin.toml  herdr plugin manifest — a TEMPLATE, rendered at install time
plugin/open-panel.sh      launcher: decides open/focus/close, project scope, and panel geometry
plugin/resize-pane.sh     one-keypress divider nudge
plugin/image-paste.sh     stage a clipboard image and type its path to the agent
libexec/<panel>           one script per panel: problems search todo blame markdown tests debug preview
libexec/herdr-fmt         formatter resolver used for format-on-save
skins/*.toml              VS Code colour schemes for herdr itself
tests/                    the oracles; see "Verification" below
```

## 🔴 The five things that fail silently

Every one of these has actually shipped broken. None produces an error message.

**1. Pane commands run under launchd's PATH.** The herdr server is started by launchd, so it execs
plugin panes and actions with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Neither `/opt/homebrew/bin` nor
`/usr/local/bin` nor `~/.local/bin` is on it. A bare `spiceedit`, `lazygit`, `chafa` or `rg` **never
resolves and the action does nothing at all**. Every external binary is therefore an `@@TEMPLATE@@`
rendered to an absolute path by `render_plugin()`. Worth knowing: on many machines `rg` is a *shell
function*, so anything that `execve`s it fails even though it works when you type it.

**2. Quote every templated path.** `@@CHROME@@` renders to `/Applications/Google Chrome.app/...`,
which contains **spaces**. `CHROME=@@CHROME@@` makes bash assign `/Applications/Google` and try to
*execute* the rest, after which the panel reports "Chrome not found" forever — indistinguishable from
a missing install. Always `CHROME="@@CHROME@@"`.

**3. A `[[keys.command]]` entry silently overrides a herdr built-in.** No warning, no log line; the
built-in just stops working and herdr gets blamed. v0.1.0 shipped `prefix+e`/`prefix+g`/`prefix+r`
and destroyed `edit_scrollback`, `goto` and `resize_mode` on every machine that installed it. The
reserved set is re-derived from `herdr --default-config` **at runtime** — never hardcode it — and
`install` refuses on a clash. `doctor --keymap` audits the user's own bindings too.
Note `prefix+r` is the *only* resize binding herdr ships, so taking it removes pane resizing entirely.

**4. `/bin/bash` on macOS is 3.2.57** and mis-parses an apostrophe inside a heredoc nested in `$( )`.
The whole script then fails to parse — silently, because herdr only sees the action produce nothing. A
comment reading "the editor's minimum" was enough to do it. `check-panels.sh` 16b guards this.

**5. Tab is IFS *whitespace*.** `IFS=$'\t' read` collapses runs and drops empty fields, so with no
file open the `active.json` payload starts empty, every value shifts left, and the line number lands
in the filename variable. Use `\x1f`. This hit all seven panels at once.

## Conventions

- **Panels** live in `libexec/`, print to stdout, then wait for a keypress so the pane persists.
  Everything in `libexec/` is treated as a panel by `check-panels.sh` and tested against the
  active-file contract — so a helper that is *not* a panel belongs in `plugin/` instead
  (`resize-pane.sh`, `image-paste.sh`).
- **Repo-scoped vs file-scoped.** Repo-scoped panels (search, todo, problems, tests, debug) must name
  the repo when no file is open; file-scoped ones (blame, markdown) must *say* they have no file
  rather than guessing. Oracle 16c enforces the distinction.
- **`doctor` names the specific failure.** "Something is wrong" is not acceptable output. Each check
  reports which thing and why, and exits non-zero so it works in CI.
- **Absence is not a negative verdict.** `plugin_registered()` is tri-state — True / False /
  **None = could not ask** — so an unreachable server is never reported as "not installed".
- Never resolve brew symlinks when recording a path: `realpath` on `/opt/homebrew/bin/chafa` pins the
  versioned Cellar path and breaks on the next `brew upgrade`.

## Geometry, in one place

`plugin/open-panel.sh` holds a `GEOMETRY POLICY` block and it is the single source of truth. Both test
suites parse the constants out of that file rather than restating them.

The division of labour is deliberate and is what keeps them from drifting:

| | question | owns |
| --- | --- | --- |
| viability guard | is a side-by-side possible *at all*? | `MIN_COLS + MIN_PEER` — a pure floor test |
| width clamp | how wide, exactly? | `MAX_FRAC`, the peer ceiling, the requested width |

🔴 **The guard must never test the requested width.** v0.4.0 did, and refused a split whenever
`avail - 88 < MIN_PEER` — sending the editor to its own tab across a 32-column band the clamp handles
perfectly well. The request is a *preference*; only the floors are non-negotiable.

`TREE_COLS` is a softer target: the width at which herdr-edit grants its file tree full width. The
clamp lifts the panel to clear it when the split can host it beside a readable agent, because
`MAX_FRAC` otherwise caps a panel without ever asking what those columns can *show*.

## Verification — required, not optional

```bash
./tests/live-check.sh   # the gate: live oracles + delegates to all four offline suites
```

`live-check.sh` is the release gate and it **delegates** to `check-panels.sh`,
`check-viability.sh`, `check-project-resolve.sh` and `check-image-paste.sh`/`check-preview.sh` rather
than reimplementing them, so there is exactly one definition of every check. It once ran none of them
— a green gate that had never executed 39 of its own oracles.

Bar for new work:

- A bug fix adds an oracle that is **confirmed RED before it goes green**. Several here were written
  against the fixed code and proved nothing until deliberately mutated.
- Oracles that catch a **hang** must be **hard bounded**. `check-preview.sh` runs the panel in the
  background with a deadline, because the regression it guards is a panel that waits forever — an
  unbounded oracle would hang the gate rather than fail it, and a hanging gate is no better than one
  that is never run.
- 🔴 **`herdr pane read --lines N` returns the LAST N lines, like `tail`.** The file tree draws at the
  *top*, so ORACLE 8 spent its life reading blank rows and reporting "no icon glyphs (expected if no
  Nerd Font is installed)" while 11 glyphs were on screen. A false negative wearing a plausible excuse
  is worse than a failure, because nobody investigates it. Omit `--lines`.
- 🔴 **`plugin action invoke` has no `--pane`** — an action always resolves the *globally* focused
  pane. `pane zoom` focuses within a workspace and cannot cross workspaces, so use `workspace focus`.
  A harness that steals focus must also put it back.

## What NOT to add

- **A plugin system.** This is an installer. If it needs its own extension points, it has failed.
- **A TOML library.** Python 3.9 is the target; marker-delimited splices are the design.
- **Anything that belongs inside the editor.** LSP features, word wrap, the file tree and rendering
  all live in [herdr-edit](https://github.com/vonzelle-vzt/herdr-edit). See
  [UPSTREAM.md](UPSTREAM.md) for what moved and what is still owed upstream.
- **Patches to herdr.** herdr is a third-party binary. Missing herdr features get worked around from
  outside, never forked around — e.g. mouse divider drag does not exist in herdr 0.7.5, so
  `plugin/resize-pane.sh` provides one-keypress nudges instead. Note herdr's issue tracker accepts
  only reproducible bugs on its template and auto-closes feature requests, so do not send them there.
