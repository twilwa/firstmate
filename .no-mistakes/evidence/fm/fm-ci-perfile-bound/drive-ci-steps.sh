#!/usr/bin/env bash
# Drives the exact portable CI test-step commands from the parsed
# .github/workflows/ci.yml against a disposable copy of the change with
# fixture test bodies, the way the GitHub-hosted job runs them.
set -u
SRC=${1:?worktree}
EV=${2:?evidence dir}
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-ci-perfile.XXXXXX")
trap 'rm -rf "$FIX"' EXIT
REPO="$FIX/repo"
mkdir -p "$REPO"
git -C "$SRC" archive HEAD | tar -x -C "$REPO"
git -C "$REPO" init -q && git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm fixture

# Extract each portable job's test step 'run' and env from the parsed workflow.
python3 -I - "$REPO/.github/workflows/ci.yml" "$FIX" <<'PY'
import sys, yaml, json
wf = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]
for job in ("tests-portable-parallel-1", "tests-portable-parallel-2", "tests-portable-serial"):
    j = wf["jobs"][job]
    step = [s for s in j["steps"] if "fm-test-run.sh" in s.get("run", "") and "--lane" in s.get("run", "")][0]
    open(f"{out}/{job}.step.sh", "w").write(step["run"])
    print(f"{job}: timeout-minutes={j['timeout-minutes']} step={step['name']!r}")
    print("  run: " + step["run"].replace("\n", "\n       "))
PY

stub_all() {
  ( cd "$REPO" && bin/fm-test-run.sh --list --all ) | while IFS= read -r s; do
    printf '#!/usr/bin/env bash\necho "ok - stub %s"\nexit 0\n' "$s" >"$REPO/$s"
  done
}

run_step() { # <job> <runner_temp> <timeout-substitute or ""> [env...]
  local job=$1 rt=$2 sub=$3; shift 3
  local cmd; cmd=$(cat "$FIX/$job.step.sh")
  [ -z "$sub" ] || cmd=${cmd//--per-script-timeout-secs 1500/--per-script-timeout-secs $sub}
  ( cd "$REPO" && env RUNNER_TEMP="$rt" "$@" setsid bash -c "$cmd" )
}

echo
echo "=== Scenario 1: hung file in portable-parallel-2 fails by name with exit 124 (bound scaled 1500s -> 4s) ==="
stub_all
HANG=$( cd "$REPO" && bin/fm-test-run.sh --list-scheduled --lane portable-parallel-2 | sed -n 5p )
cat >"$REPO/$HANG" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture about to hang"
sleep 600
SH
RT="$FIX/rt1"; mkdir -p "$RT"
start=$(date +%s)
run_step tests-portable-parallel-2 "$RT" 4 >"$FIX/s1.out" 2>&1; rc=$?
echo "step exit=$rc elapsed=$(( $(date +%s) - start ))s hung=$HANG"
grep -E "exceeded the per-script bound|FM_TEST_END .*exit=124|FM_TEST_SUMMARY" "$FIX/s1.out"
python3 -I - "$RT/fm-test/fm-test-timing-portable-parallel-2.json" "$HANG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rec = [s for s in d["scripts"] if s["path"] == sys.argv[2]]
print("json summary:", d["summary"])
print("json hung record:", {k: rec[0][k] for k in ("path", "exit", "duration_ms")})
assert rec and rec[0]["exit"] == 124
print("SCENARIO1 PASS" if d["summary"]["failed"] == 1 else "SCENARIO1 FAIL")
PY

echo
echo "=== Scenario 2: hung file in a portable serial shard (matrix shard 3 of 11, --fail-on-gate-skip kept) fails by name (bound scaled to 4s) ==="
stub_all
HANG=$( cd "$REPO" && bin/fm-test-run.sh --list-scheduled --lane portable-serial-3of11 | sed -n 2p )
printf '#!/usr/bin/env bash\necho "ok - about to hang"\nsleep 600\n' >"$REPO/$HANG"
RT="$FIX/rt2"; mkdir -p "$RT"
start=$(date +%s)
run_step tests-portable-serial "$RT" 4 FM_SERIAL_LANE=portable-serial-3of11 FM_SERIAL_SHARD=3 >"$FIX/s2.out" 2>&1; rc=$?
echo "step exit=$rc elapsed=$(( $(date +%s) - start ))s hung=$HANG"
grep -E "exceeded the per-script bound|FM_TEST_END .*exit=124|FM_TEST_SUMMARY" "$FIX/s2.out"
python3 -I - "$RT/fm-test/fm-test-timing-portable-serial-3.json" "$HANG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = [(s["path"], s["exit"]) for s in d["scripts"] if s["exit"] != 0]
print("json summary:", d["summary"], "non-zero:", bad)
print("SCENARIO2 PASS" if bad == [(sys.argv[2], 124)] else "SCENARIO2 FAIL")
PY

echo
echo "=== Scenario 3: unmodified 1500s step command does not kill a slow-but-healthy file (portable-parallel-1) ==="
stub_all
SLOW=$( cd "$REPO" && bin/fm-test-run.sh --list-scheduled --lane portable-parallel-1 | sed -n 1p )
printf '#!/usr/bin/env bash\nsleep 8\necho "ok - slow but healthy"\n' >"$REPO/$SLOW"
RT="$FIX/rt3"; mkdir -p "$RT"
run_step tests-portable-parallel-1 "$RT" "" >"$FIX/s3.out" 2>&1; rc=$?
echo "step exit=$rc"
grep -E "FM_TEST_SUMMARY" "$FIX/s3.out"
python3 -I - "$RT/fm-test/fm-test-timing-portable-parallel-1.json" "$SLOW" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rec = [s for s in d["scripts"] if s["path"] == sys.argv[2]][0]
print("json slow record:", {k: rec[k] for k in ("path", "exit", "duration_ms")}, "summary:", d["summary"])
print("SCENARIO3 PASS" if rec["exit"] == 0 and rec["duration_ms"] >= 8000 and d["summary"]["failed"] == 0 else "SCENARIO3 FAIL")
PY
[ "$rc" -eq 0 ] || echo "SCENARIO3 FAIL (step rc=$rc)"

echo
echo "=== Scenario 4: job cap kills a lane mid-hang under the real 1500s bound; completed-file timing evidence survives ==="
stub_all
HANG=$( cd "$REPO" && bin/fm-test-run.sh --list-scheduled --lane portable-serial-5of11 | tail -n 1 )
printf '#!/usr/bin/env bash\necho "ok - about to hang"\nsleep 600\n' >"$REPO/$HANG"
RT="$FIX/rt4"; mkdir -p "$RT"
( cd "$REPO" && RUNNER_TEMP="$RT" FM_SERIAL_LANE=portable-serial-5of11 FM_SERIAL_SHARD=5 \
    setsid bash -c "echo \$\$ >'$FIX/sid'; $(cat "$FIX/tests-portable-serial.step.sh")" >"$FIX/s4.out" 2>&1 ) &
pid=$!
sleep 15
# Simulate the GitHub job cap: SIGKILL the whole step session, then sweep strays.
pkill -KILL -s "$(cat "$FIX/sid")" 2>/dev/null
pkill -KILL -f "$REPO" 2>/dev/null
wait "$pid" 2>/dev/null
grep -E "FM_TEST_START .*$(basename "$HANG")" "$FIX/s4.out" | head -1
N=$( cd "$REPO" && bin/fm-test-run.sh --list --lane portable-serial-5of11 | wc -l )
echo "lane members=$N; killed after 15s while $HANG hung"
python3 -I - "$RT/fm-test/fm-test-timing-portable-serial-5.json" "$HANG" "$N" <<'PY'
import json, sys, os
p = sys.argv[1]
d = json.load(open(p))
paths = [s["path"] for s in d["scripts"]]
print("json after kill: total =", d["summary"]["total"], "of", sys.argv[3], "; hung file recorded:", sys.argv[2] in paths)
print("SCENARIO4 PASS" if d["summary"]["total"] == int(sys.argv[3]) - 1 and sys.argv[2] not in paths and all(s["exit"] == 0 for s in d["scripts"]) else "SCENARIO4 FAIL")
PY
ls "$RT/fm-test"

echo
echo "=== Scenario 5: coverage guard refuses an unhinted parallel member by name and an over-ceiling lane ==="
cp "$SRC/bin/fm-test-run.sh" "$REPO/bin/fm-test-run.sh"
MEMBER=$( cd "$REPO" && bin/fm-test-run.sh --list-scheduled --lane portable-parallel-1 | sed -n 3p )
python3 -I - "$REPO/bin/fm-test-run.sh" "$MEMBER" drop <<'PY'
import re, sys
p, m = sys.argv[1], sys.argv[2]
t = open(p).read()
t = re.sub(r"(?m)^" + re.escape(m) + r" \d+\n", "", t, count=1)
open(p, "w").write(t)
PY
( cd "$REPO" && bin/fm-test-run.sh --check-coverage ) >"$FIX/s5a.out" 2>&1; rc=$?
echo "unhinted $MEMBER: exit=$rc"; cat "$FIX/s5a.out"
{ [ "$rc" -ne 0 ] && grep -q "$MEMBER" "$FIX/s5a.out" && ! grep -q "FM_TEST_COVERAGE ok" "$FIX/s5a.out"; } && echo "SCENARIO5a PASS" || echo "SCENARIO5a FAIL"
cp "$SRC/bin/fm-test-run.sh" "$REPO/bin/fm-test-run.sh"
python3 -I - "$REPO/bin/fm-test-run.sh" "$MEMBER" <<'PY'
import re, sys
p, m = sys.argv[1], sys.argv[2]
t = open(p).read()
t, n = re.subn(r"(?m)^(" + re.escape(m) + r") \d+$", r"\1 1300000", t, count=1)
assert n == 1
open(p, "w").write(t)
PY
( cd "$REPO" && bin/fm-test-run.sh --check-coverage ) >"$FIX/s5b.out" 2>&1; rc=$?
echo "inflated $MEMBER hint to 1300000ms: exit=$rc"; cat "$FIX/s5b.out"
{ [ "$rc" -ne 0 ] && grep -q "above the 1200000ms target" "$FIX/s5b.out" && ! grep -q "FM_TEST_COVERAGE ok" "$FIX/s5b.out"; } && echo "SCENARIO5b PASS" || echo "SCENARIO5b FAIL"

echo
echo "=== Scenario 6: unchanged coverage guard on the change accepts and the parsed workflow caps satisfy the rule ==="
( cd "$SRC" && bin/fm-test-run.sh --check-coverage ) | tee "$FIX/s6.out"
python3 -I - "$SRC/.github/workflows/ci.yml" "$FIX/s6.out" <<'PY'
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
cov = dict(kv.split("=") for kv in open(sys.argv[2]).read().split()[2:])
ok = True
for job in ("tests-portable-parallel-1", "tests-portable-parallel-2", "tests-portable-serial"):
    j = wf["jobs"][job]
    run = [s["run"] for s in j["steps"] if "--lane" in s.get("run", "")][0]
    bound = int(re.search(r"--per-script-timeout-secs (\d+)", run).group(1))
    budget = int(cov["serial_budget_ms" if "serial" in job else "parallel_budget_ms"]) // 1000
    cap = j["timeout-minutes"] * 60
    need = 60 + budget + bound
    print(f"{job}: cap={cap}s bound={bound}s ceiling={budget}s setup=60s need<{cap}: {need} -> {'ok' if cap > need else 'VIOLATED'}")
    ok &= cap > need and bound == 1500
others = {k: v.get("timeout-minutes") for k, v in wf["jobs"].items() if not k.startswith("tests-portable")}
print("other job caps:", others)
print("SCENARIO6 PASS" if ok and cov["parallel_unhinted"] == "0" else "SCENARIO6 FAIL")
PY
