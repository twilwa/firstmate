#!/usr/bin/env bash
# Serial runner for the Test step: waits for the wedge-cap script to exit, then
# runs each remaining item one at a time in its own bounded systemd user scope.
set -u
WT={run-worktree}
E=~/.no-mistakes/evidence/01M6HQNX1AHCCCJRCH3X79VBD4
cd "$WT" || exit 1
while ! grep -q '^exit=' "$E/fm-watch-wedge-cap.log"; do sleep 5; done
scope() {  # <name> <runtime-secs> <log> <cmd...>
  local name=$1 secs=$2 log=$3 s; shift 3
  s=$(date +%s)
  systemd-run --user --scope --quiet --unit="nm-test-$name-$$" -p TasksMax=512 -p MemoryMax=2G \
    -p MemorySwapMax=0 -p RuntimeMaxSec="$secs" "$@" > "$log" 2>&1
  echo "exit=$? elapsed=$(( $(date +%s) - s ))s" >> "$log"
  echo "$(date +%H:%M:%S) $name $(tail -1 "$log")" >> "$E/serial-runner.status"
}
scope probe-send-park 300 "$E/probe-send-park.log" bash "$E/probe-send-park.sh" "$WT" "$E/probe-send-park.transcript.txt"
scope probe-stuck-busy 600 "$E/probe-stuck-busy.log" bash "$E/probe-stuck-busy.sh" "$WT" "$E/probe-stuck-busy.transcript.txt"
scope parity 900 "$E/fm-watch-wedge-cap-unconfigured-parity.log" bash tests/fm-watch-wedge-cap-unconfigured-parity.test.sh
scope resolve-key 900 "$E/fm-send-resolve-key.log" bash tests/fm-send-resolve-key.test.sh
scope task-inbox 900 "$E/fm-task-inbox.log" bash tests/fm-task-inbox.test.sh
if [ -e "$E/approve-ticking-probe" ]; then
  scope probe-ticking 600 "$E/probe-default-cap-ticking-footer.log" bash "$E/probe-default-cap-ticking-footer.sh" "$WT" "$E/probe-default-cap-ticking-footer.transcript.txt"
fi
echo "$(date +%H:%M:%S) DONE" >> "$E/serial-runner.status"
