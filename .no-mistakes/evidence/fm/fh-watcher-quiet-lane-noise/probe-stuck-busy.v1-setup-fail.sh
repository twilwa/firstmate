#!/usr/bin/env bash
# Live probe (test-step evidence): the real bin/fm-watch.sh main loop polls a
# real tmux pane (a live "pi" process in a recorded busy turn whose footer ticks
# every second) holding an aged, unhandled steer enqueued by the real
# bin/fm-send.sh. Arm A: no recorded progress -> stuck-busy stale wake after
# FM_TASK_INBOX_BUSY_MAX (2) deferrals despite the ticking footer, no doorbell
# typed. Arm B: recorded busy progress (fm-busy-event.sh progress, the Pi
# native-progress path) every second -> no stuck-busy wake while progress
# advances; once progress stops it escalates again.
# Usage: probe-stuck-busy.sh <repo-root> <transcript>
set -u
ROOT=$1
TRANSCRIPT=$2
: > "$TRANSCRIPT"
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_TASK_INBOX_BUSY_MAX FM_BUSY_REGEX; do unset "$v"; done
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-busy.XXXXXX")
LAB="$TMP/lab-home"; LAB_SOCKET=''; PROG_PID=''; WPID=''
cleanup() {
  [ -z "$PROG_PID" ] || kill "$PROG_PID" 2>/dev/null
  [ -z "$WPID" ] || kill "$WPID" 2>/dev/null
  wait 2>/dev/null
  [ -z "$LAB_SOCKET" ] || tmux -S "$LAB_SOCKET" kill-server >/dev/null 2>&1 || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$TRANSCRIPT"; }
die() { say "PROBE FAIL: $1"; exit 1; }
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || die "lab create failed"
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB"); export TMUX_TMPDIR="$TD"
LAB_SOCKET="$TD/tmux-$(id -u)/default"; mkdir -p "$(dirname "$LAB_SOCKET")"; chmod 700 "$(dirname "$LAB_SOCKET")"
STATE="$LAB/state"; T=t1; W=lab:pi
mkdir -p "$TMP/agent"
cat > "$TMP/agent/pi" <<'AGENT'
#!/usr/bin/env bash
printf 'pi> long tool call in progress\n'
i=1
while :; do printf '\r  working %ds (esc to interrupt)' "$i"; i=$((i + 1)); sleep 1; done
AGENT
chmod +x "$TMP/agent/pi"
tmux -S "$LAB_SOCKET" new-session -d -s lab -n pi -x 120 -y 40 "$TMP/agent/pi"
printf 'window=%s\nbackend=tmux\nharness=pi\nkind=ship\n' "$W" > "$STATE/$T.meta"
printf 'working: long test run\n' > "$STATE/$T.status"
FM_HOME="$LAB" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$LAB" "$T.status"
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$T") || die "busy arm failed"
"$ROOT/bin/fm-busy-event.sh" apply "$STATE" "$T" busy --gen "$GEN" --source pi-ext --event agent-start || die "busy apply failed"
say "probe: stuck-busy vs ticking footer and recorded progress at $(cd "$ROOT" && git rev-parse --short HEAD); lab $LAB; pane $W (live pi process, recorded busy turn gen=$GEN)"

say "enqueue a steer with the real fm-send.sh"
FM_HOME="$LAB" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$T" 'please rebase on main when this turn ends' > "$TMP/send.out" 2>&1
say "fm-send exit=$? output: $(tr '\n' ' ' < "$TMP/send.out")"
REC=$(ls "$STATE/$T.inbox"/*.msg 2>/dev/null | head -1)
[ -n "$REC" ] || die "no inbox record was written"
pane_has_doorbell() { tmux -S "$LAB_SOCKET" capture-pane -p -t "$W" -S -40 | grep -v -e '^pi> ' -e 'working [0-9]*s' -e '^$' | head -3; }
say "pane lines other than agent output after fm-send: [$(pane_has_doorbell | tr '\n' ' ')]"

reset_arm() {
  FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  rm -f "$STATE/$T.inbox/.busy-state" "$STATE/$T.inbox/.escalated" "$STATE/$T.inbox/.ring-state"
  touch -t 202001010000 "$REC"
}
# run_watcher <bound-secs>: the real main loop; returns when it wakes or at the bound.
run_watcher() {
  local bound=$1 i=0
  OUT="$TMP/watch-$RANDOM.out"
  FM_HOME="$LAB" TMUX_TMPDIR="$TD" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_TASK_INBOX_GRACE_SECS=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_BUSY_TURN_MAX_SECS=7200 \
    "$ROOT/bin/fm-watch.sh" > "$OUT" 2>&1 &
  WPID=$!
  STARTED=$(date +%s)
  while [ $i -lt $((bound * 10)) ] && kill -0 $WPID 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 $WPID 2>/dev/null; then kill $WPID; wait $WPID 2>/dev/null; RUNNING=1; else wait $WPID 2>/dev/null; RUNNING=0; fi
  WPID=''
  ELAPSED=$(( $(date +%s) - STARTED ))
  REASON=$(head -1 "$OUT")
}

say "ARM A: footer ticks, no recorded busy progress"
reset_arm
run_watcher 120
say "  watcher $([ $RUNNING = 1 ] && echo 'still polling at bound' || echo "woke after ${ELAPSED}s"); reason=${REASON:-none}"
say "  .busy-state: $(tr '\t' ' ' < "$STATE/$T.inbox/.busy-state" 2>/dev/null)"
say "  pane lines other than agent output: [$(pane_has_doorbell | tr '\n' ' ')]"
A=0
case "$REASON" in *"stuck-busy after 2 consecutive busy-deferred due doorbells without recorded busy progress"*) A=1 ;; esac
[ -f "$REC" ] || A=0
say "  arm A verdict: $([ $A = 1 ] && echo PASS || echo FAIL)"

say "ARM B: recorded busy progress every second (fm-busy-event.sh progress)"
reset_arm
( while :; do "$ROOT/bin/fm-busy-event.sh" progress "$STATE" "$T" --gen "$GEN" >/dev/null 2>&1; sleep 1; done ) &
PROG_PID=$!
run_watcher 30
say "  watcher $([ $RUNNING = 1 ] && echo "still polling at the ${ELAPSED}s bound" || echo "woke after ${ELAPSED}s"); reason=${REASON:-none}"
say "  .busy-state: $(tr '\t' ' ' < "$STATE/$T.inbox/.busy-state" 2>/dev/null)"
B1=0
case "$REASON" in *stuck-busy*) ;; *) B1=1 ;; esac
[ -s "$STATE/$T.inbox/.busy-state" ] || B1=0   # the busy deferral path must actually have run
say "  progress advancing: $([ $B1 = 1 ] && echo 'PASS (no stuck-busy wake)' || echo FAIL)"
kill $PROG_PID; wait $PROG_PID 2>/dev/null; PROG_PID=''
say "  progress stopped; watching for escalation"
FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
run_watcher 120
say "  watcher $([ $RUNNING = 1 ] && echo 'still polling at bound' || echo "woke after ${ELAPSED}s"); reason=${REASON:-none}"
B2=0
case "$REASON" in *"stuck-busy after 2 consecutive"*) B2=1 ;; esac
say "  progress stopped: $([ $B2 = 1 ] && echo 'PASS (stuck-busy escalates)' || echo FAIL)"
say "  pane lines other than agent output: [$(pane_has_doorbell | tr '\n' ' ')]"
[ $A = 1 ] && [ $B1 = 1 ] && [ $B2 = 1 ] && say "RESULT PASS" || { say "RESULT FAIL"; exit 1; }
