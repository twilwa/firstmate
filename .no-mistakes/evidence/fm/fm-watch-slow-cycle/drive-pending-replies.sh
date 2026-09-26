#!/usr/bin/env bash
# drive-pending-replies.sh <repo-root> <label> <n-historical>
# Builds a throwaway home whose state/pending-replies holds <n-historical>
# resolved records (half escalated-and-already-closed, half never escalated)
# plus ONE resolved record whose escalation is still open (the transient-failure
# retry case). Runs one real fm-watch.sh cycle and reports: how long the
# pending-replies step took, and whether the open escalation converged closed.
set -u
root=$1 label=$2 n=$3
work=$(mktemp -d /tmp/fm-prdrive.XXXX); home="$work/home"; state="$home/state"
mkdir -p "$state/pending-replies" "$home/config" "$home/data"
FM_PENDING_REPLY_NOW=4725 bash -c '. "$1/bin/fm-pending-reply-lib.sh"
  c=$(fm_pending_reply_create "$2" "$2/state" hibit "open escalation retry")
  fm_pending_reply_mark_delivered "$2/state" "$c"
  r=$(fm_pending_reply_path "$2/state" "$c")
  fm_pending_reply_set "$r" escalated_epoch 4700
  fm_pending_reply_set "$r" resolved_epoch 4720
  fm_pending_reply_set "$r" phase resolved
  printf "%s\n" "$c" > "$2/open-corr"' _ "$root" "$home"
open=$(cat "$home/open-corr")
printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=hibit pending-reply-id=%s request=open escalation retry\n' \
  "$open" "$open" > "$state/hibit.status"
tmpl="$state/pending-replies/$open"
for i in $(seq 1 "$n"); do
  id=$(printf 'h%015x' "$i"); f="$state/pending-replies/$id"
  sed -e "s/^corr_id=.*/corr_id=$id/" -e 's/^task_id=.*/task_id=old/' "$tmpl" > "$f"
  if [ $((i % 2)) -eq 0 ]; then printf 'escalation_closed_epoch=4710\n' >> "$f"
  else sed -i 's/^escalated_epoch=4700$/escalated_epoch=/' "$f"; fi
done
cp "$state/hibit.status" "$work/status.before"
echo "== $label: $n historical resolved records + 1 resolved-with-open-escalation =="
echo "open escalation before cycle: $(bash -c '. "$1/bin/fm-status-lib.sh" 2>/dev/null; . "$1/bin/fm-pending-reply-lib.sh"; status_open_decisions "$2"' _ "$root" "$state/hibit.status" | cut -f1)"
trace="$work/trace.log"; : > "$trace"
FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=300 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 FM_WATCH_TRACE="$trace" "$root/bin/fm-watch.sh" > "$work/watch.out" 2> "$work/watch.err" &
wp=$!
t0=$(date +%s.%N)
for _ in $(seq 1200); do grep -q ' secondmate-liveness$' "$trace" && break
  [ -n "$(grep -s '^escalation_closed_epoch=.' "$tmpl")" ] && [ ! -s "$trace" ] && break; sleep 0.1; done
for _ in $(seq 600); do [ -n "$(grep -s '^escalation_closed_epoch=.' "$tmpl")" ] && break; sleep 0.1; done
t1=$(date +%s.%N)
if [ -s "$trace" ]; then
  s=$(awk '$3=="reconcile-requests"{print $1}' "$trace"); e=$(awk '$3=="pending-replies"{print $1}' "$trace")
  echo "pending-replies step (FM_WATCH_TRACE epochs): $((e - s))s"
else
  printf 'no trace hook in this build; watcher start -> escalation closed: %.1fs\n' "$(echo "$t1 - $t0" | bc)"
fi
echo "escalation_closed_epoch on open record after cycle: '$(grep '^escalation_closed_epoch=' "$tmpl" | tail -1 | cut -d= -f2-)'"
echo "-- hibit.status lines appended by the watcher --"; diff "$work/status.before" "$state/hibit.status" | sed -n 's/^> /  /p'
echo "historical closed records untouched: $(grep -l '^escalation_closed_epoch=4710$' "$state"/pending-replies/h* | wc -l)/$((n/2)) still closed at 4710; lock files left: $(ls -A "$state" | grep -c '^\.pending-reply-.*\.lock' || true)"
kill $wp 2>/dev/null; wait $wp 2>/dev/null; rm -rf "$work"
