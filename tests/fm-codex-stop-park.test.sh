#!/usr/bin/env bash
# Behavior tests for the synchronous Codex Stop-hook watcher park.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-stop-park)
FAKE_CODEX="$TMP_ROOT/codex"
ln -s /bin/bash "$FAKE_CODEX"
fm_git_identity fmtest fmtest@example.invalid

install_park() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/config" "$dir/data" "$dir/.codex"
  cp "$ROOT/bin/fm-codex-stop-park.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-supervision-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" \
    "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-cursor-lib.sh" \
    "$ROOT/bin/fm-operational-input.sh" \
    "$ROOT/bin/fm-turnend-guard.sh" \
    "$ROOT/bin/fm-supervision-instructions.sh" \
    "$ROOT/bin/fm-harness.sh" \
    "$ROOT/bin/fm-hook-host-lib.sh" \
    "$dir/bin/"
  chmod +x "$dir/bin/"*.sh
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"fm-codex-stop-park.sh"}]}]}}\n' > "$dir/.codex/hooks.json"
}

make_primary() {
  local dir=$1
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_park "$dir"
}

run_park() { # <dir> <stop-active>
  local dir=$1 active=$2 payload
  payload=$(printf '{"hook_event_name":"Stop","session_id":"codex-test","stop_hook_active":%s}' "$active")
  FM_HOME="$dir" PAYLOAD="$payload" FM_CODEX_PARK_POLL=1 "$FAKE_CODEX" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s" "$PAYLOAD" | "$FM_HOME/bin/fm-codex-stop-park.sh"
  '
}

write_arm_actionable() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: crew.status\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

write_arm_wait_for_trigger() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/arm-started"
printf '%s\n' "$$" > "$FM_HOME/state/arm-pid"
while [ ! -e "$FM_HOME/state/trigger" ]; do sleep 0.1; done
printf 'signal: delayed.status\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

write_arm_failure() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: FAILED - fixture\n'
exit 1
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

test_no_work_ends_without_arming() {
  local dir="$TMP_ROOT/no-work" out status=0
  make_primary "$dir"
  write_arm_actionable "$dir"
  out=$(run_park "$dir" false 2>&1) || status=$?
  expect_code 0 "$status" "idle Codex park"
  [ -z "$out" ] || fail "idle Codex park produced output: $out"
  assert_absent "$dir/state/arm-ran" "idle Codex park launched an arm"
  pass "Codex park: no supervision need ends silently without arming"
}

test_actionable_wake_resumes_through_same_hook() {
  local dir="$TMP_ROOT/actionable" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_actionable "$dir"
  out=$(run_park "$dir" false 2>&1) || status=$?
  expect_code 2 "$status" "actionable Codex park"
  assert_contains "$out" "FIRSTMATE_OP: v1 watcher:" "actionable wake lost operational provenance"
  assert_contains "$out" "signal: crew.status" "actionable wake reason was not returned"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" = 1 ] || fail "Codex park launched more than one arm"
  pass "Codex park: an actionable watcher close exits 2 through the same Stop hook"
}

test_stop_active_does_not_suppress_real_wake() {
  local dir="$TMP_ROOT/active-wake" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_actionable "$dir"
  out=$(run_park "$dir" true 2>&1) || status=$?
  expect_code 2 "$status" "continued-turn actionable Codex park"
  assert_contains "$out" "signal: crew.status" "stop_hook_active suppressed a real watcher wake"
  pass "Codex park: stop_hook_active bounds repair loops but never suppresses a real wake"
}

test_park_waits_in_hook_until_event() {
  local dir="$TMP_ROOT/delayed" out="$TMP_ROOT/delayed.out" pid status=0 i=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_wait_for_trigger "$dir"
  run_park "$dir" false > "$out" 2>&1 &
  pid=$!
  while [ ! -e "$dir/state/arm-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$dir/state/arm-started" ] || fail "Codex park never started its tracked arm child"
  kill -0 "$pid" 2>/dev/null || fail "Codex park returned before its watcher event"
  : > "$dir/state/trigger"
  wait "$pid" || status=$?
  expect_code 2 "$status" "delayed Codex park"
  assert_contains "$(cat "$out")" "signal: delayed.status" "delayed watcher event was not returned"
  pass "Codex park: the synchronous Stop hook stays attached until its watcher event"
}

test_away_mode_stands_down() {
  local dir="$TMP_ROOT/away" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  write_arm_actionable "$dir"
  out=$(run_park "$dir" false 2>&1) || status=$?
  expect_code 0 "$status" "away-mode Codex park"
  [ -z "$out" ] || fail "away-mode Codex park produced output: $out"
  assert_absent "$dir/state/arm-ran" "away-mode Codex park competed with the daemon"
  pass "Codex park: away and quiet mode retain daemon ownership"
}

test_failure_uses_bounded_shared_guard() {
  local dir="$TMP_ROOT/failure" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_failure "$dir"
  out=$(run_park "$dir" false 2>&1) || status=$?
  expect_code 2 "$status" "initial failed Codex park"
  assert_contains "$out" "TURN WOULD END BLIND" "failed park omitted the shared alarm"
  assert_contains "$out" "Codex Stop-hook watcher park failed" "failed park used the wrong repair protocol"
  status=0
  out=$(run_park "$dir" true 2>&1) || status=$?
  expect_code 0 "$status" "repeated failed Codex park"
  [ -z "$out" ] || fail "repeated failed park created an unbounded repair loop: $out"
  pass "Codex park: a task exception gets one bounded repair continuation"
}

test_beacons_do_not_mask_a_failed_park() {
  local age dir out status label
  for age in fresh stale; do
    dir="$TMP_ROOT/beacon-$age"
    make_primary "$dir"
    : > "$dir/state/task.meta"
    : > "$dir/state/.last-watcher-beat"
    if [ "$age" = stale ]; then
      touch -t 200001010000 "$dir/state/.last-watcher-beat"
    fi
    write_arm_failure "$dir"
    status=0
    out=$(run_park "$dir" false 2>&1) || status=$?
    label="$age-beacon failed Codex park"
    expect_code 2 "$status" "$label"
    assert_contains "$out" "TURN WOULD END BLIND" "$label was mistaken for a continuation callback"
  done
  pass "Codex park: neither a fresh nor stale beacon masks a missing callback"
}

test_quiet_park_renews_before_native_timeout() {
  local dir="$TMP_ROOT/renew" out status=0 started ended
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_wait_for_trigger "$dir"
  started=$(date +%s)
  out=$(FM_CODEX_PARK_RENEW_SECONDS=2 run_park "$dir" false 2>&1) || status=$?
  ended=$(date +%s)
  expect_code 2 "$status" "scheduled Codex park renewal"
  assert_contains "$out" "FIRSTMATE_OP: v1 turn-end-guard:" "park renewal lost operational provenance"
  assert_contains "$out" "WATCHER PARK RENEWAL" "park renewal did not explain the callback rollover"
  [ $((ended - started)) -ge 2 ] || fail "park renewal returned before its interval"
  [ $((ended - started)) -lt 10 ] || fail "park renewal did not bound the quiet watcher wait"
  pass "Codex park: a quiet watcher renews its callback before the native hook timeout"
}

test_newer_stop_supersedes_older_park() {
  local dir="$TMP_ROOT/supersede" out1="$TMP_ROOT/supersede-1.out" out2="$TMP_ROOT/supersede-2.out"
  local result="$TMP_ROOT/supersede-result" payload
  make_primary "$dir"
  : > "$dir/state/task.meta"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$BASHPID" >> "$FM_HOME/state/arm-pids"
while [ ! -e "$FM_HOME/state/trigger" ]; do sleep 0.1; done
printf 'signal: superseded.status\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  payload='{"hook_event_name":"Stop","session_id":"codex-test","stop_hook_active":false}'
  FM_HOME="$dir" PAYLOAD="$payload" OUT1="$out1" OUT2="$out2" RESULT="$result" \
    FM_CODEX_PARK_POLL=1 "$FAKE_CODEX" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$PAYLOAD" | "$FM_HOME/bin/fm-codex-stop-park.sh" > "$OUT1" 2>&1 &
      first=$!
      i=0
      while [ ! -s "$FM_HOME/state/arm-pids" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      printf "%s" "$PAYLOAD" | "$FM_HOME/bin/fm-codex-stop-park.sh" > "$OUT2" 2>&1 &
      second=$!
      i=0
      while [ "$(wc -l < "$FM_HOME/state/arm-pids" 2>/dev/null || printf 0)" -lt 2 ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      : > "$FM_HOME/state/trigger"
      rc1=0; wait "$first" || rc1=$?
      rc2=0; wait "$second" || rc2=$?
      printf "%s %s\n" "$rc1" "$rc2" > "$RESULT"
    '
  [ "$(cat "$result")" = "0 2" ] || fail "superseded parks returned unexpected statuses: $(cat "$result")"
  [ ! -s "$out1" ] || fail "the superseded park emitted a duplicate continuation: $(cat "$out1")"
  assert_contains "$(cat "$out2")" "signal: superseded.status" "the newest park lost the watcher event"
  pass "Codex park: a newer Stop supersedes the older park without a duplicate wake"
}

test_live_foreign_owner_is_not_replaced() {
  local dir="$TMP_ROOT/foreign" payload out status=0 owner
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_actionable "$dir"
  /bin/bash -c 'exec -a codex sleep 20' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"
  payload='{"hook_event_name":"Stop","session_id":"foreign","stop_hook_active":false}'
  out=$(FM_HOME="$dir" PAYLOAD="$payload" "$FAKE_CODEX" -c '
    printf "%s" "$PAYLOAD" | "$FM_HOME/bin/fm-codex-stop-park.sh"
  ' 2>&1) || status=$?
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  expect_code 0 "$status" "foreign-owner Codex park"
  assert_contains "$out" "OWNED BY ANOTHER LIVE SESSION" "foreign-owner diagnostic missing"
  [ "$(cat "$dir/state/.lock")" = "$owner" ] || fail "Codex park replaced the foreign session lock"
  assert_absent "$dir/state/arm-ran" "Codex park armed under a foreign live owner"
  pass "Codex park: a foreign live session owner is preserved"
}

test_worker_worktree_is_exempt() {
  local base="$TMP_ROOT/worker-base" dir="$TMP_ROOT/worker" out status=0
  fm_git_worktree "$base" "$dir" fm/codex-park-worker
  : > "$dir/AGENTS.md"
  install_park "$dir"
  : > "$dir/state/task.meta"
  write_arm_actionable "$dir"
  out=$(run_park "$dir" false 2>&1) || status=$?
  expect_code 0 "$status" "worker-worktree Codex park"
  [ -z "$out" ] || fail "worker-worktree Codex park produced output: $out"
  assert_absent "$dir/state/arm-ran" "worker-worktree Codex park armed primary supervision"
  pass "Codex park: an unmarked worker-only worktree remains exempt"
}

test_cancellation_retires_arm_child() {
  local dir="$TMP_ROOT/cancel" out="$TMP_ROOT/cancel.out" pid park_pid arm_pid i=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_wait_for_trigger "$dir"
  run_park "$dir" false > "$out" 2>&1 &
  pid=$!
  while [ ! -e "$dir/state/arm-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$dir/state/arm-started" ] || fail "cancellation fixture never started"
  park_pid=$(sed -n 's/^seq=[0-9][0-9]* pid=\([0-9][0-9]*\) .*/\1/p' "$dir/state/.codex-park-owner")
  arm_pid=$(cat "$dir/state/arm-pid")
  kill -TERM "$park_pid"
  wait "$pid" 2>/dev/null || true
  [ -z "$arm_pid" ] || ! kill -0 "$arm_pid" 2>/dev/null || fail "cancelled Codex park left its arm child alive"
  if compgen -G "$dir/state/.codex-park-output.*" >/dev/null; then
    fail "cancelled Codex park left a capture file"
  fi
  pass "Codex park: user cancellation retires the tracked arm child"
}

test_no_work_ends_without_arming
test_actionable_wake_resumes_through_same_hook
test_stop_active_does_not_suppress_real_wake
test_park_waits_in_hook_until_event
test_away_mode_stands_down
test_failure_uses_bounded_shared_guard
test_beacons_do_not_mask_a_failed_park
test_quiet_park_renews_before_native_timeout
test_newer_stop_supersedes_older_park
test_live_foreign_owner_is_not_replaced
test_worker_worktree_is_exempt
test_cancellation_retires_arm_child

echo "# all fm-codex-stop-park tests passed"
