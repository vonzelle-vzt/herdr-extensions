# herdr-extensions — PRD

**Status:** shipped, v0.17.1 · **Owner:** vonzelle-vzt · **Last reviewed:** 2026-07-31

[SPEC.md](../SPEC.md) is the engineering authority — every design decision and the bug it prevents.
This document is the *product* view: who it is for, what problem it solves, what is deliberately out
of scope, and how we know it works.

---

## 1. Problem

Coding agents moved into the terminal. The tooling around them did not.

[herdr](https://herdr.dev) solved the multiplexing — workspaces, tabs, panes, a session that survives a
dropped SSH connection. What it has no opinion about is the *other* half of the job: reading the
codebase the agent is changing. There is no editor, no file tree, no diagnostics, no diff view, no way
to look at the app being built.

So the practical state of the art is a split terminal with an agent on one side and `vim` plus a lot of
`cat` on the other, or a GUI editor on a second monitor that cannot follow you over SSH.

The gap is not "a terminal needs an editor." It is that **the parts of an IDE that make a codebase
navigable are missing precisely where an agent is doing the navigating.**

## 2. Who this is for

| | |
| --- | --- |
| **Primary** | Developers running a coding agent in a terminal who want the IDE affordances back — tree, definitions, diagnostics, diffs, preview — without leaving the terminal. |
| **Sharpest case** | Anyone working over SSH or on a remote box, where a GUI editor is not an option and a dropped connection must not cost the session. |
| **Not for** | Someone happy in a GUI IDE with an embedded terminal. That already works; this is not better at it. |

## 3. Principles

1. **An installer, not a framework.** No plugin manager, no marketplace, no config DSL. Ship the ten
   things people actually use and get out of the way. If it needs its own extension points, it failed.
2. **Reversible, byte-for-byte.** Everything lands between managed markers. `uninstall` restores
   `config.toml` exactly. A tool that cannot be removed cleanly will not be trusted.
3. **Idempotent.** Run `install` twice; the second run reports zero changes. The most common reason
   people abandon a terminal setup is a config that broke overnight, not a missing feature.
4. **Name the failure.** Silent partial failure is the enemy. Every check in `doctor` reports *which*
   thing and *why*, and exits non-zero. "Something is wrong" is not acceptable output.
5. **Do not fork around a dependency.** Missing herdr features are worked around from *outside* herdr,
   never by patching it. Editor-side features go to `herdr-edit`. This repo owns wiring and layout only.
   (herdr's tracker takes reproducible bugs on a template only and auto-closes feature requests, so
   gaps get absorbed here rather than escalated there.)
6. **Degrade, never refuse.** A narrow pane gets a narrower tree, not an error. A missing optional
   dependency loses one capability, and says which.

## 4. Scope

### Shipped

| Capability | Surface | Notes |
| --- | --- | --- |
| Editor panel, project-scoped | `ctrl+b shift+e` | auto-opens per project, left of the agent; herdr-edit surfaces merge conflicts inline (ours/theirs tint, gutter glyphs, live diagnostics on the conflict markers) with a full resolve toolkit in the command palette |
| Editor in its own tab | `ctrl+b shift+o` | for panes too narrow to split |
| Source control | `ctrl+b shift+s` | lazygit; interactive staging is the draw |
| Problems | `ctrl+b shift+m` | `tsc --noEmit`, `eslint`, `ruff` — repo's pinned version wins |
| Search | `ctrl+b shift+f` | ripgrep, grouped by file, respects `.gitignore` |
| TODO scan | `ctrl+b t` | TODO / FIXME / HACK / XXX |
| Blame + history | `ctrl+b shift+b` | follows the active file |
| Markdown preview | `ctrl+b shift+v` | glow |
| Tests | `ctrl+b shift+u` | vitest / jest / pytest, auto-detected |
| **Debug** | `ctrl+b d` | mirrors a **live** debug session running inside herdr-edit and drives it; herdr-edit resolves `.vscode/launch.json` (JSONC) through an F5 picker and hands off to delve, debugpy or js-debug (`pwa-chrome` — real browser debugging), never speaks DAP itself |
| **Live preview** | `ctrl+b shift+a` | headless Chrome screenshot rendered inline, auto-refreshing |
| **Image / screenshot paste** | `ctrl+b i` | stages a clipboard image, types its path to the agent |
| **Review the agent's diff** | `ctrl+b shift+k` | cite `path:line`, collect notes, one key sends them all to the agent pane |
| **Spaces** | `ctrl+b shift+z` | list/focus/rename/close herdr workspaces; panels reflow on `SIGWINCH` |
| **Runtime diagnostics** | in the Problems panel | console errors + uncaught exceptions from the app Preview is driving, mapped to `file:line` |
| **AI commit messages** | in `lazygit` | a custom command drafting a subject from the staged diff via the local `claude` CLI |
| Divider nudge | `ctrl+b shift+l/h` | works around the absence of mouse divider drag |
| VS Code skin | `herdr-extensions skin` | herdr's own chrome, two variants + reset |
| Format-on-save resolver | `herdr-fmt` | vendored prettier wins over global, monorepo-safe |
| Language servers | `install` | scans one level into `--projects-root` and installs a server per language actually found, reported by `doctor` |

### Not yet — the real gaps

Kept honest against the marketplace, not against our own roadmap. Where a competitor already does
one of these well, it is named, because "use the better tool" is a legitimate answer for a package
whose whole premise is composing with a pane multiplexer.

| Gap | Who does it today | Standing |
| --- | --- | --- |
| **Cross-file replace with preview** | — | The editor has replace and a match-preview API; driving it repo-wide from the Search panel is not wired. |
| **Full multi-target `next dev` debugging** | VS Code (compound configurations) | Bounded, not missing: the Debug session is scoped to one active leaf on purpose (`TestSecondStartDebuggingIsRefusedLoudly`) — a second `startDebugging` request (a worker thread, a second `next dev` target) is refused out loud rather than silently dropped or silently replacing the session on screen. A real Next.js `next dev` therefore debugs only its first target. |
| **debugpy program stdout on Linux** | — | Measured on CI, not assumed: the debugpy session initializes, runs, streams other output events and terminates cleanly on Linux, but the debuggee's own `print()` never arrives as a DAP `output` event — the same configuration works on macOS. The debug console will be missing program output on Linux until upstream debugpy changes. |

**Dropped, not shipped.** A side-by-side diff view in the editor was on this list; it is dropped, not
built, because the Review panel (a real diff) plus the editor (gutter markers + hunk preview) already
answer the need with two herdr panes rather than one — see
[Deliberately out of scope](#deliberately-out-of-scope-permanently). A command palette, an inline
`git blame` on the cursor line, and LSP autocomplete were also on this list and have since shipped in
`herdr-edit` — the command palette and autocomplete both have real, non-test call sites in
`internal/app/app.go`, and inline blame has its own toggle and draw path in `internal/app/blame.go`.

### Deliberately out of scope, permanently

- **A plugin system** — see principle 1.
- **An extension marketplace.** Distinct from principle 1's "no plugin system": there is also no
  registry of third-party additions to install into this package or into `herdr-edit`. A permanent
  non-goal, not a gap — the marketplace this composes with is herdr's own.
- **A side-by-side diff view in the editor.** Dropped 2026-07-31, not planned. Two herdr panes already
  answer it — the Review panel renders a real diff and the editor shows gutter markers plus a hunk
  preview on the same file — and building a third view duplicates that rather than closing a gap.
- **Containers / devcontainers.** Dropped, not planned. Out of scope for a package that installs onto
  the host `PATH` by design; a devcontainer story belongs to herdr itself, not to this installer.
- **Mouse divider drag.** Not ours to build: herdr 0.7.5 has no divider-drag action at all. Worked
  around with one-keypress nudges (`ctrl+b shift+l/h`).
- **Windows.** macOS and Linux only.
- **Notifications, mobile/remote access, agent orchestration, session restore, token dashboards, tab
  naming, fuzzy navigation.** Crowded, healthy categories — 22, 17, 49, 17, 6, 16 and 46 plugins
  respectively as of 2026-07-30. This package is the IDE layer; duplicating them would dilute it and
  beat none of them.

### Where we actually win

Swept 2026-07-30 across 417 plugins carrying the `herdr-plugin` topic, by topic listing and by
keyword (`lsp`, `language server`, `autocomplete`, `refactor`, `formatter`, `snippet`, `minimap`,
`multi-cursor`, `symbol`, `outline`, `lint`, `problems`, `blame`, `intellisense`, `go to
definition`). Those terms surface exactly **two** repos: this one, natively, and
[herdr-fresh](https://github.com/rvalledorjr/herdr-fresh) (1★), a thin launcher for the third-party
[Fresh](https://getfresh.dev) editor. **No other plugin implements language intelligence**; one
wraps an editor that has it.

Every direct neighbour — file-viewer (290★), reviewr (283★), sidebar — is a read-only *viewer*. The
defensible position is therefore the thing that cannot be done with a shell wrapper, because it
needs a live process that has parsed the project: **a real editor with a real LSP client**, plus the
build-loop panels (problems, tests, debug, live preview) that no other plugin offers at all.

The corollary is the strategic risk, and it should stay written down: **the agent-workflow half of
the space is where the ecosystem has converged and where all of our real gaps sit.** Line comments
returned to the agent now has roughly eight independent implementations. Being uncontested on
editor primitives does not help if the loop users actually run all day lives somewhere else.

## 5. Constraints that shape the design

These are not preferences; they are properties of the environment that have each caused a shipped bug.

| Constraint | Consequence |
| --- | --- |
| herdr's server runs under **launchd's minimal PATH** | every external binary is templated to an absolute path at install time |
| `/bin/bash` on macOS is **3.2.57** | no `mapfile`, and no apostrophes inside a heredoc nested in `$( )` |
| Python **3.9** is what macOS ships | no `tomllib`; config edits are marker-delimited splices |
| A `[[keys.command]]` **silently overrides** a herdr built-in | reserved set re-derived at runtime; `install` refuses on a clash |
| Terminals carry **text, not image bytes** | images reach the agent as *paths*, never as a clipboard bridge |
| Terminals **cannot render a web page** | preview = headless screenshot + inline image protocol |
| `pane read --lines N` is **tail-like** | oracles that read a pane must not use it |
| `plugin action invoke` has **no `--pane`** | actions resolve the globally focused pane; harnesses must set focus explicitly |

## 6. Success criteria

1. **Install → working IDE with no manual steps**, except pointing the terminal font at a Nerd Font,
   which no program can do on the user's behalf. `doctor` explains that one.
2. **Zero-change second install.** Verified by oracle 1.
3. **Byte-for-byte uninstall.** Verified by oracle 2.
4. **No keybinding collisions**, against a set derived at runtime. Verified by oracles 11 and 12.
5. **Every failure names itself.** `doctor` exits non-zero and identifies the specific broken part.
6. **The gate is real.** `live-check.sh` delegates to every offline suite rather than reimplementing
   them — it is not allowed to be green without having executed them. It once ran none of them.

## 7. How we know it works

26 numbered oracles in [SPEC.md](../SPEC.md). `live-check.sh` is the gate; it adds its own live
oracles and runs all six offline suites plus the sizing sweep:

| Suite | Oracles | Needs a server? |
| --- | --- | --- |
| `live-check.sh` | its own live checks, then delegates to every row below | yes |
| `check-panels.sh` | 31 | no |
| `check-viability.sh` | 7 | no |
| `check-project-resolve.sh` | 7 | no |
| `check-image-paste.sh` | 11 | no |
| `check-review.sh` | 15 | no |
| `check-runtime-diagnostics.sh` | 11 | no |
| `check-preview.sh` | 8 | no |
| `check-deps.sh` | 6 | no |
| `check-sizing.py` | 141 widths swept | no |

The eight shell suites total **96 oracles** and run standalone, which matters: without a live herdr
server the live oracles cannot run at all, and a report must say so rather than call the gate green.

Standards applied to each:

- **A fix ships with an oracle confirmed RED before green.** Several here were written against already
  fixed code and proved nothing until deliberately mutated back.
- **Oracles that guard a hang are hard-bounded**, because an unbounded one hangs the gate instead of
  failing it — and a hanging gate is no better than one never run.
- **Assert on rendered output, not arithmetic**, where the user's complaint is visual. ORACLE 19 reads
  the pane for `EXPLORER` because every geometry layer once reported success while showing no files.
- **An oracle must never restate the list it polices.** Oracle 23d hardcoded the panel labels that
  image-paste excludes; it named a `Files` panel that had been removed and never named `Preview`,
  which existed — so a pasted path could be typed into the Preview pane and the gate was structurally
  incapable of noticing. It now derives the labels from the `[[panes]]` titles in the manifest, the
  same rule the geometry suites follow by parsing `open-panel.sh`.

## 8. Known risks

| Risk | Standing |
| --- | --- |
| herdr is third-party and pre-1.0 | protocol skew after a `brew upgrade` is real; `doctor` checks `herdr status`. Reserved-key set is re-derived at runtime so herdr can keep adding actions. |
| Apple Terminal cannot show images | preview and inline images degrade with an explicit message naming Ghostty/kitty/WezTerm |
| `pngpaste` is a silent partial dependency | without it clipboard paste dies but the screenshot fallback works — so `doctor` names it |
| Chrome behaviour may change | the preview waits for the *artifact*, not the process, precisely because Chrome does not exit against a dev server |

## 9. Open questions

1. Should the Preview panel gain interactivity (click-through via CDP) or stay a picture with an
   `o`-to-open escape hatch? Current answer: stay a picture — a half-interactive preview is a worse lie
   than an honest screenshot.
2. Is a Windows port worth it, given herdr's Windows support is itself beta?
3. Should `herdr-fmt` grow beyond prettier, or is a formatter resolver out of scope now that the
   editor has format-on-save?
