#!/usr/bin/env bash
# drive-arm-midcycle.sh <repo-root> <label>
# Live reproduction of the incident at scaled time: a real fm-watch.sh cycle
# whose first custom check ages the beacon past the 300 s floor (touch -t, i.e.
# "this cycle has already been running > 300 s") and completes, then a second
# check keeps the SAME cycle busy for 25 s. While that alive-but-slow cycle is
# still running, run the real bin/fm-watch-arm.sh the Stop-hook auto-arm uses,
# with its default poll-derived grace (FM_POLL=20 -> 300 s).
set -u
root=$1 label=$2
work=$(mktemp -d /tmp/fm-armmid.XXXX); home="$work/home"; state="$home/state"
mkdir -p "$state" "$home/config" "$home/data"
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$state/$1.check.sh"; chmod 700 "$state/$1.check.sh"
  printf 'fm-custom-check-v1\n%s\n' "$(sha256sum "$state/$1.check.sh" | awk '{print $1}')" > "$state/$1.check-trust"; chmod 600 "$state/$1.check-trust"; }
mk a-aged "touch -t 200001010000 '$state/.last-watcher-beat'; touch '$state/aged'"
mk b-slow "touch '$state/slow-started'; sleep 25"
FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=20 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 "$root/bin/fm-watch.sh" > "$work/watch.out" 2> "$work/watch.err" &
wp=$!
for _ in $(seq 100); do [ -e "$state/slow-started" ] && break; sleep 0.1; done
sleep 2
echo "== $label =="
echo "watcher pid $wp alive=$(kill -0 $wp 2>/dev/null && echo yes || echo no), mid-cycle inside b-slow check"
echo "beacon age now: $(( $(date +%s) - $(stat -c %Y "$state/.last-watcher-beat") ))s  (derived grace: $(FM_POLL=20 bash -c ". '$root/bin/fm-wake-lib.sh'; fm_poll_derived_grace"))"
echo "--- fm-watch-arm.sh (FM_POLL=20, FM_GUARD_GRACE unset -> derived) ---"
FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=20 FM_ARM_CONFIRM_TIMEOUT=3 \
  timeout 12 "$root/bin/fm-watch-arm.sh" > "$work/arm.out" 2>&1 &
ap=$!
for _ in $(seq 60); do grep -q 'watcher:' "$work/arm.out" && break; kill -0 $ap 2>/dev/null || break; sleep 0.1; done
sleep 0.5
cat "$work/arm.out"
kill $ap $wp 2>/dev/null; wait 2>/dev/null
rm -rf "$work"
