#!/usr/bin/env bash
# Drive the real bin/fm-watch.sh against a REAL tmux server on a private lab
# socket (never the default server) with a disposable lab FM_HOME.
#
# Usage: real-tmux-paused-drive.sh <repo-root> <dead|missing> <rounds>
#   dead    - the recorded window exists but its pane runs only a bare shell
#   missing - the tmux session exists but the recorded window does not
# Each round launches the watcher, waits for it to exit on a wake (or reaps it
# after a bounded number of seconds = "absorbed"), prints the wake it emitted,
# then drains/acks the wake queue, as the supervisor does between wakes. Between
# rounds the paused-recheck throttle marker is backdated past the cadence so
# every round after the first is a due long-cadence recheck.
set -u
ROOT=$1; MODE=$2; ROUNDS=${3:-3}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
SOCKNAME=fm-lab-paused-$$
cleanup() {
  TMUX_TMPDIR="$TD" tmux -L "$SOCKNAME" kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT
STATE="$LAB/state"
SESSION=labfleet
if [ "$MODE" = missing ]; then
  TMUX_TMPDIR="$TD" tmux -L "$SOCKNAME" new-session -d -s "$SESSION" -n other-window -x 120 -y 40 'bash --noprofile --norc'
else
  TMUX_TMPDIR="$TD" tmux -L "$SOCKNAME" new-session -d -s "$SESSION" -n fm-paused -x 120 -y 40 'bash --noprofile --norc'
fi
SOCK=$(TMUX_TMPDIR="$TD" tmux -L "$SOCKNAME" display-message -p -t "$SESSION" '#{socket_path}')
WIN="$SESSION:fm-paused"
KEY=$(printf '%s' "$WIN" | tr ':/.' '___')
printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$WIN" > "$STATE/paused.meta"
printf 'working: implementing\npaused: waiting for an upstream release\n' > "$STATE/paused.status"
touch -d "@$(( $(date +%s) - 900 ))" "$STATE/paused.status"
echo "lab=$LAB socket=$SOCK window=$WIN mode=$MODE"
echo "real tmux inventory on the lab socket:"
TMUX_TMPDIR="$TD" tmux -L "$SOCKNAME" list-windows -a -F '  #{session_name}:#{window_name} cmd=#{pane_current_command}'
echo "real backend agent_state for $WIN: $(env TMUX="$SOCK,0,0" bash -c ". '$ROOT/bin/fm-backend.sh'; fm_backend_agent_state tmux '$WIN'")"

run_round() {
  local out=$1 pid i=0
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u HERDR_ENV -u CMUX_WORKSPACE_ID \
    FM_HOME="$LAB" TMUX="$SOCK,0,0" TMUX_TMPDIR="$TD" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_PAUSE_RESURFACE_SECS=240 FM_STALE_ESCALATE_SECS=1 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 25 ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    echo "  watcher: no wake within ${i}s (absorbed); reaped"
  else
    wait "$pid"; echo "  watcher: exited after ${i}s with a wake"
  fi
  sed 's/^/  out| /' "$out"
}

ack() {
  local err sequence generation
  err="$LAB/drain.err"
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2> "$err" || true
  sed 's/^/  drained| /' "$LAB/drain.out"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -z "$sequence" ] || FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}

for r in $(seq 1 "$ROUNDS"); do
  echo "--- round $r"
  run_round "$LAB/watch-$r.out"
  ack
  echo "  .dead-reported marker: $(cat "$STATE/.dead-reported-$KEY" 2>/dev/null || echo '<none>')"
  echo "  .paused-resurfaced marker: $(cat "$STATE/.paused-resurfaced-$KEY" 2>/dev/null || echo '<none>')"
  echo "  wedge escalations file: $([ -e "$STATE/.wedge-escalations-$KEY" ] && echo present || echo absent)"
  # Make the next round's long-cadence recheck due.
  [ ! -e "$STATE/.paused-resurfaced-$KEY" ] || touch -d "@$(( $(date +%s) - 600 ))" "$STATE/.paused-resurfaced-$KEY"
done
