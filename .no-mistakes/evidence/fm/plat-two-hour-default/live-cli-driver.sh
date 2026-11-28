#!/usr/bin/env bash
# Live driver: real bin/fm-captain-hold.sh, real tasks-axi (markdown backend),
# real system clock for default/due, disposable FM_HOME. The night verdict comes
# from a real-clock stub (FM_NIGHT_CHECK_BIN) for the healthy path, and from the
# real bin/fm-night-check.sh for the unhealthy path.
set -u
ROOT=$1
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-p2-home.XXXXXX")
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin"
cat > "$H/.tasks.toml" <<'T'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
T
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"; done
cap() { PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
show() { FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" show "$1" --full; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
run() { echo; echo "\$ $*"; "$@"; echo "[exit $?]"; }
mirror() { : > "$H/state/.host-mirror.jsonl"; local s=0 e; for e in "$@"; do s=$((s+1)); jq -cn --argjson seq $s --argjson epoch "${e#*:}" --arg tag "${e%%:*}" '{seq:$seq,epoch:$epoch,key:"k",id:("e"+($seq|tostring)),tag:$tag,text:"words",text_sha256:"x"}' >> "$H/state/.host-mirror.jsonl"; done; }
cat > "$H/night-check" <<'SH'
#!/usr/bin/env bash
echo "night-check called: $*" >> "$NIGHT_LOG"
now=$(date -u +%s)
jq -n --argjson now "$now" --argjson start "$NIGHT_START" '{schema:"fm-night-verdict.v1",checked_epoch:$now,checked_at:"x",night_active:true,night_started_epoch:$start,verdict:"continue",verdict_label:"continue",allow:{dispatch:true,claude:true,merge:true,validation:true,two_hour_default:true},tripped:[],reasons:[]}'
SH
chmod +x "$H/night-check"
export NIGHT_LOG="$H/night.log"; : > "$NIGHT_LOG"
NOW=$(date -u +%s)
export NIGHT_START=$((NOW - 4*3600))
jq -n --argjson s "$NIGHT_START" '{schema:"fm-night-active.v1",started_epoch:$s,created_reserve_flags:[],stop_record_expected:false}' > "$H/state/night-active.json"
printf 'Use option B (shorter notice copy) and file the longer copy as a follow-up.\n\n' > "$H/rec.txt"
printf 'Release to main now.\n' > "$H/prod.txt"

echo "=== S1/S2: default-bearing hold by main, and hold-time refusals ==="
ASK1=$((NOW - 7500))   # ask 2h05m ago -> due now
ASK2=$((NOW - 4200))   # ask 1h10m ago -> proceeds at
ASK3=$((NOW - 1200))   # ask 20m ago   -> waits
for pair in "d1:$ASK1" "d2:$ASK2" "d3:$ASK3"; do
  id=${pair%%:*}; a=${pair#*:}
  run env FM_CAPTAIN_HOLD_NOW=$(iso $a) bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap hold $id --title 'Notice copy $id' --reason 'pick option A or B' --repo sample --default-file '$H/rec.txt' --default-class dev-revertible --default-category issue-design-choice"
done
echo; echo "--- recorded default record for d1 (data/d1/hold-default.json):"; jq . "$H/data/d1/hold-default.json"
echo "recommendation bytes in file: $(wc -c < "$H/rec.txt"); in record: $(jq -j .recommendation "$H/data/d1/hold-default.json" | wc -c)"
run cap hold p1 --title 'Prod release' --reason 'ship?' --repo sample --default-file "$H/prod.txt" --default-class dev-revertible --default-category production
run cap hold u1 --title 'Unknown cat' --reason 'x' --repo sample --default-file "$H/rec.txt" --default-class dev-revertible --default-category make-it-up
run cap hold c1 --title 'Wrong class' --reason 'x' --repo sample --default-file "$H/rec.txt" --default-class prod-irreversible --default-category issue-design-choice
run env FM_SUPERVISION_ACTOR=branch bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap hold e1 --title 'Engine' --reason 'x' --repo sample --default-file '$H/rec.txt' --default-class dev-revertible --default-category issue-design-choice"
run cap hold r1 --title 'Plain held call' --reason 'x' --repo sample
run cap hold r1 --reason 'x' --default-file "$H/rec.txt" --default-class dev-revertible --default-category issue-design-choice
for id in p1 u1 c1 e1; do echo "$id open-captain-hold? $(cap open $id >/dev/null 2>&1 && echo yes || echo no); default record? $([ -e "$H/data/$id/hold-default.json" ] && echo yes || echo no)"; done
echo "r1 default record? $([ -e "$H/data/r1/hold-default.json" ] && echo yes || echo no)"

echo; echo "=== S3: due listing (real clock, read-only) ==="
mirror "captain:$((ASK1 - 600))" "main:$((ASK1 + 60))" "main:$((NOW - 3700))" "main:$((NOW - 120))"
before=$(sha256sum "$H/data/backlog.md"); : > "$NIGHT_LOG"
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap due"
echo "backlog unchanged by due: $([ "$before" = "$(sha256sum "$H/data/backlog.md")" ] && echo yes || echo no); night-check calls during due: $(wc -l < "$NIGHT_LOG")"

echo; echo "=== S4a: captain spoke 10 minutes ago -> due says waits, default refuses ==="
mirror "captain:$((ASK1 - 600))" "main:$((ASK1 + 60))" "main:$((NOW - 3700))" "captain:$((NOW - 600))" "main:$((NOW - 120))"
run cap due
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap default d1"
echo "d1 still open captain hold: $(cap open d1 >/dev/null 2>&1 && echo yes || echo no)"
echo; echo "=== S4b: default before ask+2h refuses (d2 at 1h10m) ==="
mirror "captain:$((ASK1 - 600))" "main:$((ASK1 + 60))" "main:$((NOW - 3700))" "main:$((NOW - 120))"
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap default d2"
echo "d2 still open captain hold: $(cap open d2 >/dev/null 2>&1 && echo yes || echo no)"
echo; echo "=== S4c: real bin/fm-night-check.sh in this disposable home (no healthy inputs) refuses ==="
for t in quota-axi herdr-core; do printf '#!/usr/bin/env bash\nexit 1\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"; done
printf '#!/usr/bin/env bash\nexit 1\n' > "$H/fakebin/gh"
run cap default d1
echo "d1 still open captain hold: $(cap open d1 >/dev/null 2>&1 && echo yes || echo no); body has defaulted? $(show d1 | grep -c 'Resolution mode: defaulted')"
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/gh"
echo; echo "=== S4d: always-waits category planted in the record refuses at apply time ==="
cp "$H/data/d1/hold-default.json" "$H/d1.bak"
jq '.category="production"' "$H/d1.bak" > "$H/data/d1/hold-default.json"
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap default d1"
cp "$H/d1.bak" "$H/data/d1/hold-default.json"

echo; echo "=== S5: healthy default at ask+2h applies the exact recommendation ==="
: > "$NIGHT_LOG"
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap default d1"
echo "night-check calls: $(cat "$NIGHT_LOG")"
echo "d1 open captain hold after default: $(cap open d1 >/dev/null 2>&1 && echo yes || echo no)"
show d1 | sed -n 's/^  state: /state: /p'
show d1 | sed -n 's/^  body: //p' | jq -r . 2>/dev/null || show d1 | sed -n 's/^  body: //p'
echo "contains 'Captain decision:'? $(show d1 | grep -c 'Captain decision:')"

echo; echo "=== S6: replay is idempotent; a conflicting --release refuses ==="
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap default d1"
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap default d1 --release"
echo "defaulted records in d1 body: $(show d1 | grep -o 'Resolution mode: defaulted' | wc -l)"

echo; echo "=== S7: --release default while away is refused; attended release lifts hold without closing ==="
ASK4=$((NOW - 7500))
run env FM_CAPTAIN_HOLD_NOW=$(iso $ASK4) bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap hold w1 --title 'Held work w1' --reason 'which fix?' --repo sample --default-file '$H/rec.txt' --default-class dev-revertible --default-category issue-design-choice"
: > "$H/state/.afk"
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap default w1 --release"
echo "w1 still open captain hold: $(cap open w1 >/dev/null 2>&1 && echo yes || echo no)"
rm -f "$H/state/.afk"
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap default w1 --release"
echo "w1 open captain hold: $(cap open w1 >/dev/null 2>&1 && echo yes || echo no); state: $(show w1 | sed -n 's/^  state: //p' | head -1)"

echo; echo "=== S8: a new default-bearing hold after a released default applies (no stuck retry) ==="
ASK5=$((NOW - 7300))
run env FM_CAPTAIN_HOLD_NOW=$(iso $ASK5) bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap hold w1 --reason 'second question: which layout?' --default-file '$H/rec.txt' --default-class dev-revertible --default-category issue-design-choice"
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap due"
run env FM_NIGHT_CHECK_BIN="$H/night-check" bash -c "$(declare -f cap); H='$H' ROOT='$ROOT' cap default w1"
echo "w1 state: $(show w1 | sed -n 's/^  state: //p' | head -1); defaulted records: $(show w1 | grep -o 'Resolution mode: defaulted' | wc -l)"

echo; echo "=== S9: bearings model lists decided_by_default ==="
PATH="$H/fakebin:$PATH" FM_HOME="$H" "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$H/bearings.json" 2>"$H/bearings.err"; echo "[bearings exit $?]"
jq '{decided_by_default, omitted: (.omitted // null)}' "$H/bearings.json" 2>/dev/null || head -c 2000 "$H/bearings.err"
