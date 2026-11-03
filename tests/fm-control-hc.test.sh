#!/usr/bin/env bash
# Lifecycle control through the public CLI with a hermetic fake hc.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FM_TEST_ROOT=$ROOT
TMP_ROOT=$(fm_test_tmproot fm-control-hc)
# shellcheck source=tests/hc-fake-fixture.sh
. "$ROOT/tests/hc-fake-fixture.sh"

run_hc_control() {  # <task> <verb>...
  env -u FM_ROOT_OVERRIDE \
    FAKE_HC_DIR="$D" PATH="$FB:$PATH" FM_HC_BIN="$FB/hc" FM_HOME="$HOMEDIR" \
    FM_STATE_OVERRIDE="$HOMEDIR/state" FM_DATA_OVERRIDE="$HOMEDIR/data" \
    HOME="$D/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.1 FM_CONTROL_LAUNCH_WAIT=0.1 \
    bash "$FM_TEST_ROOT/bin/fm-control.sh" "$@" 2>&1
}

seed_task() {  # <id> <kind> <worktree> <project>
  mkdir -p "$HOMEDIR/state" "$HOMEDIR/data/$1" "$D/user-home"
  printf '# Task\nPreserve this hc task.\n' > "$HOMEDIR/data/$1/brief.md"
  printf 'window=fmtest:t2\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=%s\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nbackend=hc\nhc_session=fmtest\nhc_terminal=t2\n' \
    "$1" "$3" "$4" "$2" > "$HOMEDIR/state/$1.meta"
}

empty_screen() {
  printf '╭────────────────────────╮\n│                        │\n╰────────────────────────╯\n' > "$D/screen"
}

seed_relaunch() {  # <id>
  local tag
  setup_case relaunch
  mkdir -m 700 "/tmp/fm-$1" || fail "could not reserve the unique task temp directory"
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$1")
  tag=$(hometag_of)
  fm_git_worktree "$D/proj" "$D/wt" "task-$1"
  printf 'unfinished work\n' > "$D/wt/draft.txt"
  seed_task "$1" ship "$D/wt" "$D/proj"
  printf '# Task\n## Captain\x27s intent\nExercise hc relaunch.\n\n## Firstmate spec\nPreserve unfinished work.\n' > "$HOMEDIR/data/$1/brief.md"
  write_terminal "$D" t2 live "fm-$1" "$tag" bash /bin/bash
  jq --arg cwd "$D/wt" '.cwd=$cwd | .foreground.cwd=$cwd' "$D/t2.json" > "$D/cwd.json"
  mv "$D/cwd.json" "$D/t2.json"
  touch "$D/relaunch-starts-agent"
}

test_relaunch_reuses_identity_and_preserves_work() {
  local out rc=0 id="hcrelaunch-$$-$RANDOM" before launchdir
  seed_relaunch "$id"
  before=$(git -C "$D/wt" rev-parse HEAD)
  out=$(run_hc_control "$id" relaunch --note 'continue unfinished work') || rc=$?
  for launchdir in "/tmp/fm-$id"+*; do
    [ ! -d "$launchdir" ] || FM_TEST_CLEANUP_DIRS+=("$launchdir")
  done
  expect_code 0 "$rc" "hc relaunch from a stopped shell should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched $id harness=claude from=claude" "replacement must be confirmed"
  grep -Fx 'window=fmtest:t2' "$HOMEDIR/state/$id.meta" >/dev/null || fail 'relaunch changed the recorded endpoint'
  grep -Fx 'hc_session=fmtest' "$HOMEDIR/state/$id.meta" >/dev/null || fail 'relaunch changed the hc session'
  grep -Fx 'hc_terminal=t2' "$HOMEDIR/state/$id.meta" >/dev/null || fail 'relaunch changed the hc terminal'
  assert_equals "$(git -C "$D/wt" rev-parse HEAD)" "$before" "relaunch must not change the branch HEAD"
  assert_equals "$(cat "$D/wt/draft.txt")" 'unfinished work' "unfinished work must survive"
  assert_not_contains "$(cat "$D/log")" $'\x1frun\x1f' "relaunch must not create another terminal"
  assert_not_contains "$(cat "$D/log")" $'\x1frm\x1f' "relaunch must not remove the terminal"
  pass "hc: relaunch reuses endpoint and work"
}

test_relaunch_refuses_missing_finished_and_unreadable() {
  local out rc state id=hcmissing1 tag
  setup_case relaunch-refusals
  tag=$(hometag_of)
  fm_git_worktree "$D/proj" "$D/wt" "task-$id"
  seed_task "$id" ship "$D/wt" "$D/proj"
  # These records cannot prove that the address is recoverable. hc has no
  # authorized rebind proof yet; no launch or lifecycle input is permissible.
  for state in absent finished unreadable; do
    case "$state" in
      absent) rm -f "$D/t2.json" ;;
      finished) write_terminal "$D" t2 finished "fm-$id" "$tag" '' '' ;;
      unreadable) printf '1\n' > "$D/t2.exit" ;;
    esac
    : > "$D/log"; rc=0
    out=$(run_hc_control "$id" relaunch --note 'preserve identity on refusal') || rc=$?
    expect_code 1 "$rc" "$state endpoint must refuse rather than rebind"$'\n'"$out"
    case "$state" in
      absent|finished) assert_contains "$out" 'hc absence cannot be proven' 'refusal must come from endpoint-absence proof' ;;
      unreadable) assert_contains "$out" unreadable 'core read failure must be the reason for refusing' ;;
    esac
    assert_not_contains "$(cat "$D/log")" $'\x1frun\x1f' "$state must not mint a terminal"
    assert_not_contains "$(cat "$D/log")" $'\x1fsend\x1f' "$state must get no lifecycle input"
  done
  pass "hc: missing, finished, and unreadable refuse rebind"
}

test_exit_proves_stopped_and_preserves_terminal() {
  local tag out rc=0 id=hcexit1
  setup_case exit
  tag=$(hometag_of)
  write_terminal "$D" t2 live "fm-$id" "$tag" claude claude
  seed_task "$id" scout "$D" "$D"
  empty_screen
  touch "$D/exit-stops-agent"
  out=$(run_hc_control "$id" exit) || rc=$?
  expect_code 0 "$rc" "exit should prove the shell returned"$'\n'"$out"
  out=$(grep $'send\x1f' "$D/log")
  assert_contains "$out" $'send\x1f--json\x1ft2\x1f' "exit must use the recorded terminal"
  assert_contains "$out" $'\x1f--\x1f/exit' "exit must submit the harness exit command"
  assert_not_contains "$(cat "$D/log")" $'\x1fkill\x1f' "agent exit must preserve its terminal"
  assert_equals "$(hc_shell 'fm_backend_agent_state hc fmtest:t2')" dead "the shell, not just command acceptance, proves stopped"
  # A successful send acknowledgement alone is not a stop postcondition.
  write_terminal "$D" t2 live "fm-$id" "$tag" claude claude
  rm -f "$D/exit-stops-agent"
  rc=0; out=$(run_hc_control "$id" exit) || rc=$?
  expect_code 1 "$rc" "accepted exit text with an agent still alive must refuse"$'\n'"$out"
  assert_contains "$out" 'exit=unconfirmed' "the refused postcondition must be explicit"
  assert_equals "$(hc_shell 'fm_backend_agent_state hc fmtest:t2')" alive "unconfirmed exit must not fabricate a stopped state"
  pass "hc: control exit proves stopped without killing the terminal; send acceptance alone cannot prove it"
}

test_exit_refuses_without_safe_composer_or_process_proof() {
  local tag out rc screen state id=hcrefuse1
  setup_case exit-refusals
  tag=$(hometag_of)
  seed_task "$id" scout "$D" "$D"
  for screen in pending unknown; do
    write_terminal "$D" t2 live "fm-$id" "$tag" claude claude
    if [ "$screen" = pending ]; then
      printf '╭────────────────────────╮\n│ keep this draft        │\n╰────────────────────────╯\n' > "$D/screen"
    else
      printf 'unrecognized composer\n' > "$D/screen"
    fi
    : > "$D/log"
    rc=0; out=$(run_hc_control "$id" exit) || rc=$?
    expect_code 1 "$rc" "$screen composer must refuse"$'\n'"$out"
    assert_not_contains "$(cat "$D/log")" $'\x1fsend\x1f' "unsafe composer must get no exit text"
  done
  empty_screen
  for state in ambiguous unreadable foreign foreign-shell; do
    rm -f "$D/t2.exit"
    write_terminal "$D" t2 live "fm-$id" "$tag" unknown-program /bin/unknown-program
    case "$state" in
      unreadable) printf '1\n' > "$D/t2.exit" ;;
      foreign) write_terminal "$D" t2 live fm-other "$tag" claude claude ;;
      foreign-shell) write_terminal "$D" t2 live fm-other "$tag" bash /bin/bash ;;
    esac
    : > "$D/log"
    rc=0; out=$(run_hc_control "$id" exit) || rc=$?
    expect_code 1 "$rc" "$state state must refuse"$'\n'"$out"
    assert_not_contains "$(cat "$D/log")" $'\x1fsend\x1f' "$state terminal must get no exit text"
  done
  pass "hc: pending, unknown, ambiguous, unreadable, and foreign refuse before input"
}

fm_test_run \
  test_exit_proves_stopped_and_preserves_terminal \
  test_relaunch_reuses_identity_and_preserves_work \
  test_relaunch_refuses_missing_finished_and_unreadable \
  test_exit_refuses_without_safe_composer_or_process_proof
