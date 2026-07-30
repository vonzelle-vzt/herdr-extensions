# herdr gap closure — wave 1 (parallel-safe units only)

Derived from the 401-repo competitive sweep of 2026-07-30, recorded in
`docs/PRD.md` §4 and `README.md` "Against the other plugins in herdr's own marketplace".

**This run builds the four units that are genuinely parallel-safe, and stops at a green gate.**
The remaining editor features are specified at the bottom as a durable roadmap and are deliberately
**not** in the dispatchable `units` array — see the constraint below for why.

---

## 🔴 The constraint that prices this decomposition

**Six of the ten requested features cannot run in parallel, and it is not a style question.**

`command palette`, `go-to-line`, `select-all`, `inline git blame`, `diff view` and `LSP
autocomplete` each need three things that live in exactly one place each:

| What they need | Where it must live | Why it cannot be split |
| --- | --- | --- |
| per-feature state | the `App` struct, `internal/app/app.go` | Go declares a struct's fields in ONE file |
| a leader key | `leaderBindings()`, `internal/app/leader.go` | one table, one function |
| a menu row + key/mouse dispatch + a draw call | `internal/app/app.go` | one `menuLayout`, one `handleKey`, one draw |

So their `FILES_IN_SCOPE` sets all contain `app.go` and `leader.go`. They are **pairwise
overlapping by construction**. A barrier cannot rescue this either: if the barrier writes the
wiring and the feature files do not exist yet, the tree does not compile — and then *every* unit's
`go test` oracle fails in its own worktree for a reason that has nothing to do with that unit.

**Therefore those six are a sequential chain, run after this wave, not a fan-out.** Parallelism is
not a goal; a green oracle per unit is. Pretending six units are independent when they share a
struct field would produce six worktrees that each compile alone and conflict on merge.

The four units below were selected because each one touches files no other unit touches **and**
each compiles and tests standalone.

## Contract — the done-state a stranger could check

1. **A Review panel exists** (`ctrl+b shift+k`): shows the worktree diff against a chosen baseline,
   accepts `file:line comment` notes, accumulates them, and sends all of them to the **agent** pane
   in one keystroke — never to one of our own panels.
2. **The Problems panel reports runtime errors**, not only static analysis: `console.error` and
   uncaught exceptions raised by the app the Preview panel is already driving, each rendered as
   `file:line  runtime  <message>` alongside the existing tsc/eslint/ruff output.
3. **The Preview panel writes a console log** that the Problems panel consumes, without a CDP
   client and without a new dependency.
4. **`herdr-extensions install` writes a lazygit custom command** that drafts a commit message from
   the staged diff using the local `claude` CLI, inside a marker-delimited region that `uninstall`
   removes byte-for-byte.
5. **Diagnostics render their message inline** (Error Lens style) at end-of-line, dimmed, truncated
   to fit, in addition to the existing underline — and the existing underline behaviour is unchanged.
6. `./tests/live-check.sh`'s offline suites are green, and `make test` is green in herdr-edit.

## Out of scope — a unit may NOT "helpfully" also do these

- **Any change to `internal/app/app.go` or `internal/app/leader.go`.** That is the sequential
  chain's territory. A unit that thinks it needs them must report it, not do it.
- Refactoring `plugin/image-paste.sh` to share its agent-pane picker. b1 adds one label to its
  `PANELS` set and nothing more; u1 reimplements the picker locally. The duplication is accepted
  debt for this wave — extracting a shared helper would put a fourth file in two units' scope.
- A CDP client, a websocket library, or any new runtime dependency.
- Line-by-line *cursor selection* in the Review panel. v1 takes typed `file:line` references —
  the send-back loop is the valuable half and is what the ecosystem has converged on.
- Bumping any version, editing any Formula, tagging, or pushing.
- Touching the other repo. Each unit works in exactly one of the two.

## Interfaces that cross unit boundaries — the barrier owns these

`u1` needs the Review panel registered, and registration is spread across three shared files that
no feature unit may touch. **b1 owns all three and builds nothing else.** The lazygit AI-commit
step lives here too, because it is purely an `install`/`uninstall` change in the same CLI file —
giving it its own unit would have meant two units editing `bin/herdr-extensions`.

- `plugin/herdr-plugin.toml` — a `[[panes]]` entry titled **`Review`** plus its `[[actions]]`
  entry `open-review`, following the existing `open-blame` shape exactly (relative script path,
  `@@`-templated binaries, `placement=split`, `direction=down`, `size=0.45`).
- `bin/herdr-extensions` — one new `KEYS` row `("prefix+shift+k", "open-review", …)`, `"review"`
  added to `PANEL_SCRIPTS`, and a `write_lazygit_ai_commit()` step in `install` (+ its removal in
  `uninstall`).

🔴 **`prefix+shift+c` was WRONG and is corrected to `prefix+shift+k`.** It is free against herdr's
39 reserved bindings, but this machine already binds `prefix+shift+c` to the `persiyanov.reviewr`
plugin — and our installer's collision check covers herdr's built-ins *and the user's own*
`[[keys.command]]` entries, which is exactly what caught it (`doctor --keymap`:
"prefix+shift+c (ours) overrides your own [[keys.command]] binding"). Free on this machine as of
2026-07-30: shift+i, shift+j, shift+k, shift+q, shift+y, shift+z.
**`prefix+r` and `prefix+shift+r` are BOTH reserved** — `prefix+r` is herdr's only resize binding,
and taking it removes pane resizing entirely, presenting as "the divider will not move". The
installer's runtime collision check is the authority; if it refuses, report it, do not `--force`.

- `plugin/image-paste.sh` — the `PANELS` set, which is registration and not decoration: it is the
  list of panes a staged image path must never land in. Oracle 23d **derives** its expected list
  from the manifest's `[[panes]]` titles, so adding a pane without adding the exclusion turns 23d
  red. b1 owns both sides of that pair for exactly this reason.

## File manifest

See the `manifest` array in the machine block below.

---

## Roadmap — NOT dispatched by this run

The sequential editor chain, in dependency order. Each needs `app.go` + `leader.go`, so each must
land before the next starts.

1. **Go-to-line + Select-all** — two leader actions (`Esc g`, `Esc a`), one unit.
   🔴 **`Tab.SelectAll()` ALREADY EXISTS** at `internal/editor/tab.go:726`, is exercised by three
   tests (`comment_test.go` x2, `tab_test.go`), and has **zero non-test callers**. Swept every
   exported `Tab` method: `EnsureVisible`, `GutterWidth` and `PersistUndo` each have a real caller
   inside the editor package; **`SelectAll` is the only genuinely unreachable one.** This is the
   **THIRD** instance of the fork's signature failure — after hover/go-to-definition and after
   find/replace. So this unit is pure wiring for select-all: a leader entry, a menu row, and a call.
   Do not reimplement the selection logic.
   Recon already done, so the next session does not repeat it: jump with the exported
   `Tab.MoveCursorTo(pos, extend)` (`tab.go`) — `cursorMoved` is unexported and cannot be set from
   package `app`. Reuse `openPrompt(title, hint, initial, callback)` (`modals.go:112`) for the line
   number rather than building a second input; `flash(msg)` reports a bad one. Free leader runes:
   `g` and `a` (taken: s u r w q n t / f p h d z). Keep the parse (`"N"`, `"N:C"`, out-of-range) in a
   pure helper so it can be tested without a screen.
2. **Command palette** — reuse `internal/finder`'s scorer over `leaderBindings()` + `menuLayout()`.
3. **Inline git blame** — `git blame -L` on idle, cached per file, dim at EOL. Owed upstream too.
4. **Diff view** — inline diff with a merge-base ⇄ `HEAD` baseline flip; reuses
   `parseGitHunkPreview`. Feeds a future line-selection upgrade to the Review panel.
5. **LSP autocomplete** — `textDocument/completion` + popup. The transport, the server registry and
   the UTF-16 ↔ rune conversion already exist; the popup and the caller do not.
   🔴 Implementing the request is the easy half — this fork has shipped an unreachable engine twice.

<!-- vzt-spec -->
```json
{
  "specVersion": 1,
  "slug": "gap-closure",
  "title": "herdr gap closure — wave 1 (parallel-safe units)",
  "root": "/Users/vonzellebrown/github-projects/herdr-extensions",
  "contract": "A Review panel sends file:line comments to the agent pane; the Problems panel reports runtime console errors captured by the Preview panel without a CDP client; install writes a marker-delimited lazygit AI-commit custom command; herdr-edit renders diagnostic messages inline at end-of-line in addition to the underline. Offline oracle suites green in herdr-extensions and make test green in herdr-edit.",
  "manifest": [
    { "path": "plugin/herdr-plugin.toml", "op": "modify" },
    { "path": "bin/herdr-extensions", "op": "modify" },
    { "path": "plugin/image-paste.sh", "op": "modify" },
    { "path": "libexec/review", "op": "new" },
    { "path": "tests/check-review.sh", "op": "new" },
    { "path": "libexec/preview", "op": "modify" },
    { "path": "libexec/problems", "op": "modify" },
    { "path": "tests/check-runtime-diagnostics.sh", "op": "new" },
    { "path": "/Users/vonzellebrown/github-projects/herdr-edit/internal/app/diagnostics.go", "op": "modify" },
    { "path": "/Users/vonzellebrown/github-projects/herdr-edit/internal/app/diagnostics_test.go", "op": "modify" }
  ],
  "barrier": {
    "id": "b1",
    "title": "Registration: Review pane/action/key + lazygit AI-commit installer step",
    "agentType": "vzt-builder",
    "filesInScope": ["plugin/herdr-plugin.toml", "bin/herdr-extensions", "plugin/image-paste.sh"],
    "brief": "Two shared-registration files, nothing else. (1) In plugin/herdr-plugin.toml add a [[panes]] entry with title = \"Review\" and an [[actions]] entry id open-review, copying the SHAPE of the existing open-blame pane/action exactly: the command runs open-panel.sh with a relative script path (the plugin dir is the cwd herdr execs from), placement split, direction down, size 0.45. Every external binary MUST be an @@TEMPLATE@@ placeholder rendered by render_plugin() to an absolute path -- the herdr server runs under launchd with PATH=/usr/bin:/bin:/usr/sbin:/sbin, so a bare binary name silently never resolves. QUOTE every templated path; @@CHROME@@ contains spaces. (2) In bin/herdr-extensions: add ONE KEYS row (\"prefix+shift+c\", \"open-review\", \"Review panel: comment on the agent's diff and send it back\"); add \"review\" to PANEL_SCRIPTS so libexec/review is copied next to open-panel.sh; and add a write_lazygit_ai_commit() step to install that appends a customCommand to the user's lazygit config drafting a commit subject from the STAGED diff via the local `claude` CLI, wrapped in a marker-delimited region in the same style as the existing herdr config regions, with the matching removal in uninstall so uninstall stays byte-for-byte. Use the CLI's existing marker-splice helpers; do NOT add a YAML library (stdlib-only Python 3.9, no tomllib, no pyyaml). DO NOT create libexec/review or edit libexec/* or tests/* -- those are other units. (3) In plugin/image-paste.sh add 'Review' to the PANELS set. That set is registration, not decoration: it is the list of panes a staged image path must never be typed into, oracle 23d DERIVES its expected list from the [[panes]] titles you are adding to, and it will go RED the moment the Review pane exists unless you keep the two in step. This is the same drift that once left a 'Files' panel in the set that no longer existed while 'Preview' was missing from it, making the Preview pane a legal target for a pasted path. DO NOT bump any version.",
    "machineCheck": "cd /Users/vonzellebrown/github-projects/herdr-extensions && /usr/bin/python3 -c \"import re,sys; s=open('plugin/herdr-plugin.toml').read(); import collections; titles=re.findall(r'^title = \\\"(.*)\\\"', s, re.M); assert 'Review' in titles, 'no Review pane title'; assert 'open-review' in s, 'no open-review action'; print('OK manifest has Review pane + open-review action')\" && /usr/bin/python3 -c \"s=open('bin/herdr-extensions').read(); assert 'prefix+shift+c' in s, 'no prefix+shift+c key'; assert 'open-review' in s, 'no open-review in KEYS'; assert '\\\"review\\\"' in s, 'review not in PANEL_SCRIPTS'; assert 'write_lazygit_ai_commit' in s, 'no lazygit AI commit step'; print('OK CLI registers review + lazygit ai-commit')\" && /usr/bin/python3 -c \"s=open('plugin/image-paste.sh').read(); assert \\\"'Review'\\\" in s, 'Review missing from the image-paste PANELS set'; print('OK image-paste excludes Review')\" && ./tests/check-image-paste.sh && ./bin/herdr-extensions version",
    "expect": "exit 0; prints the three OK lines, then check-image-paste.sh reports '11 passed, 0 failed' (oracle 23d derives its labels from the manifest, so this proves the new pane and the exclusion set are in step), then the version string"
  },
  "integration": {
    "title": "Both repos green end to end",
    "machineCheck": "for s in check-panels check-viability check-project-resolve check-image-paste check-preview check-deps check-review check-runtime-diagnostics; do echo \"== $s\"; ./tests/$s.sh || exit 1; done && /usr/bin/python3 tests/check-sizing.py && ./bin/herdr-extensions doctor && cd /Users/vonzellebrown/github-projects/herdr-edit && gofmt -l internal/app/ | grep -v -e actionvars.go -e fileops.go -e formmodal_test.go | grep . && exit 1; cd /Users/vonzellebrown/github-projects/herdr-edit && go build ./... && make test",
    "expect": "every offline suite prints '0 failed' including the two new ones; check-image-paste stays at 11 passed (proving the manifest-derived exclusion list is in step with the new Review pane); doctor exits 0; herdr-edit builds and all 14 packages pass under -race"
  },
  "units": [
    {
      "id": "u1",
      "title": "Review panel — comment on the agent's diff, send it back",
      "agentType": "vzt-builder",
      "filesInScope": ["libexec/review", "tests/check-review.sh"],
      "brief": "Create libexec/review, a herdr panel script, plus tests/check-review.sh, its offline oracle. THE PANEL: print the worktree diff against a baseline (default the branch merge-base, flippable to HEAD), grouped by file with line numbers so a reader can cite a line. Then loop reading notes typed as `path:line comment text`, accumulating them in a temp file, echoing each back as confirmation. One key (`s`) SENDS every accumulated note to the AGENT pane as a single message via `herdr pane send-text`, then clears the buffer; `q` quits. THE PANE PICK IS THE HARD PART and is the whole point: never type into one of our own panels. Resolve `herdr pane list` JSON with /usr/bin/python3, EXCLUDE every pane whose label is one of our panel titles, and prefer the focused pane if usable, else an agent pane in the same tab, then the same workspace -- dropping a note into an agent in an unrelated project is worse than doing nothing. Derive that excluded-label list by parsing the [[panes]] titles out of ../herdr-plugin.toml at runtime (the rendered manifest sits beside the script); a hardcoded copy is exactly how oracle 23d went blind. Follow the house rules in CLAUDE.md: absolute paths for every external binary via @@TEMPLATE@@ (launchd's PATH has no homebrew), QUOTE templated paths, read the active-file contract with IFS=$'\\x1f' NOT tab (tab is IFS whitespace and shifts every field left), and write \"does not\" rather than an apostrophe inside any heredoc nested in $( ) because /bin/bash here is 3.2.57 and mis-parses it. Panel scripts print to stdout then wait for a keypress so the pane persists. THE ORACLE (tests/check-review.sh) must run fully OFFLINE like tests/check-image-paste.sh: render the script by substituting @@HERDR@@ with a stub on PATH that answers `pane list` from HERDR_STUB_PANES and logs every send-text, then assert (a) a note reaches the agent pane and not a panel pane, (b) a focused Review/Edit/Problems pane is skipped in favour of the agent, (c) the excluded-label list is derived from the manifest rather than restated, (d) same-tab is preferred over another workspace. Confirm each assertion RED against a deliberately broken variant before trusting it green. Do not edit plugin/herdr-plugin.toml, bin/herdr-extensions, or any other libexec script.",
      "machineCheck": "cd /Users/vonzellebrown/github-projects/herdr-extensions && test -x libexec/review && /bin/bash -n libexec/review && /bin/bash -n tests/check-review.sh && ./tests/check-review.sh",
      "expect": "exit 0; libexec/review parses under bash 3.2; check-review.sh prints 'N passed, 0 failed' with at least 4 assertions"
    },
    {
      "id": "u2",
      "title": "Runtime diagnostics — Preview captures console errors, Problems reports them",
      "agentType": "vzt-builder",
      "filesInScope": ["libexec/preview", "libexec/problems", "tests/check-runtime-diagnostics.sh"],
      "brief": "Make the Problems panel report errors from the RUNNING app, not only static analysis. THE MECHANISM IS ALREADY VERIFIED, use it and do not invent another: headless Chrome invoked with --enable-logging=stderr --v=1 prints BOTH console.error output and uncaught exceptions to stderr, in the form `[pid:tid:MMDD/HHMMSS.uuuuuu:INFO:CONSOLE:LINE] \\\"MESSAGE\\\", source: URL (LINE)`. Confirmed locally against Chrome on this machine. NO CDP client, NO websocket, NO new dependency -- those are out of scope. (1) libexec/preview: it already shells Chrome with --screenshot for each refresh; add --enable-logging=stderr --v=1, capture stderr, parse out the CONSOLE lines and write them to a small append-or-replace log at a stable path under $XDG_STATE_HOME (or ~/.local/state) alongside the existing preview state, one record per line as url\\x1fline\\x1fmessage. Keep \\x1f as the separator, never a tab: tab is IFS whitespace and collapses empty fields, which has already broken every panel at once. Preview's existing behaviour must not regress -- it waits for the ARTIFACT not the process, because Chrome does not exit against a dev server, and check-preview.sh is hard-bounded to catch a hang. (2) libexec/problems: after the existing tsc/eslint/ruff sections, read that log if it is fresh and print its records in the SAME `file:line:col  severity  message` shape the panel already uses, under a clearly labelled runtime section, mapping the source URL back to a repo-relative path where it can and printing the URL when it cannot. If the log is missing or stale, print nothing extra -- absence is not an error, and a panel that shouts about a preview nobody opened is noise. (3) tests/check-runtime-diagnostics.sh: an OFFLINE oracle. Do not launch Chrome. Feed libexec/problems a hand-written fixture log and assert the records surface with the right file, line and message; feed it a stale/missing log and assert the section is silent; and assert the parser handles a message containing a comma and one containing quotes, since the Chrome format is comma-delimited and will otherwise split mid-message. Confirm each assertion RED before green. Bound anything that could hang. Do not edit plugin/herdr-plugin.toml, bin/herdr-extensions, libexec/review, or the other test suites.",
      "machineCheck": "cd /Users/vonzellebrown/github-projects/herdr-extensions && /bin/bash -n libexec/preview && /bin/bash -n libexec/problems && /bin/bash -n tests/check-runtime-diagnostics.sh && ./tests/check-runtime-diagnostics.sh && ./tests/check-preview.sh",
      "expect": "exit 0; check-runtime-diagnostics.sh prints 'N passed, 0 failed'; the pre-existing check-preview.sh still prints '8 passed, 0 failed'"
    },
    {
      "id": "u3",
      "title": "Error Lens — diagnostic message inline at end-of-line",
      "agentType": "vzt-builder",
      "filesInScope": [
        "/Users/vonzellebrown/github-projects/herdr-edit/internal/app/diagnostics.go",
        "/Users/vonzellebrown/github-projects/herdr-edit/internal/app/diagnostics_test.go"
      ],
      "brief": "In the herdr-edit repo at /Users/vonzellebrown/github-projects/herdr-edit, extend drawDiagnostics() in internal/app/diagnostics.go so a diagnostic also renders its MESSAGE inline at the end of the offending line, dimmed, the way VS Code's Error Lens does -- in ADDITION to the existing underline, which must not change. Rules: draw only for the most severe diagnostic on a given line; start the text a couple of columns after the line's last rune; truncate with an ellipsis so it never exceeds the editor rect and never wraps; skip entirely when fewer than ~20 columns remain, because a two-word fragment of an error is worse than no error; colour it with the existing diagnosticColor for the severity but dimmed, and reuse the existing severityRank helper rather than writing a second ordering. This runs in the overlay pass AFTER tab.Render, which is exactly why syntax colours survive -- keep it there and keep it a separate pass. Respect the existing geometry helpers in internal/editor/geometry.go for the gutter-to-screen mapping; do not open-code column arithmetic. Word wrap is a SEPARATE geometry path gated on Tab.Wrap -- when wrap is on, either place the text correctly for the wrapped row or skip it, but never assume one buffer line equals one screen row. Add tests to internal/app/diagnostics_test.go using tcell.NewSimulationScreen(\\\"UTF-8\\\") and asserting against scr.GetContents(), matching the existing test style in that package: cover that the message appears, that it is truncated rather than overflowing a narrow pane, that only the most severe diagnostic on a line draws, and that the underline is still painted. 🔴 DO NOT edit internal/app/app.go or internal/app/leader.go -- a toggle, a menu row and a leader key are the sequential chain's job, not yours; this unit is unconditional rendering. Do not add a dependency. Keep the file-header convention and a doc comment on every new function.",
      "machineCheck": "cd /Users/vonzellebrown/github-projects/herdr-edit && gofmt -l internal/app/diagnostics.go internal/app/diagnostics_test.go && go build ./... && go test -race ./internal/app/ -run 'Diagnostic|ErrorLens|Inline'",
      "expect": "exit 0; gofmt lists nothing; the build succeeds; the diagnostics tests run with 0 failures and include new assertions naming the inline message"
    }
  ]
}
```
<!-- /vzt-spec -->
