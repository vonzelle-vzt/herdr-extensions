#!/usr/bin/env python3
"""Oracle 14 — panel sizing math, run against a fixture so it needs no live herdr server.

The logic under test lives inline in plugin/open-panel.sh (it has to: the launcher must stay a
single self-contained file that herdr can exec). We extract that block rather than duplicating it,
so this test can never drift from the code that actually runs.

The GEOMETRY POLICY constants are parsed out of the same file for the same reason. An earlier
version of this test declared its own `MIN_COLS = 56` / `MAX_FRAC = 0.55` prelude, which quietly
reintroduced the drift the docstring above claims to prevent — the test would have kept passing
against stale numbers after a retune. Now there is exactly one place to change them.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARK = "edges_raw, pane_id, target, min_cols, min_peer, max_frac = sys.argv[1:7]"

src = open(os.path.join(ROOT, "plugin", "open-panel.sh")).read()
if MARK not in src:
    sys.exit("could not find the sizing block in open-panel.sh")
BODY = MARK + src.split(MARK, 1)[1].split("EOF\n)", 1)[0]

# The bash side of the same policy. These feed the block above as argv, exactly as the launcher
# does, so a change to either number is picked up here with no edit to this file.
POLICY = dict(re.findall(r"^(MIN_COLS|MIN_PEER|MAX_FRAC)=([0-9.]+)", src, re.M))
for key in ("MIN_COLS", "MIN_PEER", "MAX_FRAC"):
    if key not in POLICY:
        sys.exit("could not find %s in the geometry policy block of open-panel.sh" % key)
MIN_COLS = int(POLICY["MIN_COLS"])
MIN_PEER = int(POLICY["MIN_PEER"])
MAX_FRAC = float(POLICY["MAX_FRAC"])

# Below this a side-by-side is genuinely impossible and the launcher opens a tab instead, so the
# clamp is never asked to protect the peer there. Mirrors the viability guard in open-panel.sh.
SPLITTABLE = MIN_COLS + MIN_PEER

BASE = json.load(open(os.path.join(ROOT, "tests", "fixtures", "edges-2pane.json")))


def calc(doc, pane, target):
    argv = ["-", json.dumps(doc), pane, target,
            str(MIN_COLS), str(MIN_PEER), str(MAX_FRAC)]
    ns = {"json": json, "sys": type("S", (), {"argv": argv})()}
    out = []
    ns["print"] = lambda *a: out.append(" ".join(map(str, a)))
    exec(compile(BODY, "<sizing>", "exec"), ns)
    return out[0] if out else None


def resulting_cols(width, pane, target):
    doc = json.loads(json.dumps(BASE))
    split = doc["result"]["edges"]["layout"]["splits"][0]
    split["rect"]["width"] = width
    move = calc(doc, pane, target)
    ratio = split["ratio"]
    if move:
        direction, amount = move.split()
        ratio += float(amount) if direction in ("right", "down") else -float(amount)
    first_cols = round(ratio * width)
    return (first_cols if pane == "edit" else width - first_cols), move


fails = []


def check(label, got, want):
    if got != want:
        fails.append("%s: got %r want %r" % (label, got, want))


# Exact sizing on a roomy screen.
check("200col/88", resulting_cols(200, "edit", "88")[0], 88)
check("200col/110", resulting_cols(200, "edit", "110")[0], 110)

# A second-child panel must invert to 1-want, or we would size the wrong pane.
check("second-child/88", resulting_cols(200, "agent", "88")[0], 88)

# Idempotent: asking for the size it already has must emit no resize at all.
check("idempotent", resulting_cols(200, "edit", "63")[1], None)

# --- the regression this policy exists for ------------------------------------------------------
# A 109-column split (a 145-col terminal minus herdr's 36-col sidebar) used to be refused outright:
# the viability guard compared the RAW 88-column request against MIN_PEER, got 21, and sent the
# editor to its own tab. The clamp always could have handled it. 88 shrinks to MAX_FRAC of the
# split, and both panes clear their floors with room to spare.
cols_109, _ = resulting_cols(109, "edit", "88")
check("109col/88 -> panel", cols_109, 60)
check("109col/88 -> peer", 109 - cols_109, 49)

# The requested width is a preference, so every width in the band the guard used to reject
# (SPLITTABLE .. MIN_COLS+request) must still produce a usable side-by-side rather than a refusal.
for width in range(SPLITTABLE, 133):
    cols, _ = resulting_cols(width, "edit", "88")
    if cols < MIN_COLS:
        fails.append("%dcol/88 -> %d cols, under MIN_COLS %d" % (width, cols, MIN_COLS))
    if width - cols < MIN_PEER:
        fails.append("%dcol/88 -> peer %d, under MIN_PEER %d" % (width, width - cols, MIN_PEER))

# The peer ceiling holds for any request at any splittable width — this is the term the clamp was
# missing, and MAX_FRAC alone does not imply it if MAX_FRAC is ever retuned upward.
for width in range(SPLITTABLE, 241):
    for want in ("20", "88", "150", "400"):
        cols, _ = resulting_cols(width, "edit", want)
        if width - cols < MIN_PEER:
            fails.append("%dcol/want %s -> peer %d, under MIN_PEER %d"
                         % (width, want, width - cols, MIN_PEER))

# The floor beats the cap. SpiceEdit refuses to draw under 50 columns, so no screen width may
# ever produce a panel below that -- an oversized panel is annoying, an unusable one is a bug.
for width in (64, 80, 120, 160, 200):
    for want in ("20", "88", "150"):
        cols, _ = resulting_cols(width, "edit", want)
        if cols < 50:
            fails.append("%dcol/want %s -> %d cols, under SpiceEdit minWidth 50" % (width, want, cols))

if fails:
    print("FAIL")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("panel sizing OK (MIN_COLS=%d MIN_PEER=%d MAX_FRAC=%s, %d widths swept)"
      % (MIN_COLS, MIN_PEER, MAX_FRAC, 241 - SPLITTABLE))
