#!/usr/bin/env bash
# Live driver for the P2 two-hour default, run against a disposable marked lab
# home (bin/fm-lab-home.sh create) with the real bin/fm-captain-hold.sh, real
# tasks-axi markdown backlog, real bin/fm-host-mirror.sh summary validation, the
# real bin/fm-night-check.sh start/check, and the real system clock for apply.
# Usage: drive-two-hour-default.sh <worktree> <lab-home>
set -u
WT=$1 LAB=$2
cd "$WT" || exit 1
NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
E=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
   -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_CAPTAIN_HOLD_NOW
   -u FM_SUPERVISION_ACTOR FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH")
STUB="$LAB/night-check-continue"
run() { printf '\n$ %s\n' "$*"; "${E[@]}" "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return 0; }
hold_at() {  # <epoch> <id> [extra...]
  local at=$1 id=$2; shift 2
  run env FM_CAPTAIN_HOLD_NOW="$(iso "$at")" bin/fm-captain-hold.sh hold "$id" \
    --title "Notice copy choice $id" --reason "pick option A or B for the $id notice copy" --repo sample "$@"
}
withdef() { printf -- '--default-file\n%s\n--default-class\ndev-revertible\n--default-category\n%s\n' "$1" "$2"; }
mirror_line() {  # <seq> <epoch> <tag>
  jq -cn --argjson seq "$1" --argjson epoch "$2" --arg tag "$3" \
    '{seq:$seq,epoch:$epoch,key:"lab-main",id:("lab-" + ($seq|tostring)),tag:$tag,text:"lab dialog",text_sha256:"lab"}'
}
show() { "${E[@]}" bin/fm-tasks-axi.sh show "$1" --full; }

echo "=== clock: real now $(iso "$NOW") ($NOW)"
printf 'Use the shorter notice copy (option B) and file the longer copy as a follow-up.\n\n' > "$LAB/rec.txt"
printf 'Ship the compact layout; keep the wide layout behind the existing flag.\n' > "$LAB/rec2.txt"

# Night-check stand-in for the happy path only: a healthy "continue" verdict for
# the lab's real active night, checked_epoch from the real clock at call time.
cat > "$STUB" <<SH
#!/usr/bin/env bash
jq -n --argjson now "\$(date -u +%s)" --argjson start "\$(jq .started_epoch "$LAB/state/night-active.json")" \
 '{schema:"fm-night-verdict.v1",checked_epoch:\$now,checked_at:"x",night_active:true,night_started_epoch:\$start,
   verdict:"continue",verdict_label:"continue",allow:{dispatch:true,claude:true,merge:true,validation:true,two_hour_default:true},tripped:[],reasons:[]}'
SH
chmod +x "$STUB"

echo; echo "=== S1 hold-time guards (refused before anything is written)"
mapfile -t D < <(withdef "$LAB/rec.txt" production)
hold_at $((NOW - 7500)) g1 "${D[@]}"
mapfile -t D < <(withdef "$LAB/rec.txt" made-up-key)
hold_at $((NOW - 7500)) g2 "${D[@]}"
mapfile -t D < <(withdef "$LAB/rec.txt" issue-design-choice)
printf '\n# supervision engine (branch actor) tries to write a default'
run env FM_SUPERVISION_ACTOR=branch FM_CAPTAIN_HOLD_NOW="$(iso $((NOW - 7500)))" bin/fm-captain-hold.sh hold g3 \
  --title "Engine-written default" --reason "r" --repo sample "${D[@]}"
printf '\n# an existing plain hold tries to gain a default retroactively'
hold_at $((NOW - 7500)) g4
hold_at $((NOW - 7400)) g4 "${D[@]}"
echo; echo "# what exists for g1..g4 after the refusals:"
for id in g1 g2 g3 g4; do printf '%s: default record=%s open-hold=' "$id" "$([ -e "$LAB/data/$id/hold-default.json" ] && echo yes || echo no)"; "${E[@]}" bin/fm-captain-hold.sh open "$id" >/dev/null 2>&1 && echo yes || echo no; done

echo; echo "=== S2 default-bearing holds by main at three ask times"
hold_at $((NOW - 7500)) t1 "${D[@]}"        # ask + 2h05m -> due now
hold_at $((NOW - 4200)) t2 "${D[@]}"        # ask + 1h10m -> proceeds at
hold_at $((NOW - 1200)) t3 "${D[@]}"        # ask + 20m   -> waits
hold_at $((NOW - 7600)) t5 "${D[@]}"        # for the real night-check refusal
hold_at $((NOW - 7700)) t6 "${D[@]}"        # for the release + re-hold path
hold_at $((NOW - 7800)) t7 "${D[@]}"        # for the away-posture refusal
hold_at $((NOW - 7900)) t4 "${D[@]}"        # for the captain-spoke refusal
echo "# t1 recorded default (byte-for-byte recommendation, two trailing newlines):"
jq . "$LAB/data/t1/hold-default.json"
cmp <(jq -j .recommendation "$LAB/data/t1/hold-default.json") "$LAB/rec.txt" && echo "recommendation identical to rec.txt"

echo; echo "=== dialog mirror: captain last spoke 3h ago, main entries since every ask"
{ mirror_line 1 $((NOW - 10800)) captain; mirror_line 2 $((NOW - 9000)) main; mirror_line 3 $((NOW - 3000)) main
  mirror_line 4 $((NOW - 60)) main; } > "$LAB/state/.host-mirror.jsonl"
run bin/fm-host-mirror.sh summary

echo; echo "=== S3 due listing (real clock, read-only, no night check)"
run bin/fm-captain-hold.sh due

echo; echo "=== S4 too early: default t2 at ask + 1h10m"
run env FM_NIGHT_CHECK_BIN="$STUB" bin/fm-captain-hold.sh default t2

echo; echo "=== S5 real night check refuses: default t5 with the real bin/fm-night-check.sh"
run bin/fm-captain-hold.sh default t5
run bin/fm-captain-hold.sh open t5

echo; echo "=== S6 happy path: default t1 at ask + 2h05m, silent hour, healthy night verdict"
run env FM_NIGHT_CHECK_BIN="$STUB" bin/fm-captain-hold.sh default t1
show t1
echo "# a retry is idempotent:"
run env FM_NIGHT_CHECK_BIN="$STUB" bin/fm-captain-hold.sh default t1
echo "# default record retired: $([ -e "$LAB/data/t1/hold-default.json" ] && echo present || echo absent)"

echo; echo "=== S7 away posture: default --release refused while away"
: > "$LAB/state/.afk"
run env FM_NIGHT_CHECK_BIN="$STUB" bin/fm-captain-hold.sh default t7 --release
run bin/fm-captain-hold.sh open t7
rm -f "$LAB/state/.afk"

echo; echo "=== S8 released default, then a new default-bearing hold on the same task applies"
run env FM_NIGHT_CHECK_BIN="$STUB" bin/fm-captain-hold.sh default t6 --release
run bin/fm-captain-hold.sh open t6
mapfile -t D2 < <(withdef "$LAB/rec2.txt" split-and-file)
hold_at $((NOW - 7300)) t6 "${D2[@]}"
run bin/fm-captain-hold.sh due
run env FM_NIGHT_CHECK_BIN="$STUB" bin/fm-captain-hold.sh default t6
show t6

echo; echo "=== S9 the captain speaks: a captain message lands now"
mirror_line 5 "$(date -u +%s)" captain >> "$LAB/state/.host-mirror.jsonl"
run bin/fm-host-mirror.sh summary
run bin/fm-captain-hold.sh due
run env FM_NIGHT_CHECK_BIN="$STUB" bin/fm-captain-hold.sh default t4
run bin/fm-captain-hold.sh open t4
show t4 | grep -c 'Resolution mode: defaulted' | sed 's/^/t4 defaulted records: /'

echo; echo "=== S10 bearings: decided_by_default rows"
run bash -c 'bin/fm-bearings-snapshot.sh --json 2>/dev/null | jq "{decided_by_default, omitted}"'
