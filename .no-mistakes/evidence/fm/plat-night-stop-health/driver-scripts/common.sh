# shared helpers for live night-check scenarios
WT={run-worktree}
EV=~/.no-mistakes/evidence/01M8FCJTQKYJEHM4N3NGVVC9QJ
mklab() {  # prints lab dir
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$WT/bin/fm-lab-home.sh" create "$lab" >/dev/null || return 1
  mkdir -p "$lab/fakebin"
  cat > "$lab/config/night-check" <<CFG
window-start 12:00
last-dispatch 20:00
window-end 21:00
timezone America/Los_Angeles
CFG
  printf '8\nreserve-flag %s/state/night.reserve night stop\n' "$lab" > "$lab/config/lane-capacity"
  printf 'tmux\n' > "$lab/config/backend"
  quota "$lab" 80 70
  printf '%s\n' "$lab"
}
quota() {  # <lab> <five> <week> [stale]
  local lab=$1 f=$2 w=$3 st=${4:-false}
  local payload
  payload=$(jq -cn --argjson f "$f" --argjson w "$w" --argjson stale "$st" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{generatedAt:$now,schemaVersion:5,providers:[{provider:"claude",label:"Claude",source:"oauth",plan:"max",account:{accountId:"acct",email:"lab@example.invalid",organization:"org",identityStatus:"verified"},windows:[{id:"five_hour",label:"5h",kind:"five_hour",percentUsed:(100-$f),percentRemaining:$f},{id:"seven_day",label:"week",kind:"weekly",percentUsed:(100-$w),percentRemaining:$w}],attempts:[],state:{status:"fresh",stale:$stale,refreshedAt:$now,sourcesTried:[]},quotaSemantics:{status:"known",description:"d",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:$f,boundedBy:["five_hour","seven_day"],limitingWindowIds:["five_hour"],runway:{status:"through_reset"}}]}}]}')
  printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n%s\nJSON\n' "$payload" > "$lab/fakebin/quota-axi"
  chmod +x "$lab/fakebin/quota-axi"
}
fakegh() {  # <lab> <remaining>  (stub only the rate_limit boundary)
  cat > "$1/fakebin/gh" <<G
#!/usr/bin/env bash
if [ "\${1:-}" = api ] && [ "\${2:-}" = rate_limit ]; then
  printf '{"resources":{"core":{"limit":5000,"used":%d,"remaining":%d,"reset":1795800000}}}\n' \$((5000-$2)) $2; exit 0; fi
exit 1
G
  chmod +x "$1/fakebin/gh"
}
nc() {  # <lab> args... : real CLI, real clock, real /proc load
  local lab=$1; shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_BACKEND -u HC_SESSION -u HC_SOCKET -u FM_HC_SOCKET -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET \
    PATH="$lab/fakebin:$PATH" FM_HOME="$lab" ${NC_EXTRA_ENV:-} "$WT/bin/fm-night-check.sh" "$@" </dev/null
}
summ() { jq -c '{verdict,night_active,allow,tripped:[.tripped[]|{condition,status,verdict_effect,reason}],latched:[.latched[]?|.condition],reserve_flag:.reserve_flag.state,warnings}'; }
say() { printf '\n### %s\n' "$*"; }
