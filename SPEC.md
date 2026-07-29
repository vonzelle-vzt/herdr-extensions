# herdr-tools — SPEC

Turn [herdr](https://herdr.dev) into a "tiny VS Code" in one command: an editor panel, a
source-control panel, file-type icons, git-status coloring, and format-on-save — installed,
configured, and keybound for you.

This is the portable, redistributable form of a setup that was first built by hand on one machine.
Everything in "Design decisions" below is a fact that setup discovered the hard way; none of it is
speculative.

## Why it exists

herdr ships a plugin system but no editor. SpiceEdit is an excellent terminal editor but has no
plugin system by design ("no runtime, no plugin manager"). Gluing them together correctly takes ~10
non-obvious steps — several of which fail *silently* if you get them wrong. `herdr-tools install`
does them right, is idempotent, and is fully reversible.

## v1 scope — installer + panels bundle

| Command | Behavior |
| --- | --- |
| `herdr-tools install` | Install missing dependencies, register the herdr plugin, write SpiceEdit configs, inject keybindings. Idempotent: safe to re-run. `--dry-run` prints the plan and changes nothing. |
| `herdr-tools uninstall` | Unregister the plugin and remove the managed keybinding block. Leaves your own settings untouched. `--purge` also removes the SpiceEdit configs it wrote. |
| `herdr-tools doctor` | Diagnose every moving part and explain each failure. Read-only. Exit 1 if anything is broken. |

### What `install` produces

- **Plugin** `herdr-tools` linked into herdr, providing three panes and three actions:
  editor split, editor tab, and a lazygit panel.
- **Keybindings**, injected between managed markers in `~/.config/herdr/config.toml`:
  `prefix+e` editor panel (left), `prefix+shift+e` editor tab, `prefix+g` git panel.
- **SpiceEdit configs** in `~/.config/spiceedit/`: `config.json` (icons), `format-defaults.json`
  (format-on-save via the bundled resolver), `actions.json` (Reveal in Finder / open in editor).
- **`herdr-fmt`**, the formatter resolver (see below).
- **Dependencies**, only if absent: `spiceedit`, `lazygit`, a Nerd Font, `prettier`.

### Out of scope for v1

Inline git blame, LSP/diagnostics, a file-history panel, and filtering ignored dirs out of the tree.
All four need changes *inside* SpiceEdit, which has no extension API — so they go upstream as PRs to
`cloudmanic/spice-edit` (MIT), not into this package. Tracked in `UPSTREAM.md`.

## Design decisions (each one is a bug this package prevents)

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
    `# >>> herdr-tools (managed) >>>` markers so `uninstall` removes exactly what was added and a
    user's own keys, comments, and settings survive both operations.

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

## Distribution

A GitHub repo that is its own Homebrew tap (the pattern both `spice-edit` and `herdr-plus` use):

```
brew tap <owner>/herdr-tools https://github.com/<owner>/herdr-tools
brew install <owner>/herdr-tools/herdr-tools
herdr-tools install
```

Plus `curl -fsSL .../install.sh | sh` for non-Homebrew hosts. No compiled artifact: the CLI is
stdlib-only Python 3 targeting **3.9** (what ships on macOS — so no `tomllib`, hence marker-based
config editing). A Go rewrite is possible later but buys nothing for an installer.
