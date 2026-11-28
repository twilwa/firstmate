#!/usr/bin/env bash
# Live driver: real bin/fm-night-check.sh + bin/fm-pr-review.sh against a disposable lab FM_HOME,
# real wall clock and real /proc/loadavg; only external accounts (quota-axi, gh) are PATH stubs.
set -u
WT={run-worktree}
CHECK="$WT/bin/fm-night-check.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/fakebin"
printf 'timezone Europe/London\n' > "$LAB/config/night-check"
printf '8\nreserve-flag %s/state/night.reserve night stop\n' "$LAB" > "$LAB/config/lane-capacity"
: > "$LAB/config/status-archive"
[ "${KEEP_SUPERVISION_HOST:-0}" = 1 ] || : > "$LAB/config/supervision-host-off"
H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

quota() {  # five week [refreshed-epoch]
  local ref=${3:-}
  cat > "$LAB/fakebin/quota-axi" <<EOF
#!/usr/bin/env bash
ep=${ref:-\$(date +%s)}
ref=\$(date -u -d "@\$ep" +%Y-%m-%dT%H:%M:%SZ)
jq -cn --arg ref "\$ref" --argjson f $1 --argjson w $2 '{generatedAt:\$ref,schemaVersion:5,providers:[{provider:"claude",label:"Claude",source:"oauth",plan:"max",account:{accountId:"acct",email:"a@example.com",organization:"org",identityStatus:"verified"},windows:[{id:"five_hour",label:"5h",kind:"five_hour",percentUsed:(100-\$f),percentRemaining:\$f},{id:"seven_day",label:"week",kind:"weekly",percentUsed:(100-\$w),percentRemaining:\$w}],attempts:[],state:{status:"fresh",stale:false,refreshedAt:\$ref,sourcesTried:[]},quotaSemantics:{status:"known",description:"d",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:\$f,boundedBy:["five_hour","seven_day"],limitingWindowIds:["five_hour"],runway:{status:"through_reset"}}]}}]}'
EOF
  chmod +x "$LAB/fakebin/quota-axi"
}
gh_stub() {  # remaining
  cat > "$LAB/fakebin/gh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = api ] && [ "\${2:-}" = rate_limit ]; then
  printf '{"resources":{"core":{"limit":5000,"used":%d,"remaining":%d,"reset":%d}}}\n' \$((5000-$1)) $1 \$((\$(date +%s)+3000)); exit 0; fi
if [ "\${1:-}" = pr ] && [ "\${2:-}" = view ]; then printf '{"state":"MERGED","baseRefName":"dev"}\n'; exit 0; fi
exit 1
EOF
  chmod +x "$LAB/fakebin/gh"
}
nc() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_NIGHT_NOW_EPOCH -u FM_PROC_ROOT_OVERRIDE \
      -u FM_BACKEND -u FM_HC_BIN -u FM_HC_SOCKET -u HC_SOCKET -u HC_SESSION -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE \
      PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" "$CHECK" "$@" </dev/null
}
summ() { jq -c '{verdict, allow, tripped: [.tripped[]? | (if type=="object" then {condition,status,reason} else . end)]}' ; }
cond() { jq -c --arg c "$1" '.conditions[$c] | {status, verdict_effect, reason}' ; }
ledger() { mkdir -p "$LAB/data/pr-review-ledger"; printf '%s\n' "$2" > "$LAB/data/pr-review-ledger/github--twilwa--bbchat--$1.json"; }
step() { printf '\n=== %s ===\n' "$*"; }

quota 80 70; gh_stub 4200
NOW=$(date +%s)
echo "lab home: $LAB  (real clock now=$NOW, $(TZ=Europe/London date '+%H:%M %Z' -d @$NOW) Europe/London)"

step "S1 before start: hc-guard allows hc installs"; nc hc-guard; echo "hc-guard rc=$?"
step "S1 start a night"; nc start; echo "start rc=$?"; jq -c '{schema,started_epoch}' "$LAB/state/night-active.json"
step "S1 healthy check --json"; out=$(nc check --json); echo "rc=$?"; printf '%s\n' "$out" | summ
printf '%s\n' "$out" | jq -c '.conditions | to_entries | map({(.key): .value.status}) | add'
step "S1 stored verdict for P2/P3 consumers"; nc verdict --json | jq -c '{verdict, two_hour: .allow.two_hour_default}'
step "S1 hc-guard during the active night"; nc hc-guard; echo "hc-guard rc=$?"

step "S2 pre-night (7d old) force-torn-down archive with no terminal line"
mkdir -p "$LAB/data/old1"; printf 'You are a crewmate: an autonomous worker agent managed by firstmate.\n\nDelivery contract: mode=no-mistakes\n' > "$LAB/data/old1/brief.md"
printf 'working [at=%d]: building\nblocked [at=%d]: waiting on owner\n' $((NOW-604800)) $((NOW-600000)) > "$LAB/data/old1/status.log"
out=$(nc check --json); printf '%s\n' "$out" | cond failure_streak; printf '%s\n' "$out" | summ
step "S2 adversarial: same non-terminal archive dated inside tonight"
printf 'working [at=%d]: building\nblocked [at=%d]: waiting on owner\n' $((NOW+1-1)) $((NOW)) > "$LAB/data/old1/status.log"
out=$(nc check --json); printf '%s\n' "$out" | cond failure_streak; printf '%s\n' "$out" | summ
rm -rf "$LAB/data/old1"
out=$(nc check --json); echo "after removing night archive:"; printf '%s\n' "$out" | summ

step "S3 Claude quota 20%/70% (below 25 floor)"; quota 20 70; nc check --json | summ
step "S3 Claude quota 10%/70% (below 12 floor)"; quota 10 70; nc check --json | summ
step "S3 adversarial: 20% reading aged 1200s still labelled fresh"; quota 20 70 $((NOW-1200)); out=$(nc check --json); printf '%s\n' "$out" | cond claude_quota; printf '%s\n' "$out" | summ
step "S3 recovery 80/70"; quota 80 70; nc check --json | summ

step "S4 dev_health: red judged target whose newest not-applicable is 3 days old"
ledger 1530 "$(printf '{"schema":"firstmate-pr-review-ledger.v1","task":"t-1530","url":"https://github.com/twilwa/bbchat/pull/1530","current_head":"%s","generations":[{"head":"%s","created_epoch":%d,"risk":{"level":"low","reason":"docs"},"checkpoints":[],"review_items":[],"attestations":[],"final_disposition":null,"merge_decision":null,"post_merge_verifications":[{"applicability":"not-applicable","head":"%s","recorded_epoch":%d,"base_ref":"dev","reason":"docs only"}]}]}' $H $H $((NOW-259800)) $H $((NOW-259200)))"
NS=$(jq -r .started_epoch "$LAB/state/night-active.json")
ledger 1531 "$(printf '{"schema":"firstmate-pr-review-ledger.v1","task":"t-1531","url":"https://github.com/twilwa/bbchat/pull/1531","current_head":"%s","generations":[{"head":"%s","created_epoch":%d,"risk":{"level":"low","reason":"small"},"checkpoints":[],"review_items":[],"attestations":[],"final_disposition":null,"merge_decision":{"decision":"merge","verified_head":"%s","verified_epoch":%d},"post_merge_verifications":[{"applicability":"browser","head":"%s","outcome":"failed","ready_for_qa":"blocked","recorded_epoch":%d,"base_ref":"dev"}]}]}' $H $H $NS $H $NS $H $NS)"
out=$(nc check --json); printf '%s\n' "$out" | cond dev_health; printf '%s\n' "$out" | summ
echo "stop record history:"; jq -c '[.history[]? | {condition, status, reason}]' "$LAB/state/night-stop.json"
rm -f "$LAB/data/pr-review-ledger/"*.json

step "S5 dev_health adversarial: not-applicable row carrying outcome:passed after a red record"
ledger 1513 "$(printf '{"schema":"firstmate-pr-review-ledger.v1","task":"t-1513","url":"https://github.com/twilwa/bbchat/pull/1513","current_head":"%s","generations":[{"head":"%s","created_epoch":%d,"risk":{"level":"low","reason":"small"},"checkpoints":[],"review_items":[],"attestations":[],"final_disposition":null,"merge_decision":{"decision":"merge","verified_head":"%s","verified_epoch":%d},"post_merge_verifications":[{"applicability":"browser","head":"%s","outcome":"failed","ready_for_qa":"blocked","recorded_epoch":%d,"base_ref":"dev"}]}]}' $H $H $((NOW-9000)) $H $((NOW-8800)) $H $((NOW-8000)))"
ledger 1514 "$(printf '{"schema":"firstmate-pr-review-ledger.v1","task":"t-1514","url":"https://github.com/twilwa/bbchat/pull/1514","current_head":"%s","generations":[{"head":"%s","created_epoch":%d,"risk":{"level":"low","reason":"docs"},"checkpoints":[],"review_items":[],"attestations":[],"final_disposition":null,"merge_decision":null,"post_merge_verifications":[{"applicability":"not-applicable","outcome":"passed","head":"%s","recorded_epoch":%d,"base_ref":"dev","reason":"docs only"}]}]}' $H $H $((NOW-7000)) $H $((NOW-6000)))"
out=$(nc check --json); printf '%s\n' "$out" | cond dev_health; printf '%s\n' "$out" | summ
rm -f "$LAB/data/pr-review-ledger/"*.json
step "S5 cleared ledgers -> recovery"; nc check --json | summ

step "S6 three failed night ships -> failure streak latches + reserve-flag"
for i in 1 2 3; do
  printf 'kind=ship\nspawn_gen=s%d.1\n' $((NS+i)) > "$LAB/state/ship$i.meta"
  mkdir -p "$LAB/data/ship$i"; printf 'You are a crewmate: an autonomous worker agent managed by firstmate.\n\nDelivery contract: mode=no-mistakes\n' > "$LAB/data/ship$i/brief.md"
  printf 'working [at=%d]: building\nfailed [at=%d]: tests red\n' $((NS+i)) $((NS+i+1)) > "$LAB/state/ship$i.status"
done
out=$(nc check --json); printf '%s\n' "$out" | cond failure_streak; printf '%s\n' "$out" | summ
echo "reserve flag:"; ls -l "$LAB/state/night.reserve" 2>&1 | awk '{print $1, $NF}'
rm -f "$LAB"/state/ship*.meta "$LAB"/state/ship*.status; rm -rf "$LAB"/data/ship*
step "S6 latch survives removal of the failing ships"; nc check --json | summ
step "S6 end the night"; nc end; echo "end rc=$?"; ls "$LAB/state/night.reserve" 2>&1; ls "$LAB/state/night-active.json" 2>&1
step "S6 hc-guard after end"; nc hc-guard; echo "hc-guard rc=$?"
