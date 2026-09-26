#!/usr/bin/env bash
# Focused public watcher coverage for unfiled questions at turn end.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-pane-question-tests)
WATCH="$ROOT/bin/fm-watch.sh"

run_turn() {  # <name> <pane-text> <status-text> <expected-question:0|1>
  local dir state fakebin out pid nudge count
  dir=$(make_case "$1"); state="$dir/state"; fakebin="$dir/fakebin"
  printf '%b\n' "$2" > "$dir/pane"
  printf '%b' "$3" > "$state/task.status"
  printf 'window=test:fm-task\nkind=ship\nharness=codex\n' > "$state/task.meta"
  : > "$state/task.turn-ended"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-task FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface turn end in $1"
  out=$(cat "$state/.wake-queue")
  nudge=$(rg -l 'Your last turn ended on a question' "$state/task.inbox" --glob '*.msg' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "$4" -eq 1 ]; then
    case "$out" in *'decision-pending task.turn-ended'*) ;; *) fail "missing decision-pending reason in $1: $out" ;; esac
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain" 2>/dev/null \
      || fail "cannot drain decision-pending event in $1"
    rg -q 'decision-pending task.turn-ended' "$dir/drain" \
      || fail "decision-pending event hidden in drain for $1"
    [ "$nudge" -eq 1 ] || fail "expected one nudge in $1, saw $nudge"
  else
    case "$out" in *'decision-pending'*) fail "false question in $1: $out" ;; esac
    [ "$nudge" -eq 0 ] || fail "unexpected nudge in $1"
  fi
  # The exact same marker is not a second turn. A new watcher must stay quiet.
  [ -s "$state/.seen-task_turn-ended" ] || fail "turn marker uncommitted in $1: $(ls -a "$state")"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-task FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/again" &
  pid=$!
  sleep 3
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  count=$(rg -c 'decision-pending task.turn-ended' "$state/.wake-queue" 2>/dev/null || true)
  [ "${count:-0}" -le 1 ] || fail "repeated decision wake in $1: $(cat "$state/.wake-queue")"
  nudge=$(rg -l 'Your last turn ended on a question' "$state/task.inbox" --glob '*.msg' 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "$nudge" -eq "$4" ] || fail "repeated nudge in $1"
  pass "$1"
}

# Trailing prompt and footer rows as each harness draws them at turn end, in
# the shapes tests/fm-composer-lib.test.sh pins for the composer owner.
NBSP=$(printf '\302\240')
RULE='────────────────────────'
PI_TAIL="\n$RULE\n\n$RULE\n ~/repo (fm/branch)\n ↑1.2k ↓3.4k \$0.05 12%/200k"
CLAUDE_TAIL="\n$RULE\n❯$NBSP\n$RULE\n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
CODEX_TAIL='\n\n› Use /skills to list available skills\n\n  gpt-5.5 high · ~/repo'
ASK='Would you like me to change this?'

run_turn pi-question "$ASK$PI_TAIL" '' 1
run_turn pi-summary "Implementation complete.$PI_TAIL" '' 0
run_turn claude-question "$ASK$CLAUDE_TAIL" '' 1
run_turn claude-summary "Implementation complete.$CLAUDE_TAIL" '' 0
run_turn codex-question "$ASK$CODEX_TAIL" '' 1
run_turn codex-summary "Implementation complete.$CODEX_TAIL" '' 0
run_turn unsplittable "$ASK" '' 0
run_turn keyed "$ASK$PI_TAIL" 'needs-decision [at=123] [key=choice]: Choose the path\n' 0
run_turn fenced "\`\`\`\n$ASK\n\`\`\`$PI_TAIL" '' 0
run_turn quoted "> $ASK$PI_TAIL" '' 0
run_turn log-quote "\"$ASK\"$PI_TAIL" '' 0
run_turn address "Captain, please pick one.$PI_TAIL" '' 1
run_turn captain-possessive "The captain's requested change is implemented.$PI_TAIL" '' 0
run_turn captain-mention "Ready for the captain to review.$PI_TAIL" '' 0
