#!/usr/bin/env python3
# usage: score-serial-deviation-from-mean.py <artifact-root> <lists-root> <hints.tsv>
# HEAD serial shards per hosted run: supervision-host pinned to its post-#52 517234 ms,
# scripts that did not yet exist in an older run filled from their HEAD hint.
# Prints max-min spread and each run's worst lane deviation from that run's mean.
import glob, json, os, sys
art, lists, hints = sys.argv[1:4]
H = dict(l.split() for l in open(hints) if l.strip())
d = os.path.join(lists, "head")
part = {l: [p.strip() for p in open(os.path.join(d, l)) if p.strip()] for l in os.listdir(d) if "-serial-" in l}
for r in ["40664798225", "40673507764", "40703025845", "40796972623", "40768416410"]:
    dur = {}
    for f in glob.glob(os.path.join(art, r, "**", "*.json"), recursive=True):
        if "aggregate" in f: continue
        for s in json.load(open(f)).get("scripts", []):
            if s["exit"] == 0: dur[s["path"]] = s["duration_ms"]
    dur["tests/fm-supervision-host.test.sh"] = 517234
    filled = [p for ps in part.values() for p in ps if p not in dur]
    sums = [sum(dur.get(p, int(H.get(p, 0))) for p in ps) for ps in part.values()]
    mx, mn, mean = max(sums), min(sums), sum(sums) / len(sums)
    dev = max(abs(s - mean) for s in sums) / mean
    print(f"{r} serial head max={mx/1000:.0f}s min={mn/1000:.0f}s max-min={100*(mx-mn)/mx:.0f}% worst-lane-vs-mean={100*dev:.1f}% filled_from_hint={filled}")
