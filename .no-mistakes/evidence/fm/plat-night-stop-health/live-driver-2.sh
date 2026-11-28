#!/usr/bin/env bash
set -u
WT={run-worktree}
CHECK="$WT/bin/fm-night-check.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/fakebin"
printf '8\nreserve-flag %s/state/night.reserve night stop\n' "$LAB" > "$LAB/config/lane-capacity"
: > "$LAB/config/status-archive"
cat > "$LAB/fakebin/quota-axi" <<'EOF'
#!/usr/bin/env bash
ref=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -cn --arg ref "$ref" '{generatedAt:$ref,schemaVersion:5,providers:[{provider:"claude",label:"Claude",source:"oauth",plan:"max",account:{accountId:"acct",email:"a@example.com",organization:"org",identityStatus:"verified"},windows:[{id:"five_hour",label:"5h",kind:"five_hour",percentUsed:20,percentRemaining:80},{id:"seven_day",label:"week",kind:"weekly",percentUsed:30,percentRemaining:70}],attempts:[],state:{status:"fresh",stale:false,refreshedAt:$ref,sourcesTried:[]},quotaSemantics:{status:"known",description:"d",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:80,boundedBy:["five_hour","seven_day"],limitingWindowIds:["five_hour"],runway:{status:"through_reset"}}]}}]}'
EOF
gh_stub() { printf '#!/usr/bin/env bash\n[ "$1 $2" = "api rate_limit" ] && printf %s \x27{"resources":{"core":{"limit":5000,"used":%d,"remaining":%d,"reset":%d}}}\x27 && exit 0\nexit 1\n' "%s" $((5000-$1)) "$1" $(( $(date +%s)+3000 )) > "$LAB/fakebin/gh"; }
cat > "$LAB/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "api rate_limit" ]; then r=$(cat "$(dirname "$0")/gh.remaining"); printf '{"resources":{"core":{"limit":5000,"used":%d,"remaining":%d,"reset":%d}}}\n' $((5000-r)) $r $(( $(date +%s)+3000 )); exit 0; fi
exit 1
EOF
chmod +x "$LAB/fakebin/quota-axi" "$LAB/fakebin/gh"; echo 4200 > "$LAB/fakebin/gh.remaining"
nc() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_NIGHT_NOW_EPOCH -u FM_PROC_ROOT_OVERRIDE -u FM_BACKEND -u FM_HC_BIN -u FM_HC_SOCKET -u HC_SOCKET -u HC_SESSION -u HC_SCOPE PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" "$CHECK" "$@" </dev/null; }
summ() { jq -c '{verdict, allow, tripped: [.tripped[]? | {condition,status,reason}]}'; }
step() { printf '\n=== %s ===\n' "$*"; }
L=$(TZ=Europe/London date +%H:%M); echo "lab=$LAB london-now=$L"
step "S7 enabled supervision host (Claude primary, no main-session .lock) fails closed"
printf 'timezone Europe/London\n' > "$LAB/config/night-check"
nc start >/dev/null; nc check --json | summ
: > "$LAB/config/supervision-host-off"
step "S7 explicit config/supervision-host-off opt-out reads ok"; nc check --json | jq -c '{verdict, supervision: .conditions.supervision_stall.status}'
step "S8 GitHub core API 900 remaining (< 1000 floor)"; echo 900 > "$LAB/fakebin/gh.remaining"; nc check --json | summ
step "S8 GitHub API recovers to 4200"; echo 4200 > "$LAB/fakebin/gh.remaining"; nc check --json | summ
nc end >/dev/null
step "S9 past last-dispatch cut-off (window 23:00, last-dispatch 03:00, end 04:30; now $L London)"
printf 'timezone Europe/London\nlast-dispatch 03:00\nwindow-end 04:30\n' > "$LAB/config/night-check"
nc start; nc check --json | summ; echo "reserve flag present? $([ -e "$LAB/state/night.reserve" ] && echo yes || echo no)"
nc end >/dev/null
step "S9 after window end (end 03:05 London; now $L London)"
printf 'timezone Europe/London\nlast-dispatch 03:00\nwindow-end 03:05\n' > "$LAB/config/night-check"
nc check --json | summ; echo "reserve flag present? $([ -e "$LAB/state/night.reserve" ] && echo yes || echo no)"
step "S9 adversarial: bogus timezone fails closed"
printf 'timezone Mars/Olympus\n' > "$LAB/config/night-check"
nc check --json | summ
