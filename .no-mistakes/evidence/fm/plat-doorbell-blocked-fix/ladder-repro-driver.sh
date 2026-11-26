#!/usr/bin/env bash
# Focused live doorbell repro: ROOT=<code root> runs the real bridge, real fm-send against a lab herdr-core.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
HC_BIN=$(command -v herdr-core); export FM_HC_BIN=$HC_BIN
. "$ROOT/tests/hc-test-safety.sh"
TMP_ROOT=$(fm_test_tmproot fm-doorbell-repro)
HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name repro)
cleanup_lab() { local rc=$?; trap - EXIT; hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || echo "teardown-rc=nonzero (tripwire)"; fm_test_cleanup; exit "$rc"; }
trap cleanup_lab EXIT
"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" || fail provision
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
hc_test_refuse_if_unsafe "$HC_TEST_SES" || fail unsafe
HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
FM_HOME_DIR=$TMP_ROOT/home
mkdir -p "$FM_HOME_DIR/state" "$FM_HOME_DIR/config" "$FM_HOME_DIR/data"
export FM_HOME=$FM_HOME_DIR FM_ROOT_OVERRIDE=$ROOT
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail source
wait_for() { local tries=$(( $1 * 10 )); shift; while [ "$tries" -gt 0 ]; do "$@" && return 0; tries=$((tries-1)); sleep 0.1; done; return 1; }
SES=$(fm_backend_hc_container_ensure) || fail ensure
CC=$(type -P cc)
  cat > "$TMP_ROOT/doorbell-agent.c" <<'C'
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  char line[8192];
  FILE *log = fopen(argc > 1 ? argv[1] : "/dev/null", "a");
  puts("> ");
  fflush(stdout);
  while (fgets(line, sizeof line, stdin)) {
    fputs(line, log);
    fflush(log);
  }
  return 0;
}
C
  mkdir -p "$TMP_ROOT/doorbell-bin" "$TMP_ROOT/doorbell-wt"
  "$CC" -o "$TMP_ROOT/doorbell-bin/devin" "$TMP_ROOT/doorbell-agent.c" || fail 'doorbell fake agent compilation failed'
  DB_ID="hc-doorbell-$$-$RANDOM"
  DB_LABEL="fm-$DB_ID"
  DB_STATE=$FM_HOME_DIR/state
  DB_LOG=$TMP_ROOT/doorbell-input.log
  : > "$DB_LOG"
  DB_WT=$(cd "$TMP_ROOT/doorbell-wt" && pwd -P)
  DB_ADDR=$(fm_backend_hc_create_task "$SES" "$DB_LABEL" "$DB_WT") || fail 'doorbell terminal create failed'
  DB_T="$SES:$DB_ADDR"
  DB_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$DB_STATE" "$DB_ID" --state idle --source devin-hook --event stop) \
    || fail 'doorbell busy record arm failed'
  printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=devin\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nbusy_gen=%s\nbackend=hc\nhc_session=%s\nhc_terminal=%s\n' \
    "$DB_T" "$DB_ID" "$DB_WT" "$DB_WT" "$DB_GEN" "$SES" "$DB_ADDR" > "$DB_STATE/$DB_ID.meta"
  printf 'working [at=%s]: started\n' "$(date +%s)" > "$DB_STATE/$DB_ID.status"
  q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
  # The bridge heartbeat is pushed out of the test's window so a record
  # written over the bridge's own stands until the bridge's signals change.
  fm_backend_hc_send_text_line "$DB_T" "export FM_HC_SOCKET=$(q "$HC_TEST_SOCK") XDG_STATE_HOME=$(q "$XDG_STATE_HOME") XDG_CONFIG_HOME=$(q "$XDG_CONFIG_HOME") XDG_DATA_HOME=$(q "$XDG_DATA_HOME") FM_OSC7501_INTERVAL=1 FM_OSC7501_HEARTBEAT=3600; unset FM_HOME FM_TASK_ID FM_TASK_INBOX; $(q "$ROOT/bin/fm-osc7501.sh") arm --task $DB_ID --harness devin --backend hc --kind ship --state $(q "$DB_STATE") --config $(q "$FM_HOME_DIR/config") --target $(q "$DB_T") --agent-bin $(q "$TMP_ROOT/doorbell-bin/devin") >/dev/null || true; $(q "$TMP_ROOT/doorbell-bin/devin") $(q "$DB_LOG"); $(q "$ROOT/bin/fm-osc7501.sh") disarm --state $(q "$DB_STATE") >/dev/null 2>&1 || true" "$DB_LABEL" \
    || fail 'doorbell agent launch failed'
  db_alive() { [ "$(fm_backend_agent_state hc "$DB_T" "$DB_LABEL")" = alive ]; }
  wait_for 15 db_alive || fail "doorbell fake agent is not alive: $(fm_backend_agent_state hc "$DB_T" "$DB_LABEL")"
  db_status() { fm_backend_hc_get "$DB_T" | jq -c '.status // {}'; }
  db_msg_has() { db_status | jq -e --arg m "$1" '(.msg // "") | contains($m)' >/dev/null; }
  db_doorbells() { grep -c 'Firstmate instruction waiting' "$DB_LOG" 2>/dev/null || true; }
  db_doorbells_reach() { [ "$(db_doorbells)" -ge "$1" ]; }
  db_send() { FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-send.sh" "$DB_ID" "$@"; }
  db_bridge_owns() { [ "$(db_status | jq -r '.app // empty')" = firstmate-devin ]; }
  wait_for 15 db_bridge_owns || fail "the bridge never wrote a record: $(db_status)"
REPORT=$TMP_ROOT/report.txt
echo "== code root: $ROOT"
printf 'needs-decision [at=%s] [key=k1]: pick a or b\n' "$(date +%s)" >> "$DB_STATE/$DB_ID.status"
wait_for 15 db_msg_has 'Needs your decision: pick a or b'; echo "[open key k1] pane root status: $(db_status)"
RC=0; db_send 'steer while k1 is open' 2> "$TMP_ROOT/k1.err" || RC=$?
echo "[open key k1] fm-send rc=$RC stderr: $(cat "$TMP_ROOT/k1.err")"
wait_for 6 db_doorbells_reach 1; echo "[open key k1] doorbells received by agent: $(db_doorbells)"
printf 'resolved [at=%s] [key=k1]: handed to the captain\ncaptain-held [at=%s]: tracked by plat-held-1\n' "$(date +%s)" "$(date +%s)" >> "$DB_STATE/$DB_ID.status"
wait_for 15 db_msg_has 'tracked by plat-held-1'; echo "[captain-held] pane root status: $(db_status)"
RC=0; db_send 'steer while captain-held' 2> "$TMP_ROOT/held.err" || RC=$?
echo "[captain-held] fm-send rc=$RC stderr: $(cat "$TMP_ROOT/held.err")"
BEFORE=$(db_doorbells); wait_for 6 db_doorbells_reach $((BEFORE+1)); echo "[captain-held] doorbells received by agent: $(db_doorbells)"
DB_FG=$(fm_backend_hc_get "$DB_T" | jq -r '.foreground.pid // empty')
DB_PTY=/dev/$(ps -o tty= -p "$DB_FG" | tr -d ' ')
printf '\033]7501;state=blocked:kind=question:app=devin\033\134' > "$DB_PTY"
db_blocked() { [ "$(db_status | jq -r '.state // empty')" = blocked ]; }
wait_for 10 db_blocked; echo "[program-blocked] pane root status: $(db_status)"
V=$(fm_backend_send_text_submit hc "$DB_T" ': adapter probe' 1 0.4 0 "$DB_LABEL" 2> "$TMP_ROOT/probe.err")
echo "[program-blocked] adapter verdict=$V stderr: $(cat "$TMP_ROOT/probe.err")"
BEFORE=$(db_doorbells)
RC=0; db_send 'steer while the program is blocked' 2> "$TMP_ROOT/ref.err" || RC=$?
echo "[program-blocked] fm-send rc=$RC stderr: $(cat "$TMP_ROOT/ref.err")"
sleep 1; echo "[program-blocked] doorbells received by agent: before=$BEFORE after=$(db_doorbells)"
echo "[agent input log]"; cat "$DB_LOG"
echo "== watcher ladder phase (real fm-watch.sh, real hc lab pane blocked by its program)"
INB=$DB_STATE/$DB_ID.inbox
ls "$INB"
rm -f "$INB/.ring-state" "$INB/.escalated" "$INB/.retry-ring"
printf 'working [at=%s]: resumed\n' "$(date +%s)" > "$DB_STATE/$DB_ID.status"
db_unblocked() { [ "$(db_status | jq -r '.app // empty')" = firstmate-devin ]; }
wait_for 15 db_unblocked; echo "[ladder] bridge record after status reset: $(db_status)"
printf '\033]7501;state=blocked:kind=question:app=devin\033\134' > "$DB_PTY"
wait_for 10 db_blocked; echo "[ladder] program re-asserted its own blocked: $(db_status)"
touch -t 202001010000 "$INB"/001.msg
BEFORE=$(db_doorbells)
for run in 1 2 3 4 5 6 7 8; do
  env FM_STATE_OVERRIDE="$DB_STATE" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_RING_MAX=2 bash "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
  WP=$!
  i=0; while kill -0 $WP 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 $WP 2>/dev/null; then echo "[ladder] run $run: watcher still running after 60s; stopping it"; kill $WP; wait $WP 2>/dev/null; else wait $WP; echo "[ladder] run $run: watcher exited rc=$?"; fi
  echo "[ladder] run $run watcher stdout: $(cat "$TMP_ROOT/watch.out")"
  echo "[ladder] run $run .ring-state row (msg count epoch refused): $(cat "$INB/.ring-state" 2>/dev/null)"
  if grep -q 'unread firstmate instruction' "$DB_STATE/.wake-queue" 2>/dev/null; then cp "$DB_STATE/.wake-queue" "$TMP_ROOT/final-queue"; break; fi
  FM_HOME="$FM_HOME_DIR" bash "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/drain.out" 2> "$TMP_ROOT/drain.err"
  ACK=$(grep -o 'bin/fm-wake-drain.sh --ack-through [0-9]* --recovery-generation [^ ]*' "$TMP_ROOT/drain.err" "$TMP_ROOT/drain.out" | head -1 | sed 's/^[^:]*://')
  echo "[ladder] run $run handled by firstmate drain; ack: ${ACK:-none}"
  [ -z "$ACK" ] || FM_HOME="$FM_HOME_DIR" bash "$ROOT/${ACK}" >/dev/null 2>&1 || FM_HOME="$FM_HOME_DIR" bash "$ROOT/bin/fm-wake-drain.sh" ${ACK#bin/fm-wake-drain.sh } > "$TMP_ROOT/ack.out" 2>&1
done
echo "[ladder] .ring-state row (msg count epoch refused): $(cat "$INB/.ring-state" 2>/dev/null)"
echo "[ladder] escalation wake row(s):"; cat "$TMP_ROOT/final-queue" 2>/dev/null || cat "$DB_STATE/.wake-queue" 2>/dev/null
echo "[ladder] pane root status still: $(db_status)"
echo "[ladder] doorbells received by agent: before=$BEFORE after=$(db_doorbells)"
echo "[ladder] 001.msg still unhandled: $([ -f "$INB/001.msg" ] && echo yes || echo no)"
fm_backend_kill hc "$DB_T" '' "$DB_LABEL"
