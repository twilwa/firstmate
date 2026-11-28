#!/usr/bin/env bash
# Live driver for the two-hour default (P2): runs the real bin/fm-captain-hold.sh,
# real tasks-axi, real bin/fm-host-mirror.sh check, and real bin/fm-bearings-snapshot.sh
# against a disposable marked lab home. Synthetic inputs: the dialog mirror file
# (state/.host-mirror.jsonl), the night-active record, and (for the apply path
# only) a night-check verdict served via the FM_NIGHT_CHECK_BIN seam.
set -u
ROOT=$1 LAB=$2
H="$ROOT/bin/fm-captain-hold.sh"
ASK=2026-11-27T01:00:00Z; ASK_E=$(date -u -d "$ASK" +%s)
NIGHT_START=$((ASK_E - 3600))

cap() {  # <now-iso> <args...>
  local now=$1; shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_SUPERVISION_ACTOR \
    PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_CAPTAIN_HOLD_NOW="$now" \
    FM_NIGHT_CHECK_BIN="${NIGHT_BIN:-$ROOT/bin/fm-night-check.sh}" \
    FM_TEST_VERDICT="$LAB/verdict.json" "$H" "$@"
}
step() { printf '\n$ %s\n' "$*"; }
run() { local rc=0; "$@" 2>&1 || rc=$?; printf '[exit %s]\n' "$rc"; }

mirror() {  # <tag:epoch>...
  local seq=0 e; : > "$LAB/state/.host-mirror.jsonl"
  for e in "$@"; do seq=$((seq+1))
    jq -cn --argjson seq "$seq" --argjson epoch "${e#*:}" --arg tag "${e%%:*}" \
      '{seq:$seq,epoch:$epoch,key:"lab-main",id:("e\($seq)"),tag:$tag,text:"synthetic",text_sha256:("0"*64)}' \
      >> "$LAB/state/.host-mirror.jsonl"
  done
}
verdict() {  # <checked-epoch>
  jq -n --argjson c "$1" --argjson s "$NIGHT_START" '{schema:"fm-night-verdict.v1",checked_epoch:$c,
    checked_at:"x",night_active:true,night_started_epoch:$s,verdict:"continue",verdict_label:"continue",
    allow:{dispatch:true,claude:true,merge:true,validation:true,two_hour_default:true},tripped:[],reasons:[]}' > "$LAB/verdict.json"
}
cat > "$LAB/night-stub" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_VERDICT"
SH
chmod +x "$LAB/night-stub"
jq -n --argjson s "$NIGHT_START" '{schema:"fm-night-active.v1",started_epoch:$s,created_reserve_flags:[]}' > "$LAB/state/night-active.json"
printf 'Use the shorter notice copy (option B); file the longer copy as a follow-up issue.\n' > "$LAB/rec.txt"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

echo "=== S1: main records a dev-revertible default at ask time ==="
step "hold t1 --default-category issue-design-choice (at $ASK)"
run cap "$ASK" hold t1 --title "Notice copy choice" --reason "Pick option A or B for the notice copy" \
  --repo bbchat --default-file "$LAB/rec.txt" --default-class dev-revertible --default-category issue-design-choice
step "cat data/t1/hold-default.json"; jq . "$LAB/data/t1/hold-default.json"

echo; echo "=== S2: hold-time refusals (nothing written) ==="
for spec in "t2|production|dev-revertible" "t3|security-sensitive|dev-revertible" "t4|made-up-key|dev-revertible" "t5|issue-design-choice|prod-ok"; do
  IFS='|' read -r id catg cls <<<"$spec"
  step "hold $id --default-class $cls --default-category $catg"
  run cap "$ASK" hold "$id" --title "x $id" --reason "r" --repo bbchat --default-file "$LAB/rec.txt" --default-class "$cls" --default-category "$catg"
  printf 'task %s in backlog: %s; default record: %s\n' "$id" "$(grep -c " $id " "$LAB/data/backlog.md")" "$([ -e "$LAB/data/$id/hold-default.json" ] && echo present || echo absent)"
done
step "FM_SUPERVISION_ACTOR=branch hold t6 ... (the cheaper engine)"
rc=0; FM_SUPERVISION_ACTOR=branch env PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_CAPTAIN_HOLD_NOW="$ASK" "$H" hold t6 --title "x" --reason r --repo bbchat \
  --default-file "$LAB/rec.txt" --default-class dev-revertible --default-category night-queue-order 2>&1 || rc=$?; echo "[exit $rc]"
step "hold t7 --until 2026-12-01 with a default"
run cap "$ASK" hold t7 --title "x" --reason r --repo bbchat --until 2026-12-01 --default-file "$LAB/rec.txt" --default-class dev-revertible --default-category split-and-file
step "plain hold t8 (no default), then re-hold t8 trying to add a default retroactively"
run cap "$ASK" hold t8 --title "Already held call" --reason "older question" --repo bbchat
run cap "$ASK" hold t8 --title "Already held call" --reason "older question" --repo bbchat --default-file "$LAB/rec.txt" --default-class dev-revertible --default-category split-and-file
printf 'default record for t8: %s\n' "$([ -e "$LAB/data/t8/hold-default.json" ] && echo present || echo absent)"

echo; echo "=== S3: due timeline (read-only) ==="
mirror "captain:$((ASK_E - 900))" "main:$((ASK_E + 30))"
step "due at ask+30m"; run cap "$(iso $((ASK_E + 1800)))" due
mirror "captain:$((ASK_E - 900))" "main:$((ASK_E + 30))" "main:$((ASK_E + 3800))"
step "due at ask+1h05m, no captain message in the last hour"; run cap "$(iso $((ASK_E + 3900)))" due
mirror "captain:$((ASK_E - 900))" "main:$((ASK_E + 30))" "captain:$((ASK_E + 3700))" "main:$((ASK_E + 3800))"
step "due at ask+1h05m, captain spoke at ask+1h01m40s"; run cap "$(iso $((ASK_E + 3900)))" due
mirror "captain:$((ASK_E - 900))" "main:$((ASK_E + 30))" "main:$((ASK_E + 7100))"
step "due at ask+2h, quiet"; run cap "$(iso $((ASK_E + 7200)))" due
echo "(due wrote nothing: t1 still held)"; run cap "$(iso $((ASK_E + 7200)))" open t1

echo; echo "=== S4: default refusals (adversarial, state unchanged) ==="
NOW2=$(iso $((ASK_E + 7200)))
step "default t1 at ask+1h59m (too early)"; NIGHT_BIN="$LAB/night-stub" verdict $((ASK_E + 7140)); NIGHT_BIN="$LAB/night-stub" run cap "$(iso $((ASK_E + 7140)))" default t1
mirror "captain:$((ASK_E - 900))" "main:$((ASK_E + 30))" "captain:$((ASK_E + 4000))" "main:$((ASK_E + 7100))"
step "default t1 at ask+2h, captain message 53m ago"; verdict $((ASK_E + 7200)); NIGHT_BIN="$LAB/night-stub" run cap "$NOW2" default t1
mirror "main:$((ASK_E + 4000))" "main:$((ASK_E + 7100))"
step "default t1 at ask+2h, mirror trimmed: oldest kept entry 53m old (silence unproven)"; NIGHT_BIN="$LAB/night-stub" run cap "$NOW2" default t1
mirror "captain:$((ASK_E - 900))" "main:$((ASK_E - 600))"
step "default t1 at ask+2h, mirror has no entry since the ask (writer not proven recording)"; NIGHT_BIN="$LAB/night-stub" run cap "$NOW2" default t1
mirror "captain:$((ASK_E - 900))" "main:$((ASK_E + 30))" "main:$((ASK_E + 7100))"
step "default t1 at ask+2h, quiet mirror, but the REAL bin/fm-night-check.sh (lab has no quota/gh/window inputs)"
run cap "$NOW2" default t1
step "default t1 at ask+2h, stubbed verdict says two_hour_default false"
jq '.allow.two_hour_default=false | .verdict="stop_dispatch"' "$LAB/verdict.json" > "$LAB/v2" && mv "$LAB/v2" "$LAB/verdict.json"
NIGHT_BIN="$LAB/night-stub" run cap "$NOW2" default t1
step "t1 still an open captain hold after every refusal"; run cap "$NOW2" open t1
grep -c "Resolution mode: defaulted" "$LAB/data/backlog.md" | sed 's/^/defaulted records in backlog: /'

echo; echo "=== S5: captain answer wins over a pending default ==="
run cap "$ASK" hold t9 --title "Layout choice" --reason "Pick layout A or B" --repo bbchat \
  --default-file "$LAB/rec.txt" --default-class dev-revertible --default-category issue-design-choice
printf 'Go with layout A.\n' > "$LAB/ans.txt"
step "answer t9 with the captain's words at ask+1h30m"; run cap "$(iso $((ASK_E + 5400)))" answer t9 --decision-file "$LAB/ans.txt"
verdict $((ASK_E + 7200))
step "default t9 at ask+2h"; NIGHT_BIN="$LAB/night-stub" run cap "$NOW2" default t9
step "due at ask+2h (t9 answered: not listed)"; run cap "$NOW2" due

echo; echo "=== S6: default applies at ask+2h, quiet hour, allowing night verdict ==="
step "default t1 at $NOW2"; NIGHT_BIN="$LAB/night-stub" run cap "$NOW2" default t1
step "open t1"; run cap "$NOW2" open t1
step "t1 row in data/backlog.md"; awk '/ t1 /{p=1} p&&/^- \[/&&!/ t1 /{p=0} p' "$LAB/data/backlog.md"
step "retry default t1 (idempotent)"; NIGHT_BIN="$LAB/night-stub" run cap "$NOW2" default t1
grep -c "Resolution mode: defaulted" "$LAB/data/backlog.md" | sed 's/^/defaulted records in backlog: /'
