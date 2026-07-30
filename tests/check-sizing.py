#!/usr/bin/env python3
"""Oracle 14 — panel sizing math, run against a fixture so it needs no live herdr server.

The logic under test lives inline in plugin/open-panel.sh (it has to: the launcher must stay a
single self-contained file that herdr can exec). We extract that block rather than duplicating it,
so this test can never drift from the code that actually runs.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARK = "edges_raw, pane_id, target = sys.argv[1:4]"

src = open(os.path.join(ROOT, "plugin", "open-panel.sh")).read()
if MARK not in src:
    sys.exit("could not find the sizing block in open-panel.sh")
BODY = "MIN_COLS = 56\nMAX_FRAC = 0.55\n" + MARK + src.split(MARK, 1)[1].split("EOF\n)", 1)[0]
BASE = json.load(open(os.path.join(ROOT, "tests", "fixtures", "edges-2pane.json")))


def calc(doc, pane, target):
    ns = {"json": json, "sys": type("S", (), {"argv": ["-", json.dumps(doc), pane, target]})()}
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
print("panel sizing OK")
