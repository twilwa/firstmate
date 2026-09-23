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
  # shellcheck disable=SC2016 # The child shell expands the single-quoted program.
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

test_stuck_owner_lock_reports_visible_failure() {
  local dir="$TMP_ROOT/stuck-owner-lock" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  mkdir "$dir/state/.codex-park-owner.lock"
  write_arm_actionable "$dir"
  out=$(FM_CODEX_PARK_LOCK_ATTEMPTS=1 run_park "$dir" false 2>&1) || status=$?
  expect_code 0 "$status" "stuck owner-lock Codex park"
  assert_contains "$out" "WATCHER PARK FAILED" "stuck owner lock ended required supervision silently"
  assert_contains "$out" "owner lock could not be acquired" "stuck owner-lock diagnostic lost its cause"
  assert_absent "$dir/state/arm-ran" "stuck owner-lock park armed without publishing ownership"
  pass "Codex park: a stuck owner lock fails visibly before arming"
}

test_owner_publication_failure_reports_visible_failure() {
  local dir="$TMP_ROOT/owner-publication" fake_bin="$TMP_ROOT/owner-publication-bin" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_actionable "$dir"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/mv" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in
  */.codex-park-owner) exit 1 ;;
esac
exec /bin/mv "$@"
SH
  chmod +x "$fake_bin/mv"
  out=$(PATH="$fake_bin:$PATH" run_park "$dir" false 2>&1) || status=$?
  expect_code 0 "$status" "owner-publication Codex park"
  assert_contains "$out" "WATCHER PARK FAILED" "owner publication failure ended required supervision silently"
  assert_contains "$out" "owner record could not be published" "owner-publication diagnostic lost its cause"
  assert_absent "$dir/state/arm-ran" "owner-publication failure armed without an owner record"
  pass "Codex park: owner publication failure remains visible"
}

test_delivery_lock_failure_reports_visible_failure() {
  local dir="$TMP_ROOT/delivery-lock" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
mkdir "$FM_HOME/state/.codex-park-owner.lock"
cp "$FM_HOME/state/.lock" "$FM_HOME/state/.codex-park-owner.lock/pid"
printf 'signal: delivery-lock.status\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(FM_CODEX_PARK_LOCK_ATTEMPTS=1 run_park "$dir" false 2>&1) || status=$?
  expect_code 0 "$status" "delivery-lock Codex park"
  assert_contains "$out" "WATCHER PARK FAILED" "delivery-lock failure discarded an actionable wake silently"
  assert_contains "$out" "actionable-wake delivery lock" "delivery-lock diagnostic lost its cause"
  pass "Codex park: actionable-wake delivery lock failure remains visible"
}

test_failure_episode_survives_active_stop_and_stays_bounded() {
  local dir="$TMP_ROOT/failure" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_failure "$dir"
  # shellcheck disable=SC2016 # The child shell expands the single-quoted program.
  out=$(FM_HOME="$dir" "$FAKE_CODEX" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    for attempt in 1 2 3 4; do
      status=0
      printf "{\"hook_event_name\":\"Stop\",\"session_id\":\"codex-test\",\"stop_hook_active\":true}" \
        | "$FM_HOME/bin/fm-codex-stop-park.sh" 2>&1 || status=$?
      printf "status=%s\n" "$status"
    done
  ' 2>&1) || status=$?
  expect_code 0 "$status" "bounded Codex park failure episode fixture"
  for attempt in 1 2 3; do
    assert_contains "$out" "repair attempt $attempt of 3" "active Stop suppressed failed park attempt $attempt"
  done
  [ "$(printf '%s\n' "$out" | grep -c '^status=2$')" = 3 ] \
    || fail "bounded failure episode did not return exactly three repair continuations: $out"
  assert_contains "$out" "status=0" "exhausted Codex park failure episode did not end"
  assert_contains "$out" "FAILURE BUDGET EXHAUSTED" "bounded fail-open was silent"
  pass "Codex park: failures after an active Stop retry deterministically to a visible finite bound"
}

test_replacement_session_gets_its_own_failure_episode() {
  local dir="$TMP_ROOT/replacement-failure" first_out out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_failure "$dir"
  # shellcheck disable=SC2016 # The child shell expands the single-quoted program.
  first_out=$(FM_HOME="$dir" "$FAKE_CODEX" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    for _ in 1 2 3 4; do
      printf "{\"hook_event_name\":\"Stop\",\"session_id\":\"first\",\"stop_hook_active\":true}" \
        | "$FM_HOME/bin/fm-codex-stop-park.sh" 2>&1 || true
    done
  ' 2>&1)
  assert_contains "$first_out" "FAILURE BUDGET EXHAUSTED" "first session did not exhaust its failure episode"
  out=$(run_park "$dir" true 2>&1) || status=$?
  expect_code 2 "$status" "replacement-session failed Codex park"
  assert_contains "$out" "repair attempt 1 of 3" "replacement session inherited the prior owner's exhausted failure budget"
  pass "Codex park: a replacement session receives its own bounded failure episode"
}

test_real_wake_resets_failure_episode() {
  local dir="$TMP_ROOT/failure-reset" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_failure "$dir"
  # shellcheck disable=SC2016 # The child shell expands the single-quoted program.
  out=$(FM_HOME="$dir" "$FAKE_CODEX" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    payload="{\"hook_event_name\":\"Stop\",\"session_id\":\"codex-test\",\"stop_hook_active\":true}"
    printf "%s" "$payload" | "$FM_HOME/bin/fm-codex-stop-park.sh" 2>&1 || true
    cat > "$FM_HOME/bin/fm-watch-arm.sh" <<'"'"'SH'"'"'
#!/usr/bin/env bash
printf "signal: crew.status\n"
SH
    chmod +x "$FM_HOME/bin/fm-watch-arm.sh"
    printf "%s" "$payload" | "$FM_HOME/bin/fm-codex-stop-park.sh" 2>&1 || true
    cat > "$FM_HOME/bin/fm-watch-arm.sh" <<'"'"'SH'"'"'
#!/usr/bin/env bash
printf "watcher: FAILED - fixture\n"
exit 1
SH
    chmod +x "$FM_HOME/bin/fm-watch-arm.sh"
    printf "%s" "$payload" | "$FM_HOME/bin/fm-codex-stop-park.sh" 2>&1 || true
  ' 2>&1) || status=$?
  expect_code 0 "$status" "same-session wake-reset fixture"
  assert_contains "$out" "signal: crew.status" "real wake was not delivered while resetting the episode"
  [ "$(printf '%s\n' "$out" | grep -c 'repair attempt 1 of 3')" = 2 ] \
    || fail "a real wake did not reset the next failure to attempt 1: $out"
  assert_not_contains "$out" "repair attempt 2 of 3" "a real wake retained the prior failure count"
  pass "Codex park: a delivered real wake resets the bounded failure episode"
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
    assert_contains "$out" "WATCHER PARK FAILED" "$label was mistaken for a continuation callback"
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
  # shellcheck disable=SC2016 # The child shell expands the single-quoted program.
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

test_superseded_park_preserves_shared_watcher_for_successor() {
  local dir="$TMP_ROOT/supersede-shared" out1="$TMP_ROOT/supersede-shared-1.out"
  local out2="$TMP_ROOT/supersede-shared-2.out" result="$TMP_ROOT/supersede-shared-result" payload
  make_primary "$dir"
  : > "$dir/state/task.meta"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
watcher=
if [ -s "$FM_HOME/state/shared-watcher-pid" ]; then
  watcher=$(cat "$FM_HOME/state/shared-watcher-pid")
fi
if [ -z "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
  (
    while [ ! -e "$FM_HOME/state/trigger" ]; do sleep 0.1; done
  ) &
  watcher=$!
  printf '%s\n' "$watcher" > "$FM_HOME/state/shared-watcher-pid"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$watcher"
  on_term() {
    trap - TERM
    kill -TERM "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    exit 143
  }
  trap on_term TERM
  wait "$watcher"
  trap - TERM
else
  printf 'watcher: attached pid=%s (beacon 0s)\n' "$watcher"
  while kill -0 "$watcher" 2>/dev/null; do sleep 0.1; done
fi
if [ -e "$FM_HOME/state/trigger" ]; then
  printf 'signal: shared-watcher.status\n'
else
  printf 'watcher: FAILED - shared watcher was torn down during handoff\n'
  exit 1
fi
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  payload='{"hook_event_name":"Stop","session_id":"codex-test","stop_hook_active":false}'
  # shellcheck disable=SC2016 # The child shell expands the single-quoted program.
  FM_HOME="$dir" PAYLOAD="$payload" OUT1="$out1" OUT2="$out2" RESULT="$result" \
    FM_CODEX_PARK_POLL=1 "$FAKE_CODEX" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$PAYLOAD" | "$FM_HOME/bin/fm-codex-stop-park.sh" > "$OUT1" 2>&1 &
      first=$!
      i=0
      while [ ! -s "$FM_HOME/state/shared-watcher-pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      printf "%s" "$PAYLOAD" | "$FM_HOME/bin/fm-codex-stop-park.sh" > "$OUT2" 2>&1 &
      second=$!
      i=0
      while ! grep -q "watcher: attached" "$FM_HOME/state/.codex-park-output."* 2>/dev/null \
        && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      : > "$FM_HOME/state/trigger"
      rc1=0; wait "$first" || rc1=$?
      rc2=0; wait "$second" || rc2=$?
      printf "%s %s\n" "$rc1" "$rc2" > "$RESULT"
    '
  [ "$(cat "$result")" = "0 2" ] \
    || fail "shared-watcher handoff returned unexpected statuses: $(cat "$result")"
  [ ! -s "$out1" ] || fail "superseded shared-watcher park emitted a continuation: $(cat "$out1")"
  assert_contains "$(cat "$out2")" "signal: shared-watcher.status" \
    "the superseded park killed the watcher before its successor received the wake"
  pass "Codex park: supersession preserves the shared watcher until the successor receives its wake"
}

test_no_work_supersession_retires_old_arm() {
  local dir="$TMP_ROOT/supersede-no-work" out1="$TMP_ROOT/supersede-no-work-1.out"
  local out2="$TMP_ROOT/supersede-no-work-2.out" result="$TMP_ROOT/supersede-no-work-result" payload
  make_primary "$dir"
  : > "$dir/state/task.meta"
  write_arm_wait_for_trigger "$dir"
  payload='{"hook_event_name":"Stop","session_id":"codex-test","stop_hook_active":false}'
  # shellcheck disable=SC2016 # The child shell expands the single-quoted program.
  FM_HOME="$dir" PAYLOAD="$payload" OUT1="$out1" OUT2="$out2" RESULT="$result" \
    FM_CODEX_PARK_POLL=1 "$FAKE_CODEX" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$PAYLOAD" | "$FM_HOME/bin/fm-codex-stop-park.sh" > "$OUT1" 2>&1 &
      first=$!
      i=0
      while [ ! -s "$FM_HOME/state/arm-pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      arm=$(cat "$FM_HOME/state/arm-pid")
      rm -f "$FM_HOME/state/task.meta"
      printf "%s" "$PAYLOAD" | "$FM_HOME/bin/fm-codex-stop-park.sh" > "$OUT2" 2>&1
      rc2=$?
      rc1=0; wait "$first" || rc1=$?
      alive=0; kill -0 "$arm" 2>/dev/null && alive=1
      printf "%s %s %s\n" "$rc1" "$rc2" "$alive" > "$RESULT"
    '
  [ "$(cat "$result")" = "0 0 0" ] \
    || fail "no-work supersession did not retire the old arm: $(cat "$result")"
  [ ! -s "$out1" ] && [ ! -s "$out2" ] \
    || fail "no-work supersession emitted an unexpected continuation"
  pass "Codex park: a no-work overlapping Stop retires the superseded arm"
}

test_terminal_wake_precedes_no_work_stand_down() {
  local dir="$TMP_ROOT/terminal-wake" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
rm -f "$FM_HOME/state/task.meta"
printf 'check: process-event terminal-result\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(run_park "$dir" false 2>&1) || status=$?
  expect_code 2 "$status" "terminal one-shot Codex park"
  assert_contains "$out" "check: process-event terminal-result" \
    "terminal one-shot wake was discarded after its source retired"
  pass "Codex park: a terminal one-shot wake is delivered before no-work stand-down"
}

test_nonactionable_close_after_work_retires_ends_cleanly() {
  local dir="$TMP_ROOT/retired-no-wake" out status=0
  make_primary "$dir"
  : > "$dir/state/task.meta"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
rm -f "$FM_HOME/state/task.meta"
printf 'watcher: attached pid=%s (beacon 0s)\n' "$$"
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(run_park "$dir" false 2>&1) || status=$?
  expect_code 0 "$status" "retired no-wake Codex park"
  [ -z "$out" ] || fail "retired no-wake park reported a false failure: $out"
  pass "Codex park: a nonactionable close after work retires ends cleanly"
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
  # shellcheck disable=SC2016 # The child shell expands the single-quoted program.
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
test_stuck_owner_lock_reports_visible_failure
test_owner_publication_failure_reports_visible_failure
test_delivery_lock_failure_reports_visible_failure
test_failure_episode_survives_active_stop_and_stays_bounded
test_replacement_session_gets_its_own_failure_episode
test_real_wake_resets_failure_episode
test_beacons_do_not_mask_a_failed_park
test_quiet_park_renews_before_native_timeout
test_newer_stop_supersedes_older_park
test_superseded_park_preserves_shared_watcher_for_successor
test_no_work_supersession_retires_old_arm
test_terminal_wake_precedes_no_work_stand_down
test_nonactionable_close_after_work_retires_ends_cleanly
test_live_foreign_owner_is_not_replaced
test_worker_worktree_is_exempt
test_cancellation_retires_arm_child

echo "# all fm-codex-stop-park tests passed"
