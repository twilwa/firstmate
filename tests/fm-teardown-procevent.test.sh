#!/usr/bin/env bash
# Teardown retires task-owned boards, without touching other registrations.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$ROOT/bin/fm-procevent-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-procevent)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  # No live endpoint or copy: only durable records are being cleaned up.
  fm_write_meta "$home/state/worker-a.meta" \
    'kind=scout' 'backend=tmux' 'window=fm-procevent-fixture:fm-worker-a' \
    'endpoint_task_id=worker-a' "worktree=$home/missing-copy" "project=$home/missing-project"
  fm_procevent_task_registration_publish_locked "$home/state" lavish board worker-a /bin/true
  printf '%s\n' "$home"
}

home=$(make_home pending)
mkdir -p "$home/state/procevent-inbox"
printf 'unhandled feedback\n' > "$home/state/procevent-inbox/board.1.result"
if out=$(FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" worker-a --force 2>&1); then
  fail 'teardown succeeded even though source retirement refuses an unhandled round'
fi
assert_present "$home/state/worker-a.meta" 'retirement refusal removed the task record'
assert_contains "$out" 'cannot retire process-event source board for task worker-a' 'refusal must identify the source'
assert_contains "$out" 'unacknowledged' 'refusal must preserve the retirement reason'
out=$(FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$out" 'task:worker-a/round-open' 'retirement refusal lost the source or pending round'
pass 'teardown retains task records and explains source retirement refusals'

home=$(make_home retire)
fm_procevent_task_registration_publish_locked "$home/state" lavish second-board worker-a /bin/true
fm_procevent_task_registration_publish_locked "$home/state" lavish other-board worker-b /bin/true
out=$(FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" worker-a --force 2>&1) \
  || fail "teardown failed: $out"
assert_absent "$home/state/worker-a.meta" 'successful teardown retained the task record'
out=$(FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" list)
assert_not_contains "$out" 'task:worker-a' 'teardown orphaned its board registration'
assert_contains "$out" 'task:worker-b/dead' 'teardown retired another task source'
pass 'teardown retires only its own task process-event sources'

home=$(make_home no-sources)
FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" retire board --if-owner worker-a >/dev/null
out=$(FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" worker-a --force 2>&1) \
  || fail "teardown without sources failed: $out"
assert_absent "$home/state/worker-a.meta" 'teardown without sources retained the task record'
pass 'teardown without registered process-event sources is unaffected'

# Model the external runtime accepting one final worker registration while
# closing the endpoint. Delegate all other commands to an absolute tmux path.
REAL_TMUX=$(type -P tmux)
LATE_BIN="$TMP_ROOT/late-bin"
mkdir -p "$LATE_BIN"
cat > "$LATE_BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
export PATH="${PATH#"$FM_TEST_LATE_BIN:"}"
if [ "$*" = 'kill-window -t =fm-procevent-fixture:=fm-worker-a' ]; then
  . "$FM_TEST_ROOT/bin/fm-pr-lib.sh"
  . "$FM_TEST_ROOT/bin/fm-wake-lib.sh"
  . "$FM_TEST_ROOT/bin/fm-procevent-lib.sh"
  fm_procevent_task_registration_publish_locked "$FM_TEST_LATE_HOME/state" lavish late-board worker-a /bin/true
  if [ "${FM_TEST_LATE_PENDING:-0}" = 1 ]; then
    mkdir -p "$FM_TEST_LATE_HOME/state/procevent-inbox"
    printf 'unhandled feedback\n' > "$FM_TEST_LATE_HOME/state/procevent-inbox/late-board.1.result"
  fi
  printf 'closed\n' > "$FM_TEST_LATE_HOME/endpoint-closed"
  exit 0
fi
exec "$FM_TEST_REAL_TMUX" "$@"
SH
chmod +x "$LATE_BIN/tmux"
head -n2 "$LATE_BIN/tmux" >/dev/null

home=$(make_home late-pending)
if out=$(FM_HOME="$home" FM_TEST_LATE_HOME="$home" FM_TEST_ROOT="$ROOT" \
  FM_TEST_REAL_TMUX="$REAL_TMUX" FM_TEST_LATE_BIN="$LATE_BIN" FM_TEST_LATE_PENDING=1 PATH="$LATE_BIN:$PATH" \
  "$ROOT/bin/fm-teardown.sh" worker-a --force 2>&1); then
  fail 'teardown ignored a late-source retirement refusal after endpoint closure'
fi
assert_present "$home/endpoint-closed" 'late refusal happened before endpoint closure'
assert_present "$home/state/worker-a.meta" 'late retirement refusal removed the task record'
assert_contains "$out" 'cannot retire process-event source late-board for task worker-a' 'late refusal must identify the source'
assert_contains "$out" 'unacknowledged' 'late refusal must preserve the retirement reason'
out=$(FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$out" 'task:worker-a/round-open' 'late refusal lost the source or pending round'
pass 'late-source retirement refusal retains the task record after endpoint closure'

home=$(make_home late-source)
out=$(FM_HOME="$home" FM_TEST_LATE_HOME="$home" FM_TEST_ROOT="$ROOT" \
  FM_TEST_REAL_TMUX="$REAL_TMUX" FM_TEST_LATE_BIN="$LATE_BIN" PATH="$LATE_BIN:$PATH" \
  "$ROOT/bin/fm-teardown.sh" worker-a --force 2>&1) || fail "late-source teardown failed: $out"
assert_present "$home/endpoint-closed" 'fixture did not register a source during endpoint closure'
assert_absent "$home/state/worker-a.meta" 'late-source teardown retained the task record'
out=$(FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$out" 'no sources registered' 'teardown orphaned a source registered during endpoint closure'
pass 'teardown retires sources registered after the early pass and before endpoint closure'
