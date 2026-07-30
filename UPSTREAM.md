# Editor-side work

SpiceEdit has no extension API — *"no runtime, no plugin manager"* is an explicit design goal — so
the VS-Code-shaped gaps that need to live **inside** the editor cannot live in this package.

**They now live in [`herdr-edit`](https://github.com/vonzelle-vzt/herdr-edit)**, a fork of
[cloudmanic/spice-edit](https://github.com/cloudmanic/spice-edit). Forking rather than waiting was
the right call for one reason above all: active-file publishing is the keystone, and *every* panel
in this package was blocked on it.

## Done, in the fork

| Gap | Status |
| --- | --- |
| **Publish the active file** | Done. `$XDG_STATE_HOME/spiceedit/active.json`, debounced 150 ms, atomic rename. Every panel here reads it. |
| **Hide git-ignored paths from the tree** | Done. One `git ls-files --cached --others --exclude-standard` for the whole repo, rebuilt on refresh. Real Next.js checkout: 29 top-level entries → 22. |
| **Diagnostics / LSP** | Done, and it went further than the "cheap 80%" this file originally proposed. A real LSP client — inline underlines, hover, go-to-definition — verified against real `gopls`. The Problems panel here complements it rather than substituting for it. |
| **Find and replace** | Done. Upstream had no replace at all, in any form. |
| **Auto-closing pairs, persistent undo, start page, responsive layout** | Done. Not in the original list; found while using it. |

| Gap | Still open |
| --- | --- |
| **Inline git blame** | Not yet in the fork. `prefix+shift+b` here gives file history and `git log --follow`; the GitLens signature — author and commit on the cursor's line, dim, end-of-line — is still editor-side work. |

## Going upstream

Three of the fork's changes are small, self-contained, and match upstream's house style, so they
should be offered upstream rather than carried in a fork forever:

1. **Active-file publishing** (`internal/state`) — tiny, optional, no IPC, nothing can talk back.
2. **gitignore-aware tree** (`internal/filetree`) — closes an asymmetry that already existed, since
   `internal/finder` has always built its index from `git ls-files --exclude-standard`.
3. **Inline git blame**, once written.

The rest (LSP, replace, auto-close, persistent undo, the responsive layout) are larger or more
opinionated and are not obviously things upstream wants.

**Etiquette:** file an issue describing the gap before sending a PR. The repo is MIT, small, one
author, fast release cadence, auto-release on merge to `main`. Match the house style — the file
header block, prose comments explaining *why*, and a `_test.go` beside every change.

## Which editor this package uses

Panels prefer `herdr-edit` and fall back to upstream `spiceedit`. Preferring rather than requiring
means neither install breaks the other:

| | `herdr-edit` | upstream `spiceedit` |
| --- | --- | --- |
| Editor panel, git panel, format-on-save, icons | ✅ | ✅ |
| Search / TODO / tests / debug panels | ✅ | ✅ (repo-scoped) |
| Blame / markdown panels *(need the active file)* | ✅ | ⚠️ falls back to the repo root and says so |
| Inline diagnostics | ✅ | ❌ |

`herdr-extensions doctor` reports which one it found.
