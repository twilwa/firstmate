#!/usr/bin/env bash
# Live lab scenarios for the default wedge cap (FM_WEDGE_MAX_ESCALATIONS UNSET).
# Real tmux server on a lab-private socket, real lab home minted by
# bin/fm-lab-home.sh, real bin/fm-watch.sh cycles. Harness shape copied from
# tests/fm-watch-wedge-cap-live.test.sh; the cap setting is never exported.
# usage: scenarios-default-cap.sh <repo-root>
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/wake-helpers.sh"
unset FM_WEDGE_MAX_ESCALATIONS FM_CAP_HORIZON_SECS

LAB_HOME=''; LAB_SOCKET=''; FAILS=0
cleanup() {
  [ -n "$LAB_SOCKET" ] && tmux -S "$LAB_SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "$LAB_HOME" ]; then
    "$ROOT/bin/fm-lab-home.sh" teardown "$LAB_HOME" >/dev/null 2>&1 || true
    rm -rf "$LAB_HOME"
  fi
  fm_test_cleanup
}
trap cleanup EXIT
say() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$1"; }
check() {  # <desc> <cmd...>
  local d=$1; shift
  if "$@"; then say "CHECK PASS: $d"; else say "CHECK FAIL: $d"; FAILS=$((FAILS + 1)); fi
}

STALE_SECS=2
TMP_ROOT=$(fm_test_tmproot fm-default-cap-scen)
LAB_HOME="$TMP_ROOT/lab-home"
"$ROOT/bin/fm-lab-home.sh" create "$LAB_HOME" >/dev/null || { say "lab create failed"; exit 1; }
LAB_TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB_HOME") || exit 1
export TMUX_TMPDIR="$LAB_TMUX_DIR"
LAB_SOCKET="$TMUX_TMPDIR/tmux-$(id -u)/default"
mkdir -p "$(dirname "$LAB_SOCKET")"; chmod 700 "$(dirname "$LAB_SOCKET")"
STATE="$LAB_HOME/state"
TASK=parked-worker
say "lab home $LAB_HOME; FM_WEDGE_MAX_ESCALATIONS is ${FM_WEDGE_MAX_ESCALATIONS-UNSET}"

AGENT_BIN="$TMP_ROOT/wedged-claude"
PANE_TEXT='claude> working (elapsed 00:00:01)'
cat > "$AGENT_BIN" <<'AGENT'
#!/usr/bin/env bash
# Alive, idle agent. USR2 repaints a footer line; USR1 renders the Claude
# background-task exit picker (the blocking dialog fm-composer-lib.sh names).
sleep 2147483647 & sp=$!
trap 'kill $sp 2>/dev/null' EXIT
trap 'printf "footer repaint %s\n" "$(date +%s%N)"' USR2
trap 'clear; printf "Background work is running\n\n❯ 1. Exit and stop tasks\n  2. Keep tasks running\n\nEnter to confirm · Esc to cancel\n"' USR1
printf 'claude> working (elapsed 00:00:01)\n'
while kill -0 $sp 2>/dev/null; do wait $sp; done
AGENT
chmod +x "$AGENT_BIN"
tmux -S "$LAB_SOCKET" new-session -d -s lab -n wedged "$AGENT_BIN" || exit 1
tmux -S "$LAB_SOCKET" set-option -t lab:wedged remain-on-exit on >/dev/null
WINDOW=lab:wedged
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
cat > "$STATE/$TASK.meta" <<META
window=$WINDOW
backend=tmux
harness=claude
kind=ship
META

# The pane process itself (pgrep -f would also match the tmux server, whose argv names the agent).
agent_pid() { tmux -S "$LAB_SOCKET" display -p -t "$WINDOW" '#{pane_pid}'; }

set_status() {  # <line>
  printf '%s\n' "$1" > "$STATE/$TASK.status"
  FM_HOME="$LAB_HOME" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$LAB_HOME" "$TASK.status"
}
reset_lab_state() {
  rm -f "$STATE"/.wedge-* "$STATE"/.stale-since-* "$STATE"/.stale-* \
    "$STATE"/.count-* "$STATE"/.hash-* "$STATE"/.dead-reported-*
  printf 'g1\n' > "$STATE/$TASK.busy-gen"
  printf 'v1 gen=g1 seq=1 state=busy source=fm-spawn event=turn_start ts=%s\n' "$(date +%s)" \
    > "$STATE/$TASK.busy-state"
  printf '%s' "$(hash_text "$PANE_TEXT")" > "$STATE/.hash-$KEY"
  printf '1\n' > "$STATE/.count-$KEY"
  touch -d '5 seconds ago' "$STATE/$TASK.meta"
}

cycle=0; CYCLE_WOKE=0; CYCLE_REASON=''
watcher_cycle() {  # <label>
  local label=$1 out pid i beat="$STATE/.last-watcher-beat"
  cycle=$((cycle + 1)); out="$TMP_ROOT/cycle-$cycle.out"
  env -u FM_WEDGE_MAX_ESCALATIONS FM_HOME="$LAB_HOME" TMUX_TMPDIR="$LAB_TMUX_DIR" \
    FM_STALE_ESCALATE_SECS="$STALE_SECS" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_BUSY_TURN_MAX_SECS=1 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  i=0; while [ $i -lt 200 ] && kill -0 $pid 2>/dev/null && [ ! -s "$beat" ]; do sleep 0.1; i=$((i+1)); done
  i=0; while [ $i -lt 60 ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; fi
  wait $pid 2>/dev/null
  rm -f "$beat"
  CYCLE_REASON=$(head -1 "$out" 2>/dev/null)
  if [ -n "$CYCLE_REASON" ]; then CYCLE_WOKE=1; else CYCLE_WOKE=0; fi
  say "[$label] cycle $cycle woke=$CYCLE_WOKE reason=${CYCLE_REASON:-none}"
  FM_HOME="$LAB_HOME" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
}
cap_stands() { [ -f "$STATE/.wedge-permanent-$KEY" ]; }
no_cap() { [ ! -e "$STATE/.wedge-permanent-$KEY" ]; }

# drive_to_cap <label> <max-cycles>: cycle until a PERMANENTLY-WEDGED wake.
# Records every wedge escalation number seen and the count of terminal wakes.
ESC_SEEN=''; TERMINAL=0
drive_to_cap() {
  local label=$1 max=$2 k=0
  ESC_SEEN=''; TERMINAL=0
  while [ $k -lt "$max" ]; do
    k=$((k + 1)); watcher_cycle "$label"
    case "$CYCLE_REASON" in *PERMANENTLY-WEDGED*) TERMINAL=$((TERMINAL + 1)) ;; esac
    n=$(printf '%s' "$CYCLE_REASON" | sed -n 's/.*escalation \([0-9]*\).*/\1/p')
    [ -n "$n" ] && ESC_SEEN="$ESC_SEEN $n"
    [ $TERMINAL -ge 1 ] && break
  done
}

# ---- S5b: shell-hosted agent dies back to its shell while capped ---------
say "=== S5b: shell-hosted agent exits back to its shell prompt while capped"
tmux -S "$LAB_SOCKET" respawn-window -k -t "$WINDOW" "bash --norc --noprofile"; sleep 0.5
tmux -S "$LAB_SOCKET" send-keys -t "$WINDOW" "$AGENT_BIN" Enter; sleep 1
agent_pid() { pgrep -P "$(tmux -S "$LAB_SOCKET" display -p -t "$WINDOW" '#{pane_pid}')" -f wedged-claude; }
say "agent pid $(agent_pid); backend verdict before kill: $(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "$WINDOW")"
set_status 'working: parked - waiting on landing batch'
reset_lab_state
drive_to_cap S5 8
check "S5 capped again before kill" cap_stands
watcher_cycle "S5 capped silence"
check "S5 capped and silent while agent alive" [ "$CYCLE_WOKE" -eq 0 ]
kill -TERM "$(agent_pid)"; sleep 0.5
say "backend verdict after kill: $(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "$WINDOW")"
say "pane_dead=$(tmux -S "$LAB_SOCKET" display -p -t "$WINDOW" '#{pane_dead}') cmd=$(tmux -S "$LAB_SOCKET" display -p -t "$WINDOW" '#{pane_current_command}')"
dead_wakes=0
for p in 1 2 3 4; do
  watcher_cycle "S5 after-death $p"
  case "$CYCLE_REASON" in *"agent dead"*|*"agent missing"*) dead_wakes=$((dead_wakes + 1)) ;; esac
done
check "S5 dead agent reported exactly once while capped" [ "$dead_wakes" -eq 1 ]

say "SCENARIOS DONE fails=$FAILS"
exit "$FAILS"
