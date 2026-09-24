#!/usr/bin/env bash
# Driver: one timed, locked, composed fm-session-start.sh in a scratch FM_HOME.
# Herdr is replaced by a refuse-all logging guard; the live session is never contacted.
set -u
i=$1; ROOT=/tmp/fm-nm-test-startup.pFZ80F; W=/home/firstmate/firstmate/data/fm-startup-repair-finish/opus-gate/worktrees/85029a4da11b/01M39BB0DGS93EC4MZHQXTCBA5; H=$ROOT/home-$i; O=/home/firstmate/firstmate/data/fm-startup-repair-finish/opus-gate/evidence/01M39BB0DGS93EC4MZHQXTCBA5/startup-run-$i; mkdir -p "$O" "$H/tmp"
: > "$O/herdr-commands.log"
( last=; while [ ! -e "$O/.stop" ]; do f=$(ls "$H/tmp"/fm-session-start-stage.* 2>/dev/null | head -1)
    if [ -n "$f" ]; then s=$(cat "$f" 2>/dev/null); [ -z "$s" ] || [ "$s" = "$last" ] || { printf '%s\t%s\n' "$(date +%s.%N)" "$s" >> "$O/stage-times.tsv"; last=$s; }; fi; sleep 0.25; done ) &
mon=$!
start=$(date +%s.%N); printf '%s\tstart\n' "$start" > "$O/stage-times.tsv"
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u HERDR_SESSION -u HERDR_PANE_ID   FM_HOME="$H" TMPDIR="$H/tmp" FM_BOOTSTRAP_DETECT_ONLY=1   FM_TEST_HERDR_COMMAND_LOG="$O/herdr-commands.log" PATH="$ROOT/guard:$PATH"   /usr/bin/time -f 'wall_seconds=%e user_seconds=%U sys_seconds=%S' -o "$O/time.txt"   "$W/bin/fm-session-start.sh" > "$O/session-start.out" 2> "$O/session-start.err"
echo "exit=$?" >> "$O/time.txt"
printf '%s\tend\n' "$(date +%s.%N)" >> "$O/stage-times.tsv"
touch "$O/.stop"; wait $mon; rm -f "$O/.stop"
