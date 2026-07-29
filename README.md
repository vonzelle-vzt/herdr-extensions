# herdr-extensions

Make [herdr](https://herdr.dev) behave like a tiny VS Code, in one command.

```
herdr-extensions install
```

You get an **editor panel** on the left, a **source-control panel** below, file-type icons,
git-status coloring in the tree, and format-on-save — wired up, keybound, and reversible.

| Key | Panel |
| --- | --- |
| `ctrl+b` `e` | Editor panel, **left** of your agent pane. Press again to close. |
| `ctrl+b` `shift+e` | Editor full-width in its own tab. |
| `ctrl+b` `g` | lazygit source-control panel, **below** your agent pane. |

Open a project and the editor appears on its own, already scoped to that repo.

## What it actually does

herdr has a plugin system but no editor. [SpiceEdit](https://github.com/cloudmanic/spice-edit) is a
first-rate terminal editor with no plugin system *by design*. [lazygit](https://github.com/jesseduffield/lazygit)
is the git UI. Gluing the three together correctly takes about ten steps, several of which fail
**silently** when you get them wrong. This does them right:

- registers a herdr plugin providing the editor and git panes
- renders every pane command to an **absolute path** (the herdr server runs under launchd's minimal
  `PATH`, so a bare `spiceedit` never spawns — and the right absolute path differs on Apple Silicon,
  Intel, and Linux)
- resolves the **project root** for each panel via `git rev-parse --show-toplevel`, so the tree shows
  your repo instead of ~80 dotfiles from `$HOME`
- puts the editor on the **left** (herdr can only split `right`/`down`, so it opens then swaps)
- installs `herdr-fmt`, a formatter resolver that makes format-on-save work in *every* repo
- injects keybindings between managed markers, so your own config survives install **and** uninstall

## Install

```bash
# Homebrew (this repo is its own tap)
brew tap <owner>/herdr-extensions https://github.com/<owner>/herdr-extensions
brew install <owner>/herdr-extensions/herdr-extensions
herdr-extensions install

# or, without Homebrew
curl -fsSL https://raw.githubusercontent.com/<owner>/herdr-extensions/main/install.sh | sh
herdr-extensions install
```

Requires **herdr ≥ 0.7.0**. `install` will install anything missing — `spiceedit`, `lazygit`, a Nerd
Font, `prettier` — or run it with `--no-deps` to manage those yourself.

## Commands

```
herdr-extensions install [--dry-run] [--no-deps] [--projects-root DIR]
herdr-extensions uninstall [--purge]
herdr-extensions doctor
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

Inline git blame, LSP/diagnostics, a file-history panel, and hiding git-ignored directories from the
tree all require changes *inside* SpiceEdit, which has no extension API. Those belong upstream — see
[UPSTREAM.md](UPSTREAM.md).

## Development

```bash
./bin/herdr-extensions doctor        # read-only, safe anywhere
./bin/herdr-extensions install --dry-run
./tests/live-check.sh           # behavioral oracles against a running herdr
```

`bin/herdr-extensions` is stdlib-only Python targeting **3.9** (what macOS ships), so there is no
`tomllib` — config edits are marker-delimited text injections, which is also why your comments and
settings survive. [SPEC.md](SPEC.md) records every design decision and the reason behind it; each one
is a silent failure this package prevents.

## License

MIT
