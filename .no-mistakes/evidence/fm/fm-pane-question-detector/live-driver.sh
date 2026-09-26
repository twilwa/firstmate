#!/usr/bin/env bash
# Live driver: real Claude Code in an isolated fm-lab-* Herdr session, real
# bin/fm-watch.sh reading that pane through the herdr backend adapter.
# Usage: live-driver.sh <case-name> <reply-text> <status-text> [reuse-state-dir]
set -u
ROOT=/home/firstmate/.treehouse/firstmate-e3a38d/13/firstmate/data/fm-pane-question-detector/opus-gate/worktrees/b5312afc1c86/01M3F2ZXNXJT4HJSX591T94C6P
EV=/home/firstmate/.treehouse/firstmate-e3a38d/13/firstmate/data/fm-pane-question-detector/opus-gate/evidence/01M3F2ZXNXJT4HJSX591T94C6P
S=$(cat /tmp/pq-lab-session); PANE=${PQ_PANE:-$(cat /tmp/pq-lab-pane)}
LAB="$ROOT/bin/fm-herdr-lab.sh"
lab() { "$LAB" run "$S" "$@"; }
name=$1 reply=$2 status=$3 reuse=${4:-}
WORK=/tmp/pq-live; mkdir -p "$WORK/fakebin"
ORIG_PATH=$PATH
cat > "$WORK/fakebin/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$S" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else echo "wrapper requires trailing --session $S" >&2; exit 98; fi
exec env PATH="$ORIG_PATH" "$LAB" run "$S" "\${args[@]}"
EOF
cat > "$WORK/fakebin/fm-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
echo 'state: unknown · source: none · no current-state source available'
EOF
chmod +x "$WORK/fakebin/"*

wait_idle() {
  local i st
  for i in $(seq 1 90); do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done) [ "$i" -gt 2 ] && return 0 ;; esac
    sleep 1
  done
  return 1
}

out="$EV/$name"; mkdir -p "$out"
if [ -n "$reply" ]; then
  wait_idle || { echo "agent never idle before $name"; exit 1; }
  lab pane send-text "$PANE" "Reply with exactly the following text and nothing else, no tools: $reply" >/dev/null
  sleep 0.5; lab pane send-keys "$PANE" enter >/dev/null
  sleep 3; wait_idle || { echo "agent never idle after $name"; exit 1; }
  sleep 1
fi
lab pane read "$PANE" --source visible > "$out/pane-at-turn-end.txt"

if [ -n "$reuse" ]; then state=$reuse; else state="$WORK/$name/state"; rm -rf "$WORK/$name"; mkdir -p "$state"; fi
printf 'window=%s:%s\nbackend=herdr\nkind=ship\nharness=${PQ_HARNESS:-claude}\nendpoint_task_id=task\n' "$S" "$PANE" > "$state/task.meta"
[ -n "$reuse" ] || printf '%b' "$status" > "$state/task.status"
[ -z "$reuse" ] || printf '%b' "$status" >> "$state/task.status"
date +%s%N > "$state/task.turn-ended"
cp "$state/task.status" "$out/task.status"

PATH="$WORK/fakebin:$ORIG_PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$WORK/fakebin/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_WATCH_HANDLING_SUCCESSOR=1 timeout 90 "$ROOT/bin/fm-watch.sh" > "$out/watch.out" 2> "$out/watch.err"
echo "watch rc=$?" > "$out/result.txt"
{
  echo "== .wake-queue"; cat "$state/.wake-queue" 2>/dev/null
  echo "== inbox nudges"; for f in "$state"/task.inbox/*.msg; do [ -f "$f" ] && { echo "-- $f"; cat "$f"; echo; }; done
  echo "== marker .pane-question-task"; cat "$state/.pane-question-task" 2>/dev/null
  echo "== drain"; FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" 2>&1 | head -20 || true
} >> "$out/result.txt"
wakes=$(grep -c 'decision-pending task.turn-ended' "$state/.wake-queue" 2>/dev/null); nudges=$(grep -l 'Your last turn ended on a question' "$state"/task.inbox/*.msg 2>/dev/null | wc -l)
echo "SUMMARY $name decision-pending-wakes=${wakes:-0} nudges=$nudges" | tee -a "$out/result.txt"
echo "$state" > "$out/state-dir"
