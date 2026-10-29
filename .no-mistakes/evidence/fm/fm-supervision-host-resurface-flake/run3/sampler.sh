#!/bin/bash
E=/home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run3
U=fm-suphost-focus3-4098539.scope
CG=/sys/fs/cgroup/user.slice/user-1001.slice/user@1001.service/app.slice/$U
while [ -d "$CG" ]; do
  ok=$(grep -c '^ok' $E/output.log 2>/dev/null); t=$(cat $CG/pids.current 2>/dev/null)
  w=$(cat $CG/cgroup.procs 2>/dev/null | xargs -r -I{} cat /proc/{}/cmdline 2>/dev/null | tr '\0' ' ' | grep -oE 'fm-(watch|supervision-host)[a-z-]*\.sh' | wc -l)
  echo "t=$(date +%s) ok=$ok tasks=$t watcher_or_host_procs=$w load=$(cut -d' ' -f1 /proc/loadavg)"
  sleep 5
done
echo "scope_gone t=$(date +%s)"
