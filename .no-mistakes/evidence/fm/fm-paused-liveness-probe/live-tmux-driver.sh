#!/usr/bin/env bash
# drive.sh <bin-root> <lab> <log> <pane-cmd> <phases...>
# Runs the REAL bin/fm-watch.sh from <bin-root> against lab home <lab> and a real
# private tmux server ($lab/tmux). Each round: start the watcher, let it exit on a
# wake (up to 25s) or kill it (absorb), then drain+ack the wake queue.
set -u
ROOTB=$1 LAB=$2 LOG=$3 PANECMD=$4; shift 4
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux"
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
ST="$LAB/state"; KEY=lab_fm-wedge; W=lab:fm-wedge
T() { tmux "$@"; }
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
ack() {
  local err="$ST/.drain.err" seq gen out
  out=$("$ROOTB/bin/fm-wake-drain.sh" 2>"$err") || true
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    drained: /' | tee -a "$LOG"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && "$ROOTB/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  rm -f "$err"
}
round() {  # <label>
  local out="$LAB/round.out" pid i=0 rc
  : > "$out"
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_PAUSE_RESURFACE_SECS=60 FM_WATCH_HANDLING_SUCCESSOR=1 \
    "$ROOTB/bin/fm-watch.sh" > "$out" 2>"$LAB/round.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 25 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; wait "$pid" 2>/dev/null; rc=absorbed-no-wake
  else wait "$pid"; rc="exited($?)"; fi
  log "  [$1] watcher $rc after ${i}s; stdout:"; sed 's/^/    | /' "$out" | tee -a "$LOG"
  log "    dead-reported marker: $(cat "$ST/.dead-reported-$KEY" 2>/dev/null || echo '<none>')"
  ack
}
backdate() {  # make the pause recheck due again (status + throttle older than cadence)
  touch -d '@'$(( $(date +%s) - 500 )) "$ST/wedge.status"
  [ -e "$ST/.paused-resurfaced-$KEY" ] && touch -d '@'$(( $(date +%s) - 500 )) "$ST/.paused-resurfaced-$KEY"
  # keep the status-signal scan quiet for a pure mtime change
  true
}
sock() { printf '%s/tmux-%s/default' "$TMUX_TMPDIR" "$(id -u)"; }
for ph in "$@"; do
  case "$ph" in
    setup)
      T new-session -d -s lab -n fm-wedge -c /tmp "$PANECMD"
      sleep 2
      printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$W" > "$ST/wedge.meta"
      printf 'paused: waiting for an upstream release\n' > "$ST/wedge.status"
      printf 'incarnation-one\n' > "$ST/wedge.busy-gen"
      touch -d '@'$(( $(date +%s) - 500 )) "$ST/wedge.status"
      log "== setup: real tmux window $W running '$PANECMD'; pane_current_command=$(T display -p -t "$W" '#{pane_current_command}')"
      ;;
    warm*) round "$ph" ;;
    due*) backdate; round "$ph" ;;
    unreadable)
      chmod 000 "$(sock)"; log "== chmod 000 on lab tmux socket (probe/capture now fail: $(tmux list-windows -t lab 2>&1 | head -1))"
      backdate; round unreadable-due
      chmod 700 "$(sock)"; log "== socket permissions restored; pane_current_command=$(T display -p -t "$W" '#{pane_current_command}')"
      ;;
    killwin) T new-window -d -t lab -n other "sleep 3600"; T kill-window -t "$W" 2>/dev/null; log "== killed window $W (session inventory now: $(T list-windows -t lab -F '#{window_name}' | tr '\n' ' '))" ;;
    seeddead) printf 'dead old-incarnation' > "$ST/.dead-reported-$KEY"; log "== seeded stale death marker: dead old-incarnation" ;;
    *) log "unknown phase $ph" ;;
  esac
done
log "== stale wakes in queue file for $W: $(awk -F '\t' -v w="$W" '$3=="stale" && $4==w {n++} END{print n+0}' "$ST/.wake-queue" 2>/dev/null)"
