import json, glob, sys
D="/tmp/fm-ci-timing"; runs=["40664798225","40673507764","40703025845","40796972623","40768416410","40805050743"]
L1=[l.strip() for l in open(sys.argv[1]) if l.strip()]; L2=[l.strip() for l in open(sys.argv[2]) if l.strip()]
par=L1+L2
m={r:{} for r in runs}
for r in runs:
    for f in glob.glob(f"{D}/{r}/fm-test-timing-portable-parallel-*/*.json"):
        for s in json.load(open(f))["scripts"]:
            if s["exit"]==0: m[r][s["path"]]=s["duration_ms"]
fixed="tests/fm-pi-primary-types.test.sh"
order=[fixed]+sorted(p for p in par if p!=fixed)
missing=[(r,p) for r in runs for p in order if p not in m[r]]
assert not missing, missing
print(len(order), len(runs))
for p in order: print(" ".join(str(m[r][p]) for r in runs), p, 1 if p in L1 else 2)
