#!/bin/bash
cd /home/firstmate/.no-mistakes/worktrees/8be14fbb8fb5/01M625AZYW97Z6V19RD7QP18TG
export XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
date -Is > /home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run4/start; s=$(date +%s.%N)
systemd-run --user --scope --unit=fm-suphost-run4-416573.scope -p TasksMax=512 -p MemoryMax=2G -p MemorySwapMax=0 -p RuntimeMaxSec=2700 -- bash bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1800 --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' --json /home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run4/run.json tests/fm-supervision-host.test.sh > /home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run4/output.log 2>&1
rc=$?; e=$(date +%s.%N); date -Is > /home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run4/end; echo $rc > /home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run4/exit-code
echo "wall_seconds=$(echo "$e - $s" | bc)" > /home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run4/wall-time; cat /proc/loadavg > /home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run4/loadavg-end.txt
