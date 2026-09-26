#!/usr/bin/env bash
# Live driver: real fm-brief -> fm-spawn (Herdr lab) -> fm-spawn --relaunch ->
# fm-watch / fm-crew-state against the spawned task records.
set -u
ROOT=${ROOT:?}
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
LAB="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB" name budget-wake) || exit 1
export HERDR_SESSION="$SESSION"
T=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-budget-live.XXXXXX")
WTS=()
cleanup() {
  for wt in ${WTS[@]+"${WTS[@]}"}; do treehouse return --force "$wt" >/dev/null 2>&1; done
  echo "== teardown $SESSION"; "$LAB" teardown "$SESSION"; echo "teardown rc=$?"
  rm -rf "$T"
}
trap cleanup EXIT
echo "== lab session: $SESSION"
"$LAB" provision "$SESSION" || { echo "provision failed"; exit 1; }
H="$T/home"; mkdir -p "$H/state" "$H/config" "$H/data"
printf 'off\n' > "$H/config/herdr-presentation-spaces"
P="$T/proj"; mkdir -p "$P"; git -C "$P" init -q; echo x > "$P/README.md"; git -C "$P" add .
git -C "$P" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$P" "$P.origin.git"; git -C "$P" remote add origin "file://$P.origin.git"
export FM_HOME="$H" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT"
fill() { sed -i -e 's/{TASK}/Live budget validation task./' -e 's/{FIRSTMATE_SPEC}/Do nothing; this is a lab spawn./' "$H/data/$1/brief.md"; }
meta_budget() { grep -E '^(kind|spawn_gen|budget_[a-z_]+)=' "$H/state/$1.meta"; }
spawn() { "$ROOT/bin/fm-spawn.sh" "$@" --backend herdr; }

echo; echo "### S1 default ship brief -> spawn records default budget"
"$ROOT/bin/fm-brief.sh" bdef proj --mode local-only >/dev/null; fill bdef
grep '^Task budget:' "$H/data/bdef/brief.md"
spawn bdef "$P" "sh -c 'echo budget-live-ok'" --mode local-only --yolo off > "$T/bdef.out" 2>&1; echo "spawn rc=$?"; tail -3 "$T/bdef.out"
meta_budget bdef; WTS+=("$(sed -n 's/^worktree=//p' "$H/state/bdef.meta" | tail -1)")
echo "-- launch-brief (worker-facing) budget lines:"
grep -n -E '^Current task budget:|key=task-budget|^6\. ' "$H/data/bdef/launch-brief.md"

echo; echo "### S2 per-brief override (scout --budget-wall-secs 7200 --budget-output-tokens 250000)"
"$ROOT/bin/fm-brief.sh" bscout proj --scout --budget-wall-secs 7200 --budget-output-tokens 250000 >/dev/null; fill bscout
grep '^Task budget:' "$H/data/bscout/brief.md"
spawn bscout "$P" "sh -c 'echo budget-live-ok'" --scout > "$T/bscout.out" 2>&1; echo "spawn rc=$?"; tail -2 "$T/bscout.out"
meta_budget bscout; WTS+=("$(sed -n 's/^worktree=//p' "$H/state/bscout.meta" | tail -1)")
grep -n '^Current task budget:' "$H/data/bscout/launch-brief.md"

echo; echo "### S3 spawn-time override beats brief (--budget-wall-secs 900)"
"$ROOT/bin/fm-brief.sh" bspawn proj --mode local-only >/dev/null; fill bspawn
spawn bspawn "$P" "sh -c 'echo budget-live-ok'" --mode local-only --yolo off --budget-wall-secs 900 > "$T/bspawn.out" 2>&1; echo "spawn rc=$?"
meta_budget bspawn; WTS+=("$(sed -n 's/^worktree=//p' "$H/state/bspawn.meta" | tail -1)")

echo; echo "### S4 adversarial: invalid overrides / malformed brief budget are refused before any endpoint"
"$ROOT/bin/fm-brief.sh" bbad proj --mode local-only >/dev/null; fill bbad
for a in "--budget-wall-secs 0" "--budget-wall-secs abc" "--budget-output-tokens 012"; do
  # shellcheck disable=SC2086
  out=$(spawn bbad "$P" "sh -c 'echo x'" --mode local-only --yolo off $a 2>&1); echo "[$a] rc=$? :: $(printf '%s' "$out" | grep -m1 error)"
done
sed -i 's/^Task budget: .*/Task budget: wall_secs=six-hours output_tokens=1000000/' "$H/data/bbad/brief.md"
out=$(spawn bbad "$P" "sh -c 'echo x'" --mode local-only --yolo off 2>&1); echo "[malformed Task budget line] rc=$? :: $(printf '%s' "$out" | grep -m1 error)"
[ -e "$H/state/bbad.meta" ] && echo "UNEXPECTED: bbad.meta exists" || echo "no bbad.meta written (refused before endpoint)"
out=$("$ROOT/bin/fm-spawn.sh" bdef --relaunch --budget-wall-secs 60 2>&1); echo "[relaunch + override] rc=$? :: $(printf '%s' "$out" | grep -m1 error)"

echo; echo "### S5 relaunch keeps the original budget start/id"
before=$(meta_budget bdef | grep -E '^budget_(id|start_epoch)='); echo "before:"; echo "$before"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
PANE=$(sed -n 's/^window=//p' "$H/state/bdef.meta" | tail -1)
FB="$T/fakebin"; mkdir -p "$FB"; printf '#!/bin/sh\n: > %q\n' "$T/codex-launched" > "$FB/codex"; chmod +x "$FB/codex"
fm_backend_herdr_send_text_line "$PANE" "export PATH=$FB:\$PATH" || echo "send-text failed"
sleep 3   # make the relaunch clock visibly different from the original start
"$ROOT/bin/fm-spawn.sh" bdef --relaunch --harness codex > "$T/relaunch.out" 2>&1; echo "relaunch rc=$?"; tail -3 "$T/relaunch.out"
for _ in $(seq 1 30); do [ -e "$T/codex-launched" ] && break; sleep 0.2; done
[ -e "$T/codex-launched" ] && echo "replacement harness launched" || echo "replacement harness NOT observed"
after=$(meta_budget bdef | grep -E '^budget_(id|start_epoch)=' | sort -u); echo "after (unique):"; echo "$after"; meta_budget bdef | grep spawn_gen
grep -n '^Current task budget:' "$H/data/bdef/launch-brief.md"
[ "$(printf '%s\n' "$before" | sort -u)" = "$after" ] && echo "RESULT: original budget start/id retained" || echo "RESULT: budget start/id CHANGED"

echo; echo "### S6 watcher wakes main at first crossing on the real spawned record, crew-state carries fields"
START=$(sed -n 's/^budget_start_epoch=//p' "$H/state/bdef.meta" | tail -1)
printf 'working [at=%s]: implementing\n' "$((START + 600))" > "$H/state/bdef.status"
rm -f "$H/state/bscout.meta" "$H/state/bspawn.meta"   # focus the watcher on one task
watch() { FM_BUDGET_NOW_EPOCH="$1" FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 timeout 20 "$ROOT/bin/fm-watch.sh"; echo "(watch rc=$?)"; }
echo "-- 1s before budget:"; FM_BUDGET_NOW_EPOCH=$((START + 21599)) FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 timeout 5 "$ROOT/bin/fm-watch.sh" | grep -c task-budget; echo "(budget wakes before crossing, rc=$?)"
echo "-- at budget:"; watch $((START + 21600))
echo "-- queue rows:"; awk -F'\t' '$4 ~ /^task-budget:/' "$H/state/.wake-queue"
echo "-- marker:"; cat "$H/state/.budget-wake-bdef"
echo "-- crew-state:"; FM_BUDGET_NOW_EPOCH=$((START + 21600)) FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" bdef

echo; echo "### S7 acknowledged wake is not re-sent after watcher restart in the same period; next 4h period wakes"
: > "$H/state/.wake-queue"
FM_BUDGET_NOW_EPOCH=$((START + 21600 + 14399)) FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 timeout 5 "$ROOT/bin/fm-watch.sh" > "$T/restart.out"; echo "restart watch rc=$? (124 = kept polling, no wake)"
grep -c task-budget "$T/restart.out"; awk -F'\t' '$4 ~ /^task-budget:/' "$H/state/.wake-queue" | wc -l
echo "-- +4h:"; watch $((START + 21600 + 14400))

echo; echo "### S8 done task past budget stays quiet; later working line resumes on original clock"
: > "$H/state/.wake-queue"
printf 'done [at=%s]: report written\n' "$((START + 30000))" >> "$H/state/bdef.status"
FM_BUDGET_NOW_EPOCH=$((START + 21600 + 2*14400)) FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 timeout 5 "$ROOT/bin/fm-watch.sh" > "$T/done.out"; echo "done watch rc=$?; budget lines: $(grep -c task-budget "$T/done.out")"
printf 'working [at=%s]: fixing review feedback\n' "$((START + 21600 + 2*14400 + 10))" >> "$H/state/bdef.status"
watch $((START + 21600 + 2*14400 + 60))
