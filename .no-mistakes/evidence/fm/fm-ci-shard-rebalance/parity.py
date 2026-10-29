# Parse ci.yml as YAML, expand each job's matrix (and strategy.job-total) into
# the concrete --lane values it runs, and compare with the runner's --list-lanes.
import sys, yaml, re, subprocess, itertools
wf = yaml.safe_load(open(sys.argv[1]))
lanes = set(subprocess.check_output(["bin/fm-test-run.sh", "--list-lanes"], text=True).split())
used = []
for name, job in wf["jobs"].items():
    matrix = (job.get("strategy") or {}).get("matrix") or {}
    keys = [k for k, v in matrix.items() if isinstance(v, list)]
    combos = [dict(zip(keys, c)) for c in itertools.product(*[matrix[k] for k in keys])] or [{}]
    total = len(combos)
    for combo in combos:
        def ex(s):
            s = re.sub(r"\$\{\{\s*strategy\.job-total\s*\}\}", str(total), str(s))
            return re.sub(r"\$\{\{\s*matrix\.(\w+)\s*\}\}", lambda m: str(combo[m.group(1)]), s)
        for step in job.get("steps", []):
            env = {k: ex(v) for k, v in (step.get("env") or {}).items()}
            run = ex(step.get("run") or "")
            for m in re.finditer(r"--lane\s+(\S+)", run):
                lane = m.group(1).strip('"')
                lane = re.sub(r"^\$\{?(\w+)\}?$", lambda mm: env.get(mm.group(1), mm.group(0)), lane)
                used.append((name, lane))
for j, l in used: print(f"{j}: --lane {l}")
u = {l for _, l in used}
want = {l for l in lanes if l not in ("portable-serial", "real-herdr-gated")}
print("serial matrix jobs:", sum(1 for j, l in used if l.startswith("portable-serial-")), "parallel jobs:", sum(1 for j, l in used if l.startswith("portable-parallel-")))
print("runner shard lanes not run by workflow:", sorted(want - u))
print("workflow lanes unknown to runner:", sorted(u - lanes))
ok = want <= u and u <= lanes and len(used) == len(u)
print("PARITY", "OK" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
