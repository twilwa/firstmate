#!/usr/bin/env python3
"""Drive the portable CI jobs' real runner commands from .github/workflows/ci.yml.

For each portable job: report its cap and per-file bound, check the cap rule
against the live coverage guard's budgets, then execute the job's exact `run:`
block with bin/fm-test-run.sh in a fixture suite where the lane's first file
hangs. Time is compressed (1500 -> BOUND) only for the hung case; a healthy
case runs the unmodified 1500s command.
"""
import json, os, re, shlex, shutil, subprocess, sys, tempfile, time

root, coverage_line = sys.argv[1], sys.argv[2]
BOUND = 2
jobs = __import__("yaml").safe_load(open(f"{root}/.github/workflows/ci.yml"))["jobs"]
fields = dict(p.split("=", 1) for p in coverage_line.split()[2:])
budgets = {"tests-portable-parallel-1": int(fields["parallel_budget_ms"]),
           "tests-portable-parallel-2": int(fields["parallel_budget_ms"]),
           "tests-portable-serial": int(fields["serial_budget_ms"])}
ok = True
inventory = subprocess.run([f"{root}/bin/fm-test-run.sh", "--list", "--all"],
                           capture_output=True, text=True, check=True).stdout.split()
shard_count = len(jobs["tests-portable-serial"]["strategy"]["matrix"]["shard"])

with tempfile.TemporaryDirectory(prefix="fm-ci-live.") as repo:
    for d in ("bin", "tests", "artifacts"):
        os.makedirs(f"{repo}/{d}")
    for f in ("fm-test-run.sh", "fm-timeout-lib.sh"):
        shutil.copy2(f"{root}/bin/{f}", f"{repo}/bin/{f}")
    shutil.copy2(f"{root}/tests/git-config-helpers.sh", f"{repo}/tests/")
    def stub(path, body="exit 0"):
        with open(f"{repo}/{path}", "w") as fh:
            fh.write(f"#!/usr/bin/env bash\n{body}\n")
    for f in inventory:
        stub(f)

    for job_id, budget_ms in budgets.items():
        job = jobs[job_id]
        step = next(s for s in job["steps"] if "bin/fm-test-run.sh --lane" in str(s.get("run", "")))
        command = step["run"]
        words = shlex.split(command.replace("\\\n", ""))
        i = words.index("--per-script-timeout-secs")
        bound = int(words[i + 1])
        cap = job["timeout-minutes"] * 60
        needed = 60 + -(-budget_ms // 1000) + bound
        rule = cap > needed
        ok &= rule and bound == 1500
        print(f"== {job_id}: timeout-minutes={job['timeout-minutes']} per-file bound={bound}s "
              f"cap {cap}s > 60s + {budget_ms}ms + {bound}s = {needed}s : {'OK' if rule else 'VIOLATED'}")

        env = dict(os.environ, RUNNER_TEMP=f"{repo}/artifacts", FM_SERIAL_SHARD="1",
                   FM_SERIAL_LANE=f"portable-serial-1of{shard_count}")
        lane = env["FM_SERIAL_LANE"] if job_id == "tests-portable-serial" else job_id.removeprefix("tests-")
        selected = subprocess.run([f"{repo}/bin/fm-test-run.sh", "--list", "--lane", lane],
                                  capture_output=True, text=True, check=True).stdout.split()
        hung = selected[0]

        # Healthy lane, unmodified production command (1500s bound).
        t = time.time()
        r = subprocess.run(["bash", "-eu", "-c", command], cwd=repo, env=env, capture_output=True, text=True)
        summary = [l for l in r.stdout.splitlines() if l.startswith("FM_TEST_SUMMARY ")]
        print(f"   healthy lane {lane} ({len(selected)} files), real 1500s bound: exit={r.returncode} "
              f"in {time.time()-t:.1f}s; {summary[0] if summary else 'NO SUMMARY'}")
        ok &= r.returncode == 0
        for a in os.listdir(f"{repo}/artifacts/fm-test"):
            os.remove(f"{repo}/artifacts/fm-test/{a}")

        # Hung first file, bound compressed to BOUND seconds.
        stub(hung, "echo fixture-before-hang\nsleep 60")
        fast = re.sub(r"(--per-script-timeout-secs\s+)1500\b", rf"\g<1>{BOUND}", command)
        t = time.time()
        r = subprocess.run(["bash", "-eu", "-c", fast], cwd=repo, env=env, capture_output=True, text=True)
        elapsed = time.time() - t
        out = r.stdout + r.stderr
        named = [l for l in out.splitlines() if "exceeded the per-script bound" in l]
        end = [l for l in out.splitlines() if l.startswith("FM_TEST_END") and hung in l]
        summary = [l for l in out.splitlines() if l.startswith("FM_TEST_SUMMARY ")]
        arts = os.listdir(f"{repo}/artifacts/fm-test")
        rec = None
        if len(arts) == 1:
            data = json.load(open(f"{repo}/artifacts/fm-test/{arts[0]}"))
            rec = next((s for s in data["scripts"] if s["path"] == hung), None)
        print(f"   hung {hung}, bound {BOUND}s: exit={r.returncode} in {elapsed:.1f}s (sleep was 60s)")
        print(f"     named failure: {named[0] if named else 'MISSING'}")
        print(f"     output kept:   {'fixture-before-hang' in out}")
        print(f"     marker:        {end[0] if end else 'MISSING'}")
        print(f"     summary:       {summary[0] if summary else 'MISSING'}")
        print(f"     artifact:      {arts} record={json.dumps(rec)}")
        ok &= (r.returncode != 0 and bool(named) and "fixture-before-hang" in out and elapsed < 30
               and rec is not None and rec["exit"] == 124)
        for a in arts:
            os.remove(f"{repo}/artifacts/fm-test/{a}")
        stub(hung)

print("RESULT", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
