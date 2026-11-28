#!/usr/bin/env bash
# Second live pass on the same lab home: bearings' bounded decided_by_default
# rows, and `due` reporting "unknown" for a broken binding or category list.
set -u
ROOT=$1 LAB=$2
H="$ROOT/bin/fm-captain-hold.sh"
ASK_E=$(date -u -d 2026-11-27T01:00:00Z +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
cap() { local now=$1; shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_SUPERVISION_ACTOR \
    PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_CAPTAIN_HOLD_NOW="$now" \
    FM_NIGHT_CHECK_BIN="$LAB/night-stub" FM_TEST_VERDICT="$LAB/verdict.json" "${HBIN:-$H}" "$@"; }
step() { printf '\n$ %s\n' "$*"; }
run() { local rc=0; "$@" 2>&1 || rc=$?; printf '[exit %s]\n' "$rc"; }
mirror() { local seq=0 e; : > "$LAB/state/.host-mirror.jsonl"
  for e in "$@"; do seq=$((seq+1))
    jq -cn --argjson seq "$seq" --argjson epoch "${e#*:}" --arg tag "${e%%:*}" \
      '{seq:$seq,epoch:$epoch,key:"lab-main",id:("e\($seq)"),tag:$tag,text:"synthetic",text_sha256:("0"*64)}' \
      >> "$LAB/state/.host-mirror.jsonl"; done; }
verdict() { jq --argjson c "$1" '.checked_epoch=$c | .allow.two_hour_default=true | .verdict="continue"' "$LAB/verdict.json" > "$LAB/v" && mv "$LAB/v" "$LAB/verdict.json"; }

echo "=== S7: a second default applies later; bearings lists both as decided by default, bounded ==="
A2=$((ASK_E + 600))
printf 'Split the change: land the header fix now, file the footer rework as an issue.\n' > "$LAB/rec2.txt"
run cap "$(iso $A2)" hold t10 --title "Split notice change" --reason "Split now or land whole?" --repo bbchat \
  --default-file "$LAB/rec2.txt" --default-class dev-revertible --default-category split-and-file
mirror "captain:$((ASK_E - 900))" "main:$((ASK_E + 30))" "main:$((A2 + 7100))"
verdict $((A2 + 7200))
step "default t10 at ask2+2h"; run cap "$(iso $((A2 + 7200)))" default t10
B() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_BEARINGS_NOW=2026-11-27T04:00:00Z "$ROOT/bin/fm-bearings-snapshot.sh" --json "$@"; }
step "fm-bearings-snapshot.sh --json | {decided_by_default, captain answers in landed, omitted}"
B > "$LAB/bearings-default.json" 2>"$LAB/bearings.err"; echo "[exit $?]"
jq '{decided_by_default, landed, omitted: [.omitted[] | select(.surface|test("decided_by_default|landed"))]}' "$LAB/bearings-default.json"
step "FM_BEARINGS_DEFAULTED=1 fm-bearings-snapshot.sh --json"
FM_BEARINGS_DEFAULTED=1 B > "$LAB/bearings-1.json" 2>>"$LAB/bearings.err"; echo "[exit $?]"
jq '{decided_by_default: [.decided_by_default[] | {id, applied_at}], omitted: [.omitted[] | select(.surface|test("decided_by_default"))]}' "$LAB/bearings-1.json"
step "FM_BEARINGS_DEFAULTED=1 fm-bearings-snapshot.sh --json --all-landed"
FM_BEARINGS_DEFAULTED=1 B --all-landed > "$LAB/bearings-all.json" 2>>"$LAB/bearings.err"; echo "[exit $?]"
jq '{decided_by_default: [.decided_by_default[] | {id, applied_at}], omitted: [.omitted[] | select(.surface|test("decided_by_default"))]}' "$LAB/bearings-all.json"
cat "$LAB/bearings.err" | head -5

echo; echo "=== S8: due reports unknown instead of dropping a pending default ==="
A3=$((ASK_E + 3600))
run cap "$(iso $A3)" hold t11 --title "Queue order" --reason "Which ticket first tonight?" --repo bbchat \
  --default-file "$LAB/rec.txt" --default-class dev-revertible --default-category night-queue-order
mirror "captain:$((ASK_E - 900))" "main:$((A3 + 30))" "main:$((A3 + 3800))"
step "due at ask3+1h05m (healthy)"; run cap "$(iso $((A3 + 3900)))" due
step "tasks-axi update t11 retitle (the held question changes after the default was recorded)"
(cd "$LAB" && tasks-axi update t11 --help 2>&1 | head -8)
(cd "$LAB" && run tasks-axi update t11 --title "Queue order (reworded)")
step "due after the question changed"; run cap "$(iso $((A3 + 3900)))" due
step "default t11 at ask3+2h after the question changed"
mirror "captain:$((ASK_E - 900))" "main:$((A3 + 30))" "main:$((A3 + 7100))"; verdict $((A3 + 7200))
run cap "$(iso $((A3 + 7200)))" default t11
step "malformed bin/fm-hold-default-lists.json (in a disposable copy of bin/)"
cp -r "$ROOT/bin" "$LAB/bincopy"; echo '{"schema":"broken"' > "$LAB/bincopy/fm-hold-default-lists.json"
run cap "$ASK_E" hold t12 --title "Another" --reason "r" --repo bbchat --default-file "$LAB/rec.txt" --default-class dev-revertible --default-category night-queue-order 2>&1 | head -3
printf 'with broken lists, hold t12 via copy: '; HBIN="$LAB/bincopy/fm-captain-hold.sh" run cap "$(iso $A3)" hold t13 --title "Broken lists" --reason r --repo bbchat --default-file "$LAB/rec.txt" --default-class dev-revertible --default-category night-queue-order
step "due via the copy with broken lists"; HBIN="$LAB/bincopy/fm-captain-hold.sh" run cap "$(iso $((A3 + 3900)))" due
