#!/usr/bin/env bash
# Live: real herdr-core lab + real fm-watch.sh re-ring ladder against a pane whose program's status is blocked.
set -u
ROOT={run-worktree}
. "$ROOT/tests/lib.sh"
HC_BIN=$(command -v herdr-core); export FM_HC_BIN=$HC_BIN
. "$ROOT/tests/hc-test-safety.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-ladder)
HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name ladder)
cleanup_lab() { local rc=$?; trap - EXIT; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1; fm_test_cleanup; exit "$rc"; }
trap cleanup_lab EXIT
"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" || fail provision
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
hc_test_refuse_if_unsafe "$HC_TEST_SES" || fail unsafe
HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
FM_HOME_DIR=$TMP_ROOT/home; mkdir -p "$FM_HOME_DIR/state" "$FM_HOME_DIR/config" "$FM_HOME_DIR/data"
export FM_HOME=$FM_HOME_DIR FM_ROOT_OVERRIDE=$ROOT
. "$ROOT/bin/fm-backend.sh"; fm_backend_source hc
wait_for() { local tries=$(( $1 * 10 )); shift; while [ "$tries" -gt 0 ]; do "$@" && return 0; tries=$((tries-1)); sleep 0.1; done; return 1; }
cat > "$TMP_ROOT/a.c" <<'C'
#include <stdio.h>
int main(int c,char**v){char l[8192];FILE*f=fopen(v[1],"a");puts("> ");fflush(stdout);while(fgets(l,sizeof l,stdin)){fputs(l,f);fflush(f);}return 0;}
C
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/wt"; cc -o "$TMP_ROOT/bin/devin" "$TMP_ROOT/a.c" || fail cc
SES=$(fm_backend_hc_container_ensure) || fail ensure
ID="hc-ladder-$$"; LABEL="fm-$ID"; ST=$FM_HOME_DIR/state; LOG=$TMP_ROOT/input.log; : > "$LOG"
WT=$(cd "$TMP_ROOT/wt" && pwd -P)
ADDR=$(fm_backend_hc_create_task "$SES" "$LABEL" "$WT") || fail create; T="$SES:$ADDR"
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$ST" "$ID" --state idle --source devin-hook --event stop) || fail arm
printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=devin\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nbusy_gen=%s\nbackend=hc\nhc_session=%s\nhc_terminal=%s\n' "$T" "$ID" "$WT" "$WT" "$GEN" "$SES" "$ADDR" > "$ST/$ID.meta"
fm_backend_hc_send_text_line "$T" "'$TMP_ROOT/bin/devin' '$LOG'" "$LABEL" || fail launch
alive() { [ "$(fm_backend_agent_state hc "$T" "$LABEL")" = alive ]; }
wait_for 15 alive || fail "agent not alive"
FG=$(fm_backend_hc_get "$T" | jq -r '.foreground.pid'); PTY=/dev/$(ps -o tty= -p "$FG" | tr -d ' ')
printf '\033]7501;state=blocked:kind=question:app=devin\033\134' > "$PTY"
blocked() { [ "$(fm_backend_hc_get "$T" | jq -r '.status.state // empty')" = blocked ]; }
wait_for 10 blocked || fail "native blocked never landed"
echo "# pane root status: $(fm_backend_hc_get "$T" | jq -c .status)"
. "$ROOT/bin/fm-task-inbox-lib.sh"
REC=$(fm_task_inbox_write "$ST" "$ID" "please continue") || fail write
touch -t 202001010000 "$REC"
echo "# enqueued $REC; starting real fm-watch.sh with ring budget 2"
woke() { grep -qF 'unread firstmate instruction' "$ST/.wake-queue" 2>/dev/null; }
for run in 1 2 3 4 5 6; do
  FM_STATE_OVERRIDE="$ST" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_RING_MAX=2 "$ROOT/bin/fm-watch.sh" >> "$TMP_ROOT/watch.out" 2>> "$TMP_ROOT/watch.err" &
  WPID=$!
  gone() { ! kill -0 "$WPID" 2>/dev/null; }
  wait_for 40 gone || true
  echo "# watcher run $run exited; wake lines: $(wc -l < "$ST/.wake-queue" 2>/dev/null); ring-state: $(cat "$ST/$ID.inbox/.ring-state" 2>/dev/null | tr '\t' ' ')"
  woke && break
done
woke || { echo "--- watch.out"; cat "$TMP_ROOT/watch.out"; echo "--- watch.err"; tail -30 "$TMP_ROOT/watch.err"; fail "watcher never escalated"; }
sleep 1; kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=
echo "--- .wake-queue (escalation the watcher emitted):"; cat "$ST/.wake-queue"
echo "--- .ring-refused tally: $(cat "$ST/$ID.inbox/.ring-refused" 2>/dev/null)"
echo "--- doorbell lines received by the blocked program: $(grep -c 'Firstmate instruction waiting' "$LOG" || true)"
grep -qF 'refused input on every attempt' "$ST/.wake-queue" || fail "escalation does not name the refusal"
! grep -qF 'idle pane' "$ST/.wake-queue" || fail "escalation blamed an idle pane"
[ "$(grep -c 'Firstmate instruction waiting' "$LOG" || true)" = 0 ] || fail "something was typed into the blocked program"
[ -f "$REC" ] || fail "record lost"
pass "live hc watcher ladder: refusals tallied and escalation names the blocked refusal; nothing typed; record kept"
fm_backend_kill hc "$T" '' "$LABEL" || true
echo FM_LADDER_COMPLETE
