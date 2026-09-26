#!/usr/bin/env bash
# A live watcher completing slow work must renew its beacon before the next wait.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

work=$(fm_test_tmproot fm-watch-beacon)
trap 'if [ -n "${watch_pid:-}" ]; then kill "$watch_pid" 2>/dev/null || true; wait "$watch_pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
home="$work/home"
state="$home/state"
mkdir -p "$state" "$home/config" "$home/data"
check="$state/slow.check.sh"
cat > "$check" <<EOF
#!/usr/bin/env bash
touch "$state/check-started"
touch -t 200001010000 "$state/.last-watcher-beat"
sleep 2
touch "$state/check-finished"
EOF
chmod 700 "$check"
if type -P shasum >/dev/null 2>&1; then
  hash=$(shasum -a 256 "$check" | awk '{print $1}')
else
  hash=$(sha256sum "$check" | awk '{print $1}')
fi
printf 'fm-custom-check-v1\n%s\n' "$hash" > "$state/slow.check-trust"
chmod 600 "$state/slow.check-trust"

FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$work/watch.out" 2> "$work/watch.err" &
watch_pid=$!
i=0
while [ ! -e "$state/check-finished" ] && [ "$i" -lt 120 ]; do
  kill -0 "$watch_pid" 2>/dev/null || fail "watcher exited before slow check completed: $(cat "$work/watch.err")"
  sleep 0.1
  i=$((i + 1))
done
[ -e "$state/check-finished" ] || fail 'custom check never finished'
# The check aged the beacon beyond the 300-second grace while its watcher was
# alive. A completed step must renew it before the arm performs its strict test.
i=0
while [ "$i" -lt 60 ]; do
  FM_STATE_OVERRIDE="$state" FM_HOME="$home" FM_GUARD_GRACE=300 \
    bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state" "$ROOT/bin/fm-watch.sh" "$home" \
    && break
  sleep 0.1
  i=$((i + 1))
done
[ "$i" -lt 60 ] || fail 'completed slow check left a stale beacon'
FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 \
  FM_POLL=1 FM_ARM_CONFIRM_TIMEOUT=3 "$ROOT/bin/fm-watch-arm.sh" > "$work/arm.out" 2>&1 &
arm_pid=$!
i=0
while [ "$i" -lt 100 ]; do
  rg -q 'watcher: attached pid=' "$work/arm.out" && break
  kill -0 "$arm_pid" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
rg -q 'watcher: attached pid=' "$work/arm.out" \
  || fail "auto-arm refused the live watcher: $(cat "$work/arm.out")"
printf 'working [at=%s]: test signal\n' "$(date +%s)" > "$state/probe.status"
wait "$arm_pid" || fail "attached arm did not deliver wake: $(cat "$work/arm.out")"
pass 'slow completed step refreshes beacon and arm attaches to the live watcher'
