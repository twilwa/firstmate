import json, glob, os, sys
art, lists = sys.argv[1], sys.argv[2]
runs = {"40673507764": "main #48 (hint source, pre-#49)",
        "40703025845": "main #49 (mise pre-trust)",
        "40796972623": "main #52 (current base)",
        "40768416410": "PR run of this exact partition"}
def lanes(which):
    d = os.path.join(lists, which)
    return {l: [p.strip() for p in open(os.path.join(d, l)) if p.strip()] for l in sorted(os.listdir(d))}
parts = {"base": lanes("base"), "target": lanes("target")}
for r, label in runs.items():
    dur = {}
    for f in glob.glob(os.path.join(art, r, "fm-test-timing-portable-*", "*.json")):
        for s in json.load(open(f))["scripts"]:
            if s["exit"] == 0:
                dur[s["path"]] = s["duration_ms"]
    print(f"## run {r}: {label}  (measured successful scripts: {len(dur)})")
    for kind in ("parallel", "serial"):
        for name, part in parts.items():
            sums, missing = [], 0
            for l, ps in part.items():
                if f"-{kind}-" not in l: continue
                sums.append(sum(dur.get(p, 0) for p in ps)); missing += sum(p not in dur for p in ps)
            mx, mn = max(sums), min(sums)
            print(f"  {kind:8} {name:6} lanes_ms={sums} max={mx} min={mn} spread={mx-mn} ({100*(mx-mn)/mx:.0f}% of max) unmeasured={missing}")
