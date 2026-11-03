#!/usr/bin/env bash
# tests/fm-backend-hc-smoke.test.sh - real herdr-core smoke test for the hc
# session-provider adapter (bin/backends/hc.sh, docs/hc-backend.md).
# Portable hc suites fake the CLI; this one drives the REAL hc binary, but
# only inside a lab session provisioned by bin/fm-hc-lab.sh: a unique
# fm-hclab-* HC_SESSION, scratch XDG roots, a pinned FM_HC_SOCKET, a
# real-fleet tripwire, and a teardown that sweeps the session's serve/hold
# daemons by their HC_SESSION env marker. tests/hc-test-safety.sh owns the
# only sanctioned teardown path and teardown failures propagate through the
# EXIT trap.
#
# Covers one task lifecycle through the bin/fm-backend.sh dispatcher: binary
# and generation gates, container ensure, create, submitted input, cwd
# tracking, capture, agent state for a shell and for an agent-named process,
# and a proven close. With a C compiler, a native fake agent additionally
# exercises control exit/relaunch and lost-agent truth after a core restart;
# it never starts an authenticated harness or spends tokens.
#
# Skips cleanly (exit 0, "skip: hc not found ...") when no herdr-core binary
# is installed (optional-binary gate); to pin a specific binary run
# `FM_HC_BIN=/path/to/hc bash tests/fm-backend-hc-smoke.test.sh`. Once the
# binary is present, a provisioning or teardown failure is a FAIL, not a
# skip.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# Binary resolution identical to the adapter, installer, and lab: FM_HC_BIN
# wins, then herdr-core, then the hc alias.
HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: hc not found (install via bin/fm-install-hc.sh or set FM_HC_BIN)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-smoke)

HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name smoke)

# The teardown's own result propagates: a fleet-tripwire failure or surviving
# session processes keep this run nonzero even on an otherwise-clean pass.
# Armed before provision so a half-provisioned session is still swept when
# the lab helper left a tripwire behind.
cleanup_lab() {
  local rc=$?
  trap - EXIT
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT

"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" \
  || fail "hc lab could not provision with $HC_BIN"
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SOCK" ] || fail "hc lab provisioned without a socket"

hc_test_refuse_if_unsafe "$HC_TEST_SES" \
  || fail "provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"

HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET

FM_HOME_DIR=$TMP_ROOT/home
WORK_DIR=$TMP_ROOT/work
mkdir -p "$FM_HOME_DIR" "$WORK_DIR"
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)
export FM_HOME=$FM_HOME_DIR FM_ROOT_OVERRIDE=$ROOT

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "could not source the hc adapter"

# wait_for <seconds> <cmd...>: poll a condition without a fixed sleep budget.
wait_for() {
  local tries=$(( $1 * 10 ))
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

LABEL=fm-smoke1
SES=$(fm_backend_hc_container_ensure) || fail "container_ensure failed"
assert_equals "$SES" "$HC_TEST_SES" "container_ensure names the lab session"
ADDR=$(fm_backend_hc_create_task "$SES" "$LABEL" "$WORK_DIR") || fail "create_task failed"
T="$SES:$ADDR"
fm_backend_target_exists hc "$T" "$LABEL" || fail "the new terminal must exist under its label"
pass "hc smoke: create_task started $T"

mkdir -p "$WORK_DIR/sub"
fm_backend_hc_send_text_line "$T" "cd sub" "$LABEL" || fail "send_text_line failed"
path_is_sub() { [ "$(fm_backend_hc_current_path "$T" "$LABEL")" = "$WORK_DIR/sub" ]; }
wait_for 10 path_is_sub || fail "current_path did not follow cd (got $(fm_backend_hc_current_path "$T" "$LABEL"))"
pass "hc smoke: current_path follows the shell's cwd"

fm_backend_hc_send_text_line "$T" "echo Smoke-Line-42" "$LABEL" || fail "send_text_line failed"
captured() { fm_backend_capture hc "$T" 50 "$LABEL" | grep -qx 'Smoke-Line-42'; }
wait_for 10 captured || fail "capture did not show the submitted command's output"
pass "hc smoke: send_text_line ran the command and capture shows its output"

verdict=$(fm_backend_hc_send_text_submit "$T" "echo Sub-Line-7" 1 0.4 0 "$LABEL")
case "$verdict" in
  empty|pending|pending-unproven|unknown) ;;
  *) fail "send_text_submit returned '$verdict', outside its vocabulary" ;;
esac
sub_captured() { fm_backend_capture hc "$T" 50 "$LABEL" | grep -qx 'Sub-Line-7'; }
wait_for 10 sub_captured || fail "send_text_submit's text never reached the terminal (verdict $verdict)"
pass "hc smoke: send_text_submit delivers through send --wait (verdict $verdict)"

assert_equals "$(fm_backend_agent_state hc "$T")" dead "an idle shell is dead"
STANDIN=$(fm_agent_standin "$TMP_ROOT/standin") || fail "no agent stand-in survives a foreign name here"
mkdir -p "$TMP_ROOT/bin/claude"
cp "$STANDIN" "$TMP_ROOT/bin/claude/claude"
fm_backend_hc_send_text_line "$T" "exec $TMP_ROOT/bin/claude/claude 600" "$LABEL" || fail "agent launch send failed"
is_alive() { [ "$(fm_backend_agent_state hc "$T")" = alive ]; }
wait_for 10 is_alive || fail "agent_state did not report the agent-named foreground (got $(fm_backend_agent_state hc "$T"))"
pass "hc smoke: agent_state reads dead for a shell and alive for an agent-named foreground"

fm_backend_kill hc "$T" || fail "kill failed"
assert_equals "$(fm_backend_agent_state hc "$T")" missing "a closed terminal is missing"
fm_backend_kill hc "$T" || fail "closing an already-closed terminal must be a silent success"
pass "hc smoke: kill closes and removes the terminal"
# Control proof uses a native fake agent: foreground naming and kernel
# process groups are real, while no vendor service or credential is involved.
# CI's tests-hc lane supplies cc. Without it this subcase is explicitly absent.
CC=$(type -P cc 2>/dev/null || true)
if [ -z "$CC" ]; then
  [ -z "${CI:-}" ] || fail 'cc is required for the hc control lifecycle proof in CI'
  echo '# skip: cc not found; hc control exit/relaunch proof not run'
else
  mkdir -p "$TMP_ROOT/agent-bin" "$TMP_ROOT/user-home" "$FM_HOME_DIR/state" "$FM_HOME_DIR/data"
  cat > "$TMP_ROOT/agent.c" <<'C'
#include <stdio.h>
#include <string.h>
int main(void) {
  char line[4096];
  puts("╭────────────────────────╮\n│                        │\n╰────────────────────────╯");
  fflush(stdout);
  while (fgets(line, sizeof line, stdin)) {
    if (!strcmp(line, "/exit\n")) return 0;
  }
  return 0;
}
C
  "$CC" -o "$TMP_ROOT/agent-bin/claude" "$TMP_ROOT/agent.c" || fail 'native fake agent compilation failed'
  ID="hc-control-$$-$RANDOM"
  # Reserve this unique task temp root ourselves so cleanup cannot adopt
  # another task's directory, even if relaunch fails before publishing meta.
  mkdir -m 700 "/tmp/fm-$ID" || fail 'unique task temp directory unavailable'
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$ID")
  fm_git_worktree "$TMP_ROOT/proj" "$TMP_ROOT/wt" "task-$ID"
  WT=$(cd "$TMP_ROOT/wt" && pwd -P)
  printf 'preserve unfinished work\n' > "$WT/draft.txt"
  HEAD_BEFORE=$(git -C "$WT" rev-parse HEAD)
  mkdir -p "$FM_HOME_DIR/data/$ID"
  printf '# Task\n## Captain\x27s intent\nExercise hc control.\n\n## Firstmate spec\nPreserve this task.\n' > "$FM_HOME_DIR/data/$ID/brief.md"
  LABEL="fm-$ID"
  ADDR=$(fm_backend_hc_create_task "$SES" "$LABEL" "$WT") || fail 'control terminal create failed'
  T="$SES:$ADDR"
  printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nbackend=hc\nhc_session=%s\nhc_terminal=%s\n' \
    "$T" "$ID" "$WT" "$TMP_ROOT/proj" "$SES" "$ADDR" > "$FM_HOME_DIR/state/$ID.meta"
  # The fake binary is also the only claude the terminal's later relaunch
  # can resolve. The parent has a scratch HOME for Claude's local trust file.
  fm_backend_hc_send_text_line "$T" "export PATH='$TMP_ROOT/agent-bin':\$PATH HOME='$TMP_ROOT/user-home'; '$TMP_ROOT/agent-bin/claude'" "$LABEL" \
    || fail 'fake agent start failed'
  wait_for 10 is_alive || fail 'native fake agent did not become alive'

  control() {
    PATH="$TMP_ROOT/agent-bin:$PATH" HOME="$TMP_ROOT/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=15 FM_CONTROL_LAUNCH_WAIT=15 \
      bash "$ROOT/bin/fm-control.sh" "$ID" "$@"
  }
  control exit || fail 'control exit did not prove the fake agent stopped'
  assert_equals "$(fm_backend_agent_state hc "$T")" dead 'exit returns to an agent-free shell'
  fm_backend_target_exists hc "$T" "$LABEL" || fail 'exit removed the terminal'
  pass 'hc control: normal agent exit leaves a dead shell in the same terminal'

  RC=0
  control relaunch --note 'continue the preserved test task' || RC=$?
  for launchdir in "/tmp/fm-$ID"+*; do
    [ ! -d "$launchdir" ] || FM_TEST_CLEANUP_DIRS+=("$launchdir")
  done
  [ "$RC" = 0 ] || fail 'control relaunch did not start a replacement in place'
  wait_for 10 is_alive || fail 'relaunch replacement is not alive'
  assert_grep "hc_terminal=$ADDR" "$FM_HOME_DIR/state/$ID.meta" 'relaunch retains terminal identity'
  assert_equals "$(git -C "$WT" rev-parse HEAD)" "$HEAD_BEFORE" 'relaunch preserves branch HEAD'
  assert_equals "$(cat "$WT/draft.txt")" 'preserve unfinished work' 'relaunch preserves unfinished work'
  pass 'hc control: relaunch replaces the agent in place without changing its work'

  # Stopping the core loses the agent, not merely its listener. A retained
  # shell is reusable; a finished/missing terminal must never be rebound.
  "$ROOT/bin/fm-hc-lab.sh" stop "$HC_TEST_SES" || fail 'owned core stop failed'
  restart_agent_is_gone() {
    RESTART_STATE=$(fm_backend_agent_state hc "$T" "$LABEL")
    [ "$RESTART_STATE" != alive ] || fail 'core restart falsely reports the lost fake agent alive'
    case "$RESTART_STATE" in dead|missing) return 0 ;; *) return 1 ;; esac
  }
  wait_for 10 restart_agent_is_gone || fail "core restart agent state did not settle: $RESTART_STATE"
  case "$RESTART_STATE" in
    dead)
      # A restarted shell does not inherit the previous shell's exports.
      fm_backend_hc_send_text_line "$T" "export PATH='$TMP_ROOT/agent-bin':\$PATH HOME='$TMP_ROOT/user-home'" "$LABEL" \
        || fail 'restarted shell could not receive the private fake-agent environment'
      control relaunch --note 'continue after the owned core restart' \
        || fail 'restarted dead shell refused in-place relaunch'
      wait_for 10 is_alive || fail 'restart relaunch did not start the replacement agent'
      ;;
    missing)
      if control relaunch > "$TMP_ROOT/restart-relaunch.out" 2>&1; then
        fail 'restart relaunch rebound a missing or finished terminal'
      fi
      assert_grep 'hc absence cannot be proven' "$TMP_ROOT/restart-relaunch.out" 'missing restart terminal requires absence proof'
      assert_equals "$(fm_backend_agent_state hc "$T" "$LABEL")" missing 'refused restart relaunch leaves the terminal missing'
      ;;
    *) fail "core restart must lose the fake agent: expected dead or missing, got '$RESTART_STATE'" ;;
  esac
  for launchdir in "/tmp/fm-$ID"+*; do
    [ ! -d "$launchdir" ] || FM_TEST_CLEANUP_DIRS+=("$launchdir")
  done
  assert_grep "^window=$T$" "$FM_HOME_DIR/state/$ID.meta" 'restart recovery retains recorded endpoint'
  assert_grep "^hc_terminal=$ADDR$" "$FM_HOME_DIR/state/$ID.meta" 'restart recovery retains recorded terminal identity'
  assert_equals "$(git -C "$WT" rev-parse HEAD)" "$HEAD_BEFORE" 'restart recovery preserves branch HEAD'
  assert_equals "$(cat "$WT/draft.txt")" 'preserve unfinished work' 'restart recovery preserves unfinished work'
  pass "hc core restart: lost agent is $RESTART_STATE and relaunch respects terminal identity"

  fm_backend_kill hc "$T" '' "$LABEL" || fail 'replacement terminal close failed'
  assert_equals "$(fm_backend_agent_state hc "$T")" missing 'terminal kill is missing, not dead'
  pass 'hc control: killed terminal reports missing'
fi
echo FM_TEST_COMPLETE
