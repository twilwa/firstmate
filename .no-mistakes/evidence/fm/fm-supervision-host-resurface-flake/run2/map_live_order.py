"""Map live 'ok - <msg>' lines to the host case that produced them and print the derived case order.
usage: map_live_order.py <test-source> <output.log> <mapping-out>"""
import re, sys
src, log, mapout = sys.argv[1:4]
lines = open(src).read().split('\n')
funcs = {}; cur = None
for l in lines:
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) \{(.*)$', l)
    if m:
        if m.group(2).rstrip().endswith('}'): funcs[m.group(1)] = [m.group(2)]; cur = None
        else: cur = m.group(1); funcs[cur] = []
        continue
    if l == '}': cur = None; continue
    if cur: funcs[cur].append(l)
def pat(s):
    out = ''; i = 0
    while i < len(s):
        m = re.match(r'\$\([^)]*\)|\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9]', s[i:])
        if m: out += '.*'; i += len(m.group(0))
        else: out += re.escape(s[i]); i += 1
    return re.compile('^' + out + '$')
passes = []
for f, body in funcs.items():
    for l in body:
        for m in re.finditer(r'\bpass "((?:[^"\\]|\\.)*)"', l):
            passes.append((pat(m.group(1)), f))
callers = {f: [g for g, b in funcs.items() if g != f and any(re.search(r'(^|[\s;(&|])' + re.escape(f) + r'(\s|$|;)', x) for x in b)] for f in funcs}
# host case list: host_cases=( ... ) in HEAD, bare test_ lines at top level in base
m = re.search(r'host_cases=\(\n(.*?)\n\)', '\n'.join(lines), re.S)
cases = m.group(1).split() if m else [l for l in lines if re.match(r'^test_[a-z0-9_]+$', l)]
def to_case(f, seen=()):
    if f in cases: return {f}
    r = set()
    for g in callers.get(f, []):
        if g not in seen: r |= to_case(g, seen + (f,))
    return r
order = []; unmapped = 0; prev = (None, None); outside = 0
with open(mapout, 'w') as mo:
    for l in open(log):
        if not l.startswith('ok - '): continue
        msg = l[5:].rstrip('\n')
        fs = sorted({f for p, f in passes if p.match(msg)})
        cs = set().union(*[to_case(f) for f in fs]) if fs else set()
        # prefer the case that keeps order monotonic
        pick = None
        if not cs and fs and all(f not in cases and not callers.get(f) for f in fs):
            outside += 1; mo.write(f"{msg} => (top-level, outside host_cases) (via {','.join(fs)})\n"); continue
        if len(cs) == 1: pick = next(iter(cs))
        elif cs:
            last = cases.index(order[-1]) if order else -1
            cand = sorted((cases.index(c), c) for c in cs if cases.index(c) >= last)
            # a shared parameterized assert: the next call of the same function belongs to the next case
            if len(cand) > 1 and prev == (cand[0][1], tuple(fs)): cand = cand[1:]
            pick = cand[0][1] if cand else None
        if not pick: unmapped += 1
        prev = (pick, tuple(fs))
        mo.write(f"{msg} => {pick} (via {','.join(fs) or '-'})\n")
        if pick and (not order or order[-1] != pick): order.append(pick)
print('\n'.join(order))
sys.stderr.write(f"unmapped={unmapped} top_level_outside_cases={outside} cases_in_source={len(cases)} derived={len(order)}\n")
