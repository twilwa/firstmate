#!/usr/bin/env bash
# Live probe (test-step evidence, not a repository test): the real
# bin/fm-watch.sh, at the DEFAULT FM_WEDGE_MAX_ESCALATIONS (unset), polls a real
# tmux pane on a lab-private socket. The pane is a live "claude" process in an
# over-age busy turn whose only output is a footer that ticks every second.
# Expected: escalations climb to the default bound 3, the third carries
# PERMANENTLY-WEDGED, and later polls stay silent even though the pane hash
# keeps changing (the ticking footer must not release the cap).
# Usage: probe-default-cap-ticking-footer.sh <repo-root> <transcript>
set -u
ROOT=$1
TRANSCRIPT=$2
: > "$TRANSCRIPT"
for v in FM_WEDGE_MAX_ESCALATIONS NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE \
  FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX; do unset "$v"; done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-probe.XXXXXX")
LAB="$TMP/lab-home"
LAB_SOCKET=''
cleanup() {
  [ -z "$LAB_SOCKET" ] || tmux -S "$LAB_SOCKET" kill-server >/dev/null 2>&1 || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$TRANSCRIPT"; }
die() { say "PROBE FAIL: $1"; exit 1; }

say "probe: default wedge cap vs ticking busy footer; watcher $(cd "$ROOT" && git rev-parse --short HEAD)"
say "FM_WEDGE_MAX_ESCALATIONS in probe env: ${FM_WEDGE_MAX_ESCALATIONS-<unset, shipped default>}"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || die "lab home create failed"
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || die "lab tmux dir failed"
export TMUX_TMPDIR="$TD"
LAB_SOCKET="$TD/tmux-$(id -u)/default"
mkdir -p "$(dirname "$LAB_SOCKET")"; chmod 700 "$(dirname "$LAB_SOCKET")"
STATE="$LAB/state"
TASK=ticking-worker

AGENT="$TMP/ticking-claude"
cat > "$AGENT" <<'AGENT'
#!/usr/bin/env bash
printf 'claude> running tool call that never returns\n'
i=1
while :; do printf '\r  * Working... (%ds, esc to interrupt)' "$i"; i=$((i + 1)); sleep 1; done
AGENT
chmod +x "$AGENT"
tmux -S "$LAB_SOCKET" new-session -d -s lab -n ticking -x 120 -y 40 "$AGENT" || die "tmux start failed"
WINDOW=lab:ticking
printf 'window=%s\nbackend=tmux\nharness=claude\nkind=ship\n' "$WINDOW" > "$STATE/$TASK.meta"
printf 'working: implementing\n' > "$STATE/$TASK.status"
FM_HOME="$LAB" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$LAB" "$TASK.status"
printf 'g1\n' > "$STATE/$TASK.busy-gen"
printf 'v1 gen=g1 seq=1 state=busy source=fm-spawn event=turn_start ts=%s\n' "$(date +%s)" > "$STATE/$TASK.busy-state"
touch -d '5 seconds ago' "$STATE/$TASK.meta"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
say "lab home $LAB, real tmux pane $WINDOW on $LAB_SOCKET (key=$KEY)"

cycle=0; WOKE=0
pane_md5() { tmux -S "$LAB_SOCKET" capture-pane -p -t "$WINDOW" -S -40 | md5sum | cut -c1-12; }
watcher_cycle() {  # <label>
  local out pid i reason
  cycle=$((cycle + 1)); out="$TMP/cycle-$cycle.out"
  FM_HOME="$LAB" TMUX_TMPDIR="$TD" FM_CAP_HORIZON_SECS=600 FM_STALE_ESCALATE_SECS=2 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_BUSY_TURN_MAX_SECS=1 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  i=0; while [ $i -lt 300 ] && kill -0 $pid 2>/dev/null && [ ! -s "$STATE/.last-watcher-beat" ]; do sleep 0.1; i=$((i+1)); done
  i=0; while [ $i -lt 80 ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  rm -f "$STATE/.last-watcher-beat"
  reason=$(head -1 "$out")
  if [ -n "$reason" ]; then WOKE=1; else WOKE=0; fi
  say "cycle $cycle [$1] pane-md5=$(pane_md5) esc-count=$(cat "$STATE/.wedge-escalations-$KEY" 2>/dev/null || echo -) cap-marker=$([ -e "$STATE/.wedge-permanent-$KEY" ] && echo present || echo absent) woke=$WOKE reason=${reason:-none}"
  FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
}

wakes=0; terminal=0
for n in 1 2 3 4 5; do
  watcher_cycle "climb $n"
  [ $WOKE -eq 0 ] || wakes=$((wakes + 1))
  if grep -q PERMANENTLY-WEDGED "$TMP/cycle-$cycle.out"; then terminal=$((terminal + 1)); break; fi
done
[ $terminal -eq 1 ] || die "default cap never fired PERMANENTLY-WEDGED within 5 cycles"
grep -o 'wedge [^;]*escalation [0-9]*[^;]*' "$TMP/cycle-$cycle.out" | head -1 | sed 's/^/  terminal wake detail: /' | tee -a "$TRANSCRIPT"
say "default cap fired after $wakes wake(s) (expected bound 3)"
[ -e "$STATE/.wedge-permanent-$KEY" ] || die "cap marker missing after fire"
h_before=$(pane_md5); silent=0
for n in 1 2 3; do
  sleep 2
  watcher_cycle "post-cap silence probe $n"
  [ $WOKE -eq 0 ] || die "still-wedged ticking pane re-woke after the default cap (probe $n)"
  [ -e "$STATE/.wedge-permanent-$KEY" ] || die "ticking footer released the cap marker (probe $n)"
  silent=$((silent + 1))
done
h_after=$(pane_md5)
[ "$h_before" != "$h_after" ] || die "pane hash did not change; footer was not ticking, probe proves nothing"
say "RESULT PASS: default cap bound=$wakes wakes, 1 PERMANENTLY-WEDGED, then $silent silent polls with cap marker held while pane md5 changed $h_before -> $h_after"
