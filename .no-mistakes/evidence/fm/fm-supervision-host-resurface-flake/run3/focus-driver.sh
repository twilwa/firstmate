#!/bin/bash
# Focused live run on HEAD: budget-handoff cases + resurface (park_after_stop) case, constrained scope.
cd /home/firstmate/.no-mistakes/worktrees/8be14fbb8fb5/01M625AZYW97Z6V19RD7QP18TG
E=/home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run3
export XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
date -Is > $E/start; s=$(date +%s.%N)
systemd-run --user --scope --unit=fm-suphost-focus3-$$ -p TasksMax=512 -p MemoryMax=2G -p MemorySwapMax=0 -p RuntimeMaxSec=2700 -- \
  bash bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1800 --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' --json $E/run.json tests/zz-focus-tmp-fm-supervision-host.test.sh > $E/output.log 2>&1
echo $? > $E/exit-code; e=$(date +%s.%N); date -Is > $E/end
echo "wall_seconds=$(echo "$e - $s" | bc)" > $E/wall-time
