set -u
. /tmp/fm-nc-driver/common.sh
cap() { env -u NO_MISTAKES_GATE FM_HOME="$1" "$WT/bin/fm-capacity.sh" --admit </dev/null; }
LAB=$(mklab); fakegh "$LAB" 4000; echo "lab home: $LAB"; date
nc "$LAB" start
S=$(jq -r .started_epoch "$LAB/state/night-active.json")
say "S4 baseline: fm-capacity.sh --admit before any stop"
cap "$LAB"; echo "admit rc=$?"
say "S4 a running 'worker' process that must survive the stop"
sleep 600 & WORKER=$!; echo "worker pid $WORKER"
sleep 4
for i in 1 2 3; do printf 'kind=ship\nspawn_gen=s%d.1\n' $((S+i)) > "$LAB/state/n$i.meta"; printf 'failed [at=%d]: night failure %d\n' $((S+i)) $i > "$LAB/state/n$i.status"; done
printf 'kind=scout\nspawn_gen=s%d.1\n' $((S+1)) > "$LAB/state/sc.meta"; printf 'done [at=%d]: scout ok\n' $((S+3)) > "$LAB/state/sc.status"
printf 'kind=ship\nspawn_gen=s%d.1\n' $((S-7200)) > "$LAB/state/pre.meta"; printf 'done [at=%d]: pre-night ok\n' $((S+3)) > "$LAB/state/pre.status"
say "S4 three night ship tickets failed in a row (a scout done + a pre-night ship done interleaved, both excluded) -> stop_dispatch, failure_streak latched"
nc "$LAB" check --json | tee "$LAB/v.json" | summ
jq -c '.conditions.failure_streak.details' "$LAB/v.json"
echo "reserve-flag contents:"; cat "$LAB/state/night.reserve"
echo "night-active created_reserve_flags:"; jq -c .created_reserve_flags "$LAB/state/night-active.json"
say "S4 fm-capacity.sh --admit now refuses"
cap "$LAB"; echo "admit rc=$?"
say "S4 non-destructive: worker still alive?"
kill -0 "$WORKER" && echo "worker $WORKER alive"
say "S4 a later night ship succeeds: live streak ok but latch persists"
printf 'kind=ship\nspawn_gen=s%d.1\n' $((S+4)) > "$LAB/state/n4.meta"; printf 'done [at=%d]: PR ok\n' $((S+4)) > "$LAB/state/n4.status"
nc "$LAB" check --json | tee "$LAB/v.json" | summ
jq -c '{live:.conditions.failure_streak.status}' "$LAB/v.json"
say "S4 adversarial: operator edits config/lane-capacity to a different reserve-flag path mid-night; end must still clear the owned flag"
printf '8\nreserve-flag %s/state/other.reserve other\n' "$LAB" > "$LAB/config/lane-capacity"
nc "$LAB" end; echo "end rc=$?"
ls "$LAB/state/night.reserve" 2>&1
echo "stop record kept:"; jq -c '{schema,latched:[.latched[].condition],first_tripped_at,verdict}' "$LAB/state/night-stop.json"
printf '8\nreserve-flag %s/state/night.reserve night stop\n' "$LAB" > "$LAB/config/lane-capacity"
cap "$LAB"; echo "admit rc after end=$?"
kill -0 "$WORKER" && echo "worker $WORKER still alive after end"; kill "$WORKER"; wait "$WORKER" 2>/dev/null

say "S5 adversarial: foreign (captain-set) reserve-flag is not overwritten and survives end"
nc "$LAB" start >/dev/null; S=$(jq -r .started_epoch "$LAB/state/night-active.json")
printf 'captain manual hold\n' > "$LAB/state/night.reserve"
printf '%d\tWAKE\tt-x\tdetail\tnone\n' $((S-3600)) > "$LAB/state/.wake-queue"
say "S9 oldest unacked wake is 60 min old (>30) -> supervision_stall latched with stall start time"
nc "$LAB" check --json | tee "$LAB/v.json" | summ
jq -c '{stall_since_epoch, latched:[.latched[]|{condition,latched_at}]}' "$LAB/state/night-stop.json"
echo "flag content (must be unchanged):"; cat "$LAB/state/night.reserve"
nc "$LAB" end >/dev/null; echo "after end flag:"; cat "$LAB/state/night.reserve"; rm -f "$LAB/state/night.reserve" "$LAB/state/.wake-queue"

say "S5 adversarial: corrupt state/night-stop.json during an active night"
nc "$LAB" start >/dev/null; S=$(jq -r .started_epoch "$LAB/state/night-active.json")
printf '{corrupt' > "$LAB/state/night-stop.json"; sha_before=$(sha256sum "$LAB/state/night-stop.json")
for i in 5 6 7; do printf 'kind=ship\nspawn_gen=s%d.1\n' $((S+i-4)) > "$LAB/state/m$i.meta"; printf 'failed [at=%d]: x\n' $((S+i-4)) > "$LAB/state/m$i.status"; done
sleep 4
nc "$LAB" check --json | summ
[ "$sha_before" = "$(sha256sum "$LAB/state/night-stop.json")" ] && echo "night-stop.json untouched (not overwritten)"
ls "$LAB/state/night.reserve" 2>&1
nc "$LAB" end >/dev/null
rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
