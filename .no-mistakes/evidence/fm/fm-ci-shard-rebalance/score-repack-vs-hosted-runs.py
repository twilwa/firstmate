#!/usr/bin/env python3
# usage: score-repack-vs-hosted-runs.py <artifact-root> <lists-root>
# Scores base and HEAD lane memberships (from `bin/fm-test-run.sh --list --lane`)
# against each hosted run's successful per-script duration_ms from its
# fm-test-timing-portable-* artifacts.
import glob, json, os, sys
art, lists = sys.argv[1], sys.argv[2]
runs = {
    "40664798225": "main (hint source)",
    "40673507764": "main #48 (hint source)",
    "40703025845": "main #49 (hint source)",
    "40796972623": "main #52 (hint source, current base)",
    "40768416410": "PR #50 own run (prior a6735df7 partition)",
}
def lanes(side):
    d = os.path.join(lists, side)
    return {l: [p.strip() for p in open(os.path.join(d, l)) if p.strip()]
            for l in sorted(os.listdir(d), key=lambda s: (len(s), s))}
parts = {"base": lanes("base"), "head": lanes("head")}
for r, label in runs.items():
    dur = {}
    for f in glob.glob(os.path.join(art, r, "**", "*.json"), recursive=True):
        if "aggregate" in f:
            continue
        for s in json.load(open(f)).get("scripts", []):
            if s["exit"] == 0:
                dur[s["path"]] = s["duration_ms"]
    print(f"## run {r}: {label}  (successful scripts measured: {len(dur)})")
    for kind in ("parallel", "serial"):
        for name, part in parts.items():
            sums, missing = [], []
            for l, ps in part.items():
                if f"-{kind}-" not in l:
                    continue
                sums.append(sum(dur.get(p, 0) for p in ps))
                missing += [p for p in ps if p not in dur]
            mx, mn = max(sums), min(sums)
            print(f"  {kind:8} {name:4} max={mx/1000:7.0f}s min={mn/1000:7.0f}s "
                  f"spread={100*(mx-mn)/mx:4.0f}% of max  lanes_s={[round(s/1000) for s in sums]}"
                  + (f"  unmeasured={missing}" if missing else ""))
