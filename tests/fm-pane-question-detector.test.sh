#!/usr/bin/env bash
# Focused public watcher coverage for unfiled questions at turn end.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-pane-question-tests)
WATCH="$ROOT/bin/fm-watch.sh"

export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

watch_turn() {  # <case-dir>: one watcher run until it surfaces the turn end
  local pid
  PATH="$1/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-task FM_FAKE_TMUX_CAPTURE="$1/pane" \
    FM_STATE_OVERRIDE="$1/state" FM_CREW_STATE_BIN="$1/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$1/out" &
  pid=$!
  wait_for_exit "$pid" 100
}

question_counts() {  # <state> -> "<decision-wakes> <nudges>"
  local wakes nudges
  wakes=$(rg -c 'decision-pending task.turn-ended' "$1/.wake-queue" 2>/dev/null || true)
  nudges=$(rg -l 'Your last turn ended on a question' "$1/task.inbox" --glob '*.msg' 2>/dev/null | wc -l | tr -d '[:space:]')
  printf '%s %s' "${wakes:-0}" "$nudges"
}

run_turn() {  # <name> <pane-text> <status-text> <expected-question:0|1>
  local dir state fakebin out pid nudge count
  dir=$(make_case "$1"); state="$dir/state"; fakebin="$dir/fakebin"
  printf '%b\n' "$2" > "$dir/pane"
  printf '%b' "$3" > "$state/task.status"
  printf 'window=test:fm-task\nkind=ship\nharness=codex\n' > "$state/task.meta"
  : > "$state/task.turn-ended"
  watch_turn "$dir" || fail "watcher did not surface turn end in $1"
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
run_turn claude-marker-address "⏺ Captain, please pick one of A or B.$CLAUDE_TAIL" '' 1
run_turn wrapped-address "Captain, the migration can keep the old column or drop it\n  now; pick one before I continue.$PI_TAIL" '' 1
run_turn inline-code-address "Captain, pick which command to run next:\n  \`make migrate-all\`$PI_TAIL" '' 1

# One publication per status position: a second question turn with no status
# growth stays quiet, and any status append re-arms the detector.
test_question_once_per_status_position() {
  local dir state counts
  dir=$(make_case once-per-position); state="$dir/state"
  printf '%b\n' "$ASK$PI_TAIL" > "$dir/pane"
  printf 'working [at=1]: starting\n' > "$state/task.status"
  printf 'window=test:fm-task\nkind=ship\nharness=codex\n' > "$state/task.meta"
  printf 'a' > "$state/task.turn-ended"
  watch_turn "$dir" || fail "first question turn was not surfaced"
  counts=$(question_counts "$state")
  [ "$counts" = '1 1' ] || fail "first question turn should wake and nudge once, saw $counts"
  printf 'ab' > "$state/task.turn-ended"
  watch_turn "$dir" || fail "second question turn was not surfaced"
  counts=$(question_counts "$state")
  [ "$counts" = '1 1' ] || fail "a repeat question with no status growth must stay quiet, saw $counts"
  printf 'working [at=2]: answered the nudge\n' >> "$state/task.status"
  printf 'abc' > "$state/task.turn-ended"
  watch_turn "$dir" || fail "question turn after a status append was not surfaced"
  counts=$(question_counts "$state")
  [ "$counts" = '2 2' ] || fail "a status append must re-arm the detector, saw $counts"
  pass "one decision-pending wake and nudge per status position"
}
test_question_once_per_status_position
