#!/usr/bin/env bash
# Live lab driver for `fm-send --resolve-key <k> --park`: real lab home, real
# tmux server on a lab-private socket, real hung "claude" pane, real fm-send,
# real fm-watch.sh cycles, real fm-crew-state.sh. Usage:
#   park-live-driver.sh <worktree-root> <arm> <transcript>
# arm: control | park | park-verb
set -u
ROOT=$1 ARM=$2 OUT=$3
say() { printf '%s [%s] %s\n' "$(date -u +%H:%M:%SZ)" "$ARM" "$1" | tee -a "$OUT"; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { say "lab create failed"; exit 1; }
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || { say "tmux-dir failed"; exit 1; }
export TMUX_TMPDIR="$TD"; unset TMUX
SOCK="$TD/tmux-$(id -u)/default"; mkdir -p "$(dirname "$SOCK")"; chmod 700 "$(dirname "$SOCK")"
cleanup() { tmux -S "$SOCK" kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
STATE="$LAB/state"; TASK=t1
AGENT="$LAB/data/claude"
printf '#!/usr/bin/env bash\nprintf "claude> working (elapsed 00:00:01)\\n"\nexec sleep 2147483647\n' > "$AGENT"; chmod +x "$AGENT"
tmux -S "$SOCK" new-session -d -s lab -n w1 -x 200 -y 50 "$AGENT" || { say "tmux failed"; exit 1; }
WIN=lab:w1
mkdir -p "$LAB/data/wt"; printf 'window=%s\nbackend=tmux\nharness=claude\nkind=ship\nworktree=%s\n' "$WIN" "$LAB/data/wt" > "$STATE/$TASK.meta"
printf 'working: implementing\nneeds-decision [key=posture]: CI push lease held by another lane - resume or stay parked?\n' > "$STATE/$TASK.status"
FM_HOME="$LAB" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$LAB" "$TASK.status"
printf 'g1\n' > "$STATE/$TASK.busy-gen"
printf 'v1 gen=g1 seq=1 state=busy source=fm-spawn event=turn_start ts=%s\n' "$(date +%s)" > "$STATE/$TASK.busy-state"
touch -d '5 seconds ago' "$STATE/$TASK.meta"
VERB=''; [ "$ARM" = park-verb ] && VERB=awaiting
export FM_CLASSIFY_PAUSED_VERB=$VERB
say "lab=$LAB socket=$SOCK window=$WIN FM_CLASSIFY_PAUSED_VERB='${VERB}'"
ANSWER='Stay parked until the CI push lease frees; do not push before then'
args=("$TASK" --resolve-key posture)
[ "$ARM" = control ] || args+=(--park)
say "\$ fm-send.sh ${args[*]} '$ANSWER'"
FM_HOME="$LAB" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "${args[@]}" "$ANSWER" >>"$OUT" 2>&1; rc=$?
say "fm-send exit=$rc"
say "--- state/t1.status after send ---"; cat "$STATE/$TASK.status" | tee -a "$OUT" >/dev/null
say "--- inbox ---"; ls "$STATE/$TASK.inbox" 2>&1 | tee -a "$OUT" >/dev/null; cat "$STATE/$TASK.inbox"/*.msg 2>/dev/null | tee -a "$OUT" >/dev/null
say "--- pane after send ---"; tmux -S "$SOCK" capture-pane -p -t "$WIN" | sed '/^$/d' | tee -a "$OUT" >/dev/null
say "--- fm-crew-state.sh t1 ---"
FM_HOME="$LAB" "$ROOT/bin/fm-crew-state.sh" "$TASK" 2>&1 | head -20 | tee -a "$OUT" >/dev/null
say "--- fm-wake-drain (open decisions?) ---"
FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" 2>&1 | head -20 | tee -a "$OUT" >/dev/null
woke=0; cycles=5
for c in $(seq 1 $cycles); do
  o="$LAB/data/cycle-$c.out"
  FM_HOME="$LAB" FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_BUSY_TURN_MAX_SECS=1 \
    "$ROOT/bin/fm-watch.sh" >"$o" 2>&1 &
  pid=$!; i=0
  while [ $i -lt 300 ] && kill -0 $pid 2>/dev/null; do [ -s "$STATE/.last-watcher-beat" ] && break; sleep 0.1; i=$((i+1)); done
  i=0; while [ $i -lt 60 ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; ex=alive; else wait $pid; ex=$?; fi
  rm -f "$STATE/.last-watcher-beat"
  r=$(head -1 "$o")
  [ -n "$r" ] && woke=$((woke+1))
  say "watcher cycle $c -> exit=$ex reason=${r:-<none: absorbed, kept polling>}"
  FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  sleep 3
done
say "--- watcher triage log (absorb/defer lines) ---"
grep -h -i -E 'absorb|defer|paused|wedge|escalat' "$STATE"/.watch-triage.log 2>/dev/null | tail -25 | tee -a "$OUT" >/dev/null
say "RESULT arm=$ARM fm-send-exit=$rc wakes=$woke/$cycles"
