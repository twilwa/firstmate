#!/usr/bin/env bash
# Public watcher/crew-state regression for cumulative task budgets.
# The budget clock is controlled by FM_BUDGET_NOW_EPOCH, never by sleeping hours.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=${ROOT:?}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-budget.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/config" "$HOME_DIR/data"
REPEAT=14400
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" budget-default sample --mode local-only > /dev/null
rg -q '^Task budget: wall_secs=21600 output_tokens=1000000$' "$HOME_DIR/data/budget-default/brief.md" \
  || fail 'default brief budget is missing'
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" budget-override sample --scout \
  --budget-wall-secs 3600 --budget-output-tokens 5000 > /dev/null
rg -q '^Task budget: wall_secs=3600 output_tokens=5000$' "$HOME_DIR/data/budget-override/brief.md" \
  || fail 'per-brief budget override is missing'
budget_rules() { # <brief>; rule 5, the budget backup and rule 6, in order
  awk '/^5\. /{five=NR} /\[key=task-budget/{print NR - five ": " $0} /^6\. /{print NR - five ": " $0; exit}' "$1"
}
for kind_brief in "scout:budget-override:to a human" "ship:budget-default:above the implementation worker"; do
  kind=${kind_brief%%:*}; rest=${kind_brief#*:}; brief="$HOME_DIR/data/${rest%%:*}/brief.md"
  rules=$(budget_rules "$brief")
  expected="1:    If you see the current task budget crossed (age = now - start_epoch >= wall_secs), take budget period n = (age - wall_secs) / $REPEAT rounded down; once per period, append \`needs-decision [at=<epoch>] [key=task-budget-<n>]: budget period <n> crossed; continue or stop?\` and stop; firstmate decides.
2: 6. If a decision belongs ${rest#*:} (product choices, destructive actions),"
  [ "$rules" = "$expected" ] || fail "$kind brief budget backup or rule 6 is wrong: $rules"
done
pass 'ship and scout briefs keep rule 6 and key the worker backup per budget period'
TASK=budget-fixture
START=1700000000
WALL=21600
printf 'window=fm-%s\nworktree=%s/no-local-copy\nkind=scout\nspawn_gen=first\nbudget_id=b-fixture\nbudget_start_epoch=%s\nbudget_wall_secs=%s\nbudget_output_tokens=1000000\n' \
  "$TASK" "$TMP_ROOT" "$START" "$WALL" > "$STATE/$TASK.meta"
printf 'working [at=%s]: initial work\n' "$((START + 3600))" > "$STATE/$TASK.status"

watch_at() { # <epoch> <output-file>; budget due must exit on its first cycle
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_BUDGET_NOW_EPOCH="$1" \
    FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
    "$ROOT/bin/fm-watch.sh" > "$2"
}
crew_at() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_BUDGET_NOW_EPOCH="$1" \
    "$ROOT/bin/fm-crew-state.sh" "$TASK"
}
count_budget_rows() {
  awk -F '\t' '$3 == "check" && $4 ~ /^task-budget:/ { n++ } END { print n+0 }' "$STATE/.wake-queue"
}

# First threshold (not a transient pane-staleness result) and crew-state fields.
watch_at "$((START + WALL))" "$TMP_ROOT/first.out"
rg -q "^check: task-budget task=$TASK period=0 age=21600s .*tokens=unknown compactions=unknown restarts=unknown last_status_ago=18000s" "$TMP_ROOT/first.out" \
  || fail "first crossing missing age and unknown telemetry: $(cat "$TMP_ROOT/first.out")"
[ "$(count_budget_rows)" = 1 ] || fail 'first crossing did not queue exactly one budget wake'
state_line=$(crew_at "$((START + WALL))")
case "$state_line" in
  *'budget: age=21600s wall_budget=21600s output_budget=1000000 tokens=unknown compactions=unknown restarts=unknown last_status_ago=18000s'*) ;;
  *) fail "crew-state omitted budget fields: $state_line" ;;
esac
pass 'first threshold wakes with cumulative age and crew-state fields'

# A watcher restart at the same period cannot re-enqueue, even if the first
# queue row has been acknowledged. Terminate only this test's child after one
# cycle has completed; no wall-clock advance is used to exercise the budget.
: > "$STATE/.wake-queue"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_BUDGET_NOW_EPOCH="$((START + WALL))" \
  FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
  timeout 3 "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/restart.out" || rc=$?
[ "${rc:-124}" = 124 ] || fail "restarted watcher exited unexpectedly: $(cat "$TMP_ROOT/restart.out")"
[ "$(count_budget_rows)" = 0 ] || fail 'restart requeued the same budget period after acknowledgement'
pass 'watcher restart does not duplicate an acknowledged budget wake'

watch_at "$((START + WALL + REPEAT))" "$TMP_ROOT/repeat.out"
rg -q "^check: task-budget task=$TASK period=1 age=36000s" "$TMP_ROOT/repeat.out" \
  || fail "four-hour repeat missing: $(cat "$TMP_ROOT/repeat.out")"
[ "$(count_budget_rows)" = 1 ] || fail 'four-hour repeat missing or coalesced'
pass 'four-hour repeat has a distinct durable queue key'

# Relaunch changes the endpoint generation but retains the original start.
# The watcher and crew-state must derive age from that original start, not
# spawn_gen, a fresh status event, or the replacement's first turn.
printf 'spawn_gen=replacement\n' >> "$STATE/$TASK.meta"
printf 'working [at=%s]: replacement resumed\n' "$((START + WALL + REPEAT + 60))" >> "$STATE/$TASK.status"
watch_at "$((START + WALL + 2 * REPEAT))" "$TMP_ROOT/relaunch.out"
rg -q "^check: task-budget task=$TASK period=2 age=50400s .*last_status_ago=14340s" "$TMP_ROOT/relaunch.out" \
  || fail "relaunch reset cumulative age: $(cat "$TMP_ROOT/relaunch.out")"
state_line=$(crew_at "$((START + WALL + 2 * REPEAT))")
case "$state_line" in *'budget: age=50400s '*'last_status_ago=14340s'*) ;; *) fail "crew-state reset the clock: $state_line" ;; esac
pass 'replacement endpoint retains the original task budget start'

# A marker write is unsafe when the destination has become a symlink.
# It must warn on each cycle but not take the fleet watcher down with it.
: > "$STATE/.wake-queue"
rm -f "$STATE/.budget-wake-$TASK"
ln -s /dev/null "$STATE/.budget-wake-$TASK"
rc=0
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_BUDGET_NOW_EPOCH="$((START + WALL + 2 * REPEAT))" \
  FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_WATCH_HANDLING_SUCCESSOR=1 \
  FM_WATCH_TRACE="$TMP_ROOT/marker-error.trace" timeout 3 "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/marker-error.out" 2> "$TMP_ROOT/marker-error.err" || rc=$?
[ "$rc" = 124 ] || fail "marker refusal ended watcher before test timeout: rc=$rc stdout=$(cat "$TMP_ROOT/marker-error.out") stderr=$(cat "$TMP_ROOT/marker-error.err")"
warning_count=$(rg -c 'watcher: task budget check failed; retrying next cycle' "$TMP_ROOT/marker-error.err" || true)
[ "${warning_count:-0}" -ge 1 ] || fail 'marker-write refusal did not warn'
rg -q ' task-budget$' "$TMP_ROOT/marker-error.trace" \
  || fail 'watcher did not advance past the failed budget tick'
[ "$(count_budget_rows)" = 0 ] || fail 'marker refusal published an unprotected wake'
pass 'marker-write refusal warns and the watcher continues polling'

# A done task waits on firstmate, so its budget stays quiet; a later working
# event resumes the original clock. A declared pause keeps its budget wakes.
rm -f "$STATE/$TASK.meta" "$STATE/$TASK.status" "$STATE/.budget-wake-$TASK"
: > "$STATE/.wake-queue"
TASK=budget-terminal
printf 'window=fm-%s\nworktree=%s/no-local-copy\nkind=ship\nbudget_id=b-terminal\nbudget_start_epoch=%s\nbudget_wall_secs=%s\nbudget_output_tokens=1000000\n' \
  "$TASK" "$TMP_ROOT" "$START" "$WALL" > "$STATE/$TASK.meta"
printf 'done [at=%s]: PR opened\n' "$((START + 3600))" > "$STATE/$TASK.status"
rc=0
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_BUDGET_NOW_EPOCH="$((START + WALL))" \
  FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
  timeout 3 "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/done.out" || rc=$?
[ "$(count_budget_rows)" = 0 ] || fail "done task past budget queued a budget wake: $(cat "$TMP_ROOT/done.out")"
rg -q 'task-budget' "$TMP_ROOT/done.out" && fail "done task past budget woke main: $(cat "$TMP_ROOT/done.out")"
pass 'done task past budget produces no budget wake'

: > "$STATE/.wake-queue"
printf 'working [at=%s]: addressing review feedback\n' "$((START + WALL + REPEAT - 60))" >> "$STATE/$TASK.status"
watch_at "$((START + WALL + REPEAT))" "$TMP_ROOT/resumed.out"
rg -q "^check: task-budget task=$TASK period=1 age=36000s" "$TMP_ROOT/resumed.out" \
  || fail "working after done did not resume the original budget clock: $(cat "$TMP_ROOT/resumed.out")"
pass 'a later working event resumes budget wakes against the original start'

: > "$STATE/.wake-queue"
TASK=budget-paused
printf 'window=fm-%s\nworktree=%s/no-local-copy\nkind=ship\nbudget_id=b-paused\nbudget_start_epoch=%s\nbudget_wall_secs=%s\nbudget_output_tokens=1000000\n' \
  "$TASK" "$TMP_ROOT" "$START" "$WALL" > "$STATE/$TASK.meta"
printf 'paused [at=%s]: waiting on upstream CI\n' "$((START + 3600))" > "$STATE/$TASK.status"
watch_at "$((START + WALL + REPEAT))" "$TMP_ROOT/paused.out"
rg -q "^check: task-budget task=$TASK period=1 age=36000s" "$TMP_ROOT/paused.out" \
  || fail "paused task past budget did not wake: $(cat "$TMP_ROOT/paused.out")"
pass 'a paused task past budget still wakes'
