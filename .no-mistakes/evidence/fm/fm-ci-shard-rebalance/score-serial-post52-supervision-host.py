#!/usr/bin/env python3
# usage: score-serial-post52-supervision-host.py <artifact-root> <lists-root>
# Same scoring as score-repack-vs-hosted-runs.py, but tests/fm-supervision-host.test.sh
# always takes its only post-#52 measurement (517234 ms, run 40796972623), because #52
# rewrote it: older runs measured the old ~1046 s script and PR run 40768416410 failed it.
import glob, json, os, sys
art, lists = sys.argv[1], sys.argv[2]
SH = "tests/fm-supervision-host.test.sh"
runs = ["40664798225", "40673507764", "40703025845", "40796972623", "40768416410"]
def lanes(side):
    d = os.path.join(lists, side)
    return {l: [p.strip() for p in open(os.path.join(d, l)) if p.strip()]
            for l in sorted(os.listdir(d), key=lambda s: (len(s), s))}
for r in runs:
    dur = {}
    for f in glob.glob(os.path.join(art, r, "**", "*.json"), recursive=True):
        if "aggregate" in f: continue
        for s in json.load(open(f)).get("scripts", []):
            if s["exit"] == 0: dur[s["path"]] = s["duration_ms"]
    dur[SH] = 517234
    for kind in ("parallel", "serial"):
        for side in ("base", "head"):
            sums = [sum(dur.get(p, 0) for p in ps) for l, ps in lanes(side).items() if f"-{kind}-" in l]
            mx, mn = max(sums), min(sums)
            print(f"{r} {kind:8} {side:4} max={mx/1000:5.0f}s min={mn/1000:5.0f}s spread={100*(mx-mn)/mx:3.0f}%  lanes_s={[round(s/1000) for s in sums]}")
