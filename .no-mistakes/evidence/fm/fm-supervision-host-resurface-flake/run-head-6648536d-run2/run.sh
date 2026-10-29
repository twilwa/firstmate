#!/bin/bash
cd /home/firstmate/.no-mistakes/worktrees/8be14fbb8fb5/01M625AZYW97Z6V19RD7QP18TG
s=$(date +%s.%N)
XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus systemd-run --user --scope --unit=fm-shost-run2-1793231711 -p RuntimeMaxSec=2700 -- bash bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1800 --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' tests/fm-supervision-host.test.sh > /home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run-head-6648536d-run2/output.log 2>&1
rc=$?
e=$(date +%s.%N)
echo "exit=$rc start=$s end=$e wall=$(echo "$e - $s" | bc)s (1800s per-file deadline unchanged; unconstrained scope, RuntimeMaxSec=2700 only)" > /home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run-head-6648536d-run2/result.txt
