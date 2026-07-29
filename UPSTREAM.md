# Upstream work (cloudmanic/spice-edit)

SpiceEdit has no extension API — "no runtime, no plugin manager" is an explicit design goal — so the
remaining VS-Code-shaped gaps cannot live in herdr-extensions. They are patches to send upstream (MIT, Go,
clean package boundaries in `internal/`).

Ordered by value per unit of work.

## 1. Hide git-ignored paths from the file tree

**Gap.** The tree lists `.next/`, `node_modules/`, `.vercel/` — noise that VS Code hides by default.
**Note the asymmetry:** the *fuzzy finder* already honors `.gitignore` (`internal/finder` shells out
to `git ls-files --cached --others --exclude-standard`); only the tree does not.
**Where.** `internal/filetree` + the existing `internal/app/gitstatus.go` git plumbing.
**Shape.** A `{"tree": {"respectGitignore": true}}` key in `~/.config/spiceedit/config.json`
(`internal/spiceconfig` already exists for exactly this) plus a `git check-ignore --stdin` batch call
per directory listing. Default on, with an override, matching VS Code's `files.exclude` behavior.

## 2. Inline git blame — the actual GitLens signature

**Gap.** No "who last touched this line, when, in which commit".
**Where.** New `internal/blame` (parse `git blame --porcelain -L`), rendered by `internal/editor` as
dim end-of-line text on the cursor's line only.
**Care.** Must be lazy and cancellable — blame on a large file is slow, and the editor's existing
convention is to never block the UI on git (see the comments in `gitstatus.go`).

## 3. Publish the active file so other tools can react

**Gap.** Nothing outside SpiceEdit can know which file is open, so a herdr panel cannot show "history
for the file I'm looking at". This is the blocker for *every* cross-tool feature, which is why it
ranks above the flashier ones.
**Shape.** Write `{"file": "...", "line": N, "root": "..."}` to
`$XDG_STATE_HOME/spiceedit/active.json` (debounced) on tab switch and cursor move. Tiny, optional,
and it unlocks file-history / blame / test-runner panels in herdr-extensions without further editor
changes.

## 4. Diagnostics / LSP

**Gap.** The largest real difference from VS Code: no IntelliSense, no problems list.
**Reality check.** A full LSP client is a big change and may not fit the project's "one static
binary, no runtime" ethos. A cheaper 80% step: a diagnostics *panel* in herdr-extensions that runs
`tsc --noEmit` / `eslint` and lists results — no editor change needed, though jump-to-line needs #3.

## Etiquette

Open an issue describing the gap before sending a PR; the repo is small and actively maintained
(one author, fast release cadence, auto-release on merge to `main`). Match the house style: file
header comment block, prose comments explaining *why*, and a `_test.go` beside every change.
