#!/usr/bin/env bash
# Opt-in credentialed OpenCode 2.x adapter guard: the actual fm-spawn launch
# and generated busy plugin run under a private server in an isolated Herdr lab.
# Run FM_OPENCODE_ADAPTER_LIVE=1 tests/fm-opencode-adapter-live-e2e.test.sh.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_OPENCODE_ADAPTER_LIVE herdr jq opencode rg systemd-run

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || fail "OpenCode lab helper is unavailable: $LAB_HELPER"
VERSION=$(systemd-run --user --scope -q -p TasksMax=256 -p MemoryMax=2G -p MemorySwapMax=0 -p RuntimeMaxSec=900 -- opencode --version) || fail "cannot read scoped OpenCode version"
[[ $VERSION =~ ([0-9]+)\.[0-9]+ ]] && [ "${BASH_REMATCH[1]}" -ge 2 ] || fail "OpenCode $VERSION: this guard requires OpenCode 2.0 or later"
SESSION=$("$LAB_HELPER" name fm-opencode-2-adapter)
TMP_ROOT=$(mktemp -d "$ROOT/.fm-opencode-adapter-live.XXXXXX")
cleanup() {
  local rc=$?
  trap - EXIT
  "$LAB_HELPER" teardown "$SESSION" || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

HOME_DIR=$TMP_ROOT/home
PROJECT=$TMP_ROOT/project
WT=$TMP_ROOT/worker
ID=opencode-live
LAUNCH_LOG=$TMP_ROOT/launch.log
FAKEBIN=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$HOME_DIR" opencode
fm_git_worktree "$PROJECT" "$WT" opencode-live
fm_test_spawn_brief "$HOME_DIR" "$ID" 'Run the shell command sleep 12, then answer exactly FIRSTMATE_OPENCODE_DONE.'
FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
  "$ID" "$PROJECT" --harness opencode --model opencode-go/mimo-v2.6-flash \
  --mode no-mistakes --yolo off >/dev/null || fail "OpenCode $VERSION: fm-spawn refused"
launch=$(<"$LAUNCH_LOG")
case "$launch" in
  *'opencode mini --model '\''opencode-go/mimo-v2.6-flash'\'' --standalone --prompt'*) ;;
  *) fail "OpenCode $VERSION: fm-spawn lost model pin or standalone isolation" ;;
esac
[ -f "$WT/.opencode/plugins/fm-busy-state.js" ] || fail "OpenCode $VERSION: fm-spawn omitted busy plugin"
# A shell script preserves fm-spawn's quoting through Herdr's keyboard input.
# Only the OpenCode process (and its private server child) runs in this scope.
EXITED=$TMP_ROOT/launch.exited
printf '#!/bin/bash\nsystemd-run --user --scope -q -p TasksMax=256 -p MemoryMax=2G -p MemorySwapMax=0 -p RuntimeMaxSec=900 -- /bin/bash -lc %q\n: > %q\n' "$launch" "$EXITED" > "$TMP_ROOT/launch.sh"
"$LAB_HELPER" provision "$SESSION" || fail "OpenCode $VERSION: Herdr lab provision refused"
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }
ws=$(lab workspace create --cwd "$WT" --label opencode-adapter --no-focus) || fail "OpenCode $VERSION: lab workspace create failed"
pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') || fail "OpenCode $VERSION: no lab pane"
lab pane run "$pane" "/bin/bash $TMP_ROOT/launch.sh" >/dev/null || fail "OpenCode $VERSION: lab pane launch failed"
record="$HOME_DIR/state/$ID.busy-state"
# Both the semantic plugin and an independently rendered reply must progress.
# Never interpret a stale seed (source=fm-spawn) as plugin activity.
busy=0
idle=0
answer=0
for ((i=0; i<90; i++)); do
  if [ -f "$record" ]; then
    row=$(<"$record")
    case "$row" in *'state=busy source=opencode-plugin'*) busy=1 ;; esac
    case "$row" in *'state=idle source=opencode-plugin'*) idle=1 ;; esac
  fi
  if [ "$idle" -eq 1 ]; then
    screen=$(lab pane read "$pane" --source recent --lines 120 2>/dev/null || true)
    case "$screen" in *FIRSTMATE_OPENCODE_DONE*) answer=1 ;; esac
    [ "$answer" -eq 0 ] || break
  fi
  sleep 1
done
[ "$busy" -eq 1 ] || fail "OpenCode $VERSION: v2 plugin never recorded busy (rendered output cannot substitute)"
[ "$idle" -eq 1 ] || fail "OpenCode $VERSION: v2 plugin never recorded idle"
[ "$answer" -eq 1 ] || fail "OpenCode $VERSION: plugin settled without a rendered answer"
[ -f "$HOME_DIR/state/$ID.turn-ended" ] || fail "OpenCode $VERSION: turn-end notification missing"
printf 'ok - OpenCode %s: fm-spawn model pin, private server, v2 busy/idle and rendered answer\n' "$VERSION"

# Enter during a live turn must not silently discard queued work. The plugin
# records independent start/settle transitions while the final reply proves
# that OpenCode processed the queued prompt, not just typed it.
lab pane send-text "$pane" 'Run the shell command sleep 12, then answer exactly LONG_DONE.' >/dev/null || fail "OpenCode $VERSION: cannot type long turn"
lab pane send-keys "$pane" Enter >/dev/null || fail "OpenCode $VERSION: cannot submit long turn"
seen_busy=0
for ((i=0; i<30; i++)); do
  case "$(<"$record")" in *'state=busy source=opencode-plugin'*) seen_busy=1; break ;; esac
  sleep 1
done
[ "$seen_busy" -eq 1 ] || fail "OpenCode $VERSION: no busy state during queued-Enter test"
lab pane send-text "$pane" 'Answer exactly QUEUED_DONE.' >/dev/null || fail "OpenCode $VERSION: cannot type queued instruction"
lab pane send-keys "$pane" Enter >/dev/null || fail "OpenCode $VERSION: queued Enter failed"
queued=0
for ((i=0; i<70; i++)); do
  screen=$(lab pane read "$pane" --source recent --lines 150 2>/dev/null || true)
  if printf '%s\n' "$screen" | rg -q '^[[:space:]]*QUEUED_DONE[[:space:]]*$'; then queued=1; break; fi
  sleep 1
done
[ "$queued" -eq 1 ] || fail "OpenCode $VERSION: busy-queued Enter never produced a reply"
case "$(<"$record")" in *'state=idle source=opencode-plugin'*) ;; *) fail "OpenCode $VERSION: queued reply did not settle plugin idle" ;; esac
printf 'ok - OpenCode %s: busy-queued Enter delivered and settled\n' "$VERSION"

lab pane send-text "$pane" 'Run the shell command sleep 30, then answer exactly INTERRUPT_SHOULD_NOT_APPEAR.' >/dev/null || fail "OpenCode $VERSION: cannot type interrupt probe"
lab pane send-keys "$pane" Enter >/dev/null || fail "OpenCode $VERSION: cannot submit interrupt probe"
seen_busy=0
for ((i=0; i<30; i++)); do
  case "$(<"$record")" in *'state=busy source=opencode-plugin'*) seen_busy=1; break ;; esac
  sleep 1
done
[ "$seen_busy" -eq 1 ] || fail "OpenCode $VERSION: no busy state before interrupt"
lab pane send-keys "$pane" Escape Escape >/dev/null || fail "OpenCode $VERSION: double Escape was not delivered"
interrupted=0
for ((i=0; i<20; i++)); do
  case "$(<"$record")" in *'state=idle source=opencode-plugin'*) interrupted=1; break ;; esac
  sleep 1
done
if [ "$interrupted" -eq 1 ]; then
  printf 'ok - OpenCode %s: double Escape interrupted active turn\n' "$VERSION"
else
  printf 'not ok - OpenCode %s: double Escape did not settle semantic busy state: %s\n' "$VERSION" "$(<"$record")" >&2
fi
# A long external command can ignore Escape (also observed on 1.x). An
# unresponsive interrupted pane must not be mistaken for an idle worker.
for ((i=0; i<40; i++)); do
  case "$(<"$record")" in *'state=idle source=opencode-plugin'*) break ;; esac
  sleep 1
done
[ ! -e "$EXITED" ] || fail "OpenCode $VERSION: OpenCode exited before /exit"
lab pane send-text "$pane" '/exit' >/dev/null || fail "OpenCode $VERSION: cannot type /exit"
[ ! -e "$EXITED" ] || fail "OpenCode $VERSION: OpenCode exited before /exit was submitted"
lab pane send-keys "$pane" Enter >/dev/null || fail "OpenCode $VERSION: cannot submit /exit"
exited=0
for ((i=0; i<20; i++)); do
  [ ! -e "$EXITED" ] || { exited=1; break; }
  sleep 1
done
[ "$exited" -eq 1 ] || fail "OpenCode $VERSION: /exit did not end the OpenCode process"
printf 'ok - OpenCode %s: /exit closed the private-server worker\n' "$VERSION"

resume=${launch/--prompt/--continue --prompt}
printf '#!/bin/bash\nexec systemd-run --user --scope -q -p TasksMax=256 -p MemoryMax=2G -p MemorySwapMax=0 -p RuntimeMaxSec=900 -- /bin/bash -lc %q\n' "$resume" > "$TMP_ROOT/resume.sh"
lab pane run "$pane" "/bin/bash $TMP_ROOT/resume.sh" >/dev/null || fail "OpenCode $VERSION: --continue relaunch failed"
sleep 8
history=$(lab pane read "$pane" --source recent --lines 180 2>/dev/null || true)
case "$history" in *'QUEUED_DONE'*) ;; *) fail "OpenCode $VERSION: --continue did not restore the previous session history" ;; esac
lab pane send-text "$pane" 'Reply exactly RESUME_DONE.' >/dev/null || fail "OpenCode $VERSION: cannot type resumed instruction"
lab pane send-keys "$pane" Enter >/dev/null || fail "OpenCode $VERSION: cannot submit resumed instruction"
resumed=0
for ((i=0; i<50; i++)); do
  screen=$(lab pane read "$pane" --source recent --lines 160 2>/dev/null || true)
  if printf '%s\n' "$screen" | rg -q '^[[:space:]]*RESUME_DONE[[:space:]]*$'; then resumed=1; break; fi
  sleep 1
done
[ "$resumed" -eq 1 ] || fail "OpenCode $VERSION: --continue did not process a manually submitted instruction"
printf 'ok - OpenCode %s: --continue on a private server processed a new instruction\n' "$VERSION"
[ "$interrupted" -eq 1 ] || fail "OpenCode $VERSION: double Escape interrupt remains unverified"
