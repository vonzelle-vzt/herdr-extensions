# herdr-extensions

Make [herdr](https://herdr.dev) behave like a tiny VS Code, in one command.

```
herdr-extensions install
```

Inline diagnostics, a real editor panel, source control, search, problems, a debugger, and a
VS Code skin — wired up, keybound, collision-checked, and completely reversible.

## Why one command matters

The most common reason people abandon a terminal setup is not a missing feature. It is waking up to
a config that broke overnight — a plugin renamed a module, an update moved a keybinding, and half
an hour disappears before any work starts.

So this is an **installer**, not a framework. It is idempotent (run it twice, the second run reports
zero changes), it is reversible (uninstall restores your `config.toml` byte-for-byte), it never
rewrites your config wholesale (everything lands between managed markers), and when something is
wrong `herdr-extensions doctor` tells you *which* thing and *why*. There is no plugin manager to
break, because there are no plugins.

## What you get

| Key | Panel |
| --- | --- |
| `ctrl+b` `shift+e` | Editor panel, **left** of your agent pane. Press again to close. |
| `ctrl+b` `shift+o` | Editor full-width in its own tab. |
| `ctrl+b` `shift+s` | lazygit source control, below. |
| `ctrl+b` `shift+m` | Problems — `tsc --noEmit`, `eslint`, `ruff`. |
| `ctrl+b` `shift+f` | Search — ripgrep across the repo. |
| `ctrl+b` `d` | Debug — your `.vscode/launch.json`, handed to an installed adapter. |
| `ctrl+b` `t` | TODO / FIXME / HACK / XXX. |
| `ctrl+b` `shift+b` | Blame and history for the file you are looking at. |
| `ctrl+b` `shift+v` | Markdown preview. |
| `ctrl+b` `shift+u` | Tests — vitest / jest / pytest. |

Plus a VS Code skin for herdr itself:

```
herdr-extensions skin vscode-dark-modern    # or vscode-light, or reset
```

Open a project and the editor appears on its own, already scoped to that repo.

## About those keys

herdr reserves **39** prefix bindings, and a `[[keys.command]]` entry silently overrides a built-in
— no warning, no log line, the built-in just stops working and herdr gets the blame. v0.1.0 of this
package shipped `prefix+e`, `prefix+g` and `prefix+r` and so destroyed `edit_scrollback`, `goto`
(the fuzzy space/tab/agent picker) and `resize_mode` on every machine that installed it.

That is fixed, and it will not happen again: the reserved set is re-derived from
`herdr --default-config` **at runtime** rather than hardcoded, `install` refuses on a conflict, and
`doctor --keymap` audits your own bindings too — they can break herdr just as easily as ours can.

## The panels

Each is a herdr pane. They follow the file you have open, via a small snapshot the editor publishes
to `$XDG_STATE_HOME/spiceedit/active.json` — and each degrades to the repo root, saying so, when
that is absent.

| Panel | What it runs |
| --- | --- |
| **Problems** | `tsc --noEmit`, `eslint --format json`, `ruff check` — whichever the repo has. Resolves them from `node_modules/.bin` first, so the repo's pinned version wins. |
| **Search** | `ripgrep` across the repo root, grouped by file. 5–10× faster than a GUI search, and it respects `.gitignore` for free. |
| **TODO** | `TODO` / `FIXME` / `HACK` / `XXX` with file and line. |
| **Blame** | `git log --follow` and `git show --stat` for the file you are looking at. |
| **Debug** | Parses the repo's `.vscode/launch.json` — comments and trailing commas included, because it is JSONC — lists the configurations, and hands off to an installed adapter (`koan-debugger`, `debugger-cli`, `dlv`, `lldb-dap`, `tdb`). |
| **Markdown** | `glow -s dark` on the active file. |
| **Tests** | Detects vitest / jest / pytest from `package.json` or `pyproject.toml`. |
| **Git** | `lazygit`. Interactive staging alone is worth the panel. |

Every command they run is resolved to an **absolute path**, because the herdr server runs under
launchd with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and a bare binary name fails to spawn with no
useful error. Worth knowing: on many machines `rg` is a *shell function*, so anything that `execve`s
it fails even though `rg` works fine when you type it.

## Troubleshooting

Run `herdr-extensions doctor` first — it checks every moving part and names the specific failure.

**The file tree is full of `?` or empty boxes.** Your terminal's font has no Nerd Font glyphs. The
editor detects fonts on *disk*; it cannot know what your terminal renders with. On macOS `doctor`
decodes your Terminal.app profile and tells you which font it found. Either point that profile at a
Nerd Font, or use a terminal like Ghostty — which also gains you inline images and OSC 52 clipboard,
neither of which Apple Terminal supports at all.

**A herdr keybinding stopped working.** Run `herdr-extensions doctor --keymap`. A `[[keys.command]]`
entry silently overrides a herdr built-in, and herdr gets the blame. The audit covers your own
bindings too, not just ours.

**A pane will not resize.** `prefix+r` is the *only* resize binding herdr ships (`resize_mode`), so
anything bound to `prefix+r` removes pane resizing entirely — the symptom is a divider that seems
stuck rather than a missing keybinding. The `persiyanov.reviewr` plugin binds `prefix+r` by default;
move it to `prefix+shift+c`. `doctor --keymap` names this specific collision, and note that
`prefix+shift+r` is *also* reserved, so it is not the escape hatch it looks like.

**The panel is too big, or says "Window too small — please resize".** These are the same problem.
`herdr plugin pane open` has no `--ratio`, so plugin panels open at a hard 50/50, while the editor
has a minimum width below which it refuses to draw. Panels are sized in columns here, clamped so
neither end is reachable. If you are on upstream `spiceedit`, install
[`herdr-edit`](https://github.com/vonzelle-vzt/herdr-edit) — its layout degrades instead of refusing.

**The editor panel opens but shows no file tree.** The panel is narrower than the editor's tree
threshold. Upstream `spiceedit` hides its tree below 76 columns, which switches the explorer off in
exactly the place it earns its keep — a split beside an agent, where the pane is 60-odd columns.
[`herdr-edit`](https://github.com/vonzelle-vzt/herdr-edit) narrows the tree toward 18 columns instead
and only hides it below 42. `./tests/live-check.sh` checks this directly (ORACLE 19) by reading the
pane rather than trusting its width.

**The editor opened in its own tab instead of beside my agent.** Your layout is under
`MIN_COLS + MIN_PEER` usable columns, so a side-by-side cannot give both panes a readable width. Note
that herdr's own sidebar can be 36 of them — `prefix+b` collapses it and usually resolves this
outright. Everything above that floor splits; if you see a tab above it, that is a bug.

**A project opened with no editor at all.** The workspace is rooted at `$HOME` (a plain
`herdr workspace create` with no `--cwd` does this) and its label matched no single repo under
`PROJECTS_ROOT`. Auto-open stays silent rather than rooting a file tree in your home directory. Give
the workspace a label matching the project directory, or create it with `--cwd`.

**No diagnostics.** They need a language server *and* `herdr-edit`. Upstream `spiceedit` has no LSP
client. `doctor` reports which editor it found.

**Every `herdr` command started failing after a `brew install`.** Homebrew may have upgraded herdr
underneath the running server, leaving the CLI a protocol version ahead of it. Check `herdr status`
for `compatible:`. The fix is a server restart — but that exits every pane process, so set
`[session] resume_agents_on_restore = true` **first** or you discard every agent conversation.

## What it actually does

herdr has a plugin system but no editor. [SpiceEdit](https://github.com/cloudmanic/spice-edit) is a
first-rate terminal editor with no plugin system *by design*. [lazygit](https://github.com/jesseduffield/lazygit)
is the git UI. Gluing the three together correctly takes about ten steps, several of which fail
**silently** when you get them wrong. This does them right:

- registers a herdr plugin providing the editor, git, and eight more panels
- renders every pane command to an **absolute path** (the herdr server runs under launchd's minimal
  `PATH`, so a bare `spiceedit` never spawns — and the right absolute path differs on Apple Silicon,
  Intel, and Linux)
- resolves the **project root** for each panel via `git rev-parse --show-toplevel`, so the tree shows
  your repo instead of ~80 dotfiles from `$HOME`
- puts the editor on the **left** (herdr can only split `right`/`down`, so it opens then swaps)
- installs `herdr-fmt`, a formatter resolver that makes format-on-save work in *every* repo
- injects keybindings between managed markers, so your own config survives install **and** uninstall
- sizes each panel in **columns**, not as a fraction — `herdr plugin pane open` has no `--ratio`, so
  every plugin panel otherwise opens at a hard 50/50, and the editor has a minimum width below which
  it refuses to draw at all
- decides split-vs-tab from the **floors** rather than the requested width, and lifts the editor to a
  width that can actually show a file tree whenever the split can host one beside a readable agent
- falls back to the **workspace label** to find your repo when the pane is rooted at `$HOME`, so a
  workspace called `affiliate crm` opens `affiliate-crm-fintech` instead of nothing at all

## Install

```bash
# Homebrew (this repo is its own tap)
brew tap vonzelle-vzt/herdr-extensions https://github.com/vonzelle-vzt/herdr-extensions
brew install vonzelle-vzt/herdr-extensions/herdr-extensions
herdr-extensions install

# or, without Homebrew
curl -fsSL https://raw.githubusercontent.com/vonzelle-vzt/herdr-extensions/main/install.sh | sh
herdr-extensions install
```

Requires **herdr ≥ 0.7.0**. `install` will install anything missing — the editor, `lazygit`, a Nerd
Font, `prettier` — or run it with `--no-deps` to manage those yourself.

### The editor

Panels prefer [`herdr-edit`](https://github.com/vonzelle-vzt/herdr-edit), a fork of
[SpiceEdit](https://github.com/cloudmanic/spice-edit) adding the things a VS Code user notices
missing: LSP diagnostics, a file tree that respects `.gitignore`, find *and replace*, auto-closing
pairs, a start page instead of "No file open", and a layout that degrades in a narrow pane rather
than refusing to draw. Upstream `spiceedit` is still supported and is the documented fallback —
everything except diagnostics behaves the same, and the panels degrade gracefully.

### Icons

Icons need a Nerd Font **and a terminal configured to use it**. An editor cannot know what font
your terminal renders with, so `doctor` checks the running terminal itself — on macOS it decodes
your Terminal.app profile and names the font — rather than only checking what is installed. A tree
full of question marks is almost always this.

## Commands

```
herdr-extensions install [--dry-run] [--no-deps] [--projects-root DIR] [--force]
herdr-extensions uninstall [--purge]
herdr-extensions doctor [--keymap]
herdr-extensions skin <name> | list | reset
```

- **`install`** is idempotent — re-run it any time; a second run reports zero changes.
  `--dry-run` prints the plan and touches nothing. `--projects-root` sets where the editor opens
  when you press the key outside any git repo (default `~/github-projects`).
- **`uninstall`** removes the plugin and the managed keybinding block, leaving your settings
  byte-for-byte intact. `--purge` also removes the editor configs it wrote.
- **`doctor`** checks every moving part and explains each failure. Exits non-zero if anything is
  broken, so it works in CI.

## File icons need one manual step

`install` installs a Nerd Font, and SpiceEdit will then emit icon glyphs — but no program can tell
what font your **terminal** renders with. If the file tree shows boxes or question marks, point your
terminal profile at a Nerd Font (e.g. *JetBrainsMono Nerd Font*). `doctor` reminds you.

Ghostty, kitty, and WezTerm are good hosts for this setup. macOS Terminal.app works for text but
supports neither OSC 52 clipboard nor any image protocol.

## What it doesn't do

**Inline git blame** — author and commit shown on the cursor's line, GitLens-style. The Blame panel
gives you file history and `git log --follow`; the inline version is editor-side work and is not
written yet.

**Cross-file replace with preview.** The editor has replace, regex and a match-preview API; driving
it across a whole repo from the Search panel is not wired up.

Anything else that needs to live *inside* the editor lives in
[herdr-edit](https://github.com/vonzelle-vzt/herdr-edit) rather than here — see
[UPSTREAM.md](UPSTREAM.md) for what moved and what is still owed upstream.

## Development

```bash
./bin/herdr-extensions doctor        # read-only, safe anywhere
./bin/herdr-extensions install --dry-run
./tests/live-check.sh                # behavioral oracles against a running herdr
./tests/check-panels.sh              # 25 panel oracles — no server needed
./tests/check-viability.sh           # split-vs-tab decision, against a stubbed herdr
./tests/check-project-resolve.sh     # which repo a workspace opens, against a stubbed herdr
/usr/bin/python3 tests/check-sizing.py   # panel geometry, against a fixture
```

The last four run entirely offline, which matters: they are the checks that catch the regressions
that shipped in v0.1.0 and v0.4.0, and they must work even when the herdr server is unreachable.

### Which project the panel opens

On `workspace.created` the editor opens automatically, so a project comes up VS Code-shaped with no
keypress. Resolution order:

1. the focused pane's cwd, widened to `git rev-parse --show-toplevel` — the repo root, like VS Code;
2. failing that, the **workspace label** matched against `PROJECTS_ROOT` — slugified, an exact
   directory match first, then a *unique* prefix match, and it must be a git repo;
3. failing that: auto-open does nothing, a keypress falls back to `PROJECTS_ROOT`.

Step 2 exists because `herdr workspace create` and herdr-plus Projects both leave the root pane at
`$HOME` unless you pass `--cwd`, and the launcher refuses to root a file tree at `$HOME` — that is
the dotfile-soup problem. So a workspace labelled `affiliate crm` used to get **no editor at all**;
it now opens `affiliate-crm-fintech`. Ambiguity is never guessed: two candidate repos means nothing
opens, because the wrong project is worse than none.

### Panel width, and why the editor sometimes gets its own tab

Two numbers decide the layout, and they are declared once, in the `GEOMETRY POLICY` block of
`plugin/open-panel.sh`: `MIN_COLS` (the narrowest the editor can still draw) and `MIN_PEER` (the
narrowest the pane you split away from stays readable). `MAX_FRAC` then caps how much of the split a
panel may take.

The split of responsibility is deliberate and is what keeps the two from disagreeing:

| | question | owns |
|---|---|---|
| **viability guard** | is a side-by-side possible *at all*? | `MIN_COLS + MIN_PEER` — a pure floor test |
| **width clamp** | how wide, exactly? | `MAX_FRAC`, the peer ceiling, the requested width |

The requested column count in the manifest (`88` for the editor) is a **preference**. The guard must
never test it — v0.4.0 did, and refused a split whenever `avail - 88 < MIN_PEER`, which sent the
editor to its own tab across a 32-column band (100–131) that the clamp handles perfectly well. On a
145-column terminal herdr keeps 36 for its sidebar, leaving 109: the clamp puts the editor at 60 and
the agent at 49, both comfortably over their floors. `tests/check-viability.sh` pins that band and
`tests/check-sizing.py` pins the widths; both parse the constants out of the launcher, so retuning a
number moves the tests with it.

You will still get a tab below `MIN_COLS + MIN_PEER` columns of usable width — there, the two floors
genuinely cannot coexist and a tab is the honest answer, the same thing VS Code does when you shrink
a window.

`TREE_COLS` is a third, softer target: the width at which herdr-edit gives the file tree its full 30
columns (`defaultSidebarWidth` + `minEditorAfterDrag`). The clamp lifts the panel to clear it
whenever the split can host it beside a readable agent, because `MAX_FRAC` otherwise caps the panel
without ever asking what those columns can *show*. It is a comfort target, not a floor — it loses to
`MIN_PEER`, and the tree stays on screen well below it, narrowing toward 18 columns rather than
vanishing.

`bin/herdr-extensions` is stdlib-only Python targeting **3.9** (what macOS ships), so there is no
`tomllib` — config edits are marker-delimited text injections, which is also why your comments and
settings survive. [SPEC.md](SPEC.md) records every design decision and the reason behind it; each one
is a silent failure this package prevents.

## License

MIT
