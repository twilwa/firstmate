import json, glob
D="/tmp/fm-ci-timing"; runs=["40664798225","40673507764","40703025845","40796972623","40768416410","40805050743"]
L1=[l.strip() for l in open("/tmp/fm-tgt.K6eWdK/t-portable-parallel-1.txt")]
par=L1+[l.strip() for l in open("/tmp/fm-tgt.K6eWdK/t-portable-parallel-2.txt")]
m={r:{} for r in runs}
for r in runs:
    for f in glob.glob(f"{D}/{r}/fm-test-timing-portable-parallel-*/*.json"):
        for s in json.load(open(f))["scripts"]:
            if s["exit"]==0: m[r][s["path"]]=s["duration_ms"]
tot=[sum(m[r][p] for p in par) for r in runs]
def worst(s):
    w=0
    for i,r in enumerate(runs):
        a=sum(m[r][p] for p in s); b=tot[i]-a; w=max(w,abs(a-b)/max(a,b))
    return w
fixed="tests/fm-pi-primary-types.test.sh"
order=sorted([p for p in par if p!=fixed],key=lambda p:-max(m[r][p] for r in runs))
big,small=order[:16],order[16:]
print("small-script total per run (s):",[sum(m[r][p] for p in small)//1000 for r in runs])
best=(9,None)
for bits in range(1<<len(big)):
    a=[big[i] for i in range(len(big)) if bits>>i&1]+[fixed]
    # greedy-place smalls to minimise worst spread
    for p in small:
        w1=worst(a+[p]); w2=worst(a)
        if w1<w2: a=a+[p]
    w=worst(a)
    if w<best[0]: best=(w,a)
print("target split worst lane spread across 6 hosted runs: %.1f%%"%(100*worst(L1)))
print("best found worst spread: %.1f%%"%(100*best[0]))
print("lane1:",sorted(best[1]))
for i,r in enumerate(runs):
    a=sum(m[r][p] for p in best[1]); t=sum(m[r][p] for p in L1); print(r,"best:",a//1000,(tot[i]-a)//1000,"target:",t//1000,(tot[i]-t)//1000)
