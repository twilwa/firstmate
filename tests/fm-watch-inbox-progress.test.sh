#!/usr/bin/env bash
# Real-process public watcher regressions for busy steering-inbox deferrals.
# No model is launched: a native stand-in holds a real tmux pane, while the
# public lifecycle writer supplies Pi's progress hook. Only capture faults are
# injected; all endpoint inventory, liveness and ordinary captures are real.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LIVE_INBOX_PROGRESS tmux
TMP_ROOT=$(fm_test_tmproot fm-watch-inbox-progress)
REAL_TMUX=$(type -P tmux) || fail "tmux executable missing"
export FM_REAL_TMUX="$REAL_TMUX" FM_TEST_TMUX_SOCKET="$TMP_ROOT/tmux.sock"
WATCH_PID=
cleanup() {
  [ -z "$WATCH_PID" ] || { kill "$WATCH_PID" 2>/dev/null || true; wait "$WATCH_PID" 2>/dev/null || true; }
  "$REAL_TMUX" -S "$FM_TEST_TMUX_SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
standin=$(fm_agent_standin "$TMP_ROOT/native") || fail "cannot build a native stand-in"
ln -s "$standin" "$TMP_ROOT/pi"
mkdir -p "$TMP_ROOT/bin"
# The absolute target is resolved before changing PATH. This wrapper cannot
# resolve itself, and its only fault seam is capture-pane on our private socket.
cat > "$TMP_ROOT/bin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ]; then
  case "${FM_CAPTURE_FAULT:-}" in
    missing) exit 1 ;;
    empty) exit 0 ;;
    partial) printf '%s\n' 'partial capture before failure'; exit 1 ;;
  esac
fi
exec "$FM_REAL_TMUX" -f /dev/null -S "$FM_TEST_TMUX_SOCKET" "$@"
SH
chmod +x "$TMP_ROOT/bin/tmux"
head -n2 "$TMP_ROOT/bin/tmux" | grep -qF '#!/usr/bin/env bash' || fail "invalid tmux shim header"
export PATH="$TMP_ROOT/bin:$PATH"
tmux new-session -d -s sess -n fm-t1 "$TMP_ROOT/pi" 600 || fail "private tmux start failed"
tmux set-option -t sess automatic-rename off

new_case() {  # <name> <harness>
  CASE_HOME="$TMP_ROOT/$1"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/data" "$CASE_HOME/config"
  fm_write_meta "$CASE_HOME/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$2" "backend=tmux"
  # fm-spawn is a trusted busy source for both Pi and other harnesses.
  GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$CASE_HOME/state" t1) || fail "arm failed"
  FM_STATE_OVERRIDE="$CASE_HOME/state" bash -c '
    . "$1/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_write "$2/state" t1 "please continue"
  ' _ "$ROOT" "$CASE_HOME" > "$CASE_HOME/record" || fail "inbox write failed"
  # A visible initial capture avoids conflating an empty pane with a freeze.
  tmux send-keys -t sess:fm-t1 -l "footer: $1 initial"
}

advance_progress() {
  # The native hook's public marker contract has second-resolution timestamps.
  sleep 1.1
  "$ROOT/bin/fm-busy-event.sh" progress "$CASE_HOME/state" t1 --gen "$GEN" || fail "progress hook failed"
}

round() {  # [missing|empty|partial]
  local i=0 trace="$CASE_HOME/trace" out="$CASE_HOME/out" generation
  if [ -f "$trace" ] && [ ! -s "$CASE_HOME/state/.wake-queue" ]; then
    # Complete the public recovery handshake after intentionally stopping the
    # previous process; otherwise a recovery notification can replace this poll.
    FM_HOME="$CASE_HOME" bash "$ROOT/bin/fm-wake-drain.sh" > "$CASE_HOME/drain" 2>&1 || fail "drain failed"
    generation=$(awk '/^WAKE_ACK_REQUIRED:/ {print $NF}' "$CASE_HOME/drain")
    if [ -n "$generation" ]; then
      FM_HOME="$CASE_HOME" bash "$ROOT/bin/fm-wake-drain.sh" --ack-through 0 \
        --recovery-generation "$generation" >> "$CASE_HOME/drain" 2>&1 || fail "recovery acknowledgement failed"
    fi
  fi
  : > "$trace"
  # Each round is a fresh executable, proving the observation survives restart.
  # A long poll prevents a second round before the completed-poll trace is seen.
  env FM_HOME="$CASE_HOME" FM_BACKEND=tmux FM_CAPTURE_FAULT="${1:-}" \
    FM_POLL=60 FM_HEARTBEAT=999999 FM_STALE_CYCLES=999999 \
    FM_BUSY_TURN_MAX_SECS=999999 FM_TASK_INBOX_GRACE_SECS=0 \
    FM_WATCH_TRACE="$trace" \
    bash "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  WATCH_PID=$!
  while kill -0 "$WATCH_PID" 2>/dev/null && [ "$i" -lt 200 ]; do
    grep -q ' heartbeat$' "$trace" && break
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$WATCH_PID" 2>/dev/null; then
    grep -q ' heartbeat$' "$trace" || fail "watcher did not finish a poll: $(<"$out")"
    kill "$WATCH_PID" 2>/dev/null || true
  fi
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=
  [ "$i" -lt 200 ] || fail "watcher round timed out"
  grep -q ' heartbeat$' "$trace" || grep -q 'stuck-busy' "$CASE_HOME/state/.wake-queue" 2>/dev/null \
    || fail "watcher exited without completing the busy check: $(<"$out")"
}

quiet() {
  [ ! -s "$CASE_HOME/state/.wake-queue" ] || fail "unexpected wake: $(<"$CASE_HOME/out")"
  [ ! -e "$CASE_HOME/state/t1.inbox/.ring-state" ] || fail "busy worker was rung"
}

escalated() {
  local record
  record=$(<"$CASE_HOME/record")
  grep -q 'stuck-busy after 2 consecutive busy-deferred' "$CASE_HOME/state/.wake-queue" \
    || fail "frozen busy worker did not escalate at the existing threshold: $(<"$CASE_HOME/out")"
  [ "$(wc -l < "$CASE_HOME/state/.wake-queue" | tr -d ' ')" = 1 ] || fail "busy escalation repeated"
  [ -f "$record" ] || fail "escalation lost the instruction"
  [ ! -e "$CASE_HOME/state/t1.inbox/.ring-state" ] || fail "busy escalation rang the worker"
}

test_advancing_pi_progress() {
  local n
  new_case advancing pi
  for n in 1 2 3 4; do
    advance_progress
    round
    quiet
  done
  # Progress resets, rather than merely suspends, the consecutive frozen budget.
  round
  quiet
  round
  escalated
  round
  escalated
  pass "advancing Pi progress prevents stuck-busy; two frozen rounds then escalate once"
}

test_frozen_pi_ignores_footer_churn() {
  local before after
  new_case frozen pi-signed
  advance_progress
  round
  quiet
  before=$(tmux capture-pane -p -t sess:fm-t1)
  tmux send-keys -t sess:fm-t1 -l 'footer: changed without worker progress'
  after=$(tmux capture-pane -p -t sess:fm-t1)
  [ "$before" != "$after" ] || fail "footer fixture did not change the real capture"
  round
  escalated
  pass "frozen Pi progress escalates at two rounds despite real pane churn"
}

test_missing_capture_counts() {
  local fault
  for fault in missing empty partial; do
    new_case "capture-$fault" pi
    advance_progress
    round "$fault"
    quiet
    advance_progress
    round "$fault"
    escalated
  done
  pass "failed (including partial output) and empty captures still spend the existing busy budget despite progress"
}

test_non_pi_unchanged() {
  new_case non-pi claude
  advance_progress
  round
  quiet
  advance_progress
  tmux send-keys -t sess:fm-t1 -l 'footer: non-Pi changed'
  round
  escalated
  pass "non-Pi busy deferrals retain the original threshold despite progress and pane churn"
}

fm_test_run test_advancing_pi_progress test_frozen_pi_ignores_footer_churn \
  test_missing_capture_counts test_non_pi_unchanged
