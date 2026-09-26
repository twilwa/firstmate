#!/usr/bin/env bash
# drive-per-report.sh <repo-root> <label> <n-reports> <capture-delay-s> <sample-s>
# Real fm-watch.sh supervising <n-reports> direct-report windows that live in a
# PRIVATE real tmux server (TMUX_TMPDIR scoped to a throwaway dir; the default
# server is never touched). A PATH shim adds <capture-delay-s> of latency before
# delegating each `tmux capture-pane` to the real tmux, modelling a loaded host
# where every per-report inspection is slow. Samples beacon age every second.
# WITH_STATUS=1 also seeds fresh .status files (drives the signal-triage path).
set -u
root=$1 label=$2 n=$3 delay=$4 sample=$5
real_tmux=$(type -P tmux)
work=$(mktemp -d /tmp/fm-perrep.XXXX); home="$work/home"; state="$home/state"
mkdir -p "$state" "$home/config" "$home/data" "$work/shim" "$work/tmux"
export TMUX_TMPDIR="$work/tmux"; unset TMUX
cat > "$work/shim/tmux" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = capture-pane ] && sleep $delay
exec "$real_tmux" "\$@"
SH
chmod +x "$work/shim/tmux"
"$real_tmux" new-session -d -s lab -n fm-r1 "printf 'report r1 working\n'; sleep 1000"
for i in $(seq 2 "$n"); do "$real_tmux" new-window -t lab -n "fm-r$i" "printf 'report r$i working\n'; sleep 1000"; done
for i in $(seq 1 "$n"); do
  printf 'window=lab:fm-r%s\nkind=ship\nbackend=tmux\n' "$i" > "$state/r$i.meta"
  [ -n "${WITH_STATUS:-}" ] && printf "working [at=%s]: task r%s\n" "$(date +%s)" "$i" > "$state/r$i.status"
done
echo "== $label: $n direct reports in private tmux ($TMUX_TMPDIR), capture latency ${delay}s =="
"$real_tmux" list-windows -t lab -F '  tmux window #{window_name}'
trace="$work/trace.log"
PATH="$work/shim:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=300 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRACE="$trace" \
  "$root/bin/fm-watch.sh" > "$work/watch.out" 2> "$work/watch.err" &
wp=$!; max=0
for s in $(seq 1 "$sample"); do
  sleep 1
  [ -e "$state/.last-watcher-beat" ] || continue
  age=$(( $(date +%s) - $(stat -c %Y "$state/.last-watcher-beat") )); [ "$age" -gt "$max" ] && max=$age
  printf 't=%2ss beacon_age=%ss alive=%s\n' "$s" "$age" "$(kill -0 $wp 2>/dev/null && echo yes || echo no)"
done
echo "MAX beacon age during run: ${max}s"
if [ -s "$trace" ]; then echo "-- FM_WATCH_TRACE (epoch pid step) --"; cat "$trace"; else echo "-- no FM_WATCH_TRACE output --"; fi
echo "-- watcher stderr (tail) --"; tail -5 "$work/watch.err"
kill $wp 2>/dev/null; wait $wp 2>/dev/null
"$real_tmux" kill-server 2>/dev/null
rm -rf "$work"
