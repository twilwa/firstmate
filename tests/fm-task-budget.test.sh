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
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" budget-default sample --mode local-only > /dev/null
rg -q '^Task budget: wall_secs=21600 output_tokens=1000000$' "$HOME_DIR/data/budget-default/brief.md" \
  || fail 'default brief budget is missing'
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" budget-override sample --scout \
  --budget-wall-secs 3600 --budget-output-tokens 5000 > /dev/null
rg -q '^Task budget: wall_secs=3600 output_tokens=5000$' "$HOME_DIR/data/budget-override/brief.md" \
  || fail 'per-brief budget override is missing'
rg -q 'needs-decision.*\[key=task-budget\]' "$HOME_DIR/data/budget-override/brief.md" \
  || fail 'scout brief lacks keyed worker backup'
rg -q 'needs-decision.*\[key=task-budget\]' "$HOME_DIR/data/budget-default/brief.md" \
  || fail 'ship brief lacks keyed worker backup'
pass 'ship and scout briefs expose defaults, overrides and the keyed backup'
TASK=budget-fixture
START=1700000000
WALL=21600
REPEAT=14400
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
