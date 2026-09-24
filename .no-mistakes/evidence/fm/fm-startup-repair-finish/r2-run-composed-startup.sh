#!/usr/bin/env bash
# Round-2 driver: one timed, locked, composed fm-session-start.sh in a fresh
# scratch FM_HOME copied from the seed (primary state/data/config minus locks,
# secondmates.md, worktrees). Herdr is replaced on PATH by herdr-guard.sh: status
# reports a running server, every other call is logged and refused, so the live
# session is never contacted.
set -u
i=$1; ROOT=/tmp/fm-nm-test-r2.aM1ROD; W=/home/firstmate/firstmate/data/fm-startup-repair-finish/opus-gate/worktrees/85029a4da11b/01M39BB0DGS93EC4MZHQXTCBA5
E=/home/firstmate/firstmate/data/fm-startup-repair-finish/opus-gate/evidence/01M39BB0DGS93EC4MZHQXTCBA5
H=$ROOT/home-$i; O=$E/r2-startup-run-$i
rm -rf "$H"; mkdir -p "$O" "$H"; cp -a "$ROOT/seed/." "$H/"; mkdir -p "$H/tmp"
: > "$O/herdr-commands.log"; : > "$O/stage-times.tsv"
uptime > "$O/load.txt"
( last=; while [ ! -e "$O/.stop" ]; do f=$(ls "$H/tmp"/fm-session-start-stage.* 2>/dev/null | head -1)
    if [ -n "$f" ]; then s=$(cat "$f" 2>/dev/null); [ -z "$s" ] || [ "$s" = "$last" ] || { printf '%s\t%s\n' "$(date +%s.%N)" "$s" >> "$O/stage-times.tsv"; last=$s; }; fi; sleep 0.25; done ) &
mon=$!
printf '%s\tstart\n' "$(date +%s.%N)" >> "$O/stage-times.tsv"
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID \
  -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u FM_TASK_ID -u FM_PI_HARNESS \
  FM_HOME="$H" TMPDIR="$H/tmp" FM_BOOTSTRAP_DETECT_ONLY=1 \
  FM_TEST_HERDR_COMMAND_LOG="$O/herdr-commands.log" PATH="$ROOT/guard:$PATH" \
  /usr/bin/time -f 'wall_seconds=%e user_seconds=%U sys_seconds=%S' -o "$O/time.txt" \
  "$W/bin/fm-session-start.sh" > "$O/session-start.out" 2> "$O/session-start.err"
echo "exit=$?" >> "$O/time.txt"
printf '%s\tend\n' "$(date +%s.%N)" >> "$O/stage-times.tsv"
touch "$O/.stop"; wait $mon; rm -f "$O/.stop"
cat "$H/state/.lock" > "$O/scratch-lock.txt" 2>/dev/null
