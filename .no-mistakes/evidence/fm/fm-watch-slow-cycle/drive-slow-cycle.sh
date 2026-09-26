#!/usr/bin/env bash
# drive-slow-cycle.sh <repo-root> <label> <n-checks> <seconds-per-check> <sample-seconds> [check-timeout]
# Runs the real bin/fm-watch.sh against a throwaway FM_HOME whose first cycle
# runs <n-checks> trusted custom checks, each sleeping <seconds-per-check>
# (a scaled-down stand-in for a loaded host). Samples the beacon age every
# 0.5 s and prints a timeline plus the maximum age seen while the cycle ran.
set -u
root=$1 label=$2 n=$3 per=$4 sample=$5 ctimeout=${6:-30}
work=$(mktemp -d /tmp/fm-slowcycle.XXXX)
home="$work/home"; state="$home/state"
mkdir -p "$state" "$home/config" "$home/data"
for i in $(seq 1 "$n"); do
  c="$state/slow$i.check.sh"
  printf '#!/usr/bin/env bash\nsleep %s\n' "$per" > "$c"
  chmod 700 "$c"
  printf 'fm-custom-check-v1\n%s\n' "$(sha256sum "$c" | awk '{print $1}')" > "$state/slow$i.check-trust"
  chmod 600 "$state/slow$i.check-trust"
done
trace="$work/trace.log"
FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=300 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT="$ctimeout" FM_HEARTBEAT=999999 \
  FM_WATCH_TRACE="$trace" "$root/bin/fm-watch.sh" > "$work/watch.out" 2> "$work/watch.err" &
wp=$!
t0=$(date +%s.%N); max=0
echo "== $label: $n checks x ${per}s, check-timeout ${ctimeout}s, watcher pid $wp =="
end=$(( $(date +%s) + sample ))
while [ "$(date +%s)" -lt "$end" ]; do
  if [ -e "$state/.last-watcher-beat" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$state/.last-watcher-beat") ))
    [ "$age" -gt "$max" ] && max=$age
    ran=$(ls "$state"/slow*.check.sh 2>/dev/null | wc -l)
    printf 't=%5.1fs beacon_age=%ss alive=%s\n' "$(echo "$(date +%s.%N) - $t0" | bc)" "$age" \
      "$(kill -0 $wp 2>/dev/null && echo yes || echo no)"
  fi
  sleep 1
done
echo "MAX beacon age during run: ${max}s"
if [ -s "$trace" ]; then echo "-- FM_WATCH_TRACE step log (epoch pid step) --"; cat "$trace"; else echo "-- no FM_WATCH_TRACE output (hook absent in this build) --"; fi
kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
rm -rf "$work"
