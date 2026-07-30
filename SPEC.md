# herdr-extensions — SPEC

Turn [herdr](https://herdr.dev) into a "tiny VS Code" in one command: an editor panel, a
source-control panel, file-type icons, git-status coloring, and format-on-save — installed,
configured, and keybound for you.

This is the portable, redistributable form of a setup that was first built by hand on one machine.
Everything in "Design decisions" below is a fact that setup discovered the hard way; none of it is
speculative.

## Why it exists

herdr ships a plugin system but no editor. SpiceEdit is an excellent terminal editor but has no
plugin system by design ("no runtime, no plugin manager"). Gluing them together correctly takes ~10
non-obvious steps — several of which fail *silently* if you get them wrong. `herdr-extensions install`
does them right, is idempotent, and is fully reversible.

## v1 scope — installer + panels bundle

| Command | Behavior |
| --- | --- |
| `herdr-extensions install` | Install missing dependencies, register the herdr plugin, write SpiceEdit configs, inject keybindings. Idempotent: safe to re-run. `--dry-run` prints the plan and changes nothing. |
| `herdr-extensions uninstall` | Unregister the plugin and remove the managed keybinding block. Leaves your own settings untouched. `--purge` also removes the SpiceEdit configs it wrote. |
| `herdr-extensions doctor` | Diagnose every moving part and explain each failure. Read-only. Exit 1 if anything is broken. |

### What `install` produces

- **Plugin** `herdr-extensions` linked into herdr, providing three panes and three actions:
  editor split, editor tab, and a lazygit panel.
- **Keybindings**, injected between managed markers in `~/.config/herdr/config.toml`:
  `prefix+shift+e` editor panel (left), `prefix+shift+o` editor tab, `prefix+shift+s` git panel.
- **SpiceEdit configs** in `~/.config/spiceedit/`: `config.json` (icons), `format-defaults.json`
  (format-on-save via the bundled resolver), `actions.json` (Reveal in Finder / open in editor).
- **`herdr-fmt`**, the formatter resolver (see below).
- **Dependencies**, only if absent: `spiceedit`, `lazygit`, a Nerd Font, `prettier`.

### Out of scope for v1

Inline git blame, LSP/diagnostics, a file-history panel, and filtering ignored dirs out of the tree.
All four need changes *inside* SpiceEdit, which has no extension API — so they go upstream as PRs to
`cloudmanic/spice-edit` (MIT), not into this package. Tracked in `UPSTREAM.md`.

## Design decisions (each one is a bug this package prevents)

0. **Never bind a key herdr already owns.** A `[[keys.command]]` entry silently OVERRIDES a herdr
   built-in — no warning, no log line, the built-in simply stops responding, and the user blames
   herdr rather than the extension. v0.1.0 shipped `prefix+e`, `prefix+g` and `prefix+r` and so
   destroyed `edit_scrollback`, `goto` (the fuzzy space/tab/agent picker added in 0.6.3) and
   `resize_mode` on every machine that installed it. herdr reserves **39** prefix bindings on
   0.7.5. The reserved set is therefore re-derived from `herdr --default-config` **at runtime**,
   never hardcoded — herdr keeps adding actions, and a frozen table goes stale exactly when it
   matters. `install` refuses on a conflict (`--force` overrides); `doctor --keymap` audits the
   user's own bindings too, since theirs can break herdr just as easily as ours.

1. **Absolute paths in every pane command.** The herdr server is started by launchd, so it execs
   plugin panes with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Neither `/opt/homebrew/bin` nor
   `~/.local/bin` is on it, so a bare `spiceedit` or `lazygit` fails to spawn with no useful error.
   The manifest is therefore a **template**, rendered at install time with the resolved absolute
   paths — which also makes it work on Intel Macs (`/usr/local`) and Linux.
   *Note the contrast:* herdr-plus **project tab** commands are typed into an interactive shell and
   do get the user's full PATH. Pane commands do not. Same config file, opposite rules.

2. **`$HERDR_PLUGIN_CONTEXT_JSON` is the only correct source of "where the user is" for an event.**
   On `workspace.created`, global focus has not moved to the new workspace yet, so trusting
   `pane list`'s `focused: true` targets the *previous* workspace — the observed symptom was a new
   project opening with no editor while an old one merely got re-focused. The context env var names
   the new `workspace_id` / `tab_id` / `focused_pane_id` / `focused_pane_cwd`.
   Never use `herdr pane current --current`: it resolves `$HERDR_PANE_ID`, the pane the CLI was
   invoked *from*, and reports `focused: false` when the user is elsewhere.

3. **Scope the editor to the project.** herdr launches a plugin pane in the *plugin's* directory,
   and a herdr config may set `new_cwd = "home"`. Either way an unscoped editor roots at `$HOME` and
   lists ~80 dotfiles. Resolution: take the context cwd, widen it to `git rev-parse --show-toplevel`,
   and pass `--cwd`. Outside a repo, an auto-open does **nothing** and a keypress falls back to a
   configured projects root.

4. **The editor goes on the LEFT via a swap.** `plugin pane open --direction` accepts only
   `right|down` — there is no `left`. Open the split, then
   `herdr pane swap --source-pane <new> --target-pane <agent>`. Assert with `pane edges`: the
   editor's `rect.x` must be the smaller.

5. **Panes are identified by manifest `title`.** `herdr pane list` exposes no
   `plugin_id`/`entrypoint`, so "is my panel already open?" is a title match. Titles are therefore
   load-bearing, not cosmetic.

6. **`herdr pane close` is the toggle.** herdr has no hide-without-close, and no focus-by-id —
   focusing is a `pane zoom <id> --on` then `--off` cycle.

7. **SpiceEdit JSON uses `disallowUnknownFields`.** A single `"_comment"` key silently rejects the
   *entire* file. Config templates carry no comment keys; documentation lives here instead.

8a. **No apostrophe may appear inside a heredoc in `open-panel.sh`.** The launcher runs under
   `/bin/bash`, which on macOS is still **bash 3.2.57**, and 3.2 mis-parses a lone `'` inside a
   heredoc nested in `$( )`. The whole script then fails to parse — silently, because herdr only
   sees the action produce nothing. A prose comment containing "the editor's minimum" was enough
   to break it. `tests/live-check.sh` greps for this.

8b. **Panels must be sized explicitly.** `herdr plugin pane open` has **no `--ratio`** (only
   `pane split` and `pane move` do), so every plugin panel opens at a hard 50/50 — half the screen
   for a file tree. Worse, SpiceEdit refuses to draw below **50 columns** and its tree is a fixed
   **30**, so a panel is only comfortable in a narrow band and hits "Window too small - please
   resize" just outside it. So the launcher takes a target **column count** and drives the split
   with `pane resize`, whose `--amount` is a *delta on the split ratio* (measured: ratio 0.315,
   `--direction right --amount 0.05` -> 0.365, exactly reversible). Direction names where the
   *divider* moves, so the sign of the delta alone picks it. Clamped both ways, and **the floor
   wins over the cap**: on an 80-column terminal 50 columns is already 63% of the screen, and an
   oversized panel is merely annoying where an under-minimum one renders nothing at all.

8. **Format-on-save needs a resolver, not a command.** `format.json` takes one argv array per
   extension: no PATH search, no fallback. Under launchd's PATH, plain `prettier` never resolves;
   `./node_modules/.bin/prettier` only works in repos that vendor it. `herdr-fmt` walks **up** from
   the file for a vendored prettier (so a repo's pinned version and `.prettierrc` win, monorepo-safe)
   and falls back to a **globbed** global (never version-pinned, survives a Node upgrade).
   "No parser could be inferred" exits 0 so unsupported files don't flash an error; genuine syntax
   errors still surface. SpiceEdit writes the file to disk *before* formatting, so a no-op is safe.

9. **Icons need a font the OS knows AND a terminal configured to use it.** SpiceEdit detects Nerd
   Fonts by scanning font directories; it cannot know what font your terminal renders with. So
   `install` installs a Nerd Font and `doctor` explicitly warns that the terminal profile is the
   user's job — silently emitting `U+F07B` into a terminal without the font shows tofu boxes.

10. **Never edit a user's config wholesale.** Keybindings are injected between
    `# >>> herdr-extensions (managed) >>>` markers so `uninstall` removes exactly what was added and a
    user's own keys, comments, and settings survive both operations.

11. **A geometry guard tests the FLOORS, never the request.** The split-vs-tab decision and the
    panel width are two questions, and mixing them cost a working layout. v0.4.0 asked "can I fit
    the requested 88 columns and still leave `MIN_PEER`?" before opening; on a 145-column terminal
    herdr keeps 36 for its sidebar, leaving 109, so `109 - 88 = 21` failed the 44-column floor and
    the editor went to its own tab. The clamp that runs immediately after would have sized that same
    panel to `MAX_FRAC` — 60 columns, agent 49, both floors clear. The guard refused a layout on a
    number the code never uses, across every split from 100 to 131 columns.
    So: the **guard** answers only `avail >= MIN_COLS + MIN_PEER`; the **clamp** alone owns
    `MAX_FRAC`, the peer ceiling and the requested width, which is a *preference*. All three
    constants live in one `GEOMETRY POLICY` block and both test suites parse them out of the
    launcher — `check-sizing.py` used to declare its own copies, reintroducing exactly the drift its
    docstring claimed to prevent.

12. **A panel wide enough to DRAW can still be too narrow to be the thing you asked for.** An Edit
    panel with no file tree renders a `≡` and the words "click open from the tree" with nothing to
    click. `MAX_FRAC` cannot see that: at a 130-column split it capped the panel at 71 columns
    without asking what 71 columns *show*. So each panel may declare a "useful" width (argument 8)
    and the clamp lifts the panel to clear it whenever the split can host it beside a readable peer.
    It overrides `MAX_FRAC` deliberately — a panel at 55% that cannot show its tree is not a milder
    version of the layout, it is a different and worse one — but never `MIN_PEER`.
    The editor passes **70** = herdr-edit `defaultSidebarWidth` + `minEditorAfterDrag`, the width at
    which it grants the tree its full 30 columns. It is a comfort target, not a floor: since the
    tree-narrowing change the tree survives down to 42 columns, so nothing needs a tab fallback.

13. **A workspace named after a project opens that project.** `herdr workspace create` and
    herdr-plus Projects both leave the root pane at `$HOME` unless given `--cwd`, and auto-open
    refuses to root a file tree at `$HOME` (decision 4 — the dotfile-soup problem). The two combined
    meant a workspace labelled `affiliate crm` silently got **no editor at all**, which reads as a
    broken extension. The label is the only thing that knows which repo was meant, so it is the
    fallback: slugify it, match `PROJECTS_ROOT` for an exact directory, else a **unique** prefix
    (`affiliate crm` → `affiliate-crm-fintech`), and require a git repo.
    Ambiguity is never guessed. Two candidates opens nothing, because the wrong project is worse
    than no project. A real repo cwd always outranks the label.

14. **Read the pane, not the arithmetic.** Every layer can report success while the user sees
    nothing. The pane existed, its width cleared the editor minimum, the editor drew a start page —
    and there were no files on screen. Only `pane read` catches that, which is why ORACLE 19 asserts
    on rendered output rather than on geometry.
    🔴 `pane read --lines N` returns the **last** N lines, like `tail`. The file tree is drawn at the
    TOP, so ORACLE 8 spent its life reading blank rows and reporting *"no icon glyphs (expected if no
    Nerd Font is installed)"* while 11 glyphs were on screen — a false negative wearing a plausible
    excuse, which is worse than a failure because nobody investigates it. Omit `--lines`.

## Verification (each must pass before release)

| # | Check | Oracle |
| --- | --- | --- |
| 1 | Idempotent install | Run `install` twice; the second run reports 0 changes and `git diff` of the target configs is empty |
| 2 | Clean uninstall | `install` then `uninstall` restores `config.toml` byte-for-byte |
| 3 | Editor lands left | `pane edges` — editor `rect.x` < agent `rect.x` |
| 4 | Project-scoped | Open in a repo subdir; the pane's cwd equals the repo root |
| 5 | Non-repo auto-open is silent | `workspace.created` in `$HOME` creates no Edit pane |
| 6 | Toggle cycle | invoke → open, invoke → focus, invoke (focused) → closed |
| 7 | Git coloring | `pane read --format ansi` — a modified file carries a different SGR color than a clean one |
| 8 | Icons emitted | `pane read` output contains a codepoint in U+E000–U+F8FF |
| 9 | Formatter resolution | un-vendored repo → global; vendored repo → that repo's binary; unsupported ext → exit 0 |
| 10 | `doctor` catches breakage | Rename the spiceedit binary; `doctor` exits 1 naming that specific failure |
| 11 | No keybinding collisions | `doctor` reports 0 conflicts against the runtime-derived reserved set; re-running with the v0.1.0 keymap reports `prefix+e`->`edit_scrollback` and `prefix+g`->`goto` |
| 12 | Install refuses on a clash | Add `key = "prefix+shift+e"` to the user's own config; `install` exits 1 and changes nothing; `--force` proceeds |
| 13 | bash 3.2 parses the launcher | `/bin/bash -n plugin/open-panel.sh` exits 0, and no heredoc line contains an apostrophe |
| 14 | Panel sizing is correct and idempotent | Against `tests/fixtures/edges-2pane.json`: 88 -> 88 cols; second-child pane inverts to `1-want`; every screen width from 64 to 200 yields >= 50 columns; asking for the current size emits no resize; the peer never drops under `MIN_PEER`; a 109-col split gives 60/49 — `tests/check-sizing.py` |
| 15 | Terminal font diagnosed by name | Under Apple Terminal, `doctor` names the profile and its font and says glyphs will not render; under Ghostty with a Nerd Font it passes |
| 16 | Panels parse and read the active file | Every `libexec/` panel parses under bash 3.2; no apostrophe in any heredoc; repo-scoped panels name the repo with no file open, file-scoped ones say they have none; all survive a missing `active.json` — `tests/check-panels.sh` |
| 17 | Split-vs-tab is a floor test | Against a stubbed herdr: every width `MIN_COLS+MIN_PEER`..131 splits; one column under the floor becomes a tab; the original 69-column case still becomes a tab; a fractional bottom panel is never diverted; a non-editor entrypoint is never rewritten to `editor-tab` — `tests/check-viability.sh`. Must be confirmed RED against the raw-request guard first |
| 18 | Workspace label resolves a project | Against a stubbed herdr and a fixture `PROJECTS_ROOT`: a unique prefix resolves; an exact match beats a longer sibling; an ambiguous prefix opens nothing; a non-repo directory never wins; an unmatched label stays silent on auto-open; a real repo cwd outranks the label — `tests/check-project-resolve.sh` |
| 19 | The panel actually shows files | `pane read` on the auto-opened editor contains `EXPLORER`. The end-to-end check: auto-opened, sized wide enough, and the editor chose to draw its tree. **No `--lines`** — it is `tail`-like and the tree is at the top |
| 20 | The gate runs every suite | `live-check.sh` delegates to `check-panels.sh`, `check-viability.sh` and `check-project-resolve.sh` rather than reimplementing them, and restores the originally focused workspace when it is done |

## Distribution

A GitHub repo that is its own Homebrew tap (the pattern both `spice-edit` and `herdr-plus` use):

```
brew tap vonzelle-vzt/herdr-extensions https://github.com/vonzelle-vzt/herdr-extensions
brew install vonzelle-vzt/herdr-extensions/herdr-extensions
herdr-extensions install
```

Plus `curl -fsSL .../install.sh | sh` for non-Homebrew hosts. No compiled artifact: the CLI is
stdlib-only Python 3 targeting **3.9** (what ships on macOS — so no `tomllib`, hence marker-based
config editing). A Go rewrite is possible later but buys nothing for an installer.
