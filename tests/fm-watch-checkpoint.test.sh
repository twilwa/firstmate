#!/usr/bin/env bash
# Tests for the bounded foreground watcher checkpoint diagnostic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_timeout_during_watcher_initialization_releases_lock() {
  local home out err status=0 holder ready
  home=$(make_home initialization-timeout)
  out="$home/out.txt"
  err="$home/err.txt"
  ready="$home/holder-ready"
  FM_HOME="$home" READY="$ready" ROOT="$ROOT" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$FM_HOME/state/.watcher-down.lock" || exit 1
    : > "$READY"
    trap '\''fm_lock_release "$FM_HOME/state/.watcher-down.lock"'\'' EXIT
    sleep 20
  ' &
  holder=$!
  while [ ! -e "$ready" ]; do
    kill -0 "$holder" 2>/dev/null || fail "initialization lock holder exited early"
    sleep 0.05
  done

  FM_HOME="$home" FM_POLL=30 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  kill -TERM "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 124 "$status" "initialization-timeout checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" \
    "initialization-timeout checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" \
    "watch lock survived timeout during post-claim initialization"
  pass "checkpoint timeout during watcher initialization releases its owned lock"
}

test_recovery_marker_failure_retains_stale_lock_evidence() {
  local home fakebin out err status=0 real_mktemp
  home=$(make_home recovery-marker-failure)
  fakebin="$home/fakebin"
  out="$home/out.txt"
  err="$home/err.txt"
  real_mktemp=$(command -v mktemp)
  mkdir -p "$fakebin"
  printf 'announced:downtime:fixture\n' > "$home/state/.watcher-down"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  *.watcher-down.tmp.*) exit 1 ;;
esac
exec "$REAL_MKTEMP" "$@"
SH
  chmod 0700 "$fakebin/mktemp"

  PATH="$fakebin:$PATH" REAL_MKTEMP="$real_mktemp" FM_HOME="$home" \
    FM_CHECK_INTERVAL=999999 "$WATCH" >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "recovery-marker failure watcher exit"
  assert_contains "$(cat "$err")" "retaining stale lock evidence" \
    "recovery-marker failure did not report retained evidence"
  [ -s "$home/state/.watch.lock/pid" ] \
    || fail "recovery-marker failure discarded stale lock evidence"
  pass "recovery-marker initialization failure retains stale lock evidence"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_quiet_checkpoint_exits_124_cleanly
test_timeout_during_watcher_initialization_releases_lock
test_recovery_marker_failure_retains_stale_lock_evidence
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
