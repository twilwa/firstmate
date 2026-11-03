#!/usr/bin/env bash
# Live driver: real tmux on a lab-private socket, real fake-agent process,
# real bin/fm-watch.sh from <root> against a disposable fm-lab-home.
# usage: drive.sh <root> <scenario> <transcript>
#   scenarios: alive | dead | missing-window | server-gone | unreadable
set -u
ROOT=$1; SCEN=$2; TRANSCRIPT=$3
WT={run-worktree}
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX; do unset "$v"; done
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LAB="$TMP/home"
say() { printf '%s [%s %s] %s\n' "$(date -u +%H:%M:%SZ)" "$(basename "$(dirname "$ROOT")")/$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || basename "$ROOT")" "$SCEN" "$1" | tee -a "$TRANSCRIPT"; }
SOCK=''
cleanup() {
  [ -n "$SOCK" ] && { chmod 700 "$SOCK" 2>/dev/null; tmux -S "$SOCK" kill-server >/dev/null 2>&1; }
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { say "lab create failed"; exit 1; }
TD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB") || { say "tmux-dir failed"; exit 1; }
export TMUX_TMPDIR="$TD"
mkdir -p "$TD/tmux-$(id -u)"; chmod 700 "$TD/tmux-$(id -u)"
SOCK="$TD/tmux-$(id -u)/default"
STATE="$LAB/state"; TASK=crew; SESSION=fmlab; WNAME=crew; WINDOW="$SESSION:$WNAME"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
AGENT="$TMP/claude"; cp /bin/sleep "$AGENT"
# session with a keeper window so closing the crew window leaves the session up
tmux -S "$SOCK" new-session -d -s "$SESSION" -n keeper "bash --norc --noprofile" || exit 1
tmux -S "$SOCK" new-window -d -t "$SESSION:" -n "$WNAME" "bash --norc --noprofile"
sleep 0.5
tmux -S "$SOCK" send-keys -t "$WINDOW" "PS1='$ '; clear; $AGENT 2147483647" Enter
sleep 1
cat > "$STATE/$TASK.meta" <<META
window=$WINDOW
backend=tmux
harness=claude
kind=ship
META
printf 'working: implementing\npaused: waiting for an upstream release\n' > "$STATE/$TASK.status"
touch -d '10 minutes ago' "$STATE/$TASK.status"
FM_HOME="$LAB" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATE/$TASK.status" 2>/dev/null \
 || FM_HOME="$LAB" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$LAB" "$TASK.status"
say "lab up: socket=$SOCK window=$WINDOW agent pid=$(pgrep -f "^$AGENT" | head -1) status='paused: waiting for an upstream release' (aged 600s)"
probe() { say "probe: fm_backend_agent_state tmux $WINDOW -> $(FM_HOME="$LAB" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "$WINDOW" 2>/dev/null)"; }

TRACE="$TMP/trace"; R=0; WOKE=0
round() {  # <label>
  R=$((R+1)); local out="$TMP/round-$R.out" pid i starts
  FM_HOME="$LAB" FM_WATCH_TRACE="$TRACE" FM_PAUSE_RESURFACE_SECS=120 FM_STALE_ESCALATE_SECS=2 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!; i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 900 ]; do
    starts=$(grep -c " $pid cycle-start\$" "$TRACE" 2>/dev/null); starts=${starts:-0}
    [ "$starts" -ge 4 ] && break
    sleep 0.1; i=$((i+1))
  done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; wait "$pid" 2>/dev/null; WOKE=0
  else wait "$pid"; WOKE=1; fi
  starts=$(grep -c " $pid cycle-start\$" "$TRACE" 2>/dev/null)
  say "round $R ($1): woke=$WOKE poll-cycles=${starts:-0} wake=$( [ "$WOKE" = 1 ] && head -1 "$out" || echo none)"
  [ -e "$STATE/.dead-reported-$KEY" ] && say "  .dead-reported-$KEY = '$(cat "$STATE/.dead-reported-$KEY")'"
  # acknowledge
  local err="$TMP/drain.err" seq gen
  FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" > "$TMP/drain.out" 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
age_throttle() { [ -e "$STATE/.paused-resurfaced-$KEY" ] && touch -d '10 minutes ago' "$STATE/.paused-resurfaced-$KEY"; say "aged recheck throttle past the 120s cadence (recheck now due)"; }

case "$SCEN" in
  alive)
    probe; round "agent alive, first due recheck"
    round "agent alive, inside cadence"
    age_throttle; round "agent alive, next due recheck"
    ;;
  dead)
    probe; round "agent alive, first due recheck"
    pkill -f "^$AGENT" ; sleep 1; say "killed the agent process; pane now shows a bare shell"
    probe; age_throttle; round "agent dead, next due recheck"
    age_throttle; round "agent dead, following due recheck"
    age_throttle; round "agent dead, third due recheck"
    ;;
  missing-window)
    probe; round "agent alive, first due recheck"
    tmux -S "$SOCK" kill-window -t "$WINDOW"; say "closed the crew window (session stays up)"
    probe; age_throttle; round "window gone, next due recheck"
    age_throttle; round "window gone, following due recheck"
    age_throttle; round "window gone, third due recheck"
    ;;
  server-gone)
    probe; round "agent alive, first due recheck"
    tmux -S "$SOCK" kill-server; say "killed the whole lab tmux server (daemon restart)"
    probe; age_throttle; round "server gone, next due recheck"
    age_throttle; round "server gone, following due recheck"
    ;;
  unreadable)
    probe; round "agent alive, first due recheck"
    chmod 000 "$SOCK"; say "made the lab socket unreadable (chmod 000): tmux reads fail with Permission denied"
    probe; age_throttle; round "socket unreadable, next due recheck"
    round "socket unreadable, inside cadence"
    age_throttle; round "socket unreadable, following due recheck"
    chmod 700 "$SOCK"
    ;;
esac
grep -h 'absorbed\|stopped while paused' "$STATE/.watch-triage.log" 2>/dev/null | tail -n 12 | sed 's/^/  triage: /' | tee -a "$TRANSCRIPT"
say "done"
