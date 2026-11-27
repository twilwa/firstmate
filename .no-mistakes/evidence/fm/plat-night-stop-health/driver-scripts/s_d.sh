set -u
. /tmp/fm-nc-driver/common.sh
HCL="$WT/bin/fm-hc-lab.sh"
SESS=$("$HCL" name night); echo "hc lab session: $SESS"
"$HCL" provision "$SESS" || { echo "provision failed"; exit 1; }
SOCK=$("$HCL" socket "$SESS"); SD="${TMPDIR:-/tmp}/fm-hc-lab-${UID}/$SESS"
echo "lab socket: $SOCK"
LAB=$(mklab); fakegh "$LAB" 4000; printf 'hc\n' > "$LAB/config/backend"; echo "lab home: $LAB"
export NC_EXTRA_ENV="HC_SESSION=$SESS FM_HC_SOCKET=$SOCK XDG_STATE_HOME=$SD/env/xdg-state XDG_CONFIG_HOME=$SD/env/xdg-config XDG_DATA_HOME=$SD/env/xdg-data"
say "S11 start night on backend=hc pinned to the lab core: saves (session, socket) target + baseline"
nc "$LAB" start; echo "start rc=$?"
jq -c '{hc_target,hc_baseline}' "$LAB/state/night-active.json"
say "S11 check with core unchanged -> hc_core ok, continue"
nc "$LAB" check --json | tee "$LAB/v.json" | summ; jq -c '.conditions.hc_core.status' "$LAB/v.json"
say "S11 adversarial: ambient HC_SOCKET pointing elsewhere is ignored (saved target socket used)"
NC_EXTRA_ENV="$NC_EXTRA_ENV HC_SOCKET=/tmp/nonexistent-hc.sock" nc "$LAB" check --json | jq -c '{verdict,hc:.conditions.hc_core.status}'
say "S11 restart the lab core (guarded lab stop, then auto-start on next contact)"
"$HCL" stop "$SESS"; echo "stop rc=$?"; sleep 1
"$HCL" run "$SESS" ls >/dev/null 2>&1; echo "lab core restarted via run ls (rc=$?)"
"$HCL" run "$SESS" ls >/dev/null 2>&1
say "S11 check after restart -> hc_core tripped, end_night, latched, reserve-flag set, core_restarted in stop record"
nc "$LAB" check --json | tee "$LAB/v.json" | summ
jq -c '.conditions.hc_core.details | {baseline: .baseline.pid, current: .current.pid}' "$LAB/v.json"
jq -c '{core_restarted, latched:[.latched[]|{condition,verdict_effect,latched_at}]}' "$LAB/state/night-stop.json"
say "S11 hc-guard refuses install during the night"
nc "$LAB" hc-guard; echo "hc-guard rc=$?"
nc "$LAB" end; echo "end rc=$?"
nc "$LAB" verdict --json | jq -c '{verdict,night_active,two_hour_default:.allow.two_hour_default,latched:[.latched[].condition]}'
rm -rf "$LAB"; echo "fm lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
say "teardown hc lab"
"$HCL" teardown "$SESS"; echo "teardown rc=$?"
