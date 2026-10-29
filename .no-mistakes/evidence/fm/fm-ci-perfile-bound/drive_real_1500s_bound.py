#!/usr/bin/env python3
"""Run each portable job's exact, unmodified `run:` block (real 1500s per-file
bound) against a fixture suite whose first lane file hangs for 2400s, and show
the runner terminates it by name at ~1500s, well inside the 50-minute job cap."""
import json, os, shlex, shutil, subprocess, sys, tempfile, time, yaml
from concurrent.futures import ThreadPoolExecutor

root = sys.argv[1]
jobs = yaml.safe_load(open(f"{root}/.github/workflows/ci.yml"))["jobs"]
inventory = subprocess.run([f"{root}/bin/fm-test-run.sh", "--list", "--all"],
                           capture_output=True, text=True, check=True).stdout.split()
shards = len(jobs["tests-portable-serial"]["strategy"]["matrix"]["shard"])

def drive(job_id):
    repo = tempfile.mkdtemp(prefix=f"fm-ci-real1500-{job_id}.")
    try:
        for d in ("bin", "tests", "artifacts"):
            os.makedirs(f"{repo}/{d}")
        for f in ("fm-test-run.sh", "fm-timeout-lib.sh"):
            shutil.copy2(f"{root}/bin/{f}", f"{repo}/bin/{f}")
        shutil.copy2(f"{root}/tests/git-config-helpers.sh", f"{repo}/tests/")
        for f in inventory:
            open(f"{repo}/{f}", "w").write("#!/usr/bin/env bash\nexit 0\n")
        job = jobs[job_id]
        command = next(s for s in job["steps"] if "bin/fm-test-run.sh --lane" in str(s.get("run", "")))["run"]
        env = dict(os.environ, RUNNER_TEMP=f"{repo}/artifacts", FM_SERIAL_SHARD="1",
                   FM_SERIAL_LANE=f"portable-serial-1of{shards}")
        lane = env["FM_SERIAL_LANE"] if job_id == "tests-portable-serial" else job_id.removeprefix("tests-")
        hung = subprocess.run([f"{repo}/bin/fm-test-run.sh", "--list", "--lane", lane],
                              capture_output=True, text=True, check=True).stdout.split()[0]
        open(f"{repo}/{hung}", "w").write("#!/usr/bin/env bash\necho fixture-before-hang\nsleep 2400\n")
        t = time.time()
        r = subprocess.run(["bash", "-eu", "-c", command], cwd=repo, env=env, capture_output=True, text=True)
        el = time.time() - t
        out = r.stdout + r.stderr
        named = [l for l in out.splitlines() if "exceeded the per-script bound" in l]
        end = [l for l in out.splitlines() if l.startswith("FM_TEST_END") and hung in l]
        arts = os.listdir(f"{repo}/artifacts/fm-test")
        rec = None
        if len(arts) == 1:
            rec = next((s for s in json.load(open(f"{repo}/artifacts/fm-test/{arts[0]}"))["scripts"] if s["path"] == hung), None)
        cap = job["timeout-minutes"] * 60
        ok = (r.returncode != 0 and bool(named) and rec and rec["exit"] == 124
              and 1495 <= el < cap and "fixture-before-hang" in out)
        return ok, "\n".join([
            f"== {job_id} ({lane}), exact ci.yml command, cap {cap}s, hung file {hung} sleeping 2400s",
            f"   exit={r.returncode} elapsed={el:.1f}s (under cap: {el < cap})",
            f"   named failure: {named[0] if named else 'MISSING'}",
            f"   output kept:   {'fixture-before-hang' in out}",
            f"   marker:        {end[0] if end else 'MISSING'}",
            f"   artifact:      {arts} record={json.dumps(rec)}",
            f"   {'PASS' if ok else 'FAIL'}"])
    finally:
        shutil.rmtree(repo, ignore_errors=True)

ids = ["tests-portable-parallel-1", "tests-portable-parallel-2", "tests-portable-serial"]
with ThreadPoolExecutor(3) as ex:
    results = list(ex.map(drive, ids))
for _, text in results:
    print(text, flush=True)
allok = all(ok for ok, _ in results)
print("RESULT", "PASS" if allok else "FAIL")
sys.exit(0 if allok else 1)
