#!/usr/bin/env bash
# Live driver: runs the real bin/fm-night-check.sh, bin/fm-capacity.sh, bin/fm-install-hc.sh
# against disposable lab homes (bin/fm-lab-home.sh create). Only external boundaries
# (quota-axi, gh, herdr-core, curl) are stubbed on PATH. Prints a transcript.
set -u
WT=$1; LABROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LABROOT"' EXIT
cd "$WT"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND
NIGHT_START=1795762800   # 2026-11-26 23:00 PST
T0100=1795770000         # 2026-11-27 01:00 PST
T0635=1795790100; T0735=1795793700; T2250=$((NIGHT_START-600))
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS: $1 (=$3)"; PASS=$((PASS+1)); else echo "  FAIL: $1 expected=$3 got=$2"; FAIL=$((FAIL+1)); fi; }
newhome(){ local h="$LABROOT/$1"; bin/fm-lab-home.sh create "$h" >/dev/null || exit 9; mkdir -p "$h/proc" "$h/fakebin" "$h/data/pr-review-ledger"
  printf '1.50 1.20 1.00 1/120 1234\n' > "$h/proc/loadavg"; printf 'MemTotal: 32768000 kB\nMemAvailable: 24576000 kB\n' > "$h/proc/meminfo"
  printf '4\nreserve-flag %s/state/night.reserve night stop\n' "$h" > "$h/config/lane-capacity"; quota "$h" 80 70; ghrl "$h" 4200; echo "$h"; }
quota(){ local h=$1 f=$2 w=$3; cat > "$h/fakebin/quota-axi" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
{"generatedAt":"2026-11-27T09:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"max","account":{"accountId":"acct","email":"a@example.com","organization":"org","identityStatus":"verified"},"windows":[{"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":$((100-f)),"percentRemaining":$f},{"id":"seven_day","label":"week","kind":"weekly","percentUsed":$((100-w)),"percentRemaining":$w}],"attempts":[],"state":{"status":"fresh","stale":false,"refreshedAt":"2026-11-27T09:00:00Z","sourcesTried":[]},"quotaSemantics":{"status":"known","description":"d","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":$f,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset"}}]}}]}
JSON
EOF
chmod +x "$h/fakebin/quota-axi"; }
ghrl(){ local h=$1 r=$2; cat > "$h/fakebin/gh" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "api rate_limit" ] && { printf '{"resources":{"core":{"limit":5000,"used":%d,"remaining":%d,"reset":1795800000}}}\n' $((5000-r)) $r; exit 0; }
exit 1
EOF
chmod +x "$h/fakebin/gh"; }
hcore(){ local h=$1 pid=$2 inst=$3 up=$4; cat > "$h/fakebin/herdr-core" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "server status" ] && { printf '{"core":{"id":"core-1"},"holder":{"current":true,"instance":"$inst","pid":1},"live":3,"pid":$pid,"uptime_ms":$up,"version":"0.1.18"}\n'; exit 0; }
exit 1
EOF
chmod +x "$h/fakebin/herdr-core"; }
nc(){ local h=$1 now=$2; shift 2; PATH="$h/fakebin:$PATH" FM_HOME="$h" FM_NIGHT_NOW_EPOCH=$now FM_PROC_ROOT_OVERRIDE="$h/proc" bin/fm-night-check.sh "$@" </dev/null; }
admit(){ local h=$1 rc=0; FM_HOME="$h" FM_PROC_ROOT_OVERRIDE="$h/proc" bin/fm-capacity.sh --admit >"$h/admit.out" 2>&1 || rc=$?; echo $rc; }
j(){ printf '%s\n' "$1" | jq -r "$2"; }
show(){ printf '%s\n' "$1" | jq -c '{verdict,allow,tripped:[.tripped[]|{condition,status,verdict_effect}],latched:[.latched[].condition],reserve_flag:.reserve_flag.state}'; }

echo "== S1 healthy night: start, check --json, verdict --json (P2/P3 consumer view)"
H=$(newhome s1); nc $H $NIGHT_START start
O=$(nc $H $T0100 check --json); show "$O"
ok "verdict" "$(j "$O" .verdict)" continue; ok "two_hour_default" "$(j "$O" .allow.two_hour_default)" true
V=$(FM_HOME=$H bin/fm-night-check.sh verdict --json); ok "stored verdict schema" "$(j "$V" .schema)" fm-night-verdict.v1
ok "stored verdict == latest" "$(j "$V" .checked_epoch)" $T0100
echo "  human: $(nc $H $T0100 check | head -3 | tr '\n' ' ')"

echo "== S2 Claude floors (25% / 12%)"
H=$(newhome s2); nc $H $NIGHT_START start >/dev/null
quota $H 25 70; O=$(nc $H $T0100 check --json); ok "exactly 25% remaining -> verdict" "$(j "$O" .verdict)" continue
quota $H 80 24; O=$(nc $H $T0100 check --json); show "$O"; ok "weekly 24% -> verdict" "$(j "$O" .verdict)" stop_claude; ok "dispatch still allowed" "$(j "$O" .allow.dispatch)" true; ok "claude disallowed" "$(j "$O" .allow.claude)" false
ok "admit (non-Claude) under stop_claude" "$(admit $H)" 0
quota $H 11 70; O=$(nc $H $T0100 check --json); show "$O"; ok "5h 11% -> verdict" "$(j "$O" .verdict)" stop_dispatch; ok "dispatch" "$(j "$O" .allow.dispatch)" false
quota $H 80 70; O=$(nc $H $T0100 check --json); ok "recovered quota (level) -> verdict" "$(j "$O" .verdict)" continue

echo "== S3 GitHub API floor (1000 of 5000)"
H=$(newhome s3); nc $H $NIGHT_START start >/dev/null
ghrl $H 1000; O=$(nc $H $T0100 check --json); ok "1000 remaining -> verdict" "$(j "$O" .verdict)" continue
ghrl $H 999; O=$(nc $H $T0100 check --json); show "$O"; ok "999 remaining -> verdict" "$(j "$O" .verdict)" stop_dispatch; ok "github_api status" "$(j "$O" .conditions.github_api.status)" tripped

echo "== S4 failure streak 3 -> stop flag via reserve-flag, non-destructive, end clears"
H=$(newhome s4); nc $H $NIGHT_START start >/dev/null
sleep 300 & WORKER=$!
printf 'failed [at=%d]: a\n' $((T0100-900)) > $H/state/t1.status; printf 'failed [at=%d]: b\n' $((T0100-600)) > $H/state/t2.status
O=$(nc $H $T0100 check --json); ok "2 failures -> verdict" "$(j "$O" .verdict)" continue
printf 'failed [at=%d]: c\n' $((T0100-300)) > $H/state/t3.status
O=$(nc $H $T0100 check --json); show "$O"; ok "3 failures -> verdict" "$(j "$O" .verdict)" stop_dispatch
ok "failure_streak latched" "$(j "$O" '.latched[0].condition')" failure_streak
ok "reserve-flag file exists" "$([ -f $H/state/night.reserve ] && echo yes)" yes; echo "  flag: $(head -1 $H/state/night.reserve)"
ok "fm-capacity --admit refuses (75)" "$(admit $H)" 75; echo "  admit: $(cat $H/admit.out)"
printf 'done [at=%d]: d\n' $((T0100-60)) > $H/state/t4.status
O=$(nc $H $((T0100+60)) check --json); ok "latched survives a later success" "$(j "$O" .verdict)" stop_dispatch
ok "running worker untouched" "$(kill -0 $WORKER 2>/dev/null && echo alive)" alive; kill $WORKER; wait $WORKER 2>/dev/null
ok "stop record schema" "$(jq -r .schema $H/state/night-stop.json)" fm-night-stop.v1
nc $H $T0735 end; ok "end removes own flag" "$([ -e $H/state/night.reserve ] && echo present || echo gone)" gone
ok "admit after end" "$(admit $H)" 0; ok "stop record kept after end" "$([ -f $H/state/night-stop.json ] && echo kept)" kept
echo "  -- adversarial: externally-set flag is not overwritten or removed"
H=$(newhome s4b); nc $H $NIGHT_START start >/dev/null; printf 'captain hold\n' > $H/state/night.reserve
for i in 1 2 3; do printf 'failed [at=%d]: x\n' $((T0100-100*i)) > $H/state/f$i.status; done
O=$(nc $H $T0100 check --json); ok "flag state" "$(j "$O" .reserve_flag.state)" set_externally; nc $H $T0735 end >/dev/null
ok "captain flag content kept after end" "$(cat $H/state/night.reserve)" "captain hold"

echo "== S5 dev health: failed post-merge check in review ledger"
H=$(newhome s5); nc $H $NIGHT_START start >/dev/null
L='{"schema":"firstmate-pr-review-ledger.v1","task":"t-9","url":"https://github.com/acme/app/pull/9","current_head":"HH","generations":[{"head":"HH","created_epoch":%d,"risk":{"level":"low"},"checkpoints":[],"attestations":[],"merge_decision":{"decision":"merge"},"post_merge_verifications":[{"applicability":"browser","head":"HH","outcome":"%s","ready_for_qa":"%s","recorded_epoch":%d}]}]}\n'
printf "$L" $((T0100-1200)) failed blocked $((T0100-600)) > $H/data/pr-review-ledger/github--acme--app--9.json
O=$(nc $H $T0100 check --json); show "$O"; ok "verdict" "$(j "$O" .verdict)" stop_dispatch; ok "merge disallowed" "$(j "$O" .allow.merge)" false; ok "dev_health status" "$(j "$O" .conditions.dev_health.status)" tripped

echo "== S6 check-machine rule: 2 finished PRs waiting"
H=$(newhome s6); nc $H $NIGHT_START start >/dev/null
printf 'kind=ship\npr=https://github.com/acme/app/pull/11\n' > $H/state/w1.meta
O=$(nc $H $T0100 check --json); ok "1 waiting -> verdict" "$(j "$O" .verdict)" continue
printf 'kind=ship\npr=https://github.com/acme/app/pull/12\n' > $H/state/w2.meta
O=$(nc $H $T0100 check --json); show "$O"; ok "2 waiting -> verdict" "$(j "$O" .verdict)" stop_dispatch; ok "check_machine" "$(j "$O" .conditions.check_machine.status)" tripped

echo "== S7 validation cap: 2 high-stakes runs per night"
H=$(newhome s7); nc $H $NIGHT_START start >/dev/null
hs(){ local n=$1 c=$2 hd; hd=$(printf "%040d" 0 | tr 0 $c); printf '{"schema":"firstmate-pr-review-ledger.v1","task":"t-%s","url":"https://github.com/acme/app/pull/%s","current_head":"%s","generations":[{"head":"%s","created_epoch":%d,"risk":{"level":"high"},"checkpoints":[],"attestations":[{"kind":"no-mistakes","head":"%s","at":"2026-11-27T07:20:00Z"},{"kind":"independent-agent-review","head":"%s","at":"2026-11-27T07:25:00Z"}],"merge_decision":null,"post_merge_verifications":[]}]}\n' $n $n $hd $hd $((NIGHT_START+600)) $hd $hd > $H/data/pr-review-ledger/github--acme--app--$n.json; }
hs 21 a; O=$(nc $H $T0100 check --json); ok "1 high-stakes PR (no-mistakes+independent review) -> verdict" "$(j "$O" .verdict)" continue; ok "counted runs" "$(j "$O" .conditions.validation_cap.details.count)" 1
hs 22 b; O=$(nc $H $T0100 check --json); show "$O"; ok "2 runs -> verdict" "$(j "$O" .verdict)" stop_validation; ok "validation disallowed" "$(j "$O" .allow.validation)" false; ok "claude still allowed" "$(j "$O" .allow.claude)" true; ok "dispatch still allowed" "$(j "$O" .allow.dispatch)" true

echo "== S8 host load > 24 sustained 10 min"
H=$(newhome s8); nc $H $NIGHT_START start >/dev/null
printf '24.00 1 1 1/1 1\n' > $H/proc/loadavg; O=$(nc $H $T0100 check --json); ok "load exactly 24 -> verdict" "$(j "$O" .verdict)" continue
printf '30.00 1 1 1/1 1\n' > $H/proc/loadavg; O=$(nc $H $T0100 check --json); ok "load 30 first sample -> verdict" "$(j "$O" .verdict)" continue
O=$(nc $H $((T0100+300)) check --json); ok "load 30 at +5min" "$(j "$O" .verdict)" continue
O=$(nc $H $((T0100+600)) check --json); show "$O"; ok "load 30 at +10min -> verdict" "$(j "$O" .verdict)" stop_dispatch; ok "validation disallowed" "$(j "$O" .allow.validation)" false
echo "  -- adversarial: stale since from a check 15h earlier must not trip"
H=$(newhome s8b); printf '30.00 1 1 1/1 1\n' > $H/proc/loadavg; nc $H $((NIGHT_START-54000)) check --json >/dev/null
nc $H $NIGHT_START start >/dev/null; O=$(nc $H $((NIGHT_START+300)) check --json); ok "first night sample with stale since" "$(j "$O" .conditions.host_load.status)" ok

echo "== S9 supervision stall: wake older than 30 min"
H=$(newhome s9); nc $H $NIGHT_START start >/dev/null
printf '%d\t1\tsignal\tt1\tdone: ok\n' $((T0100-1500)) > $H/state/.wake-queue; O=$(nc $H $T0100 check --json); ok "25-min wake -> verdict" "$(j "$O" .verdict)" continue
printf '%d\t1\tsignal\tt1\tdone: ok\n' $((T0100-1900)) > $H/state/.wake-queue; O=$(nc $H $T0100 check --json); show "$O"; ok "31.6-min wake -> verdict" "$(j "$O" .verdict)" stop_dispatch
ok "stop record stall_since_epoch" "$(jq -r .stall_since_epoch $H/state/night-stop.json)" $((T0100-1900))
ok "reserve-flag set" "$([ -f $H/state/night.reserve ] && echo yes)" yes

echo "== S10 hc core restart ends night; hc-guard refuses install"
H=$(newhome s10); printf 'hc\n' > $H/config/backend; hcore $H 3995 inst-a 86400000
nc $H $NIGHT_START start >/dev/null; hcore $H 3995 inst-a 93600000
O=$(nc $H $T0100 check --json); ok "steady core" "$(j "$O" .verdict)" continue
hcore $H 8812 inst-b 12000; O=$(nc $H $T0100 check --json); show "$O"; ok "restarted core -> verdict" "$(j "$O" .verdict)" end_night
ok "stop record core_restarted" "$(jq -r .core_restarted $H/state/night-stop.json)" true
rc=0; G=$(FM_HOME=$H bin/fm-night-check.sh hc-guard 2>&1) || rc=$?; ok "hc-guard exit during night" $rc 1; echo "  $G"
printf '#!/bin/sh\necho curl-called >> %s/curl.log\nexit 1\n' $H > $H/fakebin/curl; chmod +x $H/fakebin/curl
rc=0; I=$(PATH="$H/fakebin:$PATH" FM_HOME=$H bin/fm-install-hc.sh $H/hcdest 2>&1) || rc=$?; ok "fm-install-hc.sh exit during night" $rc 1; echo "  $I"
ok "no download attempted" "$([ -e $H/curl.log ] && echo called || echo none)" none
nc $H $T0735 end >/dev/null; rc=0; FM_HOME=$H bin/fm-night-check.sh hc-guard || rc=$?; ok "hc-guard after end" $rc 0
echo "  -- adversarial: corrupt night-active marker fails closed"
H=$(newhome s10b); echo 'not json' > $H/state/night-active.json; rc=0; FM_HOME=$H bin/fm-night-check.sh hc-guard 2>/dev/null || rc=$?; ok "hc-guard with corrupt marker" $rc 1

echo "== S11 unreadable sources fail closed"
H=$(newhome s11); nc $H $NIGHT_START start >/dev/null
printf '#!/bin/sh\nexit 3\n' > $H/fakebin/quota-axi; O=$(nc $H $T0100 check --json); show "$O"; ok "quota-axi failing -> claude_quota" "$(j "$O" .conditions.claude_quota.status)" unknown; ok "verdict" "$(j "$O" .verdict)" stop_dispatch
quota $H 80 70; printf '#!/bin/sh\nexit 1\n' > $H/fakebin/gh; O=$(nc $H $T0100 check --json); ok "gh failing -> github_api" "$(j "$O" .conditions.github_api.status)" unknown; ok "verdict" "$(j "$O" .verdict)" stop_dispatch
ghrl $H 4200; echo garbage > $H/proc/loadavg; O=$(nc $H $T0100 check --json); ok "loadavg garbage -> host_load" "$(j "$O" .conditions.host_load.status)" unknown
printf '1 1 1 1/1 1\n' > $H/proc/loadavg; echo '{' > $H/data/pr-review-ledger/github--acme--app--5.json; O=$(nc $H $T0100 check --json); ok "corrupt ledger -> dev_health" "$(j "$O" .conditions.dev_health.status)" unknown; ok "verdict" "$(j "$O" .verdict)" stop_dispatch

echo "== S12 night window and cut-off; checks outside a night set nothing"
H=$(newhome s12); nc $H $NIGHT_START start >/dev/null
O=$(nc $H $T0635 check --json); ok "06:35 past last-dispatch -> verdict" "$(j "$O" .verdict)" stop_dispatch; ok "flag not set by level cut-off" "$([ -e $H/state/night.reserve ] && echo set || echo none)" none
O=$(nc $H $T0735 check --json); ok "07:35 past window-end -> verdict" "$(j "$O" .verdict)" end_night
H=$(newhome s12b); O=$(nc $H $T2250 check --json); ok "22:50 preflight, no night: night_active" "$(j "$O" .night_active)" false; ok "no reserve-flag outside night" "$([ -e $H/state/night.reserve ] && echo set || echo none)" none; ok "admit outside night" "$(admit $H)" 0

echo "TOTAL PASS=$PASS FAIL=$FAIL"
