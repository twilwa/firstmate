#!/usr/bin/env bash
# bin/fm-secondmate-sleep.sh: put a persistent second mate to sleep, and wake it,
# on purpose.
#
# What these pin, through the real commands (real fm-send and persist gate, real
# fm-control exit, real liveness relaunch) against the persist-modelling session
# provider shared with the restart suite, plus a mate home whose own watcher and
# listener scripts record when they were called:
#   1. sleep writes the marker only after the agent stopped, then its watcher
#      stopped, then its unbound listeners were retired; a refusal at any of
#      those steps leaves no marker and names the step, and an asleep mate is a
#      no-op.
#   2. sleep refuses a home with in-flight work, an unregistered id, and a remote
#      route before anything is sent or stopped.
#   3. wake removes the marker, relaunches the mate and its still-registered
#      decision-bound listeners, and confirms it live; a wake
#      with no marker is a no-op.
#   4. status reads each registered mate as asleep or awake.
#   5. through the home's real process-event and captain-hold scripts, a
#      decision-bound listener stays registered with its binding while an
#      unbound one is retired.
#   6. a registered id that itself begins with fm- is addressed as itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLEEP="$ROOT/bin/fm-secondmate-sleep.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-sleep)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# shellcheck source=tests/secondmate-persist-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-persist-helpers.sh"

# register_mate <case-dir> <id> [real]: the parent's registry line for a mate
# added by add_local_mate, and that home's own watcher, binding, and listener
# scripts. Each records its argv, the FM_HOME it ran under, whether the agent had
# already been sent its exit command, and how many sleep markers the parent held
# at that moment; it refuses when FM_TEST_FAIL_STEP names its step. The home
# holds one registered process-event source, board, that no captain call is
# bound to. With real, the home instead carries this checkout's own scripts and
# no source, and only its watcher is recorded.
register_mate() {
  local dir=$1 id=$2 smhome="$1/$2-home" script step ok scripts="fm-watch-arm.sh"
  printf -- '- %s - test mate (home: %s; scope: tests; projects: none; added 2026-10-06)\n' \
    "$id" "$smhome" >> "$dir/home/data/secondmates.md"
  if [ "${3:-}" = real ]; then
    cp -R "$ROOT/bin/." "$smhome/bin/"
  else
    scripts="$scripts fm-captain-hold.sh fm-procevent.sh"
    mkdir -p "$smhome/state/procevent"
    printf 'adapter=when\nowner=builtin\n' > "$smhome/state/procevent/board.source"
  fi
  for script in $scripts; do
    case "$script" in
      fm-watch-arm.sh) step=watcher ok=0 ;;
      fm-captain-hold.sh) step=binding ok=1 ;;
      *) step=listeners ok=0 ;;
    esac
    cat > "$smhome/bin/$script" <<SH
#!/usr/bin/env bash
exited=no
grep -qx '/exit' "\$FM_FAKE_DIR/literal" 2>/dev/null && exited=yes
markers=\$(find "\$FM_TEST_PARENT_STATE" -maxdepth 1 -name '*.asleep' | wc -l | tr -d ' ')
printf '%s %s FM_HOME=%s exited=%s markers=%s\n' "\${0##*/}" "\$*" "\$FM_HOME" "\$exited" "\$markers" \\
  >> "\$FM_FAKE_DIR/home-calls"
if [ "\${FM_TEST_FAIL_STEP:-}" = $step ]; then
  echo "$step: FAILED - refused by the test"
  exit 2
fi
exit $ok
SH
    chmod +x "$smhome/bin/$script"
  done
}

# A wake launches a fresh endpoint, which would otherwise auto-detect the Herdr
# session a developer runs this suite from. Pin the tmux stub, drop any inherited
# Herdr identity, and make a stray real herdr call fail instead of landing there.
run_sleep() {  # <case-dir> <args...>
  local dir=$1; shift
  if [ ! -e "$dir/fakebin/herdr" ]; then
    printf '#!/bin/sh\necho "herdr is out of bounds for this suite" >&2\nexit 1\n' > "$dir/fakebin/herdr"
    chmod +x "$dir/fakebin/herdr"
  fi
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_SOCKET_PATH -u HERDR_SESSION FM_BACKEND=tmux \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_TEST_PARENT_STATE="$dir/home/state" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_SPAWN_NO_GUARD=1 FM_SECONDMATE_PERSIST_POLL=1 \
    FM_SECONDMATE_PERSIST_WAIT="${FM_TEST_PERSIST_WAIT:-30}" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$SLEEP" "$@" 2>&1
}

# --- T1: the marker lands only after the agent, watcher, and listeners stop ---
test_sleep_marks_only_after_every_stop() {
  local dir out rc calls doorbell_line exit_line marker
  dir=$(new_case sleep-order)
  add_local_mate "$dir" sm1
  register_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_sleep "$dir" sleep fm-sm1 --by captain --reason 'outside the current focus'); rc=$?

  expect_code 0 "$rc" "a mate that persisted and stopped cleanly should sleep"$'\n'"$out"
  assert_contains "$out" "sm1: asleep since " "the result should say the mate is asleep"
  assert_contains "$out" "(by captain): outside the current focus" "the result should say who asked and why"
  marker="$dir/home/state/sm1.asleep"
  grep -Eqx 'since=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$marker" \
    || fail "the marker must record the UTC time: $(cat "$marker")"
  grep -qx 'by=captain' "$marker" || fail "the marker must record who asked: $(cat "$marker")"
  grep -qx 'reason=outside the current focus' "$marker" || fail "the marker must record why: $(cat "$marker")"
  # The mate was asked to persist before its agent was stopped.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] && [ -n "$exit_line" ] && [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent must be asked to persist and only then stopped: $(cat "$dir/fake/literal")"
  assert_contains "$(cat "$dir/home/state/sm1.inbox"/*.msg)" "Open-record persistence" \
    "the persist request must be the restart's open-record request"
  # Watcher, then the unbound listener, each run in the mate's own home after
  # the agent stopped and before any marker existed.
  calls=$(cat "$dir/fake/home-calls")
  [ "$calls" = "fm-watch-arm.sh --stop FM_HOME=$dir/sm1-home exited=yes markers=0
fm-captain-hold.sh binding board FM_HOME=$dir/sm1-home exited=yes markers=0
fm-procevent.sh retire board FM_HOME=$dir/sm1-home exited=yes markers=0" ] \
    || fail "the watcher and listeners must stop in the mate's home after its agent and before the marker: $calls"

  # Sleeping an asleep mate changes nothing.
  out=$(run_sleep "$dir" sleep sm1 --by firstmate --reason 'again'); rc=$?
  expect_code 0 "$rc" "sleeping an asleep mate is a no-op"$'\n'"$out"
  assert_contains "$out" "sm1: already asleep since " "a repeat sleep should say the mate is already asleep"
  grep -qx 'reason=outside the current focus' "$marker" || fail "a repeat sleep rewrote the marker: $(cat "$marker")"
  [ "$(wc -l < "$dir/fake/home-calls" | tr -d ' ')" -eq 3 ] \
    || fail "a repeat sleep stopped something again: $(cat "$dir/fake/home-calls")"
  pass "T1 sleep persists, then stops the agent, watcher, and listeners, and only then writes the marker"
}

# --- T2: a refusal at any stop step leaves no marker and names the step -------
test_sleep_refusal_leaves_no_marker() {
  local row step armed dir out rc
  for row in agent:no watcher:yes listeners:yes; do
    step=${row%%:*}
    armed=${row#*:}
    dir=$(new_case "refuse-$step")
    add_local_mate "$dir" sm1
    register_mate "$dir" sm1
    [ "$armed" = no ] || arm_answer "$dir" sm1

    out=$(FM_TEST_PERSIST_WAIT=0 FM_TEST_FAIL_STEP="$step" \
      run_sleep "$dir" sleep sm1 --by captain --reason parked); rc=$?

    expect_code 3 "$rc" "a refused $step step must not report a sleep"$'\n'"$out"
    assert_contains "$out" "sm1: refused at $step:" "the refusal must name the $step step"
    [ "$step" != listeners ] || assert_contains "$out" "sm1: refused at listeners: board: " \
      "a listener refusal must name the source"
    assert_absent "$dir/home/state/sm1.asleep" "a sleep refused at $step left a marker"
    case "$step" in
      agent)
        ! grep -qx '/exit' "$dir/fake/literal" || fail "an unconfirmed persist must not stop the agent"
        assert_absent "$dir/fake/home-calls" "an unconfirmed persist must not stop the watcher"
        ;;
      watcher)
        grep -q '^fm-watch-arm.sh --stop ' "$dir/fake/home-calls" || fail "the watcher step was never tried"
        ! grep -q '^fm-procevent.sh' "$dir/fake/home-calls" || fail "a failed watcher stop must not go on to the listeners"
        ;;
    esac
  done
  pass "T2 a refusal at the agent, watcher, or listener step leaves no marker and names the step"
}

# --- T3: refusals before anything is sent or stopped --------------------------
test_sleep_refuses_busy_unregistered_and_remote_mates() {
  local dir out rc
  dir=$(new_case refuse-early)
  add_local_mate "$dir" sm1
  register_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'kind=ship\n' > "$dir/sm1-home/state/fix-login.meta"
  printf -- '- rsm - remote mate (host: lab-host; root: /remote/root; home: /remote/rsm-home; scope: remote work; projects: none; added 2026-10-06)\n' \
    >> "$dir/home/data/secondmates.md"

  out=$(run_sleep "$dir" sleep sm1 ghost rsm --by captain --reason parked); rc=$?

  expect_code 3 "$rc" "refused mates must not report a sleep"$'\n'"$out"
  assert_contains "$out" "sm1: refused at idle: its home has in-flight work: fix-login" \
    "a home with in-flight work must be refused by name"
  assert_contains "$out" "ghost: refused at registered:" "an unregistered id must be refused"
  assert_contains "$out" "rsm: refused at registered: it runs on lab-host" "a remote route must be refused"
  assert_absent "$dir/home/state/sm1.inbox" "a busy mate was asked to persist"
  ! grep -qx '/exit' "$dir/fake/literal" || fail "a busy mate's agent was stopped"
  assert_absent "$dir/fake/home-calls" "a busy mate's watcher or listeners were stopped"
  [ -z "$(find "$dir/home/state" -maxdepth 1 -name '*.asleep')" ] || fail "a refused sleep left a marker"
  pass "T3 a busy home, an unregistered id, and a remote route are refused before anything moves"
}

# --- T4: wake relaunches and clears the marker; no marker is a no-op ----------
# The mate's home carries a decision-bound listener that sleep keeps registered.
# Its command leaves a file each time it runs, so the file appearing only after
# the wake shows the wake itself relaunched it rather than a later watcher cycle;
# the command lingers a few seconds so its launch can prove it took the claim.
test_wake_relaunches_and_clears_marker() {
  local dir out rc smhome ran i=0
  dir=$(new_case wake)
  add_local_mate "$dir" sm1
  register_mate "$dir" sm1 real
  arm_answer "$dir" sm1
  smhome="$dir/sm1-home"
  ran="$dir/held-call-board.ran"
  # shellcheck disable=SC2016 # $1 expands in the listener's own shell.
  FM_HOME="$smhome" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    "$smhome/bin/fm-procevent.sh" register when held-call-board -- \
    sh -c 'touch "$1"; sleep 3' sh "$ran" >/dev/null 2>&1 \
    || fail "could not register held-call-board in the mate's home"
  FM_HOME="$smhome" "$smhome/bin/fm-captain-hold.sh" bind held-call-board >/dev/null 2>&1 \
    || fail "could not bind held-call-board in the mate's home"
  out=$(run_sleep "$dir" sleep sm1 --by captain --reason parked); rc=$?
  expect_code 0 "$rc" "the fixture mate should fall asleep"$'\n'"$out"
  assert_absent "$ran" "the fixture's bound listener ran before the wake"

  out=$(run_sleep "$dir" wake sm1); rc=$?

  expect_code 0 "$rc" "waking an asleep mate should relaunch it"$'\n'"$out"
  assert_contains "$out" "sm1: awake; relaunched" "the wake should report the relaunch"
  assert_absent "$dir/home/state/sm1.asleep" "the wake left the marker in place"
  assert_grep 'relaunched' "$dir/home/state/.secondmate-relaunch-sm1" \
    "the wake should relaunch through the guarded liveness path"
  while [ ! -e "$ran" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  assert_present "$ran" "the wake did not relaunch the mate's still-registered decision-bound listener"
  FM_HOME="$smhome" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    "$smhome/bin/fm-procevent.sh" retire held-call-board >/dev/null 2>&1 \
    || fail "could not stop the relaunched fixture listener"

  out=$(run_sleep "$dir" wake sm1); rc=$?
  expect_code 0 "$rc" "waking an awake mate is a no-op"$'\n'"$out"
  assert_contains "$out" "sm1: not asleep; nothing to wake" "a wake with no marker should say so"
  pass "T4 wake clears the marker, relaunches the mate and its decision-bound listeners, and confirms it live; no marker is a no-op"
}

# --- T5: status reads every registered mate ----------------------------------
test_status_reads_each_registered_mate() {
  local dir out rc
  dir=$(new_case status)
  mkdir -p "$dir/home/data"
  printf -- '- sm1 - one (home: %s/sm1-home; scope: a; projects: none; added 2026-10-06)\n' "$dir" \
    > "$dir/home/data/secondmates.md"
  printf -- '- sm2 - two (home: %s/sm2-home; scope: b; projects: none; added 2026-10-06)\n' "$dir" \
    >> "$dir/home/data/secondmates.md"
  printf 'since=2026-10-06T12:00:00Z\nby=captain\nreason=parked\n' > "$dir/home/state/sm2.asleep"

  out=$(run_sleep "$dir" status); rc=$?
  expect_code 0 "$rc" "status over registered mates should succeed"$'\n'"$out"
  [ "$out" = "sm1: awake
sm2: asleep since 2026-10-06T12:00:00Z (by captain): parked" ] \
    || fail "status should list every registered mate in registry order: $out"

  out=$(run_sleep "$dir" status ghost); rc=$?
  expect_code 3 "$rc" "status for an unknown id should not pass silently"$'\n'"$out"
  assert_contains "$out" "ghost: not a second mate registered in" "status should name an unknown id"
  pass "T5 status reads each registered mate as asleep or awake"
}

# --- T6: a decision-bound listener stays armed; an unbound one is retired ----
test_sleep_keeps_decision_bound_listeners() {
  local dir out rc smhome src
  dir=$(new_case bound-listeners)
  add_local_mate "$dir" sm1
  register_mate "$dir" sm1 real
  arm_answer "$dir" sm1
  smhome="$dir/sm1-home"
  for src in held-call-board idle-board; do
    FM_HOME="$smhome" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
      "$smhome/bin/fm-procevent.sh" register when "$src" -- true >/dev/null 2>&1 \
      || fail "could not register $src in the mate's home"
  done
  FM_HOME="$smhome" "$smhome/bin/fm-captain-hold.sh" bind held-call-board >/dev/null 2>&1 \
    || fail "could not bind held-call-board in the mate's home"

  out=$(run_sleep "$dir" sleep sm1 --by captain --reason parked); rc=$?

  expect_code 0 "$rc" "a mate with only owner-retirable unbound listeners should sleep"$'\n'"$out"
  assert_contains "$out" "sm1: asleep since " "the result should say the mate is asleep"
  assert_present "$smhome/state/procevent/held-call-board.source" \
    "sleep retired a listener a held captain call is bound to"
  [ "$(FM_HOME="$smhome" "$smhome/bin/fm-captain-hold.sh" binding held-call-board 2>&1)" = '(any)' ] \
    || fail "sleep dropped the held call's answer binding"
  assert_absent "$smhome/state/procevent/idle-board.source" "sleep left an unbound listener registered"
  pass "T6 sleep keeps decision-bound listeners armed with their binding and retires unbound ones"
}

# --- T7: a registered id beginning with fm- is addressed as itself ------------
test_fm_prefixed_registered_id_is_its_own() {
  local dir out rc
  dir=$(new_case fm-prefixed)
  add_local_mate "$dir" fm-sm2
  register_mate "$dir" fm-sm2
  arm_answer "$dir" fm-sm2

  out=$(run_sleep "$dir" sleep fm-sm2 --by captain --reason parked); rc=$?

  expect_code 0 "$rc" "a registered fm- id should sleep under its own id"$'\n'"$out"
  assert_contains "$out" "fm-sm2: asleep since " "the result should name the registered id"
  assert_present "$dir/home/state/fm-sm2.asleep" "the marker must be written under the registered id"
  assert_absent "$dir/home/state/sm2.asleep" "the registered id was rewritten as a selector"
  pass "T7 a registered id that begins with fm- is addressed as itself"
}

test_sleep_marks_only_after_every_stop
test_sleep_refusal_leaves_no_marker
test_sleep_refuses_busy_unregistered_and_remote_mates
test_wake_relaunches_and_clears_marker
test_status_reads_each_registered_mate
test_sleep_keeps_decision_bound_listeners
test_fm_prefixed_registered_id_is_its_own

echo "# all fm-secondmate-sleep tests passed"
