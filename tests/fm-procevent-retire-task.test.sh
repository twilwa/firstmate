#!/usr/bin/env bash
# Task-owner retirement guards through the process-event command interface.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$ROOT/bin/fm-procevent-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-retire-task)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

# Seed an idle registration without launching a runner or a real board.
HOME_FIXTURE="$TMP_ROOT/home"
mkdir -p "$HOME_FIXTURE/state"
fm_procevent_task_registration_publish_locked "$HOME_FIXTURE/state" lavish board worker-a /bin/true
out=$(FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-procevent.sh" retire board --if-owner worker-a) \
  || fail "matching task owner could not retire its board: $out"
assert_contains "$out" 'retired: board' 'retirement outcome'
out=$(FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$out" 'no sources registered' 'retired task source remains registered'
pass 'matching task owner retires its process-event source'

fm_procevent_task_registration_publish_locked "$HOME_FIXTURE/state" lavish board worker-a /bin/true
if out=$(FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-procevent.sh" retire board --if-owner worker-b 2>&1); then
  fail 'a different task owner retired the board'
fi
assert_contains "$out" 'source registration does not match the expected owner: board' 'wrong-owner refusal'
out=$(FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$out" 'task:worker-a/dead' 'wrong-owner refusal lost the source'
pass 'a different task owner cannot retire a process-event source'
